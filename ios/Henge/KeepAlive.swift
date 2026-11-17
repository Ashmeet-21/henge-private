import AVFAudio
import Foundation
import UIKit

/// Keeps iOS from suspending Henge while a Mac is open or macOS is installing.
///
/// A suspended app is the first thing iOS closes when it wants memory, and Henge holds a lot of it: leaving for a
/// message used to cost the running Mac, and the screen locking used to end an install. An app that is playing
/// audio is not suspended and is closed after every suspended app, so while there is something to lose Henge plays
/// silence (the audio background mode and the playback session were there already, for the Mac's sound). It mixes
/// with other apps' audio and stops as soon as no Mac is open and nothing installs.
///
/// A running Mac does not run on in the background: it waits, paused (InstantResume.rest), so a phone in a pocket
/// stays cool and the GPU, which is not Henge's there, is left alone. An install cannot be paused and goes on.
@MainActor
enum KeepAlive {
    static let key = "henge.keepAlive"
    /// On unless turned off in Settings.
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?
    private static var timer: Timer?
    private static var pressure: DispatchSourceMemoryPressure?
    private static var playing = false

    /// Something iOS closing Henge would lose: a Mac running, starting, stopping or paused, or an install.
    private static var needed: Bool {
        let s = henge_vm_state()
        return enabled && (s == 1 || s == 3 || s == 4 || Installer.shared.busy)
    }

    /// Once, at launch: follow what Henge is doing, and say in the log what iOS tells it about memory.
    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { update(); MemoryRelief.tick() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated {
                // A call or an alarm took the session: the silence stopped with it. Start again when it is over
                // (and try at once too: update() runs every 2 s until it works).
                HengeLog.log("keepalive", "audio interruption \(ended ? "ended" : "began")")
                playing = false
                if ended { update() }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                HengeLog.log("keepalive", "audio services were reset")
                teardown()
                update()
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { // headphones in or out: the engine stopped
                playing = false
                update()
            }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            HengeLog.log("memory", "iOS sent a memory warning; \(henge_available_memory() >> 20) MB left before Henge's limit")
            HengeLog.logFootprint("memory-warning")
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            HengeLog.log("app", "iOS is ending Henge (willTerminate)")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                update()
                HengeLog.log("keepalive", "in the background: \(playing ? "staying awake (silent audio)" : needed ? "could not stay awake" : "nothing to keep, iOS may suspend Henge"); \(henge_available_memory() >> 20) MB left before the limit")
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            HengeLog.log("keepalive", "back in the foreground")
        }
        // The system running short, whoever is using it: the lines before a kill say why, and the Mac is asked
        // to hand memory back (MemoryRelief) before iOS takes all of Henge's.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            let data = source.data
            let level = data.contains(.critical) ? 2 : data.contains(.warning) ? 1 : 0
            HengeLog.log("memory", "system memory pressure: \(["normal", "warning", "critical"][level]); \(henge_available_memory() >> 20) MB left before Henge's limit")
            HengeLog.logFootprint("pressure")
            MainActor.assumeIsolated { MemoryRelief.pressure(level) }
        }
        source.resume()
        pressure = source
        update()
    }

    private static func update() {
        let want = needed
        if want && !playing { play() }
        if !want && playing { stop() }
    }

    private static func play() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if engine == nil {
                let e = AVAudioEngine(), p = AVAudioPlayerNode()
                e.attach(p)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                e.connect(p, to: e.mainMixerNode, format: format)
                engine = e
                player = p
            }
            guard let engine, let player else { return }
            if !engine.isRunning { try engine.start() }
            let format = player.outputFormat(forBus: 0)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else { return }
            buffer.frameLength = buffer.frameCapacity // zeroed: a second of silence, over and over
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
            player.play()
            if !playing { HengeLog.log("keepalive", "on: Henge stays awake in the background while this goes on") }
            playing = true
        } catch {
            // Another app holds the session exclusively (a call): tried again in 2 s.
            if playing { HengeLog.log("keepalive", "lost: \(error.localizedDescription)") }
            playing = false
        }
    }

    private static func stop() {
        player?.stop()
        engine?.stop()
        playing = false
        HengeLog.log("keepalive", "off: nothing left to keep")
    }

    private static func teardown() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        playing = false
    }
}

/// When iOS runs short of memory, the Mac is asked to hand some of its own back (its memory balloon: macOS gives
/// up file cache and idle pages first, and Henge returns them to iOS), instead of iOS closing Henge with the Mac
/// in it. What a hypervisor does for a host under pressure. Given back slowly once the pressure is gone.
@MainActor
enum MemoryRelief {
    private static var targetMB = 0
    private static var lastPressure = Date.distantPast
    private static var lastEase = Date.distantPast
    private static var level = 0

    static func pressure(_ now: Int) {
        level = now
        guard now > 0, henge_vm_state() == 1 else { return }
        lastPressure = Date()
        let held = henge_vm_balloon(-1)
        guard held >= 0 else { return } // no balloon in this Mac
        // Half the Mac's memory at most: macOS itself needs the rest to stay up.
        let ram = Int(henge_vm_ram_mb()), most = max(ram / 2, 0)
        let want = min(max(targetMB, Int(held)) + (now == 2 ? 1024 : 512), most)
        guard want > targetMB else { return }
        targetMB = want
        _ = henge_vm_balloon(want)
        HengeLog.log("memory", "asking the Mac for \(want) MB of its \(ram) MB back (it had given \(held) MB)")
    }

    /// Every 2 s: with no pressure for two minutes, 256 MB goes back to the Mac each minute.
    static func tick() {
        guard targetMB > 0 else { return }
        guard henge_vm_state() == 1 || henge_vm_state() == 4 else { targetMB = 0; return } // that Mac is gone
        let now = Date()
        guard level == 0, now.timeIntervalSince(lastPressure) > 120, now.timeIntervalSince(lastEase) > 60 else { return }
        lastEase = now
        targetMB = max(targetMB - 256, 0)
        _ = henge_vm_balloon(targetMB)
        HengeLog.log("memory", "no pressure for a while: the Mac keeps \(targetMB) MB handed over")
    }
}

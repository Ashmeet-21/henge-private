import AVFAudio
import Foundation

/// A Mac that survives Henge going to the background (Home, another app, the phone locked).
///
/// Without this, iOS suspends Henge a few seconds after it leaves the screen, and soon closes it for its
/// memory: the Mac is gone, and so is JIT, which iOS gives once per launch. Henge has the audio background
/// mode, so a silent sound keeps it running. What the Mac does meanwhile is Settings' "In the background":
/// - Pause (the default): every CPU parks and sleeps, using no CPU at all, and the Mac's clock stops as a
///   real Mac's does asleep (core/dispatch.c hv_machine_hold), so macOS finds no time gone when it goes on.
/// - Keep running: each CPU may run a quarter of the time, for a download or a build. iOS runs no GPU work
///   for an app in the background, so what macOS draws meanwhile may need a redraw on return.
@MainActor
enum BackgroundKeeper {
    static let modeKey = "henge.background.mode"
    static let pause = "pause", keepRunning = "run"
    /// What each CPU may run while in the background in the Keep running mode, percent.
    static let runningPercent = 25
    static var keepsRunning: Bool { UserDefaults.standard.string(forKey: modeKey) == keepRunning }
    private(set) static var inBackground = false
    private static var engine: AVAudioEngine?
    private static var observing = false

    /// The scene left the foreground. Inactive comes first, while iOS still lets an app start its sound, so the
    /// silence starts then; the Mac is paused (or slowed) only once Henge is really in the background.
    static func leaving(toBackground: Bool) {
        guard henge_vm_state() == 1 else { return }
        startSilence()
        guard toBackground, !inBackground else { return }
        inBackground = true
        if keepsRunning {
            ThermalGovernor.apply()
            HengeLog.log("background", "in the background: the Mac keeps running, each CPU at most \(runningPercent)% of the time")
        } else {
            henge_vm_set_hold(1)
            HengeLog.log("background", "in the background: the Mac is paused (no CPU used, its clock stopped)")
        }
    }

    /// Back on screen.
    static func becameActive() {
        stopSilence()
        guard inBackground else { return }
        inBackground = false
        henge_vm_set_hold(0)
        ThermalGovernor.apply()
        HengeLog.log("background", "back on screen: the Mac goes on")
    }

    /// The session closed (the Mac stopped, or the view went away).
    static func sessionEnded() {
        let wasInBackground = inBackground
        inBackground = false
        henge_vm_set_hold(0)
        stopSilence()
        if wasInBackground { ThermalGovernor.apply() }
    }

    private static func startSilence() {
        observe()
        if let engine {
            if !engine.isRunning { restart() }
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // As at launch (HengeApp): playback, mixed, so the user's own music keeps playing.
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            HengeLog.log("background", "audio session refused: \(error.localizedDescription)")
        }
        let e = AVAudioEngine()
        let source = makeSilentSource()
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: source.outputFormat(forBus: 0))
        do {
            try e.start()
            engine = e
            HengeLog.log("background", "silent sound on, so iOS keeps Henge running")
        } catch {
            HengeLog.log("background", "silent sound failed: \(error.localizedDescription); iOS may suspend Henge")
        }
    }

    private static func stopSilence() {
        engine?.stop()
        engine = nil
    }

    private static func restart() {
        guard let engine, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do { try engine.start() } catch {
            HengeLog.log("background", "silent sound did not restart: \(error.localizedDescription)")
        }
    }

    /// A call or Siri stops the sound; it is started again when they are done, and after a route change.
    private static func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            Task { @MainActor in restart() }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            Task { @MainActor in restart() }
        }
    }

    /// Zeros, 48 kHz stereo. Made outside the main actor: the block runs on the audio thread.
    nonisolated private static func makeSilentSource() -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, _, buffers -> OSStatus in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
}

import Foundation
import UIKit

/// Hands the Mac's memory back to iOS when iOS needs it, through the virtio memory balloon
/// (devices/virtio_balloon.c, macOS's AppleVirtIOBalloon driver). The Mac's RAM is real memory on the device;
/// without this, the only way iOS gets it back is closing Henge, and the Mac with it.
/// - Before Henge is paused in the background, macOS is asked for a quarter of its memory (it hands over free
///   pages first, then drops caches), and given a few seconds to do it. Back on screen, it gets it all back.
/// - On an iOS memory warning while on screen, 256 MB more is asked, up to a third, and given back two minutes
///   after the last warning.
/// Settings > Performance > "Give memory back to iOS" turns it off (no balloon device in the Mac at all).
@MainActor
enum MemoryGiver {
    static let enabledKey = "henge.perf.giveMemoryBack"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Asked back before the Mac pauses in the background, percent of its memory.
    static let backgroundPercent = 25
    /// Per memory warning, and the most warnings may take, percent of the Mac's memory.
    static let warningStepMB = 256
    static let warningCapPercent = 33
    /// How long the Mac gets to hand memory over before it is paused.
    static let backgroundWaitSeconds = 4.0
    static let releaseAfterSeconds: UInt64 = 120

    private static var backgroundMB = 0
    private static var warningMB = 0
    private static var askedMB = 0
    private static var release: Task<Void, Never>?
    private static var observing = false

    /// A balloon in the running Mac (the setting was on when it started).
    static var available: Bool { henge_vm_state() == 1 && henge_vm_balloon(-1) >= 0 }
    private static var ramMB: Int { max(0, Int(henge_vm_balloon_ram_mb())) }
    private static var givenMB: Int { max(0, Int(henge_vm_balloon(-1))) }

    /// A Mac started.
    static func start() {
        backgroundMB = 0
        warningMB = 0
        askedMB = 0
        release?.cancel()
        observe()
        guard available else { return }
        HengeLog.log("memory", "balloon ready: up to \(ramMB * backgroundPercent / 100) MB of the Mac's \(ramMB) MB go back to iOS in the background")
    }

    /// Henge is going to the background. With wait, returns once the Mac has handed most of it over (or the time is up).
    static func leaving(wait: Bool) async {
        guard enabled, available else { return }
        backgroundMB = ramMB * backgroundPercent / 100
        ask()
        guard wait, backgroundMB > 0 else { return }
        let start = Date()
        while Date().timeIntervalSince(start) < backgroundWaitSeconds && givenMB < backgroundMB * 9 / 10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !BackgroundKeeper.inBackground { return } // back on screen meanwhile
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        HengeLog.log("memory", "the Mac handed over \(givenMB) of \(backgroundMB) MB in \(seconds) s")
    }

    /// Back on screen: the Mac gets its memory back (what a warning asked for stays out a while).
    static func backOnScreen() {
        guard backgroundMB > 0 else { return }
        backgroundMB = 0
        if available { ask() }
    }

    private static func memoryWarning() {
        guard enabled, available else { return }
        warningMB = min(warningMB + warningStepMB, ramMB * warningCapPercent / 100)
        HengeLog.log("memory", "iOS is short of memory: asking the Mac for \(max(warningMB, backgroundMB)) MB (it has handed over \(givenMB) MB)")
        ask()
        release?.cancel()
        release = Task { @MainActor in
            try? await Task.sleep(nanoseconds: releaseAfterSeconds * 1_000_000_000)
            guard !Task.isCancelled, available else { return }
            warningMB = 0
            ask()
        }
    }

    private static func ask() {
        let mb = max(backgroundMB, warningMB)
        guard mb != askedMB else { return }
        askedMB = mb
        _ = henge_vm_balloon(mb)
        HengeLog.log("memory", mb == 0 ? "the Mac gets all its memory back" : "asking the Mac to hand \(mb) MB back to iOS")
    }

    private static func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in memoryWarning() }
        }
    }
}

import Foundation
import UIKit

/// Instant resume: when Henge leaves the foreground the running Mac is stopped where it is and written to storage,
/// so opening it again picks up there in a few seconds, even if iOS closed Henge in between. Coming straight back
/// just lets it run on. The engine keeps a saved Mac only for its disk exactly as it was (host/snapshot.c) and uses a
/// file once; this side decides when to save, and says which build and settings a file belongs to.
enum InstantResume {
    static let key = "henge.instantResume"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Saving and running on take turns on one queue, never on the main thread: a save takes a few seconds.
    private static let queue = DispatchQueue(label: "henge.instant-resume", qos: .userInitiated)

    static func file(for mac: VirtualMac) -> URL { mac.directory.appendingPathComponent("resume.hsnap") }

    /// What a saved Mac is for: this build of Henge (a restored machine must meet the code that saved it), the Mac,
    /// and what it was started with. The engine adds the disk's own identity.
    static func ident(for mac: VirtualMac, ramMB: UInt64, cpus: Int) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["HengeBuildCommit"] as? String ?? "unstamped"
        let stamp = info["HengeBuildDate"] as? String ?? "?"
        return "Henge \(version) (\(build)) \(commit) \(stamp) mac \(mac.id.uuidString) ram \(ramMB) cpus \(cpus) "
            + "screen \(mac.screen.width)x\(mac.screen.height) retina \(mac.isRetina)"
    }

    /// A whole saved Mac for these settings, and when it was saved.
    static func saved(for mac: VirtualMac, ramMB: UInt64, cpus: Int) -> Date? {
        var at: Int64 = 0
        guard henge_vm_saved_ok(file(for: mac).path, ident(for: mac, ramMB: ramMB, cpus: cpus), nil, &at) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(at))
    }

    /// Whether a file is there at all (the Home screen's hint; the start checks it properly).
    static func hasSave(for mac: VirtualMac) -> Bool { FileManager.default.fileExists(atPath: file(for: mac).path) }

    /// The file, and a half-written one from a save iOS cut short (the engine writes beside it, then renames).
    static func discard(for mac: VirtualMac) {
        try? FileManager.default.removeItem(at: file(for: mac))
        try? FileManager.default.removeItem(at: mac.directory.appendingPathComponent("resume.hsnap.part"))
    }

    /// Henge went to the background with this Mac running: save it and leave it paused.
    static func suspend(_ mac: VirtualMac, ramMB: UInt64, cpus: Int) {
        guard enabled, henge_vm_state() == 1 else { return }
        let path = file(for: mac).path, id = ident(for: mac, ramMB: ramMB, cpus: cpus)
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Henge save") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        queue.async {
            let t0 = Date()
            var buffer = [CChar](repeating: 0, count: 256)
            let rc = henge_vm_suspend(path, id, &buffer, buffer.count)
            let took = String(format: "%.1f", Date().timeIntervalSince(t0))
            if rc == 0 {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                HengeLog.log("resume", "saved the Mac in \(took) s (\(ByteText.string(UInt64(max(bytes, 0)))))")
            } else {
                HengeLog.log("resume", "not saved after \(took) s: \(String(cString: buffer))")
            }
            DispatchQueue.main.async {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                task = .invalid
            }
        }
    }

    /// Back in the foreground before iOS closed Henge: the saved file is out of date the moment the Mac runs on.
    static func cameBack(_ mac: VirtualMac) {
        queue.async {
            guard henge_vm_state() == 4 else { return }
            discard(for: mac)
            HengeLog.log("resume", henge_vm_continue() == 0 ? "back: the Mac runs on" : "back: the Mac could not run on")
        }
    }
}

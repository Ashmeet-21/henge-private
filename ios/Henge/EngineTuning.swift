import Foundation

/// Engine settings, without a rebuild. Defaults below, then the Performance settings, then
/// Documents/henge-env.txt (KEY=VALUE per line, # comments), which overrides them all.
/// Applied before each Mac starts. Based on lemarlab/Henge's EngineTuning (PR #7).
/// Keeps the device from overheating: as iOS reports it warmer, each of the Mac's CPUs may run less of the
/// time (100, 85, 60, 40 percent). A little slower and steady, instead of iOS throttling everything to a crawl.
@MainActor
enum ThermalGovernor {
    static let enabledKey = "henge.perf.keepCool"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private(set) static var percent: Int = 100
    private static var started = false

    static func limit(for state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 100
        case .fair: return 85
        case .serious: return 60
        case .critical: return 40
        @unknown default: return 100
        }
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "cool"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "very hot"
        @unknown default: return "unknown"
        }
    }

    static func apply() {
        let state = ProcessInfo.processInfo.thermalState
        percent = enabled ? limit(for: state) : 100
        henge_vm_set_duty(Int32(percent))
        HengeLog.log("thermal", "\(name(state)): each CPU may run \(percent)% of the time")
    }

    /// Once a Mac is running.
    static func start() {
        apply()
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in apply() }
        }
    }
}

enum EngineTuning {
    static let superblocksKey = "henge.perf.superblocks"
    static let wfiSpinKey = "henge.perf.wfiSpin"
    static let fastFlushKey = "henge.perf.fastFlush"
    static let refreshKey = "henge.perf.hz"

    static func apply() {
        let d = UserDefaults.standard
        var env = [
            "HV_FLUSH": d.object(forKey: fastFlushKey) as? Bool == false ? "0" : "2", // 2: F_BARRIERFSYNC, 0: fsync
            "HV_WFI_SPIN": d.bool(forKey: wfiSpinKey) ? "50" : "0", // microseconds an idle CPU watches for work
            "HV_HZ": d.integer(forKey: refreshKey) == 30 ? "30" : "60", // the refresh rate macOS draws at
        ]
        if d.bool(forKey: superblocksKey) { env["HV_SUPERBLOCKS"] = "1" } else { unsetenv("HV_SUPERBLOCKS") }
        unsetenv("HV_STATS")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let text = try? String(contentsOf: docs.appendingPathComponent("henge-env.txt"), encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
                env[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            setenv(k, v, 1)
            HengeLog.log("tuning", "\(k)=\(v)")
        }
    }
}

import Foundation

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
        var allowed = enabled ? limit(for: state) : 100
        // Running in the background (BackgroundKeeper's Keep running): a quarter at most, whatever the heat.
        if BackgroundKeeper.inBackground && BackgroundKeeper.keepsRunning { allowed = min(allowed, BackgroundKeeper.runningPercent) }
        percent = allowed
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

/// Engine settings, without a rebuild. Defaults below, then the Performance settings,
/// then Documents/henge-env.txt (KEY=VALUE per line, # comments) overrides them all.
/// Applied at launch and again before each Mac starts, so changes need no relaunch.
enum EngineTuning {
    static let refreshKey = "henge.perf.hz"
    static let superblocksKey = "henge.perf.superblocks"
    static let wfiSpinKey = "henge.perf.wfiSpin"
    static let fastFlushKey = "henge.perf.fastFlush"

    static let defaults: [String: String] = [
        // 60, not 120: every frame macOS draws is emulated and replayed, so 120 Hz
        // halves the CPU left for apps for animation few will notice.
        "HV_HZ": "60",         // the refresh rate macOS is told its display has
        "HV_WFI_SPIN": "0",    // microseconds an idle CPU watches for work before sleeping
        "HV_FLUSH": "2",       // disk flush: F_BARRIERFSYNC, ordered but without a full fsync
        "HV_STATS": "10",      // seconds between engine stats lines in the log; 0 = off
    ]

    static func apply() {
        var env = defaults
        let d = UserDefaults.standard
        switch d.integer(forKey: refreshKey) { case 120: env["HV_HZ"] = "120"; case 30: env["HV_HZ"] = "30"; default: break }
        if d.bool(forKey: superblocksKey) { env["HV_SUPERBLOCKS"] = "1" } else { unsetenv("HV_SUPERBLOCKS") }
        if d.bool(forKey: wfiSpinKey) { env["HV_WFI_SPIN"] = "50" }
        if d.object(forKey: fastFlushKey) as? Bool == false { env["HV_FLUSH"] = "0" }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // GPU command trace: on while Documents/trace-on exists (it is checked every frame, so it can be toggled live).
        env["HV_PVG_TRACE_FILE"] = docs.appendingPathComponent("trace-on").path
        let url = docs.appendingPathComponent("henge-env.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
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

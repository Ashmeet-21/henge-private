import Foundation

/// Engine settings, without a rebuild. Defaults below, then the Performance settings, then
/// Documents/henge-env.txt (KEY=VALUE per line, # comments), which overrides them all.
/// Applied before each Mac starts. Based on lemarlab/Henge's EngineTuning (PR #7).
enum EngineTuning {
    static let superblocksKey = "henge.perf.superblocks"
    static let wfiSpinKey = "henge.perf.wfiSpin"
    static let fastFlushKey = "henge.perf.fastFlush"

    static func apply() {
        let d = UserDefaults.standard
        var env = [
            "HV_FLUSH": d.object(forKey: fastFlushKey) as? Bool == false ? "0" : "2", // 2: F_BARRIERFSYNC, 0: fsync
            "HV_WFI_SPIN": d.bool(forKey: wfiSpinKey) ? "50" : "0", // microseconds an idle CPU watches for work
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

import Foundation

@main enum NativeTouchSessionTests {
    @MainActor static func main() {
        let suite = "NativeTouchSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var time: TimeInterval = 0
        let session = NativeTouchSession(defaults: defaults, now: { time })
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && hv_native_touch_status() == 0)
        session.requested = true
        precondition(NativeTouchSession(defaults: defaults).requested, "The choice must survive a new session")
        session.changedRequest()
        session.poll(active: true, helperRunning: false)
        precondition(session.status == 1 && hv_native_touch_status() == 0, "Wait for the guest helper before negotiating")
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 1 && !session.ready)
        let first = hv_native_touch_epoch()
        hv_native_touch_report(first, 2)
        session.poll(active: true, helperRunning: true)
        precondition(session.ready)
        session.poll(active: false, helperRunning: true)
        precondition(!session.ready && hv_native_touch_status() == 0)
        session.poll(active: true, helperRunning: true)
        precondition(hv_native_touch_epoch() != first)
        hv_native_touch_report(hv_native_touch_epoch(), 4)
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && session.status == 4)
        let failed = hv_native_touch_epoch()
        time = 100
        session.poll(active: true, helperRunning: true)
        precondition(hv_native_touch_epoch() == failed, "Failures must not cause a retry loop")
        session.requested = false
        precondition(!NativeTouchSession(defaults: defaults).requested, "Disabling native touch must also persist")
        session.changedRequest()
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && session.status == 0)
        session.requested = true
        session.changedRequest()
        session.poll(active: true, helperRunning: true)
        hv_native_touch_report(hv_native_touch_epoch(), 2)
        session.poll(active: true, helperRunning: true)
        precondition(session.ready)

        // Exercise the real transport watchdog; advance only the reconnect delay.
        Thread.sleep(forTimeInterval: 0.8)
        session.poll(active: true, helperRunning: true)
        precondition(!session.ready && session.status == 6)
        let timedOut = hv_native_touch_epoch()
        time += 1.9
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 6 && hv_native_touch_epoch() == timedOut, "Retries need a backoff")
        time += 0.2
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 1 && hv_native_touch_epoch() != timedOut, "A timeout must reconnect without toggling")
        hv_native_touch_report(hv_native_touch_epoch(), 2)
        session.poll(active: true, helperRunning: true)
        precondition(session.ready)
        session.poll(active: true, helperRunning: false)
        precondition(!session.ready && hv_native_touch_status() == 0, "Losing the helper must release native input")
        session.poll(active: true, helperRunning: true)
        precondition(session.status == 1)
        session.stop()
        precondition(!session.ready && hv_native_touch_status() == 0)
        precondition(NativeTouchSession(defaults: defaults).requested, "Stopping must preserve the choice")
        print("native touch session: persistence, delayed helper, suspend, fallback and automatic retry passed")
    }
}

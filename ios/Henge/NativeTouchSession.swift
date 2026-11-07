import Foundation
import Observation

/// Negotiates the optional guest companion. Trackpad remains the default and fallback.
@MainActor @Observable
final class NativeTouchSession {
    var requested = false {
        didSet { defaults.set(requested, forKey: Self.preferenceKey) }
    }
    private(set) var ready = false
    private(set) var status: Int32 = 0
    private static let preferenceKey = "nativeTouchRequested"
    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private var attempted = false
    private var wasActive = false
    private var retryAfter: TimeInterval?

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.now = now
        requested = defaults.bool(forKey: Self.preferenceKey)
    }

    func changedRequest() {
        stop()
        status = 0
    }

    func poll(active: Bool, helperRunning: Bool) {
        let wantsInput = requested && active
        if !wantsInput {
            if wasActive { stop() }
            wasActive = false
            return
        }
        wasActive = true
        // Booting the guest can take much longer than the negotiation timeout.
        guard helperRunning else {
            if attempted { stop() }
            wasActive = true
            status = 1
            return
        }
        if let retryAfter {
            guard now() >= retryAfter else { return }
            self.retryAfter = nil
            attempted = false
        }
        if !attempted {
            attempted = true
            hv_native_touch_enable(1)
        }
        status = hv_native_touch_status()
        ready = status == 2
        // Only transport timeouts are transient. Permission and device errors
        // remain visible until the user changes the setup or reconnects.
        if status == 6 { retryAfter = now() + 2 }
    }

    func stop() {
        hv_native_touch_enable(0)
        ready = false
        attempted = false
        wasActive = false
        retryAfter = nil
    }
}

import AppKit
import CoreHID
import IOKit.hid


@available(macOS 15, *)
actor NativeTouchDeviceDelegate: HIDVirtualDeviceDelegate {
    enum ReportError: Error { case unsupported }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws { throw ReportError.unsupported }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        guard type == .feature, id?.rawValue == 2, maxSize >= 1 else { throw ReportError.unsupported }
        let maximum = UInt8(NativeTouchFrame.maximumContacts)
        return maxSize == 1 ? Data([maximum]) : Data([2, maximum])
    }
}

@MainActor
@available(macOS 15, *)
final class SystemNativeTouchDevice: NativeTouchDevice {
    struct Slot {
        var finger: NativeTouchContact
        let hidID: UInt8
        var down = true
        var published = false
        var liftedAt: TimeInterval?
    }
    private var device: HIDVirtualDevice?
    private let delegate = NativeTouchDeviceDelegate()
    private var task: Task<Void, Never>?
    private var slots: [Slot?] = Array(repeating: nil, count: NativeTouchFrame.maximumContacts)
    private var pending: [[NativeTouchContact]] = []
    private var hadReport = false
    private var lastSentReport: Data?
    private var lastDownIDs = Set<UInt8>()
    private var transitionDeadline: TimeInterval = 0
    private let allowed: ([NativeTouchContact]) -> Bool = { $0.allSatisfy(\.isValid) && AXIsProcessTrusted() }
    var onFailure: ((String) -> Void)?

    func start(displayID: CGDirectDisplayID) async throws {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { throw CocoaError(.featureUnsupported) }
        let displayUUID = CFUUIDCreateString(nil, uuid) as String
        guard IOHIDCheckAccess(kIOHIDRequestTypePostEvent).rawValue == 0 else { throw CocoaError(.userCancelled) }
        guard let device = HIDVirtualDevice(properties: .init(descriptor: NativeTouchDescriptor.descriptor(),
            vendorID: 0x1209, productID: 0xD006, transport: .virtual,
            product: "Henge touchscreen", manufacturer: "Henge",
            uniqueID: UUID().uuidString,
            extraProperties: [kIOHIDDisplayIntegratedKey: NSNumber(value: true), "displayUUID": displayUUID as NSString])) else {
            throw CocoaError(.featureUnsupported)
        }
        self.device = device
        await device.activate(delegate: delegate)
        // Validate report dispatch before advertising readiness to the host.
        try await device.dispatchInputReport(data: report(), timestamp: .now)
    }

    func enqueue(_ contacts: [NativeTouchContact]) {
        guard contacts.count <= NativeTouchFrame.maximumContacts else { releaseAll(); return }
        // Neutral heartbeats do not need a report loop once every finger has lifted.
        if contacts.isEmpty && pending.isEmpty && slots.allSatisfy({ $0 == nil }) { return }
        if let last = pending.last, Set(last.map(\.id)) == Set(contacts.map(\.id)) {
            pending[pending.count-1] = contacts
        } else { pending.append(contacts) }
        if pending.count > 64 { releaseAll(); onFailure?("Input queue overflow; lift all fingers.") }
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            while !Task.isCancelled {
                do {
                    try await self.tick()
                    // Finish the lift/slot-retirement sequence before sleeping until new input.
                    if self.pending.isEmpty && !self.hadReport && self.slots.allSatisfy({ $0 == nil }) { return }
                    try await Task.sleep(for: .milliseconds(16))
                }
                catch is CancellationError { return }
                catch { self.releaseAll(); self.onFailure?(error.localizedDescription); return }
            }
        }
    }

    func releaseAll() {
        pending.removeAll()
        for index in slots.indices {
            guard var slot = slots[index] else { continue }
            if !slot.published { slots[index] = nil; continue }
            if slot.down { slot.down = false; slot.liftedAt = nil; slots[index] = slot }
        }
    }

    func stop() async {
        task?.cancel(); await task?.value; task = nil
        let remaining = transitionDeadline-ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        releaseAll()
        if let device {
            let lifted = report()
            if lifted != lastSentReport { try? await device.dispatchInputReport(data: lifted, timestamp: .now) }
            try? await Task.sleep(for: .milliseconds(70))
            slots = Array(repeating: nil, count: NativeTouchFrame.maximumContacts)
            try? await device.dispatchInputReport(data: report(), timestamp: .now)
        }
        device = nil; hadReport = false
    }

    private func tick() async throws {
        guard let device else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // AppKit needs time to consume each contact transition's change mask.
        guard now >= transitionDeadline else { return }
        for index in slots.indices {
            if let slot = slots[index], !slot.down, let lifted = slot.liftedAt, now-lifted >= 0.06 { slots[index] = nil }
        }
        if let desired = pending.first {
            if !allowed(desired) { releaseAll() }
            else {
                let new = desired.filter { finger in !slots.contains { $0?.finger.id == finger.id } }
                if new.count <= slots.filter({ $0 == nil }).count {
                    pending.removeFirst()
                    for index in slots.indices {
                        guard var slot = slots[index] else { continue }
                        if let finger = desired.first(where: { $0.id == slot.finger.id }), slot.down {
                            slot.finger = finger
                        } else if slot.down { slot.down = false; slot.liftedAt = nil }
                        slots[index] = slot
                    }
                    for finger in new {
                        if let free = slots.firstIndex(where: { $0 == nil }) {
                            slots[free] = Slot(finger: finger, hidID: UInt8(free + 1))
                        }
                    }
                }
            }
        }
        let down = slots.compactMap { $0 }.filter(\.down).map(\.finger)
        if !down.isEmpty && !allowed(down) { releaseAll() }
        let occupied = slots.contains { $0 != nil }
        if occupied || hadReport {
            let data = report()
            guard data != lastSentReport else { return }
            let downIDs = Set(slots.compactMap { $0 }.filter(\.down).map { $0.finger.id })
            for index in slots.indices where slots[index]?.down == true { slots[index]?.published = true }
            for index in slots.indices where slots[index]?.down == false && slots[index]?.liftedAt == nil { slots[index]?.liftedAt = now }
            try await device.dispatchInputReport(data: data, timestamp: .now)
            if downIDs != lastDownIDs { transitionDeadline = ProcessInfo.processInfo.systemUptime + 0.06 }
            lastDownIDs = downIDs; lastSentReport = data
            hadReport = occupied
        }
    }

    private func report() -> Data {
        var bytes: [UInt8] = [1]
        // Pack valid contacts first; gaps trigger AppKit's "Missing Touches" assertion.
        let occupied = slots.compactMap { $0 }
        for index in 0..<NativeTouchFrame.maximumContacts {
            if index < occupied.count {
                let slot = occupied[index]
                let x = UInt16((min(1,max(0,slot.finger.x))*32767).rounded())
                let y = UInt16((min(1,max(0,slot.finger.y))*32767).rounded())
                bytes += [slot.down ? 1 : 0, slot.hidID, UInt8(x&255), UInt8(x>>8), UInt8(y&255), UInt8(y>>8)]
            } else { bytes += Array(repeating: 0, count: 6) }
        }
        bytes.append(UInt8(occupied.count))
        return Data(bytes)
    }
}

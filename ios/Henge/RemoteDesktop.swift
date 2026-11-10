import Foundation
import Network
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

/// Remote desktop: the Mac's screen through the phone's hardware H.264 encoder to one client on port 5901,
/// as a raw Annex-B stream, and the client's mouse and keyboard back as 6-byte messages:
/// [type][a][x: Int16 LE][y: Int16 LE], type 1 move (x, y), 2 button (a, x = down), 3 scroll (x, y), 4 key (a = HID usage, x = down).
/// The client is tools/henge-remote.py; over USB, `iproxy 15901:5901` on the computer. `ffplay tcp://…` shows the picture alone.
/// Only USB clients by default. With Wi-Fi allowed, a network client must first send the 6-digit code shown on the phone.
final class RemoteDesktop: ObservableObject {
    static let shared = RemoteDesktop()
    static let enabledKey = "henge.remote.enabled"
    static let headlessKey = "henge.remote.headless"
    static let wifiKey = "henge.remote.wifi"
    static let port: UInt16 = 5901

    @Published private(set) var connected = false
    @Published private(set) var client = ""
    /// What a client over Wi-Fi must send first. New each time streaming is turned on.
    @Published private(set) var code = ""

    private let queue = DispatchQueue(label: "henge.remote", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "henge.remote.input", qos: .userInteractive)
    private let netQueue = DispatchQueue(label: "henge.remote.net", qos: .userInteractive)
    // queue only
    private var listener: NWListener?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var screen = (w: Int32(0), h: Int32(0))
    private var lastSeq: Int32 = -2
    private var lastSent = 0.0
    private var forceKey = true
    private var unsent = 0
    private var codeBytes: [UInt8] = []
    private var lockedUntil = 0.0
    // inputQueue only
    private var inbox: [UInt8] = []
    private var heldKeys = Set<UInt8>()
    private var heldButtons = Set<Int32>()

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
            codeBytes = Array(code.utf8)
            DispatchQueue.main.async { self.code = code }
            do {
                let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { state in HengeLog.log("remote", "listener: \(state)") }
                l.start(queue: queue)
                listener = l
            } catch {
                HengeLog.log("remote", "can't listen on \(Self.port): \(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            drop()
        }
    }

    /// The "hide on phone" setting changed while a client may be watching.
    func applyHeadless() {
        queue.async { [self] in
            if connection != nil { henge_vm_set_headless(UserDefaults.standard.bool(forKey: Self.headlessKey) ? 1 : 0) }
        }
    }

    /// The phone's Wi-Fi address, to connect to without USB.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard String(cString: a.ifa_name) == "en0", let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: - Connection (queue)

    /// USB (iproxy) connections come from usbmux on the phone itself, so from loopback; anything else came over a network.
    static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        default: return false
        }
    }

    private func accept(_ c: NWConnection) {
        let usb = Self.isLoopback(c.endpoint)
        if !usb && (!UserDefaults.standard.bool(forKey: Self.wifiKey) || CACurrentMediaTime() < lockedUntil) {
            HengeLog.log("remote", "refused \(c.endpoint): not over USB, and Wi-Fi is off or locked after a wrong code")
            c.cancel()
            return
        }
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.queue.async { if c === self.connection { self.drop() } }
            default: break
            }
        }
        // Its own queue: `queue` waits on the GPU for each frame, which under a game would hold up input behind it.
        c.start(queue: netQueue)
        if usb { promote(c); return }
        // Over Wi-Fi the first 6 bytes must be the code shown on the phone; until then no picture and no input.
        // A wrong code shuts Wi-Fi out for 2 s, so guessing a million codes takes weeks.
        c.receive(minimumIncompleteLength: 6, maximumLength: 6) { [weak self] data, _, _, _ in
            self?.queue.async {
                guard let self else { return }
                if let data, [UInt8](data) == self.codeBytes, !self.codeBytes.isEmpty {
                    self.promote(c)
                } else {
                    HengeLog.log("remote", "wrong code from \(c.endpoint)")
                    self.lockedUntil = CACurrentMediaTime() + 2
                    c.cancel()
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, c !== self.connection { c.cancel() }
        }
    }

    /// One client at a time: the newest that got in wins.
    private func promote(_ c: NWConnection) {
        drop()
        connection = c
        begin(c)
        receive(c)
    }

    private func begin(_ c: NWConnection) {
        HengeLog.log("remote", "client \(c.endpoint)")
        unsent = 0
        forceKey = true
        lastSeq = -2
        if UserDefaults.standard.bool(forKey: Self.headlessKey) { henge_vm_set_headless(1) }
        let name = "\(c.endpoint)"
        DispatchQueue.main.async { self.connected = true; self.client = name }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func drop() {
        timer?.cancel()
        timer = nil
        let had = connection != nil
        connection?.cancel()
        connection = nil
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        pool = nil
        screen = (0, 0)
        guard had else { return }
        henge_vm_set_headless(0)
        inputQueue.async { [self] in
            for k in heldKeys { henge_vm_key_hid(k, 0) }
            for b in heldButtons { henge_vm_mouse_button(b, 0) }
            heldKeys.removeAll()
            heldButtons.removeAll()
            inbox.removeAll()
        }
        DispatchQueue.main.async { self.connected = false; self.client = "" }
    }

    // MARK: - Video (queue)

    private func tick() {
        guard connection != nil, unsent < 1_000_000 else { return } // the client is behind: skip, don't queue
        var w: Int32 = 0, h: Int32 = 0
        let seq = henge_vm_stream_frame(nil, &w, &h)
        guard seq >= 0, w > 0, h > 0 else { return }
        let now = CACurrentMediaTime()
        if seq == lastSeq && !forceKey && now - lastSent < 1 { return } // nothing new; still a frame a second
        if w != screen.w || h != screen.h { makeEncoder(w, h) }
        guard let session, let pool else { return }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let pb = made else { return }
        let drawn = henge_vm_stream_frame(Unmanaged.passUnretained(pb).toOpaque(), &w, &h)
        guard drawn >= 0 else { return }
        lastSeq = drawn
        lastSent = now
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.queue.async { self.send(sample) }
        }
    }

    private func makeEncoder(_ w: Int32, _ h: Int32) {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        pool = nil
        screen = (w, h)
        // The hardware encoder tops out around 4K; past 2560 on the long side the stream only gets slower.
        let scale = min(1, 2560 / Double(max(w, h)))
        let ew = Int32(Double(w) * scale) & ~1, eh = Int32(Double(h) * scale) & ~1
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                     kCVPixelBufferMetalCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        var s: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var err = VTCompressionSessionCreate(allocator: nil, width: ew, height: eh, codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
                                             imageBufferAttributes: attrs, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if err != noErr {
            err = VTCompressionSessionCreate(allocator: nil, width: ew, height: eh, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                             imageBufferAttributes: attrs, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard err == noErr, let s else {
            HengeLog.log("remote", "no encoder for \(ew)x\(eh): \(err)")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 15_000_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        pool = VTCompressionSessionGetPixelBufferPool(s)
        forceKey = true
        HengeLog.log("remote", "encoding \(w)x\(h) as \(ew)x\(eh)")
    }

    /// One encoded frame as Annex-B: parameter sets before each keyframe, start codes for the length prefixes.
    private func send(_ sample: CMSampleBuffer) {
        guard let c = connection, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                                                                      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
                    out.append(contentsOf: startCode)
                    out.append(p, count: n)
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == kCMBlockBufferNoErr else { return }
        var i = 0
        while i + 4 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= bytes.count else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<(i + n)])
            i += n
        }
        let size = out.count
        unsent += size
        c.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async { if c === self.connection { self.unsent = max(0, self.unsent - size) } }
        })
    }

    // MARK: - Input

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.inputQueue.async { self.handle(data) } }
            if done || error != nil {
                self.queue.async { if c === self.connection { self.drop() } }
                return
            }
            self.receive(c)
        }
    }

    private func handle(_ data: Data) {
        inbox.append(contentsOf: data)
        var at = 0
        while at + 6 <= inbox.count {
            let type = inbox[at], a = inbox[at + 1]
            let x = Int32(Int16(bitPattern: UInt16(inbox[at + 2]) | UInt16(inbox[at + 3]) << 8))
            let y = Int32(Int16(bitPattern: UInt16(inbox[at + 4]) | UInt16(inbox[at + 5]) << 8))
            at += 6
            switch type {
            case 1:
                henge_vm_mouse_move(x, y)
            case 2:
                let b = Int32(a)
                henge_vm_mouse_button(b, x != 0 ? 1 : 0)
                if x != 0 { heldButtons.insert(b) } else { heldButtons.remove(b) }
            case 3:
                henge_vm_mouse_scroll(x, y)
            case 4:
                henge_vm_key_hid(a, x != 0 ? 1 : 0)
                if x != 0 { heldKeys.insert(a) } else { heldKeys.remove(a) }
            default:
                break
            }
        }
        inbox.removeFirst(at)
    }
}

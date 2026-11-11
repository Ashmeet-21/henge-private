import AVFoundation
import AVFAudio
import SwiftUI

/// Only this session's explicit switches authorize host capture. The guest
/// receives silence/black while a switch is off, and needs no helper installed.
final class GuestMediaCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var microphone = false { didSet { updateAuthorization(camera: false) } }
    @Published var camera = false { didSet { updateAuthorization(camera: true) } }
    @Published var frontCamera = true {
        didSet {
            stopCamera()
            if !availableResolutions.contains(resolution) { resolution = availableResolutions.last ?? .vga }
        }
    }
    @Published var resolution = CameraResolution(rawValue: UserDefaults.standard.integer(forKey: "cameraResolution")) ?? .vga {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: "cameraResolution")
            stopCamera()
            requestedResolution = nil
        }
    }
    @Published var flipHorizontally = UserDefaults.standard.bool(forKey: "cameraFlipHorizontally") {
        didSet {
            UserDefaults.standard.set(flipHorizontally, forKey: "cameraFlipHorizontally")
            let flip = flipHorizontally
            videoQueue.async { [weak self] in self?.videoFlipped = flip }
        }
    }
    @Published private(set) var microphoneStatus = "Off"
    @Published private(set) var cameraStatus = "Off"
    @Published private(set) var message: String?

    private var micAllowed = false
    private var cameraAllowed = false
    private var foreground = true
    private var audioInterrupted = false
    private var microphoneEngine: AVAudioEngine?
    private var cameraSession: AVCaptureSession?
    private var cameraFrameRate: UInt32 = 0
    private var cameraRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var cameraRotationObservation: NSKeyValueObservation?
    private let videoQueue = DispatchQueue(label: "henge.camera.frames", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "henge.camera.session", qos: .userInitiated)
    private var loggedCameraFrame = false // accessed only on videoQueue
    private var observers: [NSObjectProtocol] = []
    private var lastGeneration: UInt64 = 0
    private var wasRunning = false
    private var lastDemand: Int32 = -1
    private var requestedResolution: CameraResolution?
    private lazy var frameEncoder = CameraFrameEncoder()
    private var blackFrames: [CameraResolution: Data] = [:]
    private var videoResolution: CameraResolution = .vga // videoQueue only
    private var videoFlipped = false // videoQueue only, after gravity rotation
    private weak var videoOutput: AVCaptureVideoDataOutput? // videoQueue only

    private var selectedCameraDevice: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: frontCamera ? .front : .back).devices.first
    }

    var availableResolutions: [CameraResolution] {
        let device = selectedCameraDevice
        return CameraResolution.allCases.filter { $0 == .vga || device?.supportsSessionPreset($0.preset) == true }
    }

    override init() {
        super.init()
        if !availableResolutions.contains(resolution) { resolution = .vga }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if kind == .began { self.audioInterrupted = true; self.stopMicrophone(); self.microphoneStatus = "Interrupted"; self.publishGates() }
            else if kind == .ended { self.audioInterrupted = false; self.publishGates() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason != .categoryChange else { return }
            self?.stopMicrophone()
            if let self, self.microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { self.micAllowed = true; self.publishGates() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopMicrophone()
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let session = note.object as? AVCaptureSession, session === self.cameraSession else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            HengeLog.log("media", "camera runtime error: \(error?.localizedDescription ?? "unknown")")
            self.stopCamera()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func updateAuthorization(camera isCamera: Bool) {
        let on = isCamera ? camera : microphone
        if !on {
            if isCamera { cameraAllowed = false; stopCamera(); cameraStatus = "Off" }
            else { micAllowed = false; stopMicrophone(); microphoneStatus = "Off" }
            publishGates()
            return
        }
        message = nil
        let media: AVMediaType = isCamera ? .video : .audio
        let done: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, isCamera ? self.camera : self.microphone else { return }
                if isCamera {
                    self.cameraAllowed = granted
                    self.cameraStatus = granted ? (self.cameraSession == nil ? "Ready" : "In use by Mac") : "Permission needed"
                } else {
                    self.micAllowed = granted
                    self.microphoneStatus = granted ? (self.microphoneEngine == nil ? "Ready" : "In use by Mac") : "Permission needed"
                }
                if !granted { self.message = "Allow \(isCamera ? "Camera" : "Microphone") for Henge in this device’s Settings." }
                self.publishGates()
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: media, completionHandler: done)
        default: done(false)
        }
    }

    private func publishGates() {
        henge_vm_media_enable(foreground && microphone && micAllowed && !audioInterrupted ? 1 : 0,
                              foreground && camera && cameraAllowed ? 1 : 0)
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active { wasRunning = false; stopMicrophone(); stopCamera() }
        publishGates()
    }

    @MainActor func followGuest() async {
        while !Task.isCancelled {
            if henge_vm_state() == 1, foreground {
                let generation = henge_vm_generation()
                // Instant resume keeps the same VM generation. The first
                // foreground publication may have run while it was paused.
                if !wasRunning || generation != lastGeneration {
                    lastGeneration = generation
                    requestedResolution = nil
                    publishGates()
                }
                wasRunning = true
                if requestedResolution != resolution { configureResolution() }
                let demand = henge_vm_media_demand()
                if demand != lastDemand {
                    lastDemand = demand
                    HengeLog.log("media", "guest capture demand: microphone \(demand & 1 != 0), camera \(demand & 2 != 0)")
                }
                if microphone && micAllowed && !audioInterrupted && demand & 1 != 0 {
                    if microphoneEngine == nil { startMicrophone() }
                } else {
                    stopMicrophone()
                    if microphone && micAllowed { microphoneStatus = audioInterrupted ? "Interrupted" : "Ready" }
                }
                if camera && cameraAllowed && demand & 2 != 0 && henge_vm_camera_resolution() == resolution.rawValue {
                    let rate: UInt32 = henge_vm_camera_frame_rate() == 15 ? 15 : 30
                    if cameraSession == nil || cameraFrameRate != rate {
                        stopCamera()
                        startCamera(frameRate: rate)
                    }
                } else {
                    stopCamera()
                    if camera && cameraAllowed { cameraStatus = "Ready" }
                }
            } else {
                wasRunning = false
                stopMicrophone(); stopCamera()
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
        }
        // SessionView.onDisappear owns cleanup. A cancelled monitor must not
        // turn capture off again after the session view has reappeared.
    }

    func stop() {
        foreground = false
        henge_vm_media_enable(0, 0)
        stopMicrophone(); stopCamera()
    }

    private func configureResolution() {
        let result: Int32
        if resolution == .vga { result = henge_vm_camera_set_resolution(0, nil, 0) }
        else {
            if blackFrames[resolution] == nil { blackFrames[resolution] = frameEncoder.blackFrame(resolution) }
            guard let black = blackFrames[resolution] else { return }
            result = black.withUnsafeBytes {
                henge_vm_camera_set_resolution(UInt32(resolution.rawValue), $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count))
            }
        }
        if result == 0 {
            requestedResolution = resolution
            HengeLog.log("media", "camera resolution selected: \(resolution.width)x\(resolution.height)")
        }
    }

    private func startMicrophone() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let hardware = input.outputFormat(forBus: 0)
            guard hardware.channelCount > 0, hardware.sampleRate > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: hardware, to: format) else {
                throw NSError(domain: "HengeMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available on this audio route."])
            }
            let direct = hardware.sampleRate == 48_000 && hardware.channelCount == 1 && hardware.commonFormat == .pcmFormatFloat32
            var loggedBlock = false
            input.installTap(onBus: 0, bufferSize: 512, format: hardware) { buffer, _ in
                if direct, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    if !loggedBlock {
                        loggedBlock = true
                        HengeLog.log("media", "microphone first block: \(buffer.frameLength) frames, direct 48000 Hz mono")
                    }
                    henge_vm_microphone(samples, buffer.frameLength)
                    return
                }
                let count = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48_000 / hardware.sampleRate)) + 32
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
                var used = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true; status.pointee = .haveData; return buffer
                }
                if error == nil, converted.frameLength > 0, let samples = converted.floatChannelData?[0] {
                    if !loggedBlock {
                        loggedBlock = true
                        HengeLog.log("media", "microphone first block: \(buffer.frameLength) -> \(converted.frameLength) frames")
                    }
                    henge_vm_microphone(samples, converted.frameLength)
                }
            }
            engine.prepare()
            try engine.start()
            microphoneEngine = engine
            microphoneStatus = "In use by Mac"
            HengeLog.log("media", "microphone started: \(hardware.sampleRate) Hz -> 48000 Hz mono")
        } catch {
            microphoneStatus = "Unavailable"
            message = error.localizedDescription
            // Retry only after an explicit user action or route change.
            micAllowed = false
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            publishGates()
        }
    }

    private func stopMicrophone() {
        guard let engine = microphoneEngine else { return }
        microphoneEngine = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        HengeLog.log("media", "microphone stopped")
    }

    private func startCamera(frameRate: UInt32) {
        VolumeClicks.shared.setCameraShared(true)
        let session = AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        guard let device = selectedCameraDevice,
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            cameraAllowed = false; cameraStatus = "Unavailable"
            message = "This device’s camera is unavailable."
            VolumeClicks.shared.setCameraShared(false)
            publishGates()
            return
        }
        session.addInput(input)
        if session.canSetSessionPreset(resolution.preset) { session.sessionPreset = resolution.preset }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            cameraAllowed = false; cameraStatus = "Unavailable"
            message = "The camera could not provide video frames."
            VolumeClicks.shared.setCameraShared(false); publishGates(); return
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            // Capture orientation comes from the camera's gravity-relative
            // angle, independently of the app's layout or rotation lock. The
            // coordinator also accounts for different iPhone/iPad sensors.
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            cameraRotationCoordinator = coordinator
            Self.rotateCamera(connection, to: coordinator.videoRotationAngleForHorizonLevelCapture)
            cameraRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self, weak coordinator, weak connection] _, change in
                guard let angle = change.newValue else { return }
                DispatchQueue.main.async {
                    guard let self, let coordinator, let connection,
                          self.cameraRotationCoordinator === coordinator else { return }
                    self.sessionQueue.async { Self.rotateCamera(connection, to: angle) }
                }
            }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
        do {
            try device.lockForConfiguration()
            let rate = Double(frameRate)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && $0.maxFrameRate >= rate }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            }
            device.unlockForConfiguration()
        } catch { HengeLog.log("media", "camera uses its default capture frame rate") }
        session.commitConfiguration()
        cameraSession = session
        cameraFrameRate = frameRate
        cameraStatus = "In use by Mac"
        HengeLog.log("media", "camera starting: \(frontCamera ? "front" : "back"), \(device.localizedName), \(frameRate) fps")
        let selectedResolution = resolution
        let selectedFlip = flipHorizontally
        videoQueue.async { [weak self, weak output] in
            self?.loggedCameraFrame = false
            self?.videoResolution = selectedResolution
            self?.videoFlipped = selectedFlip
            self?.videoOutput = output
        }
        sessionQueue.async {
            session.startRunning()
            HengeLog.log("media", "camera running: \(session.isRunning)")
        }
    }

    private func stopCamera() {
        cameraRotationObservation?.invalidate()
        cameraRotationObservation = nil
        cameraRotationCoordinator = nil
        guard let session = cameraSession else { return }
        cameraSession = nil
        cameraFrameRate = 0
        videoQueue.async { [weak self] in self?.videoOutput = nil }
        sessionQueue.async { [weak self] in
            session.stopRunning()
            DispatchQueue.main.async {
                if self?.cameraSession == nil { VolumeClicks.shared.setCameraShared(false) }
            }
        }
    }

    private static func rotateCamera(_ connection: AVCaptureConnection, to angle: CGFloat) {
        guard connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle else { return }
        connection.videoRotationAngle = angle
        HengeLog.log("media", "camera gravity rotation: \(angle) degrees")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoOutput,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixel) == 2 else { return }
        if videoResolution != .vga {
            guard let jpeg = frameEncoder.jpeg(pixel, resolution: videoResolution, mirrored: videoFlipped) else { return }
            if !loggedCameraFrame {
                loggedCameraFrame = true
                HengeLog.log("media", "camera first frame: \(videoResolution.width)x\(videoResolution.height) MJPEG, sensor \(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))")
            }
            jpeg.withUnsafeBytes {
                henge_vm_camera_jpeg($0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count), UInt32(videoResolution.rawValue))
            }
            return
        }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) else { return }
        if !loggedCameraFrame {
            loggedCameraFrame = true
            HengeLog.log("media", "camera first frame: \(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel)) NV12")
        }
        henge_vm_camera_nv12(y.assumingMemoryBound(to: UInt8.self), UInt32(CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)),
                             uv.assumingMemoryBound(to: UInt8.self), UInt32(CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)),
                             UInt32(CVPixelBufferGetWidth(pixel)), UInt32(CVPixelBufferGetHeight(pixel)), videoFlipped ? 1 : 0)
    }
}

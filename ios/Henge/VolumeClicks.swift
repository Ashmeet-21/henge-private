import SwiftUI
import UIKit
import MediaPlayer
import AVFAudio

/// The volume buttons become the trackpad's buttons: up is left click, down is right
/// click, and holding one keeps it pressed so you can drag. iOS won't hand an app the
/// raw button events, so this is the camera-shutter trick: a hidden MPVolumeView keeps
/// the system volume HUD away, we pin the volume to the middle, and every press arrives
/// as a step up or down that we read and then immediately undo. The buttons therefore
/// never actually change the volume while a Mac is running.
///
/// The one wrinkle: iOS reports volume *changes*, not press and release, so "let go" is
/// inferred from the changes stopping (holding a button auto-repeats). releaseAfter is
/// the quiet gap that counts as a release.
final class VolumeClicks: NSObject {
    static let enabledKey = "henge.trackpad.volumeButtons"
    static let shared = VolumeClicks()

    /// How long without a repeat before a held button is treated as released.
    private let releaseAfter: TimeInterval = 0.5
    private let baseline: Float = 0.5
    private let step: Float = 0.01

    private var volumeView: MPVolumeView?
    private var observing = false
    private var originalVolume: Float = 0.5
    private var leftDown = false
    private var rightDown = false
    private var leftTimer: Timer?
    private var rightTimer: Timer?
    private let buzz = UIImpactFeedbackGenerator(style: .light)

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Begin intercepting while a session is on screen.
    func start() {
        guard !observing, enabled else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        originalVolume = AVAudioSession.sharedInstance().outputVolume

        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        view.showsRouteButton = false
        view.isUserInteractionEnabled = false
        keyWindow()?.addSubview(view)
        volumeView = view

        setVolume(baseline)
        AVAudioSession.sharedInstance().addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        observing = true
        buzz.prepare()
        /* The slider can take a run-loop turn to appear; pin it again once it has. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.observing else { return }
            self.setVolume(self.baseline)
        }
        HengeLog.log("input", "volume buttons: now the trackpad's buttons")
    }

    /// Stop intercepting and give the volume back when the session goes away.
    func stop() {
        guard observing else { return }
        AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
        observing = false
        releaseButtons()
        setVolume(originalVolume)
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    /// Let go of any held click (backgrounding, a dialog opening) so it never sticks.
    func releaseButtons() {
        leftTimer?.invalidate(); rightTimer?.invalidate()
        leftTimer = nil; rightTimer = nil
        if leftDown { henge_vm_mouse_button(0, 0); leftDown = false }
        if rightDown { henge_vm_mouse_button(1, 0); rightDown = false }
    }

    // MARK: - Volume changes

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "outputVolume" else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observing else { return }
            let volume = AVAudioSession.sharedInstance().outputVolume
            if volume > self.baseline + self.step {
                self.press(left: true)
            } else if volume < self.baseline - self.step {
                self.press(left: false)
            } else {
                return /* our own reset back to the middle */
            }
            self.setVolume(self.baseline)
        }
    }

    /// A press (or an auto-repeat while held): put the button down and arm its release.
    private func press(left: Bool) {
        let button: Int32 = left ? 0 : 1
        let alreadyDown = left ? leftDown : rightDown
        if !alreadyDown {
            henge_vm_mouse_button(button, 1)
            buzz.impactOccurred()
            HengeLog.log("input", "volume button: \(left ? "left" : "right") down")
        }
        if left { leftDown = true } else { rightDown = true }

        let timer = Timer(timeInterval: releaseAfter, repeats: false) { [weak self] _ in
            guard let self else { return }
            if left { self.leftDown = false } else { self.rightDown = false }
            henge_vm_mouse_button(button, 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        if left { leftTimer?.invalidate(); leftTimer = timer } else { rightTimer?.invalidate(); rightTimer = timer }
    }

    // MARK: - Keeping the volume pinned

    /// Set the system volume through MPVolumeView's slider, the one place an app can.
    private func setVolume(_ value: Float) {
        guard let view = volumeView, let slider = findSlider(in: view) else { return }
        slider.value = value
    }

    /// The slider's place in MPVolumeView's guts moves between iOS versions; look deep.
    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews { if let slider = findSlider(in: sub) { return slider } }
        return nil
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
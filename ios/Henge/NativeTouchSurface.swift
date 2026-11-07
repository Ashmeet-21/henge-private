import SwiftUI
import UIKit

/// Sends full snapshots of up to five contacts in the displayed Mac image.
/// The supplied rectangle is relative to this overlay, including zoom and letterboxing.
struct NativeTouchSurface: UIViewRepresentable {
    let imageRect: CGRect
    let revealsControls: Bool

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.configure(imageRect, revealsControls: revealsControls) }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.cancel() }

    final class Surface: UIView {
        private struct Finger {
            let touch: UITouch
            let id: UInt8
            var point: CGPoint
        }
        private var fingers: [Finger] = []
        private var imageRect = CGRect.zero
        private var generation: UInt32 = 0
        private var heartbeat: Timer?
        private var waitForLift = false
        private var held = Set<UITouch>()
        private let controlsTap = UITapGestureRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            controlsTap.numberOfTouchesRequired = 3
            controlsTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            controlsTap.cancelsTouchesInView = true
            controlsTap.isEnabled = false
            controlsTap.addTarget(self, action: #selector(revealControls))
            addGestureRecognizer(controlsTap)
        }
        required init?(coder: NSCoder) { fatalError("made in code") }

        func configure(_ rect: CGRect, revealsControls: Bool) {
            if controlsTap.isEnabled != revealsControls {
                controlsTap.isEnabled = revealsControls
            }
            if imageRect != rect {
                cancel()
                if imageRect != .zero { hv_native_touch_reset() }
                imageRect = rect
                generation = hv_native_touch_epoch()
                waitForLift = !held.isEmpty
            }
            if heartbeat == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.send() }
                RunLoop.main.add(timer, forMode: .common)
                heartbeat = timer
            }
            send()
        }

        @objc private func revealControls() {
            cancel()
            NotificationCenter.default.post(name: Trackpad.threeFingerTap, object: nil)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancel(); heartbeat?.invalidate(); heartbeat = nil }
        }

        func cancel() {
            fingers.removeAll()
            _ = hv_native_touch_submit(generation, nil, nil, nil, 0)
            waitForLift = !held.isEmpty
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let direct = touches.filter { $0.type == .direct }
            held.formUnion(direct)
            guard !waitForLift, hv_native_touch_status() == 2 else { waitForLift = true; return }
            for touch in direct where fingers.count < 5 {
                let point = touch.location(in: self)
                guard imageRect.contains(point) else { continue }
                let id = (UInt8(1)...UInt8(127)).first { candidate in !fingers.contains { $0.id == candidate } }!
                fingers.append(Finger(touch: touch, id: id, point: point))
            }
            send()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !waitForLift else { return }
            for index in fingers.indices where touches.contains(fingers[index].touch) {
                fingers[index].point = fingers[index].touch.location(in: self)
            }
            send()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel(); lift(touches) }
        private func lift(_ touches: Set<UITouch>) {
            held.subtract(touches)
            fingers.removeAll { touches.contains($0.touch) }
            if held.isEmpty { waitForLift = false }
            send()
        }
        private func send() {
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            if generation != hv_native_touch_epoch() {
                fingers.removeAll(); waitForLift = !held.isEmpty
                generation = hv_native_touch_epoch()
            }
            let ids = fingers.map(\.id)
            let x = fingers.map { min(1, max(0, Double(($0.point.x-imageRect.minX)/imageRect.width))) }
            let y = fingers.map { min(1, max(0, Double(($0.point.y-imageRect.minY)/imageRect.height))) }
            _ = hv_native_touch_submit(generation, ids, x, y, ids.count)
        }
    }
}

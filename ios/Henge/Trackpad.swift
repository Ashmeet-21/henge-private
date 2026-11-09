import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad. One finger moves the pointer; a tap clicks; a finger
/// held still for a moment presses the button until it lifts, which is how to drag. Two fingers
/// scroll, and tapped together they right-click. Pointer speed suits a 1920-wide screen on a small
/// one. Only fingers count here: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Three fingers tapped together: the session shows its hidden controls.
    static let threeFingerTap = Notification.Name("henge.trackpad.threeFingerTap")

    /// Settings' "Scroll speed" for two fingers: it scales the wheel units, and macOS moves a page by about their
    /// square, so 0.2 scrolls about a twenty-fifth as far as 1 (what Henge did before: too fast even at macOS's
    /// slowest Scrolling Speed).
    static let scrollSpeedKey = "henge.trackpad.scrollSpeed"
    static let defaultScrollSpeed = 0.2
    static var scrollSpeed: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: scrollSpeedKey) as? Double ?? defaultScrollSpeed)
    }

    /// Settings' "Pointer speed" for one finger: it multiplies the base move distance (which already depends on
    /// screen size), so the pointer can be calmed on a small, high-resolution screen. 1 is the built-in feel.
    static let pointerSpeedKey = "henge.trackpad.pointerSpeed"
    static let defaultPointerSpeed = 1.0
    static var pointerSpeed: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: pointerSpeedKey) as? Double ?? defaultPointerSpeed)
    }

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {}

    final class Surface: UIView, UIPointerInteractionDelegate {
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8
        private var fingers: [UITouch] = []
        private var started = Date()
        private var travelled: CGFloat = 0
        private var hadTwoFingers = false
        private var mostFingers = 0
        private var holding = false
        private var holdTimer: Timer?
        private var scrollX: CGFloat = 0
        private var scrollY: CGFloat = 0
        private var lastScroll: CFTimeInterval = 0
        private var restX: CGFloat = 0
        private var restY: CGFloat = 0
        private let buzz = UIImpactFeedbackGenerator(style: .medium)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        /// A full-size iPad has more room to move a finger across than a phone does; the user's "Pointer speed" scales it.
        private var speed: CGFloat { (traitCollection.horizontalSizeClass == .regular ? 2 : 3) * Trackpad.pointerSpeed }

        required init?(coder: NSCoder) { fatalError("made in code") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                hadTwoFingers = false
                mostFingers = 0
                scrollX = 0
                scrollY = 0
                restX = 0
                restY = 0
                buzz.prepare()
            }
            fingers.append(contentsOf: touches)
            mostFingers = max(mostFingers, fingers.count)
            if fingers.count >= 2 {
                hadTwoFingers = true
                cancelHold()
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let finger = fingers.first, touches.contains(finger) || (fingers.count >= 2 && touches.contains(where: fingers.contains)) else { return }
            let now = finger.location(in: self), before = finger.previousLocation(in: self)
            let dx = now.x - before.x, dy = now.y - before.y
            travelled += abs(dx) + abs(dy)
            if fingers.count >= 2 {
                scroll(dx, dy)
            } else {
                if travelled >= Self.tapDistance, !holding { cancelHold() }
                restX += dx * speed
                restY += dy * speed
                let moveX = restX.rounded(), moveY = restY.rounded()
                guard moveX != 0 || moveY != 0 else { return }
                restX -= moveX
                restY -= moveY
                henge_vm_mouse_move(Int32(moveX), Int32(moveY))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            fingers.removeAll { touches.contains($0) }
            guard fingers.isEmpty else { return }
            cancelHold()
            if holding {
                holding = false
                henge_vm_mouse_button(0, 0)
                StickyKeys.shared.releaseAll()
                return
            }
            if mostFingers >= 3 {
                if travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                    NotificationCenter.default.post(name: Trackpad.threeFingerTap, object: nil)
                }
                return
            }
            guard travelled < Self.tapDistance, Date().timeIntervalSince(started) < Self.tapTime else { return }
            let button: Int32 = hadTwoFingers ? 1 : 0
            henge_vm_mouse_button(button, 1)
            henge_vm_mouse_button(button, 0)
            StickyKeys.shared.releaseAll()
        }

        private func armHold() {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        /// As on a Mac's trackpad, the page follows the fingers. macOS accelerates the wheel hard: a page
        /// moves about 0.08 d² pixels for an event of d units (measured: 8 units 4 px, 100 units 970 px).
        /// So d comes from the square root of how far the fingers went, to move the page about three
        /// pixels for each point, the same as the pointer.
        /// One wheel event carries at most this many units. macOS re-accelerates wheel events, so without a cap one
        /// fast flick emits a large event that jumps the page much further than the finger travelled (the overshoot).
        private static let maxUnitsPerTick: CGFloat = 6

        private func scroll(_ dx: CGFloat, _ dy: CGFloat) {
            scrollX += dx
            scrollY += dy
            // Keep a page from drifting sideways (or a browser going back) without flattening a real diagonal scroll:
            // drop the minor axis only when it is both much smaller than the major and small in itself.
            if abs(scrollY) > 2 * abs(scrollX), abs(scrollX) < 3 { scrollX = 0 }
            else if abs(scrollX) > 2 * abs(scrollY), abs(scrollY) < 3 { scrollY = 0 }
            // At most 60 wheel events a second, the rest gathered into the next: macOS speeds a wheel up more the
            // faster its events come, and touches arrive at 120 Hz. The distance per point stays the same.
            let now = CACurrentMediaTime()
            guard now - lastScroll >= 1.0 / 60 else { return }
            let unitsX = wheelUnits(scrollX), unitsY = wheelUnits(scrollY)
            guard unitsX != 0 || unitsY != 0 else { return }
            lastScroll = now
            if unitsX != 0 { scrollX = 0 }
            if unitsY != 0 { scrollY = 0 }
            henge_vm_mouse_scroll(-unitsX, unitsY)
        }

        private func wheelUnits(_ points: CGFloat) -> Int32 {
            guard abs(points) >= 0.5 else { return 0 } // a resting or tiny finger move: no scroll, no accidental nudge
            let raw = 6 * Trackpad.scrollSpeed * abs(points).squareRoot()
            let units = min(raw, Self.maxUnitsPerTick).rounded()
            guard units != 0 else { return 0 }
            return Int32(points < 0 ? -units : units)
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}

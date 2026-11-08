import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls. A tap is a click; hold to press, then drag to
/// grab. Only fingers count here: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {}

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8

        private struct Finger { var touch: UITouch; var id: Int32 }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var holding = false
        private var holdTimer: Timer?
        private var touchesLogged = 0
        private let buzz = UIImpactFeedbackGenerator(style: .medium)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            let x = min(max(p.x / bounds.width, 0), 1)
            let y = min(max(p.y / bounds.height, 0), 1)
            return (Int32(x * Double(Self.sensorW)), Int32(y * Double(Self.sensorH)))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                buzz.prepare()
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y)
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a press becomes a gesture */
                    holding = false
                    henge_vm_touch_button(0)
                }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                if travelled >= Self.tapDistance, !holding { cancelHold() }
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            if !fingers.isEmpty { /* fingers still down: just lift these */
                for id in lifted { henge_vm_touch(id, 2, 0, 0) }
                return
            }
            /* The gesture is over. */
            cancelHold()
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            if mostFingers == 1 {
                let id = lifted[0]
                if holding {
                    holding = false
                    henge_vm_touch_button(0)
                    henge_vm_touch(id, 2, 0, 0)
                } else if travelled < Self.tapDistance, Date().timeIntervalSince(started) < Self.tapTime {
                    /* A tap is a brief firm press. */
                    henge_vm_touch_button(1)
                    henge_vm_touch(id, 2, 0, 0)
                    henge_vm_touch_button(0)
                } else {
                    henge_vm_touch(id, 2, 0, 0)
                }
            } else {
                for id in lifted { henge_vm_touch(id, 2, 0, 0) }
            }
            StickyKeys.shared.releaseAll()
        }

        private func armHold() {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_touch_button(1)
                self.buzz.impactOccurred()
            }
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
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
            .font(.system(size: 15))
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

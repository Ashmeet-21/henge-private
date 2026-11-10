import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, a quick
///    two-finger tap is a right click, and touching then holding presses the button
///    down so moving drags. These go out as mouse buttons alongside the pad's fingers.
///  - Volume buttons: the surface only points and gestures; the clicks live on the
///    volume keys (VolumeClicks), so a tap here does nothing.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    /// The running session's guest width in pixels, set by SessionView at start. 0 before any
    /// session, when the size-class guess below is as good as anything.
    static var guestScreenWidth = 0
    /// The guest height too: the direct mapping needs both dimensions.
    static var guestScreenHeight = 0

    /// Direct (absolute) pointing. Default false is load-bearing: every surface is a
    /// trackpad until SessionView opts the main surface in; the portrait pad panel never does.
    var direct: Bool = false
    /// The session's screen rect and this surface's origin, both in layout coordinates,
    /// refreshed on every update so a rotation or fold re-aims the mapping at once.
    var screenRect: CGRect = .zero
    var touchOrigin: CGPoint = .zero

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.direct = direct
        surface.screenRect = screenRect
        surface.touchOrigin = touchOrigin
        return surface
    }

    func updateUIView(_ view: Surface, context: Context) {
        view.direct = direct
        view.screenRect = screenRect
        view.touchOrigin = touchOrigin
    }

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
        private var touchesLogged = 0

        /* Touchscreen-mode clicking. */
        private var holding = false
        private var holdTimer: Timer?
        private let buzz = UIImpactFeedbackGenerator(style: .medium)
        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen }

        /// Direct-pointing configuration, set by the representable (see Trackpad).
        var direct = false
        var screenRect: CGRect = .zero
        var touchOrigin: CGPoint = .zero
        /// Shorter than the trackpad's hold: in direct mode the cursor is already
        /// where the finger is, so a hold reads as intent sooner.
        private static let directHoldTime: TimeInterval = 0.35
        private var engaged = false   /* the left button is down for a direct drag */
        private var pencilActive = false
        private var hadTwoFingers = false
        private var scrollX: CGFloat = 0
        private var scrollY: CGFloat = 0

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
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if direct { directBegan(touches, with: event); return }
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                if tapsClick { buzz.prepare() }
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, Self.ms(t.timestamp))
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            guard tapsClick else { return }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    henge_vm_mouse_button(0, 0)
                }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if direct { directMoved(touches, with: event); return }
            var moved = false
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y, ts)
                moved = true
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if tapsClick && travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            if moved { henge_vm_touch_frame(ts) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if direct { directLift(touches); return }
            lift(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if direct { directLift(touches); return }
            lift(touches)
        }

        private func lift(_ touches: Set<UITouch>) {
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            let ts = Self.ms(touches.map(\.timestamp).max() ?? 0)
            for id in lifted { henge_vm_touch(id, 2, 0, 0, ts) }
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            if tapsClick {
                cancelHold()
                let quick = Date().timeIntervalSince(started) < Self.tapTime
                let still = travelled < Self.tapDistance
                if holding {
                    holding = false
                    henge_vm_mouse_button(0, 0) /* let go of the drag */
                } else if quick && still {
                    if mostFingers == 1 { click(0) }      /* a tap is a left click */
                    else if mostFingers == 2 { click(1) } /* a two-finger tap is a right click */
                }
            }
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            StickyKeys.shared.releaseAll()
        }

        /// A brief press of a mouse button: down then up.
        private func click(_ button: Int32) {
            henge_vm_mouse_button(button, 1)
            henge_vm_mouse_button(button, 0)
            buzz.impactOccurred()
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func scroll(_ dx: CGFloat, _ dy: CGFloat) {
            scrollX += dx
            scrollY += dy
            // Mostly one way is that way only: a page shouldn't drift sideways, or a browser go back.
            if abs(scrollY) > 2 * abs(scrollX) { scrollX = 0 } else if abs(scrollX) > 2 * abs(scrollY) { scrollY = 0 }
            let unitsX = wheelUnits(scrollX), unitsY = wheelUnits(scrollY)
            guard unitsX != 0 || unitsY != 0 else { return }
            if unitsX != 0 { scrollX = 0 }
            if unitsY != 0 { scrollY = 0 }
            henge_vm_mouse_scroll(-unitsX, unitsY)
        }

        private func wheelUnits(_ points: CGFloat) -> Int32 {
            guard abs(points) >= 0.25 else { return 0 } // less than this is a finger resting
            let units = (6 * abs(points).squareRoot()).rounded()
            return Int32(points < 0 ? -units : units)
        }

        // MARK: Direct (absolute) pointing

        /// Map a point in this surface's coordinates to a guest pixel: convert to
        /// layout coordinates, then scale the session's screen rect onto the guest.
        /// Touches outside the screen rect clamp to the nearest edge pixel, as a
        /// real absolute tablet pins the cursor at its active-area boundary.
        private func guestCoords(forSurfacePoint p: CGPoint) -> (Int32, Int32) {
            let gw = max(Trackpad.guestScreenWidth, 1)
            let gh = max(Trackpad.guestScreenHeight, 1)
            let qx = p.x + touchOrigin.x
            let qy = p.y + touchOrigin.y
            var gx = 0
            var gy = 0
            if screenRect.width > 0 { gx = Int((qx - screenRect.minX) / screenRect.width * CGFloat(gw)) }
            if screenRect.height > 0 { gy = Int((qy - screenRect.minY) / screenRect.height * CGFloat(gh)) }
            return (Int32(min(max(gx, 0), gw - 1)), Int32(min(max(gy, 0), gh - 1)))
        }

        private func sendAbs(surfacePoint p: CGPoint) {
            let (gx, gy) = guestCoords(forSurfacePoint: p)
            henge_vm_mouse_move_abs(gx, gy)
        }

        private func sendAbs(for touch: UITouch, precise: Bool) {
            sendAbs(surfacePoint: precise ? touch.preciseLocation(in: self) : touch.location(in: self))
        }

        private func directBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches where touch.type != .indirectPointer {
                if touch.type == .pencil {
                    // A pen landing ends any finger drag: release it, then the pen drives.
                    if engaged { henge_vm_mouse_button(0, 0); engaged = false }
                    fingers.removeAll { $0.touch.type == .direct }
                    cancelHold()
                    pencilActive = true
                    if fingers.isEmpty { started = Date(); travelled = 0; hadTwoFingers = false }
                    fingers.append(Finger(touch: touch, id: 0))
                    // Pen-down semantics: the button engages on first contact, and the
                    // move first puts the cursor under the pen (and makes the tablet
                    // the engine's active pointer device).
                    sendAbs(for: touch, precise: true)
                    henge_vm_mouse_button(0, 1)
                    engaged = true
                } else {
                    // Palm rule: fingers are ignored while the pen is down.
                    if pencilActive { continue }
                    if fingers.isEmpty {
                        started = Date()
                        travelled = 0
                        hadTwoFingers = false
                        scrollX = 0
                        scrollY = 0
                        buzz.prepare()
                    }
                    fingers.append(Finger(touch: touch, id: 0))
                    if fingers.count >= 2 {
                        hadTwoFingers = true
                        cancelHold()
                        if engaged { henge_vm_mouse_button(0, 0); engaged = false }
                    } else {
                        sendAbs(for: touch, precise: false)
                        armDirectHold()
                    }
                }
            }
        }

        private func directMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let active = touches.filter { t in fingers.contains { $0.touch == t } }
            guard !active.isEmpty else { return }
            if pencilActive {
                // Every coalesced sample, in order: the device slot coalesces, so
                // sending them all costs bridge calls, not guest lag.
                for touch in active where touch.type == .pencil {
                    for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                        sendAbs(surfacePoint: sample.preciseLocation(in: self))
                    }
                }
                return
            }
            if fingers.count >= 2 {
                // Scroll from the centroid's motion, as the trackpad path does.
                var dx: CGFloat = 0, dy: CGFloat = 0
                for touch in active {
                    let now = touch.location(in: self), before = touch.previousLocation(in: self)
                    dx += now.x - before.x
                    dy += now.y - before.y
                }
                dx /= CGFloat(active.count)
                dy /= CGFloat(active.count)
                travelled += abs(dx) + abs(dy)
                scroll(dx, dy)
                return
            }
            guard let finger = fingers.first?.touch, active.contains(finger) else { return }
            let now = finger.location(in: self), before = finger.previousLocation(in: self)
            travelled += abs(now.x - before.x) + abs(now.y - before.y)
            if !engaged, travelled >= Self.tapDistance {
                cancelHold()
                sendAbs(surfacePoint: now)
                henge_vm_mouse_button(0, 1)
                engaged = true
                return
            }
            sendAbs(surfacePoint: now)
        }

        private func directLift(_ touches: Set<UITouch>) {
            let lifting = Array(touches.filter { $0.type != .indirectPointer })
            guard !lifting.isEmpty else { return }
            // Fingers lifting under an active pen were never registered.
            let registered = lifting.filter { t in fingers.contains { $0.touch == t } }
            fingers.removeAll { f in lifting.contains(f.touch) }
            if registered.isEmpty { return }
            if !fingers.contains(where: { $0.touch.type == .pencil }) { pencilActive = false }
            guard fingers.isEmpty else { return }
            cancelHold()
            if engaged {
                engaged = false
                if let last = registered.last { sendAbs(for: last, precise: last.type == .pencil) }
                henge_vm_mouse_button(0, 0)
                StickyKeys.shared.releaseAll()
                return
            }
            guard travelled < Self.tapDistance, Date().timeIntervalSince(started) < Self.tapTime else { return }
            if hadTwoFingers {
                // A two-finger tap is a right click at the centroid: where the fingers are.
                let cx = registered.map { $0.location(in: self).x }.reduce(0, +) / CGFloat(registered.count)
                let cy = registered.map { $0.location(in: self).y }.reduce(0, +) / CGFloat(registered.count)
                sendAbs(surfacePoint: CGPoint(x: cx, y: cy))
                henge_vm_mouse_button(1, 1)
                henge_vm_mouse_button(1, 0)
            } else if let last = registered.last {
                // A tap is a click at that pixel: move and click use the same point.
                sendAbs(for: last, precise: last.type == .pencil)
                henge_vm_mouse_button(0, 1)
                henge_vm_mouse_button(0, 0)
            }
            StickyKeys.shared.releaseAll()
        }

        private func armDirectHold() {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.directHoldTime, repeats: false) { [weak self] _ in
                guard let self, self.direct, self.fingers.count == 1, !self.engaged, self.travelled < Self.tapDistance else { return }
                self.engaged = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window == nil else { return }
            // A layout rebuild must not strand a held button in the guest.
            if engaged || holding {
                henge_vm_mouse_button(0, 0)
                engaged = false
                holding = false
            }
            cancelHold()
        }

        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
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
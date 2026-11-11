import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Keyboard-viewport focus logic.
///
/// Pure Foundation so the exact shipped solver and signal store can be compiled
/// headlessly by tests/test_kb_viewport.swift on macOS. No UIKit types cross
/// this file: keyboard frames arrive already converted (see Input.swift).
///
/// Coordinate spaces:
/// - Focus points/rects are normalised guest coordinates (0...1 of guest
///   width/height), stamped with the guest size they were recorded against.
/// - The solver works in SessionView Layout coordinates (points, device top
///   left), against the base (full-transform) screen rect and a band rect.
/// - The band and the keyboard frame are in Layout coordinates. Input.swift
///   converts the notification's end frame from the active UIWindowScene's
///   screen coordinate space (NOT UIScreen.main, which does not describe the
///   device's inner panel; see ViewportPlan in Hardware.swift) into the Holder's
///   window coordinates, and SessionView shifts scene coordinates into Layout
///   coordinates by the same centring offset Layout applies to the pane.

// NOTE: focus targets come only from real signals: the user's tap and
// the guest pointer. There is no built-in login target and no stored
// login geometry.

// MARK: - Keyboard frame, as reported by the notifications

struct KeyboardInfo: Equatable {
    /// End frame converted into Layout coordinates (SessionView does the shift).
    var frameInLayout: CGRect
    /// True when the frame is docked at the bottom and spans the width.
    var docked: Bool
    var duration: Double
    /// UIView.AnimationCurve raw value (0 easeInOut, 1 easeIn, 2 easeOut, 3 linear).
    var curve: Int
}

enum KeyboardEvent {
    case show(KeyboardInfo)
    case changeFrame(KeyboardInfo)
    case hide(duration: Double, curve: Int)
}

// MARK: - Focus signals

struct KBFocusTarget: Equatable {
    var point: CGPoint          // normalised guest coordinates
    var rect: CGRect            // normalised guest coordinates
    var fieldRect: CGRect?      // priority sub-rect of the target, if any
    var source: String          // "tap", "pointer"
    var guestWidth: Int
    var guestHeight: Int
}

final class KeyboardSignals {
    static let shared = KeyboardSignals()

    struct Tap { var target: KBFocusTarget; var at: Date; var consumed: Bool }
    struct Pointer { var point: CGPoint; var movedAt: Date }

    private(set) var lastTap: Tap?
    private(set) var lastPointer: Pointer?
    private(set) var kbSessionOpen = false

    /// Session start: clear any signals from the previous session.
    func resetSession(now: Date = Date()) {
        lastTap = nil
        lastPointer = nil
        kbSessionOpen = false
    }

    func endSession() {
        lastTap = nil
        lastPointer = nil
        kbSessionOpen = false
    }

    func invalidateTap() { lastTap = nil }

    /// Posture changed: taps do not survive rotation/fold.
    func postureChanged() { lastTap = nil }

    func recordTap(point: CGPoint, guestWidth: Int, guestHeight: Int, now: Date = Date()) {
        let rect = CGRect(x: point.x - 0.035, y: point.y - 0.030, width: 0.070, height: 0.060)
        let target = KBFocusTarget(point: point, rect: rect, fieldRect: nil, source: "tap",
                                   guestWidth: guestWidth, guestHeight: guestHeight)
        lastTap = Tap(target: target, at: now, consumed: false)
    }

    func recordPointer(point: CGPoint, now: Date = Date()) {
        if let last = lastPointer, last.point == point { return }
        lastPointer = Pointer(point: point, movedAt: now)
    }

    func kbWillShow(now: Date = Date()) {
        kbSessionOpen = true
    }

    func kbDidHide() {
        kbSessionOpen = false
    }

    /// The decision chain, in order. Returns nil for "no signal".
    func focusTarget(guestWidth: Int, guestHeight: Int, now: Date = Date()) -> KBFocusTarget? {
        if let tap = lastTap, !tap.consumed,
           now.timeIntervalSince(tap.at) <= 30,
           tap.target.guestWidth == guestWidth, tap.target.guestHeight == guestHeight {
            return tap.target
        }
        if let pointer = lastPointer, now.timeIntervalSince(pointer.movedAt) <= 120 {
            let rect = CGRect(x: pointer.point.x - 0.035, y: pointer.point.y - 0.030, width: 0.070, height: 0.060)
            return KBFocusTarget(point: pointer.point, rect: rect, fieldRect: nil, source: "pointer",
                                 guestWidth: guestWidth, guestHeight: guestHeight)
        }
        return nil
    }

    func consumeTap() { lastTap?.consumed = true }
}

// MARK: - The solver

enum KeyboardSolver {
    /// The rect the focus guarantee is checked against: the band with a 10 pt
    /// margin on top and sides; the bottom may sit flush with the band's
    /// bottom edge (region (10, 10, W-20, V-10)).
    static func innerRegion(band: CGRect) -> CGRect {
        CGRect(x: band.minX + 10, y: band.minY + 10, width: band.width - 20, height: band.height - 10)
    }

    static func viewRect(forNormalized rect: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + rect.minX * screen.width,
               y: screen.minY + rect.minY * screen.height,
               width: rect.width * screen.width,
               height: rect.height * screen.height)
    }

    static func fullyInside(_ rect: CGRect, _ region: CGRect) -> Bool {
        rect.minX >= region.minX - 0.001 && rect.minY >= region.minY - 0.001 &&
        rect.maxX <= region.maxX + 0.001 && rect.maxY <= region.maxY + 0.001
    }

    /// The occlusion gate: true when the target already sits fully
    /// inside the band under the base transform, so nothing should move.
    static func gatePasses(baseScreen: CGRect, band: CGRect, target: KBFocusTarget) -> Bool {
        fullyInside(viewRect(forNormalized: target.rect, in: baseScreen), innerRegion(band: band))
    }

    /// Solve the keyboard screen rect, or return nil when the gate passes.
    /// - fullHeight: the full-geometry height H of the solver formula (points).
    /// - band: the unobscured region in Layout coordinates.
    static func solve(baseScreen: CGRect, band: CGRect, fullHeight: CGFloat,
                      target: KBFocusTarget) -> CGRect? {
        guard band.height > 0, band.width > 0, baseScreen.width > 0, baseScreen.height > 0 else { return nil }
        if gatePasses(baseScreen: baseScreen, band: band, target: target) { return nil }
        let inner = innerRegion(band: band)
        var s = min(max(0.92 * fullHeight / band.height, 1.30), 1.80)
        var rect = place(scale: s, baseScreen: baseScreen, band: band, target: target)
        // Feasibility retry: an empty clamp interval raises S.
        while rect == nil && s < 2.00 {
            s = min(2.00, s + 0.10)
            rect = place(scale: s, baseScreen: baseScreen, band: band, target: target)
        }
        if rect == nil {
            // Still infeasible at the cap: accept the preferred placement
            // (the single coverage exception).
            rect = placePreferred(scale: 2.00, baseScreen: baseScreen, band: band, target: target)
            s = 2.00
        }
        var screen = rect!
        // Step 3, rect guarantee: shift so the target rect fits the inner
        // region; if it is taller/wider than the region at this scale,
        // reduce S toward 1.30, prioritising the field sub-rect.
        screen = shiftToFit(screen: screen, band: band, targetRect: target.rect)
        var viewTarget = viewRect(forNormalized: target.rect, in: screen)
        if (viewTarget.height > inner.height + 0.001 || viewTarget.width > inner.width + 0.001), s > 1.30 {
            let priority = target.fieldRect ?? target.rect
            while s > 1.30 {
                s = max(1.30, s - 0.05)
                if let placed = place(scale: s, baseScreen: baseScreen, band: band, target: target) {
                    screen = shiftToFit(screen: placed, band: band, targetRect: priority)
                    viewTarget = viewRect(forNormalized: priority, in: screen)
                    if viewTarget.height <= inner.height + 0.001 && viewTarget.width <= inner.width + 0.001 { break }
                }
            }
        }
        return screen
    }

    /// Placement. Returns nil when a clamp interval is empty.
    /// Origins follow the manual-zoom precedent in Layout (origin = desired
    /// focus view position - focus fraction * scaled size), which is the
    /// sign convention Layout's zoomed branch already uses.
    private static func place(scale s: CGFloat, baseScreen: CGRect, band: CGRect,
                              target: KBFocusTarget) -> CGRect? {
        let sw = s * baseScreen.width, sh = s * baseScreen.height
        let fx = target.point.x, fy = target.point.y
        let prefX = band.minX + 0.50 * band.width
        let prefY = band.minY + 0.55 * band.height
        let loX = band.maxX - (1 - fx) * sw, hiX = band.minX + fx * sw
        let loY = band.maxY - (1 - fy) * sh, hiY = band.minY + fy * sh
        guard loX <= hiX + 0.001, loY <= hiY + 0.001 else { return nil }
        let xt = min(max(prefX, loX), hiX)
        let yt = min(max(prefY, loY), hiY)
        return CGRect(x: xt - fx * sw, y: yt - fy * sh, width: sw, height: sh)
    }

    private static func placePreferred(scale s: CGFloat, baseScreen: CGRect, band: CGRect,
                                       target: KBFocusTarget) -> CGRect {
        let sw = s * baseScreen.width, sh = s * baseScreen.height
        let prefX = band.minX + 0.50 * band.width
        let prefY = band.minY + 0.55 * band.height
        return CGRect(x: prefX - target.point.x * sw, y: prefY - target.point.y * sh, width: sw, height: sh)
    }

    /// Shift a placed rect the minimum amount so the target rect sits inside
    /// the inner region (which shifts on Y only: the keyboard
    /// occludes from the bottom, and a horizontal shift for an edge-touching
    /// rect would break coverage on that side). The rect (field) wins
    /// over the point preference; coverage may yield at the band's bottom.
    private static func shiftToFit(screen: CGRect, band: CGRect, targetRect: CGRect) -> CGRect {
        let inner = innerRegion(band: band)
        var screen = screen
        var view = viewRect(forNormalized: targetRect, in: screen)
        if view.maxY > inner.maxY { screen.origin.y -= (view.maxY - inner.maxY) }
        view = viewRect(forNormalized: targetRect, in: screen)
        if view.minY < inner.minY { screen.origin.y += (inner.minY - view.minY) }
        return screen
    }
}

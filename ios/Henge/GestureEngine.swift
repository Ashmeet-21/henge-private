// GestureEngine.swift
//
// The click language for Henge's trackpad surface, factored into pure
// Foundation code so the exact shipped logic is exercised headlessly by
// tests/test_gesture_engine.swift. Trackpad.Surface (Trackpad.swift)
// is a thin adapter: it forwards every contact to the emulated pad,
// routes single-finger contacts into this engine, and executes only
// the engine's button actions against the henge-vm bridge. Pointer
// motion stays with the forwarded contacts and the guest's own
// trackpad driver, so the adapter drops the engine's motion actions,
// and no scroll engine is part of this change: a second finger
// suspends the arbitration (releasing any held button first) and the
// forwarded contacts carry the gesture from there.
//
// The language, as the pad adapter runs it (finger contacts, pad mode):
//
//   quick tap                       -> left click
//   press-and-hold, stationary      -> RIGHT click (the secondary
//                                      button goes down when the hold
//                                      threshold passes, and up at lift)
//   double tap, second press held   -> GRAB (primary button down at
//                                      the second press, drag until
//                                      lift)
//
// A press can no longer fire the primary button on contact: the
// contact opens a decision window and the outcomes are told apart by
// lift timing, stillness, travel and tap history. The click path pays
// no latency for this (a tap clicks on its lift, exactly as before),
// and the grab path pays none (the button goes down on the second
// press itself). Only the right click pays the hold threshold, which
// is the price of telling it apart from the others.
//
// The arbitration below also carries the absolute-mode and Pencil
// variants of the same language (position actions, a tighter Pencil
// slop, a grab radius in absolute mode); the pad adapter in this
// change runs it with direct == false for finger contacts only, and
// those variants are exercised by the harness at engine level.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// All arbitration timings in one place. holdThreshold is supplied
/// per surface (the values the app has always used per mode); the
/// rest are shared.
enum GestureTimings {
    /// A press lifted sooner than this, having barely moved, is a
    /// tap. The app's long-standing tap window.
    static let tapMaxDuration: TimeInterval = 0.3
    /// A second press landing within this of a tap's lift (and, in
    /// absolute mode, within grabRadius of the tap's point) is the
    /// grab press.
    static let doubleTapWindow: TimeInterval = 0.35
    /// Finger travel (accumulated path length, points) that still
    /// counts as "stationary" and below which a press can tap or
    /// hold. The app's long-standing tap distance.
    static let fingerSlop: CGFloat = 8
    /// Pencil travel that commits a draw/drag. The pen tip does not
    /// wander like a fingertip, so the commit radius is tight: a
    /// real stroke crosses it within a sample or two of motion,
    /// while a held-still pen stays well under it.
    static let pencilSlop: CGFloat = 2
    /// Absolute mode only: the grab press must land within this of
    /// the first tap's point. Without it, tap a button then quickly
    /// press-and-hold somewhere else for a right click would be
    /// stolen by the grab rule. About a finger width and a half.
    static let grabRadius: CGFloat = 32
}

enum GesturePointerKind {
    case finger
    case pencil
}

/// What a finished contact turned out to be; delivered as the last
/// action a contact produces, not as button logic.
enum GestureOutcome {
    case tap        // click emitted
    case right      // secondary button was held and released
    case grab       // grab press released
    case drag       // slop-committed drag released
    case none       // dead-band press, leftover finger, cancellation
}

enum GestureAction: Equatable {
    /// Absolute mode: move the guest pointer to this surface point.
    case moveAbs(CGPoint)
    /// Relative (pad) mode: move the guest pointer by this many
    /// surface points (the adapter applies speed and rounding).
    case moveRel(dx: CGFloat, dy: CGFloat)
    /// Press a button (0 primary, 1 secondary). `at` is the surface
    /// point in absolute mode, nil in pad mode (cursor position).
    case buttonDown(Int32, at: CGPoint?)
    /// Release a button.
    case buttonUp(Int32)
    /// A complete click (down+up) at a point: a tap.
    case click(Int32, at: CGPoint?)
    /// The contact finished as this outcome; always the last
    /// action a contact produces.
    case ended(GestureOutcome)
}

/// The single-contact arbitration state machine. One engine per
/// touch surface. It never sees a second simultaneous contact:
/// the adapter suspends it when a second finger lands and resumes a
/// leftover finger in a pass-through state.
final class GestureEngine {
    /// true: absolute pointing (positions come from the touch);
    /// false: pad (positions are the cursor's, moves are relative).
    let direct: Bool
    /// Seconds a stationary press must last to become a right
    /// click. Supplied by the surface (the pad adapter in this
    /// change supplies its long-standing 0.40).
    let holdThreshold: TimeInterval

    private enum State {
        case idle
        case deciding   // inside the decision window
        case dragging   // slop committed: primary down, moving
        case rightHeld  // hold fired: secondary down until lift
        case grabbing   // grab press: primary down since the press
        case leftover   // remainder finger after a multi-finger gesture: moves only
        case suspended  // a multi-finger gesture owns the surface
    }
    private var state: State = .idle

    private var kind: GesturePointerKind = .finger
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var pathLength: CGFloat = 0

    private var lastTap: (point: CGPoint, upTime: TimeInterval)?

    init(direct: Bool, holdThreshold: TimeInterval) {
        self.direct = direct
        self.holdThreshold = holdThreshold
    }

    private func slop(for kind: GesturePointerKind) -> CGFloat {
        kind == .pencil ? GestureTimings.pencilSlop : GestureTimings.fingerSlop
    }

    /// Absolute time at which the adapter should call tick, if any.
    var nextTickDeadline: TimeInterval? {
        state == .deciding ? startTime + holdThreshold : nil
    }

    var isActive: Bool { state != .idle && state != .suspended }

    private func positionAction(to point: CGPoint) -> GestureAction {
        direct ? .moveAbs(point) : .moveRel(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
    }

    /// A new contact lands. Returns the actions it produces (in
    /// absolute mode the pointer first moves to the contact point;
    /// a grab press also presses the primary button immediately).
    func down(kind: GesturePointerKind, point: CGPoint, time: TimeInterval) -> [GestureAction] {
        guard state == .idle else { return [] }
        self.kind = kind
        startPoint = point
        lastPoint = point
        startTime = time
        pathLength = 0
        if let tap = lastTap,
           time - tap.upTime <= GestureTimings.doubleTapWindow,
           !direct || hypot(point.x - tap.point.x, point.y - tap.point.y) <= GestureTimings.grabRadius {
            // The grab press: primary down NOW, drag until lift.
            lastTap = nil
            state = .grabbing
            if direct {
                return [.moveAbs(point), .buttonDown(0, at: point)]
            }
            return [.buttonDown(0, at: nil)]
        }
        state = .deciding
        return direct ? [.moveAbs(point)] : []
    }

    /// The contact moved to a new point.
    func move(point: CGPoint, time: TimeInterval) -> [GestureAction] {
        var actions = tick(time: time)
        switch state {
        case .deciding:
            let seg = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            pathLength += seg
            if direct && pathLength >= slop(for: kind) {
                // Slop commit: press at the current pointer position
                // (the pointer already tracks the contact), then let
                // this move carry the drag's first segment.
                state = .dragging
                actions.append(.buttonDown(0, at: lastPoint))
                actions.append(positionAction(to: point))
            } else {
                actions.append(positionAction(to: point))
            }
            lastPoint = point
        case .dragging, .grabbing, .rightHeld, .leftover:
            actions.append(positionAction(to: point))
            lastPoint = point
        case .idle, .suspended:
            break
        }
        return actions
    }

    /// Time passed with no event. Fires the right click when a
    /// still-stationary press crosses the hold threshold.
    func tick(time: TimeInterval) -> [GestureAction] {
        guard state == .deciding,
              time - startTime >= holdThreshold,
              pathLength < slop(for: kind) else { return [] }
        state = .rightHeld
        return [.buttonDown(1, at: direct ? lastPoint : nil)]
    }

    /// The contact lifted.
    func up(time: TimeInterval) -> [GestureAction] {
        // A lift arriving after the threshold without a timer tick
        // still converts to a right click first, then releases it.
        var actions = tick(time: time)
        switch state {
        case .deciding:
            let duration = time - startTime
            if duration < GestureTimings.tapMaxDuration && pathLength < slop(for: kind) {
                lastTap = (point: lastPoint, upTime: time)
                actions.append(.click(0, at: direct ? lastPoint : nil))
                actions.append(.ended(.tap))
            } else {
                actions.append(.ended(.none))
            }
        case .dragging:
            actions.append(.buttonUp(0))
            actions.append(.ended(.drag))
        case .grabbing:
            actions.append(.buttonUp(0))
            actions.append(.ended(.grab))
        case .rightHeld:
            actions.append(.buttonUp(1))
            actions.append(.ended(.right))
        case .leftover:
            actions.append(.ended(.none))
        case .idle, .suspended:
            return actions
        }
        state = .idle
        return actions
    }

    /// A second finger landed: the gesture leaves the click
    /// language. Any held button is released first (the app's
    /// standing behavior: a drag never survives into a
    /// multi-finger gesture).
    func cancelForScroll() -> [GestureAction] {
        var actions: [GestureAction] = []
        switch state {
        case .dragging, .grabbing: actions.append(.buttonUp(0))
        case .rightHeld: actions.append(.buttonUp(1))
        default: break
        }
        if state != .idle && state != .suspended {
            actions.append(.ended(.none))
        }
        lastTap = nil
        state = .suspended
        return actions
    }

    /// A multi-finger gesture ended with one finger still down. That
    /// finger becomes a pass-through: it can keep moving the
    /// pointer but can never click, hold or grab.
    func resumeLeftover(point: CGPoint) {
        guard state == .suspended else { return }
        lastPoint = point
        state = .leftover
    }

    /// The multi-finger gesture ended with nothing down.
    func scrollEnded() {
        if state == .suspended { state = .idle }
    }

    /// Hard stop: release whatever is held and forget everything
    /// (view detached, Pencil takeover, app teardown).
    func cancelAll() -> [GestureAction] {
        var actions: [GestureAction] = []
        switch state {
        case .dragging, .grabbing: actions.append(.buttonUp(0))
        case .rightHeld: actions.append(.buttonUp(1))
        default: break
        }
        if state != .idle {
            actions.append(.ended(.none))
        }
        lastTap = nil
        state = .idle
        return actions
    }
}


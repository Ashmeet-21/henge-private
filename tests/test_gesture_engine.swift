// Click-language harness: exercises the shipped GestureEngine.swift
// (compiled into this binary unchanged) with scripted touch streams
// and asserts the emitted action streams event for event, for the
// direct, Pencil, and pad variants of the click arbitration. The
// mapping and scroll sections of the full engine harness are not
// part of this change and are not included here.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
struct GestureEngineTests {
    static var failures = 0
    static var checks = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures += 1; print("FAIL: \(label)") }
    }

    static func expect(_ got: [GestureAction], _ want: [GestureAction], _ label: String) {
        check(got == want, "\(label): got \(got), want \(want)")
    }

    /// Bridge-level projection: what the guest would actually see.
    static func bridgeEvents(_ actions: [GestureAction]) -> [String] {
        var out: [String] = []
        for a in actions {
            switch a {
            case .buttonDown(let b, _): out.append("down\(b)")
            case .buttonUp(let b): out.append("up\(b)")
            case .click(let b, _): out.append("down\(b)"); out.append("up\(b)")
            default: break
            }
        }
        return out
    }

    static func directEngine() -> GestureEngine { GestureEngine(direct: true, holdThreshold: 0.35) }
    static func padEngine() -> GestureEngine { GestureEngine(direct: false, holdThreshold: 0.40) }
    static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static func main() {
        arbitrationDirect()
        arbitrationPencil()
        arbitrationPad()
        print("GESTURE HARNESS: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    // MARK: Arbitration, direct finger

    static func arbitrationDirect() {
        // A1: tap -> click only, at the tap point.
        do {
            let e = directEngine()
            var all: [GestureAction] = []
            all += e.down(kind: .finger, point: pt(100, 100), time: 0)
            let up = e.up(time: 0.12)
            all += up
            expect(up, [.click(0, at: pt(100, 100)), .ended(.tap)], "A1 tap")
            check(bridgeEvents(all) == ["down0", "up0"], "A1 bridge stream")
        }
        // A2: hold -> secondary only, zero primary events, moves after
        // the fire move the pointer but never become a drag.
        do {
            let e = directEngine()
            var all: [GestureAction] = []
            all += e.down(kind: .finger, point: pt(100, 100), time: 0)
            check(e.tick(time: 0.34).isEmpty, "A2 no fire before threshold")
            let fire = e.tick(time: 0.35)
            all += fire
            expect(fire, [.buttonDown(1, at: pt(100, 100))], "A2 right fires at threshold")
            let mv = e.move(point: pt(150, 100), time: 0.5)
            all += mv
            expect(mv, [.moveAbs(pt(150, 100))], "A2 move after fire is pointer-only")
            let up = e.up(time: 0.6)
            all += up
            expect(up, [.buttonUp(1), .ended(.right)], "A2 lift")
            check(!bridgeEvents(all).contains("down0"), "A2 zero primary events in whole stream")
        }
        // A3: double tap, second held -> grab: primary down AT the
        // second press, drag, up at lift.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(200, 200), time: 0)
            _ = e.up(time: 0.1)
            let press2 = e.down(kind: .finger, point: pt(200, 200), time: 0.3)
            expect(press2, [.moveAbs(pt(200, 200)), .buttonDown(0, at: pt(200, 200))], "A3 grab press is immediate")
            expect(e.move(point: pt(260, 200), time: 0.45), [.moveAbs(pt(260, 200))], "A3 grab drag move")
            expect(e.up(time: 0.6), [.buttonUp(0), .ended(.grab)], "A3 grab lift")
        }
        // A4: a quick second press is a plain second click at bridge
        // level (grab entry, released at once).
        do {
            let e = directEngine()
            var all: [GestureAction] = []
            all += e.down(kind: .finger, point: pt(200, 200), time: 0)
            all += e.up(time: 0.1)
            all += e.down(kind: .finger, point: pt(200, 200), time: 0.25)
            all += e.up(time: 0.35)
            check(bridgeEvents(all) == ["down0", "up0", "down0", "up0"], "A4 double tap = two clicks")
        }
        // A5: press-and-move -> drag commits at the slop crossing.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(50, 50), time: 0)
            let commit = e.move(point: pt(80, 50), time: 0.05)
            expect(commit, [.buttonDown(0, at: pt(50, 50)), .moveAbs(pt(80, 50))], "A5 drag commit")
            check(e.tick(time: 1.0).isEmpty, "A5 no right-fire after drag commit")
            expect(e.up(time: 0.4), [.buttonUp(0), .ended(.drag)], "A5 drag lift")
        }
        // A6: dead-band press (between tap window and hold threshold)
        // fires nothing, as the old recognizer behaved.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(10, 10), time: 0)
            expect(e.up(time: 0.32), [.ended(.none)], "A6 dead band")
        }
        // A7: a lift arriving after the threshold with no timer tick
        // still converts to a right click, then releases it.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(10, 10), time: 0)
            expect(e.up(time: 0.5), [.buttonDown(1, at: pt(10, 10)), .buttonUp(1), .ended(.right)], "A7 late lift converts")
        }
        // A8: grab radius: a press far from the tap is a fresh press
        // (its hold still right-clicks at the new point).
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(100, 100), time: 0)
            _ = e.up(time: 0.1)
            let press2 = e.down(kind: .finger, point: pt(200, 100), time: 0.3)
            expect(press2, [.moveAbs(pt(200, 100))], "A8 far press is not a grab")
            expect(e.tick(time: 0.65), [.buttonDown(1, at: pt(200, 100))], "A8 far press hold rights")
            _ = e.up(time: 0.7)
        }
        // A9: window expiry: a press after the double-tap window is fresh.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(100, 100), time: 0)
            _ = e.up(time: 0.1)
            let press2 = e.down(kind: .finger, point: pt(100, 100), time: 0.5)
            expect(press2, [.moveAbs(pt(100, 100))], "A9 late press is not a grab")
            expect(e.up(time: 0.6), [.click(0, at: pt(100, 100)), .ended(.tap)], "A9 late press taps")
        }
        // A10: a second finger cancels into scroll: a dragging button
        // is released, a deciding press emits nothing, and the
        // leftover finger afterwards can move but never click.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(50, 50), time: 0)
            _ = e.move(point: pt(80, 50), time: 0.05)
            expect(e.cancelForScroll(), [.buttonUp(0), .ended(.none)], "A10 drag released for scroll")
            e.resumeLeftover(point: pt(80, 50))
            expect(e.move(point: pt(120, 50), time: 0.3), [.moveAbs(pt(120, 50))], "A10 leftover moves only")
            expect(e.up(time: 0.4), [.ended(.none)], "A10 leftover never clicks")

            let e2 = directEngine()
            _ = e2.down(kind: .finger, point: pt(50, 50), time: 0)
            let cancel = e2.cancelForScroll()
            check(bridgeEvents(cancel).isEmpty, "A10 deciding cancel emits no buttons")
            e2.scrollEnded()
        }
        // A11: scroll cancel while the right button is held releases it.
        do {
            let e = directEngine()
            _ = e.down(kind: .finger, point: pt(50, 50), time: 0)
            _ = e.tick(time: 0.35)
            expect(e.cancelForScroll(), [.buttonUp(1), .ended(.none)], "A11 right released for scroll")
            e.scrollEnded()
        }
    }

    // MARK: Arbitration, Pencil (same language, tighter slop)

    static func arbitrationPencil() {
        // B1: pen tap clicks at the pen point.
        do {
            let e = directEngine()
            _ = e.down(kind: .pencil, point: pt(300, 300), time: 0)
            expect(e.up(time: 0.1), [.click(0, at: pt(300, 300)), .ended(.tap)], "B1 pen tap")
        }
        // B2: a stroke commits to drawing within the tight slop and a
        // long stationary pause AFTER committing never right-clicks.
        do {
            let e = directEngine()
            _ = e.down(kind: .pencil, point: pt(300, 300), time: 0)
            let commit = e.move(point: pt(305, 300), time: 0.03)
            expect(commit, [.buttonDown(0, at: pt(300, 300)), .moveAbs(pt(305, 300))], "B2 draw commit at 5pt")
            check(e.tick(time: 1.0).isEmpty, "B2 no right-fire mid-stroke")
            expect(e.up(time: 1.1), [.buttonUp(0), .ended(.drag)], "B2 stroke lift")
        }
        // B3: a pen held truly still right-clicks, with zero primary.
        do {
            let e = directEngine()
            var all: [GestureAction] = []
            all += e.down(kind: .pencil, point: pt(300, 300), time: 0)
            all += e.tick(time: 0.35)
            all += e.up(time: 0.5)
            check(bridgeEvents(all) == ["down1", "up1"], "B3 pen hold = secondary only")
        }
        // B4: pen double-tap-hold grabs.
        do {
            let e = directEngine()
            _ = e.down(kind: .pencil, point: pt(300, 300), time: 0)
            _ = e.up(time: 0.1)
            let press2 = e.down(kind: .pencil, point: pt(302, 300), time: 0.28)
            expect(press2, [.moveAbs(pt(302, 300)), .buttonDown(0, at: pt(302, 300))], "B4 pen grab press")
            expect(e.up(time: 0.5), [.buttonUp(0), .ended(.grab)], "B4 pen grab lift")
        }
    }

    // MARK: Arbitration, pad (relative) mode

    static func arbitrationPad() {
        // C1: pad tap clicks at the cursor (no position actions).
        do {
            let e = padEngine()
            expect(e.down(kind: .finger, point: pt(10, 10), time: 0), [], "C1 pad press emits nothing")
            expect(e.up(time: 0.12), [.click(0, at: nil), .ended(.tap)], "C1 pad tap")
        }
        // C2: pad hold right-clicks at the hold threshold.
        do {
            let e = padEngine()
            _ = e.down(kind: .finger, point: pt(10, 10), time: 0)
            check(e.tick(time: 0.39).isEmpty, "C2 no early fire")
            expect(e.tick(time: 0.40), [.buttonDown(1, at: nil)], "C2 pad right fire")
            expect(e.up(time: 0.5), [.buttonUp(1), .ended(.right)], "C2 pad right lift")
        }
        // C3: pad press-and-move is cursor motion, never a drag, and a
        // well-travelled press never right-fires either.
        do {
            let e = padEngine()
            var all: [GestureAction] = []
            all += e.down(kind: .finger, point: pt(10, 10), time: 0)
            all += e.move(point: pt(70, 10), time: 0.1)
            check(bridgeEvents(all).isEmpty, "C3 pad move presses nothing")
            check(e.tick(time: 1.0).isEmpty, "C3 travelled press never rights")
            expect(e.up(time: 1.1), [.ended(.none)], "C3 travelled press ends inert")
        }
        // C4: pad double-tap-hold grabs at the cursor.
        do {
            let e = padEngine()
            _ = e.down(kind: .finger, point: pt(10, 10), time: 0)
            _ = e.up(time: 0.1)
            expect(e.down(kind: .finger, point: pt(10, 10), time: 0.28), [.buttonDown(0, at: nil)], "C4 pad grab press")
            let mv = e.move(point: pt(40, 10), time: 0.4)
            check(mv.count == 1, "C4 pad grab drags relatively")
            expect(e.up(time: 0.5), [.buttonUp(0), .ended(.grab)], "C4 pad grab lift")
        }
        // C5: a pad press that wiggles within the slop still holds.
        do {
            let e = padEngine()
            _ = e.down(kind: .finger, point: pt(10, 10), time: 0)
            _ = e.move(point: pt(13, 10), time: 0.1)
            _ = e.move(point: pt(10, 10), time: 0.2)
            expect(e.tick(time: 0.40), [.buttonDown(1, at: nil)], "C5 within-slop wiggle still rights")
            _ = e.up(time: 0.5)
        }
    }

}

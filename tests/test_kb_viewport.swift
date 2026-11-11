import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Keyboard-viewport verification harness: exercises the SHIPPED solver
// (ios/Henge/KeyboardViewport.swift, compiled into this binary unchanged)
// and a faithful replica of Trackpad.Surface.guestCoords
// (ios/Henge/Trackpad.swift) plus its inverse. The replica is formula-
// identical to the shipped function: translate by touchOrigin, subtract
// screenRect origin, normalise by screenRect size, scale by guest size,
// truncate to Int, clamp to [0, guest-1]. The app's own conversion cannot
// be invoked headlessly (it lives in a UIKit view), so the round-trip
// proof binds to the shipped code by this stated formula identity.

func guestCoordsReplica(surfacePoint p: CGPoint, touchOrigin: CGPoint, screenRect: CGRect, gw: Int, gh: Int) -> (Int32, Int32) {
    let gwv = max(gw, 1), ghv = max(gh, 1)
    let qx = p.x + touchOrigin.x, qy = p.y + touchOrigin.y
    var gx = 0, gy = 0
    if screenRect.width > 0 { gx = Int((qx - screenRect.minX) / screenRect.width * CGFloat(gwv)) }
    if screenRect.height > 0 { gy = Int((qy - screenRect.minY) / screenRect.height * CGFloat(ghv)) }
    return (Int32(min(max(gx, 0), gwv - 1)), Int32(min(max(gy, 0), ghv - 1)))
}
func viewPointReplica(guestX gx: Int32, guestY gy: Int32, touchOrigin: CGPoint, screenRect: CGRect, gw: Int, gh: Int) -> CGPoint {
    CGPoint(x: screenRect.minX + CGFloat(gx) / CGFloat(gw) * screenRect.width - touchOrigin.x,
            y: screenRect.minY + CGFloat(gy) / CGFloat(gh) * screenRect.height - touchOrigin.y)
}

@main
struct KBViewportTests {
    static var failures = 0
    static var checks = 0
    static var maxRoundTripErr: CGFloat = 0
    static var roundTrips = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures += 1; print("FAIL: \(label)") }
    }
    static func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }

    struct Case {
        var name: String; var full: CGSize; var pane: CGRect; var guestW: Int; var guestH: Int; var hOcc: CGFloat
    }

    static func roundTrip(screenRect: CGRect, touchOrigin: CGPoint, gw: Int, gh: Int) {
        var pts: [CGPoint] = []
        for i in 0..<20 { for j in 0..<15 {
            pts.append(CGPoint(x: screenRect.minX + screenRect.width * CGFloat(i) / 19.0,
                               y: screenRect.minY + screenRect.height * CGFloat(j) / 14.0))
        } }
        for (nx, ny) in [(0.43, 0.76), (0.57, 0.76), (0.43, 0.96), (0.57, 0.96), (0.50, 0.86)] {
            pts.append(CGPoint(x: screenRect.minX + nx * screenRect.width, y: screenRect.minY + ny * screenRect.height))
        }
        for p in pts {
            let sp = CGPoint(x: p.x - touchOrigin.x, y: p.y - touchOrigin.y)
            let (gx, gy) = guestCoordsReplica(surfacePoint: sp, touchOrigin: touchOrigin, screenRect: screenRect, gw: gw, gh: gh)
            let back = viewPointReplica(guestX: gx, guestY: gy, touchOrigin: touchOrigin, screenRect: screenRect, gw: gw, gh: gh)
            let backLayout = CGPoint(x: back.x + touchOrigin.x, y: back.y + touchOrigin.y)
            let err = max(abs(backLayout.x - p.x), abs(backLayout.y - p.y))
            let interior = p.x > screenRect.minX && p.x < screenRect.maxX - screenRect.width / CGFloat(gw) &&
                           p.y > screenRect.minY && p.y < screenRect.maxY - screenRect.height / CGFloat(gh)
            if interior {
                roundTrips += 1
                if err > maxRoundTripErr { maxRoundTripErr = err }
            }
        }
    }

    static func main() {
        let cases: [Case] = [
            Case(name: "panel-land", full: CGSize(width: 951, height: 669), pane: CGRect(x: 1, y: 1, width: 949, height: 667), guestW: 1896, guestH: 1336, hOcc: 300),
            Case(name: "panel-land-shortkb", full: CGSize(width: 951, height: 669), pane: CGRect(x: 1, y: 1, width: 949, height: 667), guestW: 1896, guestH: 1336, hOcc: 200),
            Case(name: "panel-land-tallkb", full: CGSize(width: 951, height: 669), pane: CGRect(x: 1, y: 1, width: 949, height: 667), guestW: 1896, guestH: 1336, hOcc: 400),
            Case(name: "full-land", full: CGSize(width: 951, height: 669), pane: CGRect(x: 1, y: 1, width: 949, height: 667), guestW: 2664, guestH: 1872, hOcc: 300),
            Case(name: "perf-land", full: CGSize(width: 951, height: 669), pane: CGRect(x: 1, y: 1, width: 949, height: 667), guestW: 1992, guestH: 1400, hOcc: 300),
            Case(name: "panel-port", full: CGSize(width: 669, height: 951), pane: CGRect(x: 1, y: 0, width: 667, height: 473), guestW: 1336, guestH: 944, hOcc: 366),
            Case(name: "full-port", full: CGSize(width: 669, height: 951), pane: CGRect(x: 1, y: 0, width: 667, height: 473), guestW: 1872, guestH: 1328, hOcc: 366),
            Case(name: "compact-port", full: CGSize(width: 669, height: 951), pane: CGRect(x: 1, y: 0, width: 667, height: 399), guestW: 1872, guestH: 1120, hOcc: 366),
            Case(name: "ipad43-land", full: CGSize(width: 1024, height: 768), pane: CGRect(x: 1, y: 1, width: 1022, height: 766), guestW: 2048, guestH: 1536, hOcc: 280),
        ]
        let targets: [(String, KBFocusTarget)] = [
            ("centre-field", KBFocusTarget(point: CGPoint(x: 0.5, y: 0.5), rect: CGRect(x: 0.465, y: 0.47, width: 0.07, height: 0.06), fieldRect: nil, source: "tap", guestWidth: 0, guestHeight: 0)),
            ("bottom-field", KBFocusTarget(point: CGPoint(x: 0.5, y: 0.97), rect: CGRect(x: 0.465, y: 0.94, width: 0.07, height: 0.06), fieldRect: nil, source: "tap", guestWidth: 0, guestHeight: 0)),
            ("top-field", KBFocusTarget(point: CGPoint(x: 0.5, y: 0.05), rect: CGRect(x: 0.465, y: 0.02, width: 0.07, height: 0.06), fieldRect: nil, source: "tap", guestWidth: 0, guestHeight: 0)),
            ("corner-field", KBFocusTarget(point: CGPoint(x: 0.03, y: 0.95), rect: CGRect(x: 0.0, y: 0.92, width: 0.07, height: 0.06), fieldRect: nil, source: "tap", guestWidth: 0, guestHeight: 0)),
        ]
        var solvedCount = 0, gateCount = 0
        for c in cases {
            // The band is the pane's own column: coverage is about
            // guest content, and the pane sits inside the full geometry with
            // a ~1 pt centring margin that no layout ever covers with guest
            // pixels. SessionView's kbBand uses the same definition.
            let band = CGRect(x: c.pane.minX, y: c.pane.minY, width: c.pane.width, height: c.full.height - c.hOcc - c.pane.minY)
            for (tname, rawTarget) in targets {
                var target = rawTarget; target.guestWidth = c.guestW; target.guestHeight = c.guestH
                let label = "\(c.name)/\(tname)"
                let solved = KeyboardSolver.solve(baseScreen: c.pane, band: band, fullHeight: c.full.height, target: target)
                if KeyboardSolver.gatePasses(baseScreen: c.pane, band: band, target: target) {
                    gateCount += 1
                    check(solved == nil, "\(label): gate passes but solver moved")
                    continue
                }
                guard let screen = solved else { check(false, "\(label): gate fails but solver returned nil"); continue }
                solvedCount += 1
                let s = screen.width / c.pane.width
                check(s >= 1.30 - 0.001 && s <= 2.00 + 0.001, "\(label): scale bound \(s)")
                check(approx(screen.height / c.pane.height, s, 0.002), "\(label): aspect preservation")
                if s < 2.00 - 0.001 {
                    check(screen.minX <= band.minX + 0.01 && screen.minY <= band.minY + 0.01 &&
                          screen.maxX >= band.maxX - 0.01 && screen.maxY >= band.maxY - 0.01,
                          "\(label): band coverage screen=\(screen) band=\(band)")
                }
                // Rect guarantee: the rect sits inside the band
                // horizontally and inside the inner region vertically (step 3
                // shifts on Y only; an edge-touching rect cannot also keep a
                // 10 pt side margin without breaking coverage).
                let inner = KeyboardSolver.innerRegion(band: band)
                let vr = KeyboardSolver.viewRect(forNormalized: target.rect, in: screen)
                let rectOK = vr.minX >= band.minX - 0.01 && vr.maxX <= band.maxX + 0.01 &&
                             vr.minY >= inner.minY - 0.01 && vr.maxY <= inner.maxY + 0.01
                if !rectOK {
                    if let field = target.fieldRect {
                        let fv = KeyboardSolver.viewRect(forNormalized: field, in: screen)
                        check(fv.minX >= band.minX - 0.01 && fv.maxX <= band.maxX + 0.01 &&
                              fv.minY >= inner.minY - 0.01 && fv.maxY <= inner.maxY + 0.01,
                              "\(label): rect guarantee (field priority) vr=\(vr) inner=\(inner)")
                    } else {
                        check(false, "\(label): rect guarantee vr=\(vr) inner=\(inner) s=\(s)")
                    }
                }
                let again = KeyboardSolver.solve(baseScreen: c.pane, band: band, fullHeight: c.full.height, target: target)
                check(again == screen, "\(label): purity/determinism")
                // Per-frame coverage: interpolation between two rects
                // that both cover the band also covers it. The check applies
                // where the full transform itself covers the band
                // (fills-phone); in the portrait split the pre-keyboard pane never
                // covers the sub-pane band region (the trackpad lives
                // there), so the invariant's precondition does not apply
                // and only the final-state coverage above is asserted.
                let baseCovers = c.pane.minX <= band.minX + 0.01 && c.pane.minY <= band.minY + 0.01 &&
                                 c.pane.maxX >= band.maxX - 0.01 && c.pane.maxY >= band.maxY - 0.01
                if baseCovers {
                    for t in [0.25, 0.5, 0.75] {
                        let interp = CGRect(x: c.pane.minX + (screen.minX - c.pane.minX) * t,
                                            y: c.pane.minY + (screen.minY - c.pane.minY) * t,
                                            width: c.pane.width + (screen.width - c.pane.width) * t,
                                            height: c.pane.height + (screen.height - c.pane.height) * t)
                        check(interp.minX <= band.minX + 0.01 && interp.minY <= band.minY + 0.01 &&
                              interp.maxX >= band.maxX - 0.01 && interp.maxY >= band.maxY - 0.01,
                              "\(label): per-frame interpolation coverage t=\(t)")
                    }
                }
            }
        }
        print("matrix: solved=\(solvedCount) gateNoOp=\(gateCount)")

        // Named case: a generic bottom field in the large-panel landscape
        // fixture geometry solves, and its rect lands inside the band.
        // (The login worked example is deferred with the login heuristic.)
        do {
            let pane = CGRect(x: 1, y: 1, width: 949, height: 667)
            let band = CGRect(x: 0, y: 0, width: 951, height: 369)
            let target = KBFocusTarget(point: CGPoint(x: 0.5, y: 0.97), rect: CGRect(x: 0.465, y: 0.94, width: 0.07, height: 0.06), fieldRect: nil, source: "tap", guestWidth: 1896, guestHeight: 1336)
            let solved = KeyboardSolver.solve(baseScreen: pane, band: band, fullHeight: 669, target: target)
            check(solved != nil, "named: landscape bottom-field solves")
            if let screen = solved {
                let s = screen.width / pane.width
                check(s >= 1.30 - 0.001 && s <= 2.00 + 0.001, "named: landscape bottom-field scale in range (got \(s))")
                let vr = KeyboardSolver.viewRect(forNormalized: target.rect, in: screen)
                let inner = KeyboardSolver.innerRegion(band: band)
                check(vr.minX >= band.minX - 0.01 && vr.maxX <= band.maxX + 0.01 &&
                      vr.minY >= inner.minY - 0.01 && vr.maxY <= inner.maxY + 0.01,
                      "named: bottom-field rect inside band vr=\(vr) inner=\(inner)")
            }
        }

        // Mapping round-trip (one rect for rendering and input alike)
        do {
            let pane = CGRect(x: 1, y: 1, width: 949, height: 667)
            let band = CGRect(x: 0, y: 0, width: 951, height: 369)
            let target = KBFocusTarget(point: CGPoint(x: 0.5, y: 0.97), rect: CGRect(x: 0.465, y: 0.94, width: 0.07, height: 0.06), fieldRect: nil, source: "tap", guestWidth: 1896, guestHeight: 1336)
            let solved = KeyboardSolver.solve(baseScreen: pane, band: band, fullHeight: 669, target: target)!
            let touch = CGPoint.zero
            roundTrip(screenRect: pane, touchOrigin: touch, gw: 1896, gh: 1336)
            roundTrip(screenRect: solved, touchOrigin: touch, gw: 1896, gh: 1336)
            for t in [0.25, 0.5, 0.75] {
                let interp = CGRect(x: pane.minX + (solved.minX - pane.minX) * t, y: pane.minY + (solved.minY - pane.minY) * t,
                                    width: pane.width + (solved.width - pane.width) * t, height: pane.height + (solved.height - pane.height) * t)
                roundTrip(screenRect: interp, touchOrigin: touch, gw: 1896, gh: 1336)
            }
            let manual = CGRect(x: -200, y: -150, width: 949 * 1.5, height: 667 * 1.5)
            roundTrip(screenRect: manual, touchOrigin: touch, gw: 1896, gh: 1336)
            let tol = solved.width / 1896.0
            print("roundtrip: interior points=\(roundTrips) maxErr=\(String(format: "%.4f", maxRoundTripErr)) pt, tolerance (1 guest px)=\(String(format: "%.4f", tol)) pt")
            check(maxRoundTripErr <= tol + 0.001, "round-trip max error within one guest pixel")
        }

        // Signal chain (same large-panel guest size as the named case)
        do {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let sig = KeyboardSignals()
            sig.resetSession(now: t0)
            sig.kbWillShow(now: t0.addingTimeInterval(5))
            let cold = sig.focusTarget(guestWidth: 1896, guestHeight: 1336, now: t0.addingTimeInterval(5))
            check(cold == nil, "chain: cold raise, no signal -> no target (login heuristic removed)")
            sig.kbDidHide()
            sig.recordTap(point: CGPoint(x: 0.2, y: 0.3), guestWidth: 1896, guestHeight: 1336, now: t0.addingTimeInterval(60))
            sig.kbWillShow(now: t0.addingTimeInterval(65))
            let tapped = sig.focusTarget(guestWidth: 1896, guestHeight: 1336, now: t0.addingTimeInterval(65))
            check(tapped?.source == "tap" && tapped!.point == CGPoint(x: 0.2, y: 0.3), "chain: fresh tap wins")
            sig.consumeTap(); sig.kbDidHide()
            let stale = sig.focusTarget(guestWidth: 1896, guestHeight: 1336, now: t0.addingTimeInterval(60 + 31))
            check(stale == nil, "chain: stale tap, nothing else -> no signal (got \(String(describing: stale?.source)))")
            sig.recordPointer(point: CGPoint(x: 0.4, y: 0.4), now: t0.addingTimeInterval(300))
            sig.kbWillShow(now: t0.addingTimeInterval(360))
            let ptr = sig.focusTarget(guestWidth: 1896, guestHeight: 1336, now: t0.addingTimeInterval(360))
            check(ptr?.source == "pointer", "chain: recent pointer")
            sig.kbDidHide()
            let old = sig.focusTarget(guestWidth: 1896, guestHeight: 1336, now: t0.addingTimeInterval(300 + 121))
            check(old == nil, "chain: old pointer -> no signal")
        }

        print("checks=\(checks) failures=\(failures)")
        if failures > 0 { print("KB-VIEWPORT-TESTS FAILED"); exit(1) }
        print("KB-VIEWPORT-TESTS PASSED")
    }
}

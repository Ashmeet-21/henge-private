import SwiftUI
import UIKit

/// A Mac app's screen (Mac apps with windows, experimental): the windows Henge's AppKit hands over, scaled to fit,
/// with touches as a mouse (tap to click, one finger to scroll, two fingers to drag, long press for a right click)
/// and the iOS keyboard as a Mac keyboard.
final class MacScreenUIView: UIView, UIKeyInput {
    private let stage = CALayer()
    private var holders: [CALayer] = []
    var screen = CGSize(width: 1180, height: 680)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        stage.anchorPoint = .zero
        stage.isGeometryFlipped = true // the Mac's way up: origin at the bottom left
        stage.masksToBounds = true
        stage.backgroundColor = UIColor(white: 0.16, alpha: 1).cgColor
        layer.addSublayer(stage)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        // One finger scrolls, as everywhere on iOS; two fingers drag with the mouse button down (select, move).
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        for g in [tap, doubleTap, pan, scroll, press] as [UIGestureRecognizer] { addGestureRecognizer(g) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fit: CGFloat { min(bounds.width / max(screen.width, 1), bounds.height / max(screen.height, 1)) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = fit
        stage.bounds = CGRect(origin: .zero, size: screen)
        stage.transform = CATransform3DMakeScale(s, s, 1)
        stage.position = CGPoint(x: (bounds.width - screen.width * s) / 2, y: (bounds.height - screen.height * s) / 2)
        CATransaction.commit()
    }

    /// Puts every window the app shows at its place, back to front.
    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holders.forEach { $0.removeFromSuperlayer() }
        holders.removeAll()
        let count = Int(henge_tl_app_window_count())
        for i in 0..<count {
            guard let raw = henge_tl_app_window_layer(Int32(i)) else { continue }
            let root = Unmanaged<CALayer>.fromOpaque(raw).takeUnretainedValue()
            var x = 0.0, y = 0.0, w = 0.0, h = 0.0
            guard henge_tl_app_window_frame(Int32(i), &x, &y, &w, &h) == 0 else { continue }
            let holder = CALayer()
            holder.anchorPoint = .zero
            holder.frame = CGRect(x: x, y: y, width: w, height: h)
            root.removeFromSuperlayer()
            holder.addSublayer(root)
            stage.addSublayer(holder)
            holders.append(holder)
        }
        CATransaction.commit()
    }

    /// A point in this view to the Mac's screen (points, origin at the bottom left).
    private func mac(_ p: CGPoint) -> CGPoint { stage.convert(p, from: layer) }

    private func mouse(_ type: Int32, _ p: CGPoint, clicks: Int32 = 1, flags: UInt = 0) {
        let m = mac(p)
        henge_tl_app_mouse(type, m.x, m.y, clicks, flags)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        mouse(5, p, clicks: 0)
        mouse(1, p)
        mouse(2, p)
    }

    /// The keyboard button: the iOS keyboard comes up as the Mac's keyboard, or goes.
    func toggleKeyboard() {
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        mouse(1, p, clicks: 1)
        mouse(2, p, clicks: 1)
        mouse(1, p, clicks: 2)
        mouse(2, p, clicks: 2)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began: mouse(1, p)
        case .changed: mouse(6, p)
        case .ended, .cancelled, .failed: mouse(2, p)
        default: break
        }
    }

    private var lastScroll = CGPoint.zero
    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self), p = mac(g.location(in: self))
        let phase: Int32 = g.state == .began ? 1 : (g.state == .ended || g.state == .cancelled) ? 8 : 4
        if g.state == .began { lastScroll = .zero }
        let s = max(fit, 0.01)
        henge_tl_app_scroll(p.x, p.y, (t.x - lastScroll.x) / s, (t.y - lastScroll.y) / s, phase)
        lastScroll = t
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        mouse(3, p)
        mouse(4, p)
    }

    // MARK: the keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for ch in text {
            let s = String(ch)
            if s == "\n" { key(36, "\r"); continue }
            let (code, shift) = MacKeys.code(for: ch)
            key(code, s, flags: shift ? 1 << 17 : 0)
        }
    }

    func deleteBackward() { key(51, "\u{7f}") }

    private func key(_ code: UInt16, _ chars: String, flags: UInt = 0) {
        chars.withCString { c in
            henge_tl_app_key(1, code, c, flags)
            henge_tl_app_key(0, code, c, flags)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let k = p.key, let code = MacKeys.special[k.keyCode] else { continue }
            let chars = code.1.isEmpty ? k.characters : code.1
            henge_tl_app_key(1, code.0, chars, MacKeys.flags(k.modifierFlags))
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let k = p.key, let code = MacKeys.special[k.keyCode] else { continue }
            henge_tl_app_key(0, code.0, code.1, MacKeys.flags(k.modifierFlags))
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }
}

/// The Mac's key codes (Carbon's kVK_ values) for what the iOS keyboard types.
enum MacKeys {
    private static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func code(for ch: Character) -> (UInt16, Bool) {
        if let c = ansi[ch] { return (c, false) }
        if ch.isUppercase, let lower = ch.lowercased().first, let c = ansi[lower] { return (c, true) }
        if let base = shifted[ch], let c = ansi[base] { return (c, true) }
        return (0, false)
    }

    /// Hardware-keyboard keys the text path doesn't carry: arrows, escape, return, delete, tab.
    static let special: [UIKeyboardHIDUsage: (UInt16, String)] = [
        .keyboardLeftArrow: (123, "\u{F702}"), .keyboardRightArrow: (124, "\u{F703}"), .keyboardDownArrow: (125, "\u{F701}"),
        .keyboardUpArrow: (126, "\u{F700}"), .keyboardEscape: (53, "\u{1b}"), .keyboardReturnOrEnter: (36, "\r"),
        .keyboardDeleteOrBackspace: (51, "\u{7f}"), .keyboardTab: (48, "\t"),
    ]

    static func flags(_ m: UIKeyModifierFlags) -> UInt {
        var f: UInt = 0
        if m.contains(.shift) { f |= 1 << 17 }
        if m.contains(.control) { f |= 1 << 18 }
        if m.contains(.alternate) { f |= 1 << 19 }
        if m.contains(.command) { f |= 1 << 20 }
        return f
    }
}

struct MacScreenView: UIViewRepresentable {
    let screen: CGSize
    func makeUIView(context: Context) -> MacScreenUIView {
        let v = MacScreenUIView()
        v.screen = screen
        MacScreenHub.shared.view = v
        return v
    }
    func updateUIView(_ v: MacScreenUIView, context: Context) { v.refresh() }
}

/// Where Henge's AppKit's "a window changed" lands (a C callback, on the main thread).
final class MacScreenHub {
    static let shared = MacScreenHub()
    weak var view: MacScreenUIView?
}

/// The full-screen place a windowed Mac app runs in: loads it, enters its main, shows its windows.
struct MacAppScreen: View {
    let app: MacApp
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Loading…"
    @State private var started = false
    private let screen = MacAppScreen.screenSize()

    /// The Mac's screen in points: the device's long side by short side, made a little larger than the device so
    /// a desktop app has room (it is shown scaled down to fit).
    static func screenSize() -> CGSize {
        let b = UIScreen.main.bounds.size
        let long = max(b.width, b.height), short = min(b.width, b.height)
        let zoom: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 1.0 : 1.35
        return CGSize(width: (long * zoom).rounded(), height: (short * zoom).rounded())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MacScreenView(screen: screen).ignoresSafeArea()
            Button { MacScreenHub.shared.view?.toggleKeyboard() } label: {
                Image(systemName: "keyboard").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .frame(width: 38, height: 38).background(.black.opacity(0.45), in: Circle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(14)
            if !started || !status.isEmpty {
                Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule()).padding(16)
            }
        }
        .statusBarHidden()
        .task { await start() }
    }

    private func start() async {
        guard !started else { return }
        started = true
        // 2x at most: the Mac's screen is shown scaled down to fit, and the app draws in software
        henge_tl_app_set_screen(screen.width, screen.height, min(UIScreen.main.scale, 2))
        henge_tl_app_on_change { MacScreenHub.shared.view?.refresh() }
        let path = app.url.path
        HengeLog.log("macapps", "opening \(app.name) with windows (\(path))")
        let failure: String? = await Task.detached(priority: .userInitiated) {
            var err = [CChar](repeating: 0, count: 512)
            return henge_tl_app_load(path, &err, err.count) == 0 ? nil : String(cString: err)
        }.value
        if let failure {
            HengeLog.log("macapps", "could not load \(app.name): \(failure)")
            status = "Could not open it: \(failure)"
            return
        }
        status = "Starting…"
        henge_tl_app_run_soon { rc in
            HengeLog.log("macapps", "the app's main returned \(rc)")
        }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        status = ""
    }
}

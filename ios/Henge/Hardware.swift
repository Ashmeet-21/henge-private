import SwiftUI
import UIKit
import GameController
import Metal

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads are
    /// squarer than 16:9, which would leave bars above and below. Phones use the full-screen viewport
    /// plan instead: the guest is the display's own native pixels, so it fills the device exactly.
    static var fittingScreen: (width: Int, height: Int) {
        guard isPad else { return ViewportPlan.fullScreenGuest }
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)) / 8 * 8, Int(min(n.width, n.height)) / 8 * 8)
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// The chip's name ("Apple A20 Pro"). iOS has no name for the CPU (machdep.cpu.brand_string is empty on an
    /// iPhone), but Metal names the GPU after the chip: "Apple A20 Pro GPU".
    static var chipName: String? {
        guard var name = MTLCreateSystemDefaultDevice()?.name.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.hasSuffix(" GPU") { name.removeLast(4) }
        return name.hasPrefix("Apple ") && name.count > 6 ? name : nil
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        // About 6 GB: a 4 GB Mac ran the phone out of memory once booted (jetsam vm-pageshortage); 3 GB ran (#70 too).
        // 4 GB devices, 2.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : mb >= 7_000 ? 4 : mb >= 5_000 ? 3 : 2
    }

    /// A device with about 6 GB (A14, A15 and A16 iPads and iPhones). iOS has no swap on these and gives an app
    /// about 4 GB, so the code region and the Mac's memory have to fit in that together.
    static let hasLittleMemory = ProcessInfo.processInfo.physicalMemory >> 20 < 7_000

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < 4 && !hasLittleMemory { return "macOS has little room under 4 GB, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."
}

/// A per-start display profile: a named Start-time choice of guest size, resolved through
/// ViewportPlan and remembered per machine, per posture class (VirtualMac.profileLandscape /
/// profilePortrait). Profiles are behaviour, not data: the definitions live here in code, the
/// machine record stores only the chosen raw value, and an absent choice means Full.
/// Sizing is boot-time only, exactly like the display mode itself: a profile applies at the
/// next Start and never changes a running session.
enum DisplayProfile: String, CaseIterable {
    case full, perf, splitCompact

    /// The guest-size scale against the Full guest size. Split-compact does not scale the
    /// guest; it shrinks the portrait pane instead (portraitPaneFraction).
    var scale: CGFloat {
        switch self {
        case .full, .splitCompact: return 1
        case .perf: return 0.75
        }
    }

    /// The fraction of the scene height the portrait split pane takes. Today's split is the
    /// top half; Split-compact takes the top 0.42, giving the bottom surface the difference.
    var portraitPaneFraction: CGFloat { self == .splitCompact ? 0.42 : 0.5 }

    var displayName: String {
        switch self {
        case .full: return "Full"
        case .perf: return "Perf"
        case .splitCompact: return "Split-compact"
        }
    }

    /// The profile's scale applied to a stored screen size (the record-size surface, e.g. the
    /// host default 1920x1080): multiply by the scale, floored to an even dimension.
    /// 1920x1080 at Perf is 1440x810. ViewportPlan's own Perf derivation floors to a
    /// multiple of 8 instead, as pane-derived guest sizes always have (2664x1872 at Perf
    /// is 1992x1400); the two surfaces keep their own granularity, the scale is the same.
    static func scaledScreenSize(width: Int, height: Int, profile: DisplayProfile) -> (width: Int, height: Int) {
        guard profile == .perf else { return (width, height) }
        func scaled(_ dimension: Int) -> Int { max(64, Int(CGFloat(dimension) * profile.scale) / 2 * 2) }
        return (scaled(width), scaled(height))
    }
}

/// How a Mac's screen maps onto this device for one session: the pane it occupies (points, in the
/// session's full-geometry coordinates) and the size macOS is told its screen is (physical pixels).
/// One plan, from the active window scene, gives both the size handed to the engine at boot and
/// the guest size pointer following normalizes against, so the two always describe the same
/// rectangle: the guest framebuffer is the pane at the scene screen's native scale, and the pane
/// is the guest back in points, each guest dimension rounded down to a multiple of 8 (the
/// granularity the iPad fitting size already used). Nothing is aspect-fitted or letterboxed:
/// full-screen sessions take the whole display, and in portrait the pane is the full width and
/// the top half of the height (the little-laptop split), so the Mac is edge to edge in both. The
/// pane is re-derived from the guest, so it can never exceed the scene bounds it was made from.
/// The boot path and pointer following derive the plan from the same scene geometry and the
/// scene screen's native scale, so the guest size they use cannot diverge.
struct ViewportPlan {
    let pane: CGRect          // in scene-bounds points; never larger than bounds
    let bounds: CGSize        // the scene bounds the pane sits inside
    let guestWidth: Int
    let guestHeight: Int
    let scale: CGFloat        // the scene screen's native scale
    let nativeBounds: CGSize  // the scene screen's native bounds, in pixels
    let landscape: Bool
    let profile: DisplayProfile // the per-start display profile this plan was resolved with

    var aspect: CGFloat { CGFloat(guestWidth) / CGFloat(max(guestHeight, 1)) }
    var guest: (width: Int, height: Int) { (guestWidth, guestHeight) }

    /// The plan for a scene of `bounds` points on a screen of the given native scale. In portrait
    /// a session shows the split layout, so the pane is the top half; `split` says so.
    static func make(bounds: CGSize, scale: CGFloat, nativeBounds: CGSize, split: Bool = true,
                     profile: DisplayProfile = .full) -> ViewportPlan {
        let s = scale > 0 ? scale : 2
        let landscape = bounds.width > bounds.height
        func pixels(_ points: CGFloat) -> Int { max(64, Int(points * s) / 8 * 8) }
        // The Full guest size, exactly as before profiles: the whole scene, or in the portrait
        // split the pane's fraction of the height (the top half, or Split-compact's 0.42).
        let fullW = pixels(bounds.width)
        let fullH = pixels(!landscape && split ? bounds.height * profile.portraitPaneFraction : bounds.height)
        // Perf derives the guest FROM the Full pane size at the profile's scale, floored to a
        // multiple of 8; the pane itself is never derived from the reduced guest, so the pane
        // stays the Full pane, edge to edge, and the presenter draws the smaller framebuffer
        // into it. Deriving the pane from the reduced guest would shrink it to 75% and leave
        // bars, defeating the profile.
        var guestW = fullW, guestH = fullH
        if profile == .perf {
            guestW = max(64, Int(CGFloat(fullW) * profile.scale) / 8 * 8)
            guestH = max(64, Int(CGFloat(fullH) * profile.scale) / 8 * 8)
        }
        let paneW = CGFloat(fullW) / s, paneH = CGFloat(fullH) / s
        let pane = CGRect(x: (bounds.width - paneW) / 2, y: landscape ? (bounds.height - paneH) / 2 : 0,
                          width: paneW, height: paneH)
        return ViewportPlan(pane: pane, bounds: bounds, guestWidth: guestW, guestHeight: guestH,
                            scale: s, nativeBounds: nativeBounds, landscape: landscape, profile: profile)
    }

    /// The active window scene: the only trustworthy source on a foldable. UIScreen.main on the
    /// unfolded Duo reports a different screen than the session runs on (466x678 pt and
    /// 1398x2034 px in a landscape session on the inner panel), so nothing sizes from it.
    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// `profileFor` resolves the per-start display profile from the scene's posture class
    /// (true = landscape), which only the scene itself knows; a caller passes the machine's
    /// remembered choice as `{ mac.displayProfile(landscape: $0) }`. Nil means Full, so every
    /// pre-profile call site keeps its exact behaviour.
    private static func scenePlan(split: Bool, profileFor: ((Bool) -> DisplayProfile)? = nil) -> ViewportPlan {
        let scene = activeScene
        let bounds = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
        let screen = scene?.screen ?? UIScreen.main
        let profile = profileFor?(bounds.width > bounds.height) ?? .full
        return make(bounds: bounds.size, scale: screen.nativeScale,
                    nativeBounds: screen.nativeBounds.size, split: split, profile: profile)
    }

    /// The plan for the device's current window scene: what run() boots with and what pointer
    /// following normalizes against, one plan from one source. A session started folded,
    /// unfolded or on its side is sized for the screen it actually starts on. run() logs the
    /// plan at boot, so the session log records the pane and the guest size the session used.
    static func current(observing size: CGSize? = nil, insets: EdgeInsets? = nil,
                        profileFor: ((Bool) -> DisplayProfile)? = nil) -> ViewportPlan {
        if let size, let insets { observedGeometry = (size, insets) }
        return scenePlan(split: true, profileFor: profileFor)
    }

    /// The guest size for a Mac filling the whole display in the current orientation (new Macs).
    static var fullScreenGuest: (width: Int, height: Int) { scenePlan(split: false).guest }

    /// The geometry SessionView last laid out with, for the session log.
    static var observedGeometry: (size: CGSize, insets: EdgeInsets)?

    /// Everything the session log needs to prove the fit, in one line. The renderer's own
    /// drawableSize line (pvg_metal, "[pvg] drawableSize ...") completes the proof.
    func describe() -> String {
        var text = "scene bounds \(Int(bounds.width))x\(Int(bounds.height)) pt, scene screen nativeBounds \(Int(nativeBounds.width))x\(Int(nativeBounds.height)) px, nativeScale \(scale)"
        if let g = Self.observedGeometry {
            text += "; geo \(Int(g.size.width))x\(Int(g.size.height)) pt, insets (top \(Int(g.insets.top)), leading \(Int(g.insets.leading)), bottom \(Int(g.insets.bottom)), trailing \(Int(g.insets.trailing)))"
        }
        text += "; pane \(Int(pane.width))x\(Int(pane.height)) pt at (\(Int(pane.minX)),\(Int(pane.minY))); guest \(guestWidth)x\(guestHeight) px (\(landscape ? "landscape" : "portrait"))"
        text += "; profile \(profile.rawValue), scale \(String(format: "%g", Double(profile.scale)))"
        return text
    }
}

/// A keyboard attached to the device, by HID usage, which is what the Mac's USB keyboard sends, so every
/// key and modifier goes straight across. GameController reports each key going down and coming up.
/// UIKit's presses are kept for when it has no keyboard: on an iPad on iPadOS 27 they never came, not
/// to a plain view nor to one taking text (that got only text, so no modifiers or shortcuts).
enum HardwareKeys {
    private static var held: Set<UInt8> = []
    private static var lastKey: CFTimeInterval = 0
    private static var observers: [NSObjectProtocol] = []
    private static var keyboard: GCKeyboard?
    private static var noted: Set<String> = []
    private static var gameControllerTyped = false

    /// GameController has the keyboard, and has sent a key, so presses and the text iOS makes of its
    /// keys aren't sent again. Until then they are, should it never send any.
    static var fromGameController: Bool { keyboard != nil && gameControllerTyped }

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        held.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    static func start() {
        attach(GCKeyboard.coalesced)
        observers.append(NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            HardwareKeys.attach(GCKeyboard.coalesced)
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            HardwareKeys.releaseAll()
            HardwareKeys.attach(GCKeyboard.coalesced)
        })
    }

    static func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        attach(nil)
        releaseAll()
    }

    private static func attach(_ next: GCKeyboard?) {
        guard next !== keyboard else { return }
        keyboard?.keyboardInput?.keyChangedHandler = nil
        keyboard = next
        gameControllerTyped = false
        guard let input = next?.keyboardInput else {
            keyboard = nil
            return
        }
        HengeLog.log("input", "hardware keyboard by GameController")
        input.keyChangedHandler = { _, _, code, down in
            let raw = Int(code.rawValue)
            guard raw >= 0x04, raw <= 0xe7 else { return }
            // A sheet's text field (the Mac's name) types into the sheet, not the Mac.
            guard !down || !HardwareKeys.sheetOpen else { return }
            HardwareKeys.note("first key by GameController")
            HardwareKeys.gameControllerTyped = true
            HardwareKeys.key(UInt8(raw), down: down)
        }
    }

    private static var sheetOpen: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            note("first key by UIKit presses")
            if !fromGameController { key(UInt8(raw), down: down) }
        }
        return rest
    }

    /// A keyboard made for Windows (most Logitech ones) has Alt beside the space bar, where a Mac has Command.
    /// On, Alt is Command and the Windows key is Option, on both sides, so shortcuts sit where a Mac's do.
    static let windowsLayoutKey = "henge.keyboard.windowsLayout"

    private static func key(_ pressed: UInt8, down: Bool) {
        var usage = pressed
        if UserDefaults.standard.bool(forKey: windowsLayoutKey) {
            switch pressed {
            case 0xe2: usage = 0xe3 // left Alt -> left Command
            case 0xe3: usage = 0xe2 // left Windows -> left Option
            case 0xe6: usage = 0xe7 // right Alt -> right Command
            case 0xe7: usage = 0xe6 // right Windows -> right Option
            default: break
            }
        }
        guard down || held.contains(usage) else { return }
        henge_vm_key_hid(usage, down ? 1 : 0)
        if usage < 0xe0 { lastKey = CACurrentMediaTime() }
        if down {
            held.insert(usage)
        } else {
            held.remove(usage)
            if usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
        }
    }

    /// Which way keys arrive, once each: never which keys were typed.
    static func note(_ line: String) {
        if noted.insert(line).inserted { HengeLog.log("input", line) }
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in held { henge_vm_key_hid(usage, 0) }
        held.removeAll()
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { _ in wanted }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        return !scenes.isEmpty && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttons = PhysicalMouseButtons(swapsRightAndMiddle: false)
    private var buttonsLogged = 0
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var lastScrollFirst: Float = 0, lastScrollSecond: Float = 0

    func start() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        releaseButtons()
        let swapButtons = defaults.bool(forKey: PhysicalMouseButtons.swapKey)
        buttons = PhysicalMouseButtons(swapsRightAndMiddle: swapButtons)
        buttonsLogged = 0
        HengeLog.log("input", "physical mouse: swap right/middle \(swapButtons ? "on" : "off")")
        lastScrollFirst = 0
        lastScrollSecond = 0
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        PointerLock.set(false)
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        let held = buttons.releaseAll()
        if !held.isEmpty { henge_vm_mouse_use_relative() }
        for button in held { henge_vm_mouse_button(button, 0) }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in self?.scrolled(first, second) }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool) {
        guard let guestButton = buttons.event(physicalButton, pressed: pressed) else { return }
        if buttonsLogged < 32 {
            buttonsLogged += 1
            HengeLog.log("input", "physical mouse button: raw=\(physicalButton) guest=\(guestButton) \(pressed ? "down" : "up")")
        }
        henge_vm_mouse_use_relative() // the mouse clicks where its pointer is, never where a finger last tapped
        henge_vm_mouse_button(guestButton, pressed ? 1 : 0)
        if !pressed { StickyKeys.shared.releaseAll() }
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second.
    /// macOS accelerates wheel units roughly quadratically, so use a tunable square root
    /// and cap each event to keep a small pad gesture from jumping across a page.
    private func scrolled(_ first: Float, _ second: Float) {
        // GameController reports both axis states when either one changes. On a
        // Magic Keyboard it calls us twice per movement, with one stale axis in
        // each call; sending both values doubles the scroll and adds sideways drift.
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        let mostlyVertical = abs(first) > 2 * abs(second)
        let mostlyHorizontal = abs(second) > 2 * abs(first)
        let verticalRaw = verticalChanged && !mostlyHorizontal ? -first : 0
        let horizontalRaw = horizontalChanged && !mostlyVertical ? second : 0
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: Self.scrollSpeedKey) == nil
            ? 0.3 : defaults.double(forKey: Self.scrollSpeedKey)
        let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        let way: Int32 = reverse ? -1 : 1
        let horizontal = way * Self.wheelUnits(horizontalRaw, scale: scale)
        let vertical = way * Self.wheelUnits(verticalRaw, scale: scale)
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second); units: \(horizontal), \(vertical)")
        }
        if horizontal != 0 || vertical != 0 {
            henge_vm_mouse_use_relative()
            henge_vm_mouse_scroll(horizontal, vertical)
        }
    }

    private static func wheelUnits(_ value: Float, scale: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let units = Int32(min(32, (22 * scale * abs(value).squareRoot()).rounded()))
        return value < 0 ? -units : units
    }
}

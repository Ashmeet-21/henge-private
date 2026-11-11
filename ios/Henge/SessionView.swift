import SwiftUI
import UIKit
import GameController
import UIKit

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @AppStorage("henge.cpus") private var cpus = 4
    /// Pointing mode: "auto" (the default when nothing is stored), "direct", or
    /// "trackpad". A person-and-posture preference, readable before any machine
    /// is chosen, so it lives here and not in the machine record.
    @AppStorage("henge.pointing") private var pointing = "auto"
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @ObservedObject private var remote = RemoteDesktop.shared
    @AppStorage(RemoteDesktop.enabledKey) private var remoteEnabled = true
    @AppStorage(RemoteDesktop.headlessKey) private var remoteHeadless = true
    @AppStorage(RemoteDesktop.wifiKey) private var remoteWifi = true
    @AppStorage(RemoteDesktop.muteHereKey) private var remoteMuteHere = true

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var showPasteUnavailable = false
    @State private var pointerRefused = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State private var restartWanted = false // Restart was chosen here: start again once macOS has shut down
    @State private var askedMac: Date? // when macOS was last asked to shut down or restart
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    /// Keyboard viewport: app-wide toggle, default ON.
    @AppStorage("henge.keyboardZoom") private var kbZoomEnabled = true
    @State private var kbKeyboard: KeyboardInfo?
    @State private var kbTarget: KBFocusTarget?
    @State private var kbActive = false
    @State private var kbArmed = false
    @State private var kbManualTakeover = false
    @State private var kbFade = true
    @State private var kbPhase = "full" // full / focused / returning (bookkeeping)
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: typing, centre: zoomCentre, aspect: mac.aspect,
                                kb: kbLayoutInput(full: full, insets: insets, landscape: landscape))
            /// An explicit choice wins; auto is direct when the pane fills the phone
            /// and trackpad in the portrait split.
            let effectiveDirect = pointing == "direct" || (pointing != "trackpad" && layout.fillsPhone)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : (kbFade ? 1 : 0.35))
                    .overlay {
                        if display.isExternal && state != 2 {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac on external display").font(.headline)
                                Text("Use the trackpad, keyboard or a connected mouse.")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .overlay {
                        if remote.connected && remoteHeadless {
                            ZStack {
                                Color.black
                                VStack(spacing: 8) {
                                    Image(systemName: "desktopcomputer").font(.largeTitle)
                                    Text("Streaming to \(remote.client)").font(.headline)
                                    Text("The Mac is shown on the computer. The trackpad still works here.")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                if state != 2 {
                    Trackpad(direct: effectiveDirect, screenRect: layout.screen, touchOrigin: layout.touch.origin)
                        .frame(width: layout.touch.width, height: layout.touch.height)
                        .position(x: layout.touch.midX, y: layout.touch.midY)
                    if inputMode == .volumeButtons && volumeMode == .intercept {
                        // The capture interaction must live in the SwiftUI hierarchy to receive
                        // the volume-button events; it passes touches through to the trackpad.
                        CaptureInteractionView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if !layout.fillsPhone {
                        uprightControls(layout)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("Make Henge full screen to use the trackpad or mouse as the Mac's", systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label("Tap with four fingers to show the controls", systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showWallpaperTip && !showRevealHint && !pointerRefused {
                        Label("For more speed, give this Mac a still wallpaper and set its screen saver to Never in System Settings.", systemImage: "speedometer")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: min(full.width - 40, 520))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .position(x: full.width / 2, y: insets.top + 56)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                if state == 2 {
                    StoppedMacView(outcome: henge_vm_exit_outcome(), reason: String(cString: henge_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                KeyboardCatcher(active: $typing, onKeyboard: { handleKeyboard($0) }).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onChange(of: landscape) { _ in
                KeyboardSignals.shared.postureChanged()
            }
            .onAppear { shown = layout.shown }
            .onChange(of: layout.shown) { shown = $0 }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showDetails) { details }
        .alert("Couldn’t Paste", isPresented: $showPasteUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy text on your iPad and allow Henge to paste if prompted.")
        }
        .confirmationDialog("Shut down \(mac.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Shut Down") { askMac(restart: false) }
            Button("Restart") { askMac(restart: true) }
            Button("Force Off", role: .destructive) { finish() }
        } message: {
            Text(askedMac == nil
                 ? "Shut Down and Restart press the Mac's power button: macOS shows its own dialog and closes apps first. Force Off turns the Mac off at once, and anything not saved on it is lost."
                 : "macOS has been asked. If it is stuck, Force Off turns the Mac off at once: anything not saved on it is lost.")
        }
        .onChange(of: zoomed) { on in
            if on && kbActive {
                // Manual takeover: the zoom tool ends keyboard focus; the
                // view adopts the focus target as its centre and this keyboard
                // session will not auto-return on dismiss.
                kbManualTakeover = true
                kbActive = false
                if let target = kbTarget { zoomCentre = target.point }
                kbTarget = nil
            }
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: kbZoomEnabled) { on in
            if !on && kbActive {
                animateKB(duration: 0.25, curve: 0) { kbActive = false; kbKeyboard = nil }
                kbTarget = nil
                kbPhase = "full"
            }
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                return
            }
            if kbActive || kbKeyboard != nil {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { kbActive = false }
                kbKeyboard = nil
                kbTarget = nil
                kbArmed = false
                kbPhase = "full"
            }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            // Blanket release on whichever pointer device is active: no-ops when
            // nothing is down, and the rescue when a drag is interrupted.
            henge_vm_mouse_button(0, 0)
            henge_vm_mouse_button(1, 0)
            henge_vm_mouse_button(2, 0)
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: remoteEnabled) { on in
            if on { RemoteDesktop.shared.start() } else { RemoteDesktop.shared.stop() }
        }
        .onChange(of: remoteHeadless) { _ in RemoteDesktop.shared.applyHeadless() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
            HardwareKeys.start()
            if remoteEnabled { RemoteDesktop.shared.start() }
            VolumeClicks.shared.start()
        }
        .onDisappear {
            RemoteDesktop.shared.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            KeyboardSignals.shared.endSession()
            kbActive = false
            kbKeyboard = nil
            kbTarget = nil
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            henge_vm_mouse_button(0, 0)
            henge_vm_mouse_button(1, 0)
            henge_vm_mouse_button(2, 0)
            HardwareMouse.shared.stop()
            HardwareKeys.stop()
            VolumeClicks.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: mac.aspect)))
        .task(id: bootAttempt) { await run() }
        .task { await kbSignalSampler() }
        .task { await Sharing.followMacClipboard() }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == 2 || showDetails || confirmStop || error != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        /// The keyboard viewport's input: the visible band above the keyboard
        /// (Layout coordinates), the focus target (normalised guest), and the
        /// base screen rect the solver solves from. Layout derives its
        /// geometry from the aspect alone, so the caller, which already
        /// builds the base layout to find the band, supplies that rect.
        struct KBInput {
            var band: CGRect
            var target: KBFocusTarget
            var baseScreen: CGRect
        }

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat, kb: KBInput? = nil) {
            self.insets = insets
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if let kb, let solved = KeyboardSolver.solve(baseScreen: kb.baseScreen, band: kb.band, fullHeight: full.height, target: kb.target) {
                // Keyboard viewport: expressed ONLY as this screen rect,
                // so rendering and Trackpad mapping follow it
                // together. It wins over manual zoom while active; the manual
                // state is untouched underneath and returns on hide.
                screen = solved
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                let height = max(min(room, (full.width - side) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if y - insets.top >= 54 { barY = insets.top + (y - insets.top) / 2 }
            } else if landscape {
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Keyboard viewport

    /// The band the current keyboard frame leaves visible, in Layout
    /// coordinates. The band is the pane's own column: coverage is
    /// about guest content, and the pane sits inside the full geometry with
    /// a ~1 pt centring margin no layout covers with guest pixels.
    /// coordinates. The frame Holder reports is in scene (window)
    /// coordinates; Layout coordinates shift scene coordinates by the same
    /// centring offset Layout applies between the full geometry and the
    /// scene bounds.
    private func kbBand(info: KeyboardInfo, full: CGSize, insets: EdgeInsets, baseScreen: CGRect, target: KBFocusTarget) -> CGRect {
        // The scene bounds are the full geometry minus its insets, so the
        // centring offset is half the inset sums on each axis.
        let offset = CGPoint(x: (insets.leading + insets.trailing) / 2, y: (insets.top + insets.bottom) / 2)
        let frame = info.frameInLayout.offsetBy(dx: offset.x, dy: offset.y)
        if info.docked {
            let top = max(baseScreen.minY, frame.minY)
            return CGRect(x: baseScreen.minX, y: baseScreen.minY, width: baseScreen.width, height: max(0, top - baseScreen.minY))
        }
        // Floating keyboard: no intersection with the target's placement
        // means no occlusion: the band is the whole screen and the gate
        // passes. Otherwise the band ends at the frame's top when it spans
        // the focus column, else at its bottom edge in that column.
        let targetView = KeyboardSolver.viewRect(forNormalized: target.rect, in: baseScreen).insetBy(dx: -10, dy: -10)
        if !frame.intersects(targetView) {
            return CGRect(x: baseScreen.minX, y: baseScreen.minY, width: baseScreen.width, height: baseScreen.height)
        }
        let focusX = baseScreen.minX + target.point.x * baseScreen.width
        let spansColumn = frame.minX <= focusX && focusX <= frame.maxX
        let bottom = spansColumn ? frame.minY : frame.maxY
        return CGRect(x: baseScreen.minX, y: baseScreen.minY, width: baseScreen.width, height: max(0, bottom - baseScreen.minY))
    }

    private func kbLayoutInput(full: CGSize, insets: EdgeInsets, landscape: Bool) -> Layout.KBInput? {
        guard kbZoomEnabled, kbActive, let info = kbKeyboard, let target = kbTarget else { return nil }
        let base = Layout(full: full, insets: insets, landscape: landscape, zoomed: false, typing: typing, centre: zoomCentre, aspect: mac.aspect, kb: nil)
        return Layout.KBInput(band: kbBand(info: info, full: full, insets: insets, baseScreen: base.screen, target: target), target: target, baseScreen: base.screen)
    }

    /// Drive a keyboard transform change with the keyboard notification's own
    /// duration and curve (fallback 0.25 s easeInOut). Reduce Motion cuts
    /// under a 0.12 s crossfade instead.
    private func animateKB(duration: Double, curve: Int, _ change: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            kbFade = false
            withAnimation(.linear(duration: 0.12), change)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.linear(duration: 0.12)) { kbFade = true }
            }
            return
        }
        let d = duration > 0 ? duration : 0.25
        let animation: Animation
        switch curve {
        case 1: animation = .easeIn(duration: d)
        case 2: animation = .easeOut(duration: d)
        case 3: animation = .linear(duration: d)
        default: animation = .easeInOut(duration: d)
        }
        withAnimation(animation, change)
    }

    private func adoptKBTarget(_ target: KBFocusTarget, info: KeyboardInfo) {
        if target.source == "tap" { KeyboardSignals.shared.consumeTap() }
        kbArmed = false
        kbPhase = "focused"
        animateKB(duration: info.duration, curve: info.curve) {
            kbTarget = target
            kbKeyboard = info
            kbActive = true
        }
        HengeLog.log("keyboard", "focus target \(target.source) at \(target.point)")
    }

    private func handleKeyboard(_ event: KeyboardEvent) {
        switch event {
        case .hide(let duration, let curve):
            KeyboardSignals.shared.kbDidHide()
            kbArmed = false
            if kbManualTakeover {
                kbManualTakeover = false
                kbTarget = nil
                kbKeyboard = nil
                kbPhase = "full"
                return
            }
            if kbActive {
                kbPhase = "returning"
                animateKB(duration: duration, curve: curve) {
                    kbActive = false
                    kbKeyboard = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.12) + 0.05) {
                    if kbPhase == "returning" { kbPhase = "full" }
                }
            } else {
                kbKeyboard = nil
            }
            kbTarget = nil
        case .show(let info):
            guard kbZoomEnabled, !showDetails, !confirmStop, error == nil else { return }
            KeyboardSignals.shared.kbWillShow()
            guard !kbManualTakeover else { kbKeyboard = info; return }
            if let target = KeyboardSignals.shared.focusTarget(guestWidth: Trackpad.guestScreenWidth, guestHeight: Trackpad.guestScreenHeight) {
                adoptKBTarget(target, info: info)
            } else {
                kbKeyboard = info
                kbArmed = true
                HengeLog.log("keyboard", "no focus signal; staying full, late-focus armed")
            }
        case .changeFrame(let info):
            guard kbZoomEnabled, !showDetails, !confirmStop, error == nil else { return }
            guard !kbManualTakeover else { kbKeyboard = info; return }
            if let target = kbTarget {
                // Same target, new band: Layout re-solves from the
                // updated kbKeyboard state inside this animation.
                animateKB(duration: info.duration, curve: info.curve) {
                    kbKeyboard = info
                    kbActive = true
                }
                _ = target
            } else if kbArmed, let target = KeyboardSignals.shared.focusTarget(guestWidth: Trackpad.guestScreenWidth, guestHeight: Trackpad.guestScreenHeight) {
                adoptKBTarget(target, info: info)
            } else {
                kbKeyboard = info
            }
        }
    }

    /// The 2 Hz guest-pointer sampler plus late-focus pickup:
    /// while the keyboard is up with no signal, the first guest
    /// click becomes the focus target.
    private func kbSignalSampler() async {
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0, Trackpad.guestScreenWidth > 0, Trackpad.guestScreenHeight > 0 {
                KeyboardSignals.shared.recordPointer(point: CGPoint(x: CGFloat(x) / CGFloat(Trackpad.guestScreenWidth),
                                                                    y: CGFloat(y) / CGFloat(Trackpad.guestScreenHeight)))
            }
            if kbArmed, let info = kbKeyboard,
               let target = KeyboardSignals.shared.focusTarget(guestWidth: Trackpad.guestScreenWidth, guestHeight: Trackpad.guestScreenHeight),
               target.source == "tap" {
                adoptKBTarget(target, info: info)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if !typing && !controlsHidden {
            HStack {
                tool("eye.slash", "Hide controls") { hideControls() }
                Spacer()
                tool("keyboard", "Keyboard") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "Zoom in") { zoomed = true }
                Spacer()
                pointingToggle(fillsPhone: false)
                Spacer()
                tool("info.circle", "Details") { showDetails = true }
                Spacer()
                tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        trackpadPanel(layout)
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("Trackpad").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("Drag", "to move")
                        hint("Tap", "to click")
                        hint("Hold, then drag", "to grab")
                        hint("Two fingers", "to scroll")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "Click", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "Right-click", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    private var pasteTool: some View {
        tool("clipboard", "Paste from iPad") {
            // Read only on tap. iPadOS can ask before granting access to text from another app.
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                showPasteUnavailable = true
                return
            }
            Sharing.paste(text)
        }
        .disabled(state != 1)
    }

    /// Hides the session's controls; four fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    /// The pointing-mode toggle: one tap always flips the effective mode, including
    /// from auto, because it writes the explicit value opposite to it. Symbol and
    /// label name the mode a tap switches to, as the zoom tool names its action.
    /// Returning to auto is done by the absence of a stored value (v1).
    private func pointingToggle(fillsPhone: Bool, tint: Color = Desk.text) -> some View {
        let isDirect = pointing == "direct" || (pointing != "trackpad" && fillsPhone)
        return tool(isDirect ? "cursorarrow.click.2" : "hand.tap.fill",
                    isDirect ? "Trackpad pointing" : "Direct pointing", tint: tint) {
            pointing = isDirect ? "trackpad" : "direct"
        }
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 4) {
            tool("eye.slash", "Hide controls", tint: .white) { hideControls() }
            tool("keyboard", "Keyboard", tint: .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            pointingToggle(fillsPhone: true, tint: .white)
            tool("info.circle", "Details", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "Shut down", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if controlsHidden {
            EmptyView()
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomed { zoomMap(layout) }
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / mac.aspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// The size macOS is told its screen is at start. Henge fork: a Mac with no Display profile picked for this
    /// posture keeps its saved Screen size (mac.screen, as before profiles, never overwritten); a picked profile
    /// uses upstream's viewport plan.
    private func bootGuest() -> (width: Int, height: Int, fromProfile: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let bounds = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.coordinateSpace.bounds ?? UIScreen.main.bounds
        let landscape = bounds.width > bounds.height
        guard mac.usesProfile(landscape: landscape) else { return (mac.screen.width, mac.screen.height, false) }
        let plan = ViewportPlan.current { mac.displayProfile(landscape: $0) }
        HengeLog.log("session", "viewport: \(plan.describe())")
        return (plan.guestWidth, plan.guestHeight, true)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        let guest = bootGuest() // the size this session booted with; it cannot change mid-session
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0, !kbActive {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(guest.width), y: CGFloat(y) / CGFloat(guest.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / (CGFloat(guest.width) / CGFloat(guest.height)))) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac could not start").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("Close") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "Starting…" : "Not started"
        case 1: return userCode ? "macOS is running" : "Booting"
        case 3: return "Finishing shutdown…"
        default: return "Stopped (\(String(cString: henge_vm_exit_reason())))"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("CPUs on", value: "\(cpusOn) of \(cpus)")
                    LabeledContent("Temperature", value: Self.thermalLabel(thermalState))
                    LabeledContent("Translated blocks", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("Network frames", value: "\(framesOut) out, \(framesIn) in")
                    LabeledContent("Up", value: "\(Int(Date().timeIntervalSince(started))) s")
                }
                Section("Display") {
                    Toggle("Color matching", isOn: $matchScreenColors)
                    Toggle("Zoom to keyboard focus", isOn: $kbZoomEnabled)
                    LabeledContent("Brightness", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("Brightness dims only the Mac's screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pointer") {
                    Toggle("Sharp edges", isOn: $sharpCursor)
                    LabeledContent("Mouse scroll speed", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("The Mac supplies a small pointer image, drawn at its natural size at any guest size. Scroll speed changes apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Remote desktop") {
                    Toggle("Stream to a computer", isOn: $remoteEnabled)
                    Toggle("Hide the Mac here while streaming", isOn: $remoteHeadless)
                    Toggle("Allow over Wi-Fi with a code", isOn: $remoteWifi)
                    Toggle("Silent here while the computer plays the sound", isOn: $remoteMuteHere)
                    if remoteEnabled {
                        LabeledContent("Status", value: remote.connected ? "Streaming to \(remote.client)" : "Waiting on port \(RemoteDesktop.port)")
                        if remoteWifi {
                            if let ip = RemoteDesktop.wifiAddress() { LabeledContent("Wi-Fi address", value: "\(ip):\(RemoteDesktop.port)") }
                            LabeledContent("Code", value: remote.code)
                            Button("New code") { RemoteDesktop.shared.renewCode() }
                        }
                    }
                    Text("Run tools/henge-remote.py on the computer. Over USB, start iproxy 15901:5901 there first and connect to 127.0.0.1:15901. Over Wi-Fi, give it the address and --code. Keep Henge open: iOS pauses it in the background.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sharing") {
                    LabeledContent("Clipboard and folder", value: helperRunning ? "On" : "Not set up")
                    if !helperRunning {
                        Button("Type the Set Up Command") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "Put files in Files, Henge, Shared to see them in the Henge folder in this Mac's home folder. What you copy on the Mac is copied here too, and the paste button pastes from here into the Mac."
                         : "Once for each Mac: open Terminal on the Mac, tap this, then press Return. When macOS asks about henge-agent and local networks, choose Allow. It types \(Sharing.setUpCommand) and needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Lighter macOS") {
                    Button("Type the Lighter macOS Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("Type the Undo Command") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("Less drawing for the emulated CPUs: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper go. Open Terminal on the Mac, tap the button and press Return, then log out and back in. Also turn on Reduce Motion and Reduce Transparency in the Mac's System Settings, Accessibility. Undo puts it back, apart from the wallpaper. Needs the Mac's keyboard layout to be U.S.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Running

    /// Serious or critical: the guest's CPUs drop a QoS class until it cools (hv_vm_set_hot).
    private static func isHot(_ state: ProcessInfo.ThermalState) -> Bool { state == .serious || state == .critical }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot — performance reduced"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func run() async {
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        zoomed = false
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        while henge_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(mac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "There is not room for this Mac's memory: it needs a few GB of free storage."
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        // The guest size is this session's viewport plan: the pane SessionView lays out, at the
        // display's native scale. It is worked out now, at start, from the scene the session is
        // starting in (folded, unfolded, portrait or landscape); the display mode is boot-time
        // only, so a fold or rotation mid-session aspect-fits until the next start.
        let guest = bootGuest()
        Trackpad.guestScreenWidth = guest.width
        Trackpad.guestScreenHeight = guest.height
        KeyboardSignals.shared.resetSession()
        henge_vm_set_display(UInt32(guest.width), UInt32(guest.height))
        if mac.isRetina {
            henge_vm_set_display_mm(UInt32(Device.retinaMM.width), UInt32(Device.retinaMM.height))
        } else {
            henge_vm_set_display_mm(0, 0)
        }
        HengeLog.log("session", "screen \(guest.width)x\(guest.height) retina \(mac.isRetina)")
        henge_vm_set_hot(Self.isHot(ProcessInfo.processInfo.thermalState) ? 1 : 0)
        let rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        started = Date()
        var used = mac
        used.lastUsed = started
        if guest.fromProfile { (used.screenWidth, used.screenHeight) = (guest.width, guest.height) }
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            if state == 3 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            cpusOn = henge_vm_cpus_on()
            userCode = userCode || henge_vm_guest_el0() != 0
            let now = Date(), blocks = henge_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                if Self.isHot(heat) != Self.isHot(thermalState) { henge_vm_set_hot(Self.isHot(heat) ? 1 : 0) }
                thermalState = heat
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 {
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                // A restart asked for here ends as a shut down by macOS: start again, unless that was long ago
                // (the dialog in macOS was cancelled, and this shut down is a later one).
                let outcome = henge_vm_exit_outcome()
                let again = restartWanted && outcome == Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue)
                    && (askedMac.map { Date().timeIntervalSince($0) < 300 } ?? false)
                restartWanted = false
                askedMac = nil
                if (outcome == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) || again) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Shut Down or Restart from here: the Mac's power button, which macOS answers with its own dialog. A restart is a
    /// shut down that this screen follows with a start (see the stopped state in the watch loop).
    private func askMac(restart: Bool) {
        restartWanted = restart
        askedMac = Date()
        HengeLog.log("session", restart ? "power button pressed, to restart" : "power button pressed, to shut down")
        Task.detached {
            henge_vm_power_button(1)
            try? await Task.sleep(nanoseconds: 300_000_000)
            henge_vm_power_button(0)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    private func finish() {
        if state == 1 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        close()
    }
}

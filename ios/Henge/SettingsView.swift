import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(Trackpad.scrollSpeedKey) private var trackpadScroll = Trackpad.defaultScrollSpeed
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(Device.smallCodeRegionKey) private var smallCodeRegion = Device.smallCodeRegionByDefault
    @AppStorage(Device.ramOnStorageKey) private var ramOnStorage = Device.hasLittleMemory
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(ThermalGovernor.enabledKey) private var keepCool = true
    @AppStorage(BackgroundKeeper.modeKey) private var backgroundMode = BackgroundKeeper.pause
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge uses \(jit.method.title).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Set up JIT") { jit.showSetup = true }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("Henge connects LocalDevVPN first when it is off, and comes back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Code region", value: "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                }
                .listRowBackground(Desk.card)
                Section("Performance") {
                    Toggle("Keep the \(Device.name) cool", isOn: $keepCool)
                    Picker("Mac refresh rate", selection: $refreshRate) {
                        Text("30 Hz (cooler)").tag(30)
                        Text("60 Hz").tag(60)
                        // 120 only where the screen shows it: elsewhere macOS would draw twice the frames for nothing.
                        if UIScreen.main.maximumFramesPerSecond >= 120 || refreshRate == 120 { Text("120 Hz").tag(120) }
                    }
                    .pickerStyle(.segmented)
                    Picker("In the background", selection: $backgroundMode) {
                        Text("Pause the Mac").tag(BackgroundKeeper.pause)
                        Text("Keep it running").tag(BackgroundKeeper.keepRunning)
                    }
                    Text(backgroundMode == BackgroundKeeper.keepRunning
                         ? "When you leave Henge or lock the \(Device.name), the Mac keeps running, each CPU at most \(BackgroundKeeper.runningPercent)% of the time, for a download or a build. iOS draws nothing for apps in the background, so windows may need a moment to redraw when you come back, and iOS can still close Henge if another app needs its memory."
                         : "When you leave Henge or lock the \(Device.name), the Mac pauses: no CPU used, no heat, and its clock stops like a sleeping Mac's, so it goes on where it was when you come back. Henge plays silence meanwhile so iOS keeps it (and JIT) alive; iOS can still close it if another app needs its memory.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Faster disk writes", isOn: $fastFlush)
                    Toggle("Quicker wake from idle", isOn: $wfiSpin)
                    Toggle("Superblocks (experimental)", isOn: $superblocks)
                    Text("Keep cool lets each of the Mac's CPUs run less of the time as iOS reports the device warmer (85%, 60%, 40%): a little slower, but steady, instead of iOS slowing everything down. 30 Hz halves what macOS draws. Faster disk writes keep them in order without waiting for a full sync; a sudden power loss could lose the last ones. Quicker wake keeps an idle CPU watching for work for 50 µs, at some battery cost. Superblocks let translated code run past conditional branches. Changes apply the next time a Mac starts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Extended addressing", value: Entitlements.extendedAddressing ? "On" : "Off")
                    LabeledContent("This \(Device.name)'s memory", value: ByteText.string(ProcessInfo.processInfo.physicalMemory))
                    // One choice for the code region: 512 MB is Device.smallCodeRegion, the others JITBootstrap.codeCacheKey.
                    Picker("Code cache", selection: Binding(get: { smallCodeRegion ? 512 : codeCacheMB },
                                                            set: { mb in
                                                                smallCodeRegion = mb == 512
                                                                if mb != 512 { codeCacheMB = mb }
                                                            })) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Keep the Mac's memory on storage while installing", isOn: $ramOnStorage)
                    Text("The code cache is claimed whole, as real memory, when JIT turns on. A bigger one empties less often. With about 6 GB, 512 MB is the default: 1 GB took Henge to 2.85 GB with a 3 GB Mac and iOS closed it. Applies the next time Henge opens; if JIT stops turning on, choose a smaller one. Memory on storage is on by default with about 6 GB, for installs only; a running Mac always keeps its memory in RAM.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Henge's limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Free for Henge", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "A Mac's memory is kept out of this limit once JIT is on. If iOS refuses that, it uses free storage instead."
                         : "This install isn't signed with the increased memory limit entitlement. Reinstall Henge with a certificate that has it. Export your Mac first if the reinstall replaces the app's data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("On-screen trackpad") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scroll speed")
                        Slider(value: $trackpadScroll, in: 0.05...1)
                    }
                    Text("How far two fingers scroll the Mac. Applies straight away.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scroll speed")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Text("A Magic Keyboard or a Bluetooth mouse moves the Mac's pointer. Pointer speed changes apply the next time a Mac starts; scroll speed changes apply immediately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Log") {
                    ShareLink(item: HengeLog.logFileURL) { Label("Share henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
        }
    }
}

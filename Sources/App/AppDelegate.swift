import AppKit
import Combine
import SwiftUI

@MainActor
enum RuntimeFlags {
    static let isSnapshot = ProcessInfo.processInfo.environment["FLOW8_SNAPSHOT"] != nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: MixerModel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if ProcessInfo.processInfo.environment["FLOW8_LANG_DEBUG"] != nil {
            print("PREFERRED", Locale.preferredLanguages)
            print("BUNDLELOC", Bundle.main.localizations)
            print("PREFBUNDLE", Bundle.main.preferredLocalizations)
            print("L10N", L10n.code, L10n.string("Снапшоты"))
        }
        buildMenu()

        let model = MixerModel()
        self.model = model
        model.$appLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)
        for publisher in [model.$hiddenChannels.map { _ in () }.eraseToAnyPublisher(),
                          model.$hiddenBuses.map { _ in () }.eraseToAnyPublisher(),
                          model.$showsFXChannels.map { _ in () }.eraseToAnyPublisher(),
                          model.$monStereoLinked.map { _ in () }.eraseToAnyPublisher()] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.fitWindowToStrips() }
                .store(in: &cancellables)
        }

        let root = RootView().environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FLOW8"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Custom traffic lights live in the top bar, so hide the native ones
        // and let the content run under the title bar.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.032, green: 0.034, blue: 0.040, alpha: 1)
        window.isOpaque = true
        window.minSize = NSSize(width: 244, height: 640)
        window.contentMinSize = NSSize(width: 244, height: 640)
        window.contentView = hosting
        window.setFrameAutosaveName("Flow8MainWindow")
        if !window.setFrameUsingName("Flow8MainWindow") {
            window.setContentSize(NSSize(width: 1440, height: 840))
            window.center()
        }
        if let sizeString = ProcessInfo.processInfo.environment["FLOW8_WINDOW"] {
            let parts = sizeString.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.center()
            }
        }
        if ProcessInfo.processInfo.environment["FLOW8_FULLSCREEN_DEBUG"] != nil {
            model.fullScreen = true
        }

        if let hidden = ProcessInfo.processInfo.environment["FLOW8_HIDE"] {
            let ids = hidden.split(separator: ",").compactMap { Int($0) }
            for id in ids where id >= 7 { model.setBus(id, hidden: true) }
            for id in ids where id < 7 { model.setChannel(id, hidden: true) }
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model?.fullScreen = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model?.fullScreen = false }
        }
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowToStrips()
            if ProcessInfo.processInfo.environment["FLOW8_LAYOUT_DEBUG"] != nil, let w = self?.window {
                print("WINDOW frame", w.frame, "content", w.contentLayoutRect, "view", w.contentView?.frame ?? .zero)
            }
        }

        NSApp.activate(ignoringOtherApps: true)

        if let raw = ProcessInfo.processInfo.environment["FLOW8_SNAP_DELETE_TEST"] {
            let slot = UInt8(Int(raw) ?? 14)
            let candidates: [(String, [UInt8])] = [
                ("19 spaces", [0x19, 0x01, slot, 0x03, 0x20, 0x20, 0x20]),
                ("19 empty", [0x19, 0x01, slot, 0x00]),
                ("1A", [0x1A, 0x01, slot])
            ]
            for (index, candidate) in candidates.enumerated() {
                let when = 3.0 + Double(index) * 4.0
                DispatchQueue.main.asyncAfter(deadline: .now() + when) {
                    print("SNAPDEL try \(candidate.0): \(candidate.1.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    model.ble.sendRaw(candidate.1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        model.syncNow(silent: true)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + when + 3.0) {
                    print("SNAPDEL names \(index): \(model.snapshotNames)")
                }
            }
        }

        if let spec = ProcessInfo.processInfo.environment["FLOW8_EQ_TEST"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    model.setEQ(channel: parts[0], band: parts[1], value: parts[2])
                }
            }
        }

        if let spec = ProcessInfo.processInfo.environment["FLOW8_BUSEQ_TEST"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    model.setBusEQ(bus: parts[0], band: parts[1], value: parts[2])
                }
            }
        }

        if ProcessInfo.processInfo.environment["FLOW8_EQ_PROBE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                print("EQPROBE 200Hz Q3")
                model.ble.sendRaw([0x09, 0x01, 0, 0, 0x00, 0xC8, 0x03, 0x40])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                print("EQPROBE back 100Hz")
                model.ble.sendRaw([0x09, 0x01, 0, 0, 0x00, 0x64, 0x00, 0x40])
            }
        }

        if ProcessInfo.processInfo.environment["FLOW8_HPF_ORDERS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                print("ORDERS send BE 01 3B")
                model.ble.sendRaw([0x04, 0x01, 0, 0x00, 0x01, 0x3B])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                print("ORDERS send LE 3B 01")
                model.ble.sendRaw([0x04, 0x01, 0, 0x00, 0x3B, 0x01])
            }
        }

        if let raw = ProcessInfo.processInfo.environment["FLOW8_HPF_PROBE"] {
            let hz = Int(raw) ?? 300
            let lo = UInt8(hz & 0xFF), hi = UInt8((hz >> 8) & 0xFF)
            let cc = UInt8(min(127, max(0, Param.lowCutCC(Double(hz)))))
            let ch: UInt8 = 1
            let candidates: [(String, [UInt8])] = [
                ("hi,lo (current)", [0x04, 0x01, ch, 0x00, hi, lo]),
                ("lo,hi", [0x04, 0x01, ch, 0x00, lo, hi]),
                ("hi,lo,00", [0x04, 0x01, ch, hi, lo, 0x00]),
                ("lo,hi,00", [0x04, 0x01, ch, lo, hi, 0x00]),
                ("00,00,hi,lo", [0x04, 0x01, ch, 0x00, 0x00, hi, lo]),
                ("00,00,lo,hi", [0x04, 0x01, ch, 0x00, 0x00, lo, hi]),
                ("type0A hi,lo", [0x0A, 0x01, ch, 0x00, hi, lo]),
                ("type0B hi,lo", [0x0B, 0x01, ch, 0x00, hi, lo]),
                ("cc byte", [0x04, 0x01, ch, 0x00, 0x00, cc]),
                ("cc 4 bytes", [0x04, 0x01, ch, cc])
            ]
            for (index, candidate) in candidates.enumerated() {
                let when = 3.0 + Double(index) * 3.0
                DispatchQueue.main.asyncAfter(deadline: .now() + when) {
                    print("HPF try \(index) [\(candidate.0)] \(candidate.1.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    model.ble.sendRaw(candidate.1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + when + 2.0) {
                    let value = model.channel(1)?.lowCut ?? -1
                    let hz = value >= 0 ? Int(Param.lowCutHz(value)) : -1
                    print("HPF value \(index): cc=\(value) hz=\(hz)")
                }
            }
        }

        if let spec = ProcessInfo.processInfo.environment["FLOW8_LOWCUT_TEST"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            let channel = parts.first ?? 1
            let values = parts.dropFirst().map { $0 }
            for (index, value) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(index) * 2.5) {
                    print("LOWCUT step \(index) value \(value)")
                    model.setLowCut(channel: channel, value: value)
                }
            }
        }

        if let spec = ProcessInfo.processInfo.environment["FLOW8_TEMPO_TEST"] {
            let values = spec.split(separator: ",").compactMap { Int($0) }
            for (index, value) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(index) * 3.0) {
                    print("TEMPO send \(value)")
                    model.ble.sendRaw([0x40, 0x01, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
                }
            }
        }

        if ProcessInfo.processInfo.environment["FLOW8_KNOB_TEST2"] != nil {
            for step in 0..<30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(step) * 0.015) {
                    model.setGain(channel: 1, value: 20 + step % 60)
                    model.setCompressor(channel: 1, value: step % 50 + 10)
                    model.setLowCut(channel: 1, value: 20 + step % 60)
                    model.setEQ(channel: 1, band: 0, value: 30 + step % 40)
                    model.toggleMute(channel: 1)
                }
            }
        }

        if let spec = ProcessInfo.processInfo.environment["FLOW8_KNOB_TEST"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2 {
                let channel = parts[0]
                let steps = parts[1]
                let interval = parts.count > 2 ? Double(parts[2]) / 1000.0 : 0.015
                for step in 0..<steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(step) * interval) {
                        model.setPan(channel: channel, value: 20 + (step % 60))
                    }
                }
            }
        }

        if let sweep = ProcessInfo.processInfo.environment["FLOW8_FADER_SWEEP"] {
            let values = sweep.split(separator: ",").compactMap { Int($0) }
            for (index, value) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(index) * 2.0) {
                    print("SWEEP \(Date().timeIntervalSince1970) cc=\(value)")
                    model.setLevel(channel: 6, value: value)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(values.count) * 2.0) {
                model.setLevel(channel: 6, value: 111)
            }
        }

        if let spec = ProcessInfo.processInfo.environment["FLOW8_FADER_TEST"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2 {
                let channel = parts[0]
                let value = parts[1]
                let restore = parts.count > 2 ? parts[2] : 111
                let delay = Double(ProcessInfo.processInfo.environment["FLOW8_FADER_DELAY"] ?? "") ?? 3.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    model.setLevel(channel: channel, value: value)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 6.0) {
                    model.setLevel(channel: channel, value: restore)
                }
            }
        }

        if let level = ProcessInfo.processInfo.environment["FLOW8_LEVEL_TEST"], let value = Int(level) {
            for index in model.channels.indices {
                model.channels[index].level = value
            }
        }

        if let calib = ProcessInfo.processInfo.environment["FLOW8_BLE_CALIB"] {
            let parts = calib.split(separator: ",").compactMap { Int($0) }
            if parts.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    BLECalibrator.shared.start(
                        channel: UInt8(parts[0]),
                        from: UInt8(parts[1]),
                        to: UInt8(parts[2]),
                        value: UInt8(parts[3])
                    )
                }
            }
        }

        if let tab = ProcessInfo.processInfo.environment["FLOW8_TAB"] {
            switch tab {
            case "fx": model.tab = .fx
            case "snapshots": model.tab = .snapshots
            case "settings": model.tab = .settings
            default: model.tab = .mixer
            }
        }

        if ProcessInfo.processInfo.environment["FLOW8_SNAPSHOT"] != nil {
            window.makeKeyAndOrderFront(nil)
            let delay = Double(ProcessInfo.processInfo.environment["FLOW8_SNAPSHOT_DELAY"] ?? "") ?? 1.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let basePath = ProcessInfo.processInfo.environment["FLOW8_SNAPSHOT"] ?? "/tmp/flow8-snapshot.png"
                for (index, candidate) in NSApp.windows.enumerated() where candidate.isVisible {
                    guard let view = candidate.contentView else { continue }
                    var target = view
                    if let frameView = view.superview { target = frameView }
                    guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
                    target.cacheDisplay(in: target.bounds, to: rep)
                    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                    let url = index == 0
                        ? URL(fileURLWithPath: basePath)
                        : URL(fileURLWithPath: basePath.replacingOccurrences(of: ".png", with: "-\(index).png"))
                    try? data.write(to: url)
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.string("О программе FLOW8"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Скрыть FLOW8"),
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Завершить FLOW8"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let syncItem = NSMenuItem(title: L10n.string("Синхронизировать с микшером"),
                                  action: #selector(syncNow(_:)),
                                  keyEquivalent: "r")
        syncItem.keyEquivalentModifierMask = [.command, .shift]
        syncItem.target = self

        let appActions = NSMenuItem()
        mainMenu.addItem(appActions)
        let actionsMenu = NSMenu(title: L10n.string("Действия"))
        appActions.submenu = actionsMenu
        actionsMenu.addItem(syncItem)

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L10n.string("Вид"))
        viewMenuItem.submenu = viewMenu
        let fullScreenItem = NSMenuItem(
            title: L10n.string("Полноэкранный режим"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.string("Правка"))
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.string("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.string("Вернуть"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.string("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.string("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.string("Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu

        if ProcessInfo.processInfo.environment["FLOW8_LANG_DEBUG"] != nil {
            print("MENU", mainMenu.items.compactMap { $0.submenu?.title })
            print("LANG", L10n.code)
        }
    }

    /// Keeps the window width in step with the number of visible strips.
    private func fitWindowToStrips() {
        guard let window, let model else { return }
        guard !window.styleMask.contains(.fullScreen),
              ProcessInfo.processInfo.environment["FLOW8_NO_FIT"] == nil else { return }
        let target = min(max(model.mixerContentWidth, 244), 2200)
        var frame = window.frame
        guard abs(frame.width - target) > 0.5 else { return }
        frame.size.width = target
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.origin.x < visible.minX { frame.origin.x = visible.minX }
        }
        window.setFrame(frame, display: true, animate: true)
    }

    @objc private func syncNow(_ sender: Any?) {
        model?.syncNow()
    }
}

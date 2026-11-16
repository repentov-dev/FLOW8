import AppKit
import SwiftUI

/// Opens the channel EQ in its own non-modal window, like the EQ panels in
/// RME Control. One window per channel, reopened on demand.
/// Borderless EQ panel: no title bar, draggable by its background, rounded.
final class EQPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class EQWindowManager: NSObject, NSWindowDelegate {
    static let shared = EQWindowManager()

    private var windows: [String: NSWindow] = [:]

    func show(channelID: Int, model: MixerModel) {
        let key = "ch\(channelID)"
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let name = model.channel(channelID)?.name ?? "Канал"
        let content = ChannelEQSheet(channelID: channelID, onClose: { [weak self] in
            self?.close(channelID: channelID)
        })
        .environmentObject(model)
        // The EQ lives in its own NSWindow, so it does not inherit the locale
        // from the main hierarchy — pass the app language explicitly.
        .environment(\.locale, model.appLocale)

        let hosting = NSHostingView(rootView: content)
        let window = EQPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.format("Эквалайзер · %@", name)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.contentView = hosting
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 260)
        self.roundCorners(window)
        self.centerOnMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        windows[key] = window
    }

    func show(busID: Int, model: MixerModel) {
        let key = "bus\(busID)"
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let name = model.buses.first(where: { $0.id == busID })?.title ?? "BUS"
        let content = BusEQSheet(busID: busID, onClose: { [weak self] in
            self?.close(busID: busID)
        })
        .environmentObject(model)
        .environment(\.locale, model.appLocale)

        let hosting = NSHostingView(rootView: content)
        let window = EQPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 330),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.format("Эквалайзер · %@", name)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.contentView = hosting
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 280)
        self.roundCorners(window)
        self.centerOnMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        windows[key] = window
    }

    /// Opens the panel in the middle of the app window, not the screen.
    private func centerOnMainWindow(_ window: NSWindow) {
        guard let main = NSApp.windows.first(where: { $0 !== window && $0.isVisible && !($0 is EQPanel) }) else {
            window.center()
            return
        }
        let target = main.frame
        let size = window.frame.size
        let origin = NSPoint(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func roundCorners(_ window: NSWindow) {
        guard let view = window.contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
    }

    func close(channelID: Int) {
        windows["ch\(channelID)"]?.close()
        windows["ch\(channelID)"] = nil
    }

    func close(busID: Int) {
        windows["bus\(busID)"]?.close()
        windows["bus\(busID)"] = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if ProcessInfo.processInfo.environment["FLOW8_LAYOUT_DEBUG"] != nil {
                let _ = print("ROOT size", proxy.size)
            }
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    TopBarView(width: width)
                    Divider().opacity(0.6)

                    Group {
                        switch model.tab {
                        case .mixer: MixerPage()
                        case .fx: FXPage()
                        case .snapshots: SnapshotsPage()
                        case .settings: SettingsPage()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(!model.isMixerConnected)
                    .overlay {
                        if !model.isMixerConnected {
                            DisconnectedOverlay()
                        }
                    }

                }
                .frame(width: width, height: proxy.size.height, alignment: .topLeading)
                .environment(\.locale, model.appLocale)
                .clipped()
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .frame(minWidth: 244, minHeight: 640)
    }
}

// MARK: - Top bar: tabs on the left, connection + actions on the right

private struct TopBarView: View {
    @EnvironmentObject private var model: MixerModel
    var width: CGFloat = 1440

    private var compact: Bool { width < 820 }
    private var veryCompact: Bool { width < 700 }
    /// Below the width of five channel strips the tabs switch to icons so the
    /// top bar keeps fitting without clipping.
    private var showsTabTitles: Bool { width >= 590 }

    var body: some View {
        HStack(spacing: 6) {
            TrafficLights()
                .padding(.trailing, 8)

            if width < 520 {
                Menu {
                    ForEach(MainTab.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { model.tab = tab }
                        } label: {
                            Text(LocalizedStringKey(tab.title))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(model.tab.title))
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Palette.accent.opacity(0.18)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.tab = tab
                        }
                    } label: {
                        Text(LocalizedStringKey(tab.title))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(model.tab == tab ? Palette.accent : Color.secondary)
                            .padding(.horizontal, width < 760 ? 7 : 11)
                            .padding(.vertical, 5)
                            .fixedSize()
                            .background(
                                Capsule().fill(model.tab == tab ? Palette.accent.opacity(0.18) : .clear)
                            )
                            .shadow(color: model.tab == tab ? Palette.accent.opacity(0.45) : .clear,
                                    radius: model.tab == tab ? 7 : 0)
                            .animation(.easeOut(duration: 0.18), value: model.tab == tab)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .help(tab.title)
                }
            }

            Spacer(minLength: 8)

            if model.tab == .mixer {
                FXPowerButton(compact: compact)
                StripsMenu(compact: compact)
            }
            SnapshotMenu(compact: compact || veryCompact)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(width: width)
        .frame(height: 46)
        .clipped()
    }


}

// MARK: - Window buttons

/// Custom close / minimise / zoom buttons, drawn inside the top bar so the
/// window has no title bar strip of its own.
private struct TrafficLights: View {
    @State private var hovering: Int?

    var body: some View {
        HStack(spacing: 8) {
            light(index: 0, color: Color(red: 1.0, green: 0.37, blue: 0.34)) {
                NSApp.keyWindow?.performClose(nil)
            }
            light(index: 1, color: Color(red: 1.0, green: 0.74, blue: 0.18)) {
                NSApp.keyWindow?.performMiniaturize(nil)
            }
            light(index: 2, color: Color(red: 0.24, green: 0.85, blue: 0.36)) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .onHover { hovering = $0 ? hovering : nil }
    }

    private func light(index: Int, color: Color, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(color.opacity(hovering == index ? 1.0 : 0.85))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            .shadow(color: color.opacity(hovering == index ? 0.6 : 0.25), radius: hovering == index ? 4 : 2)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .onHover { inside in
                hovering = inside ? index : (hovering == index ? nil : hovering)
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - FX power button

private struct FXPowerButton: View {
    @EnvironmentObject private var model: MixerModel
    var compact: Bool = false
    var showsTitle: Bool = true

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                model.toggleFXPower()
            }
        } label: {
            Text("FX")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(model.showsFXChannels ? Palette.fx : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Palette.fx.opacity(model.showsFXChannels ? 0.22 : 0.05))
            )
            .shadow(color: Palette.fx.opacity(model.showsFXChannels ? 0.45 : 0.12),
                    radius: model.showsFXChannels ? 6 : 2)
            .animation(.easeOut(duration: 0.2), value: model.showsFXChannels)
        }
        .buttonStyle(.plain)
        .help(model.showsFXChannels ? "Скрыть каналы FX 1 / FX 2" : "Показать каналы FX 1 / FX 2")
    }
}

// MARK: - Strips menu

private struct StripsMenu: View {
    @EnvironmentObject private var model: MixerModel
    var compact: Bool = false
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .semibold))
                if !compact {
                    Text("Полосы")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if model.hiddenStripCount > 0 {
                    Text("\(model.hiddenStripCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Каналы")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.channels) { channel in
                    Toggle(channel.name, isOn: Binding(
                        get: { !model.hiddenChannels.contains(channel.id) },
                        set: { model.setChannel(channel.id, hidden: !$0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                }
                Divider().padding(.vertical, 2)
                Text("Шины")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.buses) { bus in
                    Toggle(bus.title, isOn: Binding(
                        get: { !model.hiddenBuses.contains(bus.id) },
                        set: { model.setBus(bus.id, hidden: !$0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                }
                Divider().padding(.vertical, 2)
                Button("Показать все полосы") {
                    model.showAllStrips()
                }
                .disabled(model.hiddenStripCount == 0)
            }
            .padding(12)
            .frame(width: 210)
        }
    }
}

// MARK: - Snapshots menu

private struct SnapshotMenu: View {
    @EnvironmentObject private var model: MixerModel
    var compact: Bool = false
    @State private var showsSaveSheet = false

    var body: some View {
        Menu {
            ForEach(0..<15, id: \.self) { index in
                Button {
                    model.loadSnapshot(index)
                } label: {
                    if let name = model.snapshotNames[index], !name.isEmpty {
                        Text("\(String(format: "%02d", index + 1))  \(name)")
                    } else {
                        Text("\(String(format: "%02d", index + 1))  Снапшот")
                    }
                }
            }
            Divider()
            Button("Сохранить текущее состояние…") {
                showsSaveSheet = true
            }
            Button("Сбросить микшер", role: .destructive) {
                model.resetMixer()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                if compact {
                    EmptyView()
                } else if let index = model.currentSnapshot, index < 15,
                   let name = model.snapshotNames[index], !name.isEmpty {
                    Text(verbatim: name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if let index = model.currentSnapshot, index < 15 {
                    Text("Снапшот \(index + 1)")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("Снапшоты")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .layoutPriority(1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .animation(.easeOut(duration: 0.2), value: model.hiddenStripCount)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .sheet(isPresented: $showsSaveSheet) {
            SnapshotSaveSheet(initialIndex: model.currentSnapshot ?? 0)
                .environmentObject(model)
                .environment(\.locale, model.appLocale)
        }
        .help("Снапшоты микшера")
    }
}

// MARK: - Sync button

private struct SyncButton: View {
    @EnvironmentObject private var model: MixerModel
    var compact: Bool = false

    private var isBusy: Bool {
        switch model.syncState {
        case .connecting, .syncing: return true
        default: return false
        }
    }

    private var tint: Color {
        switch model.syncState {
        case .synced: return Palette.eq
        case .failed: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Button {
            model.syncNow()
        } label: {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                if !compact {
                    Text("Синхронизировать")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .layoutPriority(1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .animation(.easeOut(duration: 0.2), value: model.hiddenStripCount)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help("Прочитать актуальное состояние микшера (Bluetooth)")
    }
}

// MARK: - Disconnected overlay

private struct DisconnectedOverlay: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text("Микшер не подключён")
                    .font(.system(size: 17, weight: .semibold))
                Text("Включите FLOW 8 и подключитесь по Bluetooth.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                Button {
                    model.connectBluetooth()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Подключить")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Palette.accent.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .allowsHitTesting(true)
    }
}

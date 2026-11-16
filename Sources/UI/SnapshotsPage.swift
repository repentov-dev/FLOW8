import SwiftUI

struct SnapshotsPage: View {
    @EnvironmentObject private var model: MixerModel
    @State private var showsDebugSheet = false

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["FLOW8_SNAP_SHEET"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showsDebugSheet = true }
            }
        }
        .sheet(isPresented: $showsDebugSheet) {
            SnapshotSaveSheet(initialIndex: 14)
                .environmentObject(model)
                .environment(\.locale, model.appLocale)
        }
    }

    private func content(width: CGFloat) -> some View {
        let count = width < 700 ? 1 : (width < 1100 ? 2 : 3)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: count)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionHeader(
                        title: "Снапшоты микшера",
                        subtitle: "15 слотов хранятся в FLOW 8; имена считываются по Bluetooth"
                    )
                    Spacer()
                    Button {
                        model.syncNow()
                    } label: {
                        Label("Обновить имена", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    Button {
                        model.resetMixer()
                    } label: {
                        Label("Сбросить микшер", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.mute)
                }
                .padding(.horizontal, 2)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<15, id: \.self) { index in
                        SnapshotCard(index: index)
                    }
                }

                hint
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("Снапшоты хранятся в микшере. Нажмите на слот, чтобы загрузить его; имена появляются после синхронизации по Bluetooth.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

private struct SnapshotCard: View {
    @EnvironmentObject private var model: MixerModel
    let index: Int

    @State private var hovering = false
    @State private var showsSaveSheet = false
    @State private var showsDeleteAlert = false

    private var name: String? {
        guard index < model.snapshotNames.count else { return nil }
        let value = model.snapshotNames[index]
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var isCurrent: Bool { model.currentSnapshot == index }

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Palette.accent : Color.primary.opacity(0.75))
                .frame(width: 40, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if let name {
                        Text(verbatim: name)
                    } else {
                        Text("Снапшот \(index + 1)")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(name == nil ? .secondary : .primary)
                .lineLimit(1)

                Group {
                    if name == nil {
                        Text("Имя не задано")
                    } else {
                        Text("Слот \(index + 1)")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if hovering {
                HStack(spacing: 6) {
                    Button {
                        showsSaveSheet = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.accent.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Переименовать…")

                    Button {
                        showsDeleteAlert = true
                    } label: {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.mute.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Удалить снапшот")
                }
            } else if isCurrent {
                Pill(text: "ТЕКУЩИЙ", color: Palette.accent, filled: true)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrent
                      ? Palette.accent.opacity(0.14)
                      : Color(red: 0.072, green: 0.075, blue: 0.083)
                          .opacity(hovering ? 1.0 : 0.85))
                .shadow(color: isCurrent ? Palette.accent.opacity(0.30) : .black.opacity(0.22),
                        radius: isCurrent ? 7 : 4, y: 1)
        )
        .animation(.easeOut(duration: 0.18), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            model.loadSnapshot(index)
        }
        .contextMenu {
            Button("Загрузить") {
                model.loadSnapshot(index)
            }
            Button("Сохранить текущее состояние") {
                model.saveSnapshot(index)
            }
            Button("Переименовать…") {
                showsSaveSheet = true
            }
            Button("Удалить снапшот", role: .destructive) {
                showsDeleteAlert = true
            }
        }
        .alert("Удалить снапшот?", isPresented: $showsDeleteAlert) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                model.clearSnapshot(index)
            }
        } message: {
            Text("Имя слота будет очищено на микшере.")
        }
        .sheet(isPresented: $showsSaveSheet) {
            SnapshotSaveSheet(initialIndex: index)
                .environmentObject(model)
                .environment(\.locale, model.appLocale)
        }
        .onHover { hovering = $0 }
        .help("Загрузить снапшот \(index + 1)")
    }
}

/// Save the current mixer state into a slot under a chosen name.
struct SnapshotSaveSheet: View {
    @EnvironmentObject private var model: MixerModel
    @Environment(\.dismiss) private var dismiss

    let initialIndex: Int

    @State private var index: Int
    @State private var name: String

    init(initialIndex: Int) {
        self.initialIndex = initialIndex
        _index = State(initialValue: initialIndex)
        _name = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Сохранить снапшот")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                Text("Слот")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Picker("", selection: $index) {
                    ForEach(0..<15, id: \.self) { slot in
                        Text("\(slot + 1)").tag(slot)
                    }
                }
                .labelsHidden()
                .frame(width: 72)
                .onChange(of: index) { _, newValue in
                    name = model.snapshotNames[newValue] ?? ""
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text("Имя")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                TextField("Имя", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("В слот записывается текущее состояние микшера.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    model.saveSnapshot(index, name: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            name = model.snapshotNames[index] ?? ""
        }
    }
}

import SwiftUI

struct FXPage: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 1150 {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 9) {
                        ForEach(0..<2, id: \.self) { slot in
                            FXCard(slot: slot)
                        }
                        FXGlobalCard(fillsWidth: true)
                    }
                    .padding(10)
                }
            } else {
                // Scrolls horizontally if the window is narrower than the three
                // cards need, so nothing gets clipped at the right edge.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 9) {
                        ForEach(0..<2, id: \.self) { slot in
                            FXCard(slot: slot)
                        }
                        FXGlobalCard()
                    }
                    .padding(10)
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct FXCard: View {
    @EnvironmentObject private var model: MixerModel
    let slot: Int

    private var state: FXSlotState { model.fx[slot] }
    private var info: FXPresetInfo { FXCatalog.info(slot: slot, preset: state.preset) }
    private var presets: [FXPresetInfo] { FXCatalog.presets(for: slot) }
    private var busLevel: Int {
        model.buses.first(where: { $0.id == 10 + slot })?.level ?? 0
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("FX \(slot + 1)")
                    .font(.system(size: 13, weight: .bold))
                    .kerning(0.5)
                Text(slot == 0 ? "REVERB / MODULATION" : "DELAY / ECHO")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Palette.fx.opacity(0.9))
                Spacer()
                Text(String(format: "%02d", state.preset))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(size: 19, weight: .semibold))
                Text("Пресет \(state.preset) из 16")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(presets) { preset in
                    presetChip(preset)
                }
            }

            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(info.param1Label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(state.param1) %")
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ValueSlider(
                    value: Binding(
                        get: { model.fx[slot].param1 },
                        set: { model.setFXParam1(slot: slot, value: $0) }
                    ),
                    range: 0...100,
                    accent: Palette.fx
                )
                .frame(height: 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ХАРАКТЕР")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    CapsuleButton(
                        title: LocalizedStringKey(info.param2Off),
                        isOn: !state.param2,
                        color: Palette.fx
                    ) {
                        model.setFXParam2(slot: slot, isOn: false)
                    }
                    CapsuleButton(
                        title: LocalizedStringKey(info.param2On),
                        isOn: state.param2,
                        color: Palette.fx
                    ) {
                        model.setFXParam2(slot: slot, isOn: true)
                    }
                }
            }

            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("УРОВЕНЬ FX-ШИНЫ")
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Param.dbText(busLevel))
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ValueSlider(
                    value: Binding(
                        get: { model.buses.first(where: { $0.id == 10 + slot })?.level ?? 0 },
                        set: { model.setBusLevel(bus: 10 + slot, value: $0) }
                    ),
                    accent: Palette.fx
                )
                .frame(height: 20)
            }

            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 3) {
                Text("ПОСЫЛЫ КАНАЛОВ")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                ForEach(model.channels) { channel in
                    HStack(spacing: 8) {
                        Text(channel.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 66, alignment: .leading)

                        ValueSlider(
                            value: Binding(
                                get: { model.channel(channel.id)?.sends[slot + 2] ?? 0 },
                                set: { model.setSend(channel: channel.id, send: slot + 2, value: $0) }
                            ),
                            accent: Palette.fx
                        )

                        Text(channel.sends[slot + 2] == 0 ? "off" : Param.dbText(channel.sends[slot + 2]))
                            .font(.system(size: 8.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .stripCard(radius: 12)
    }

    private func presetChip(_ preset: FXPresetInfo) -> some View {
        let selected = preset.index == state.preset
        return Button {
            model.setFXPreset(slot: slot, preset: preset.index)
        } label: {
            HStack(spacing: 4) {
                Text(String(format: "%02d", preset.index))
                    .font(.system(size: 7.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary)
                Text(preset.name)
                    .font(.system(size: 8.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Palette.fx.opacity(0.75) : Color.primary.opacity(0.05))
            )
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))

        }
        .buttonStyle(.plain)
    }
}

private struct FXGlobalCard: View {
    @EnvironmentObject private var model: MixerModel
    var fillsWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ГЛОБАЛЬНО")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("TAP TEMPO")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)

                Button {
                    model.tapTempo()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "metronome")
                            .font(.system(size: 12, weight: .semibold))
                        Text("TAP")
                            .font(.system(size: 12, weight: .bold))
                            .kerning(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.accent.opacity(0.15))
                    )

                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)

                Text(model.tapBPM.map { String(format: "%.0f BPM", $0) } ?? "— BPM")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("Влияет на FX 2 (delay / echo)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 6) {
                Text("FX MUTE")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                CapsuleButton(title: "ЗАГЛУШИТЬ ОБА FX", isOn: model.fxMuted, color: Palette.fx) {
                    model.toggleFXMute()
                }
            }

        }
        .padding(10)
        .frame(width: fillsWidth ? nil : 250)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .stripCard(radius: 12)
    }
}

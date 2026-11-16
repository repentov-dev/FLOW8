import SwiftUI

struct MixerPage: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        GeometryReader { proxy in
            if ProcessInfo.processInfo.environment["FLOW8_LAYOUT_DEBUG"] != nil {
                let _ = print("PAGE size", proxy.size)
            }
            if model.visibleChannels.isEmpty && model.visibleBuses.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(model.visibleChannels) { channel in
                            ChannelStrip(channelID: channel.id) {
                                EQWindowManager.shared.show(channelID: channel.id, model: model)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                        }

                        if !model.visibleChannels.isEmpty && !model.visibleBuses.isEmpty {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 1)
                                .padding(.vertical, 6)
                        }

                        ForEach(model.visibleBuses.filter { !(model.monStereoLinked && $0.id == 9) }) { bus in
                            BusStrip(busID: bus.id) {
                                EQWindowManager.shared.show(busID: bus.id, model: model)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                        }

                        if !model.parkedChannels.isEmpty || !model.parkedBuses.isEmpty {
                            Spacer(minLength: 24)

                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 1)
                                .padding(.vertical, 6)

                            // Strips hidden in window mode stay on the far right,
                            // apart from the working set.
                            ForEach(model.parkedChannels) { channel in
                                ChannelStrip(channelID: channel.id) {
                                    EQWindowManager.shared.show(channelID: channel.id, model: model)
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                            }

                            ForEach(model.parkedBuses.filter { !(model.monStereoLinked && $0.id == 9) }) { bus in
                                BusStrip(busID: bus.id) {
                                    EQWindowManager.shared.show(busID: bus.id, model: model)
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                            }
                        }
                    }
                    .padding(12)
                    .frame(minWidth: proxy.size.width, alignment: .center)
                    .frame(height: proxy.size.height)
                    .animation(.easeInOut(duration: 0.24), value: model.hiddenChannels)
                    .animation(.easeInOut(duration: 0.24), value: model.hiddenBuses)
                }
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["FLOW8_BUS_EQ"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    EQWindowManager.shared.show(busID: 7, model: model)
                }
            }
            if let raw = ProcessInfo.processInfo.environment["FLOW8_EQ_CHANNEL"], let id = Int(raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    EQWindowManager.shared.show(channelID: id, model: model)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Все полосы скрыты")
                .font(.system(size: 12, weight: .medium))
            Button("Показать все полосы") {
                model.showAllStrips()
            }
            .font(.system(size: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Channel strip

struct ChannelStrip: View {
    @EnvironmentObject private var model: MixerModel
    let channelID: Int
    var onOpenEQ: () -> Void = {}

    var body: some View {
        if let channel = model.channel(channelID) {
            content(channel)
        }
    }

    private func content(_ channel: ChannelState) -> some View {
        VStack(spacing: 7) {
            header(channel)
            preampRow(channel)
            preampKnobs(channel)
            eqRow(channel)
            dynamicsRow(channel)
            sendsRow(channel)
            muteSoloRow(channel)

            VStack(spacing: 3) {
                Text(Param.dbText(channel.level))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Fader(
                    value: Binding(
                        get: { model.channel(channelID)?.level ?? 0 },
                        set: { model.setLevel(channel: channelID, value: $0) }
                    ),
                    defaultValue: Param.levelCC(0),
                    accent: Palette.kind(channel.kind),
                    showsScale: true,
                    meters: [model.inputMeters[channelID]],
                    meterColor: Palette.kind(channel.kind)
                )
                .frame(width: 70)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 7)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(width: 106)
        .frame(maxHeight: .infinity)
        .stripCard(radius: 10)
        .overlay(alignment: .top) {
            Capsule()
                .fill(Palette.kind(channel.kind))
                .frame(width: 30, height: 3)
                .shadow(color: Palette.kind(channel.kind).opacity(0.7), radius: 5)
                .padding(.top, 4)
        }
        .contextMenu {
            Button("Скрыть полосу") {
                model.setChannel(channelID, hidden: true)
            }
            Button("Показать все полосы") {
                model.showAllStrips()
            }
            .disabled(model.hiddenStripCount == 0)
            Divider()
            Button("Открыть эквалайзер") {
                onOpenEQ()
            }
        }
    }

    private func header(_ channel: ChannelState) -> some View {
        VStack(spacing: 1) {
            ChannelNameLabel(
                name: model.channel(channelID)?.name ?? "",
                onCommit: { model.renameChannel(id: channelID, to: $0) }
            )
            .frame(height: 14)

            Text(channel.kind.label + (channel.isStereo ? " · ST" : " · MONO"))
                .font(.system(size: 7.5, weight: .medium))
                .kerning(0.3)
                .foregroundStyle(Palette.kind(channel.kind).opacity(0.9))
                .lineLimit(1)
        }
        .frame(height: 27)
    }

    @ViewBuilder
    private func preampRow(_ channel: ChannelState) -> some View {
        HStack(spacing: 3) {
            if channel.hasPhantom {
                CapsuleButton(
                    title: "48V",
                    isOn: channel.phantom,
                    color: Palette.phantom
                ) {
                    model.togglePhantom(channel: channelID)
                }
            } else if channel.kind == .usbBT {
                Text("PLAYBACK")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            } else {
                Text(channel.isStereo ? "STEREO LINE" : "PREAMP")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func preampKnobs(_ channel: ChannelState) -> some View {
        if channel.hasGain {
            HStack(spacing: 4) {
                Knob(
                    value: Binding(
                        get: { model.channel(channelID)?.gain ?? 0 },
                        set: { model.setGain(channel: channelID, value: $0) }
                    ),
                    defaultValue: Param.gainCC(0),
                    size: 30,
                    label: "GAIN",
                    valueText: String(format: "%.0f dB", Param.gainDB(channel.gain)),
                    accent: Palette.kind(channel.kind)
                )
                Knob(
                    value: Binding(
                        get: { model.channel(channelID)?.lowCut ?? 0 },
                        set: { model.setLowCut(channel: channelID, value: $0) }
                    ),
                    defaultValue: 0,
                    size: 30,
                    label: "LOW CUT",
                    valueText: Param.lowCutText(channel.lowCut),
                    accent: Palette.solo
                )
            }
            .frame(height: 48)
        } else {
            HStack {
                Image(systemName: "waveform.path")
                    .font(.system(size: 10))
                Text("без преампа")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.tertiary)
            .frame(height: 48)
        }
    }

    private func eqRow(_ channel: ChannelState) -> some View {
        Button {
            onOpenEQ()
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Text("EQ")
                        .font(.system(size: 7.5, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 5)

                MiniEQCurve(gains: channel.eq, accent: Palette.kind(channel.kind))
                    .padding(.horizontal, 3)
                    .padding(.bottom, 2)
            }
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Открыть эквалайзер канала")
    }

    private func panKnob(_ channel: ChannelState) -> some View {
        Knob(
            value: Binding(
                get: { model.channel(channelID)?.pan ?? 64 },
                set: { model.setPan(channel: channelID, value: $0) }
            ),
            defaultValue: 64,
            size: 30,
            label: "PAN",
            valueText: Param.panText(channel.pan),
            accent: Palette.send
        )
    }

    private func dynamicsRow(_ channel: ChannelState) -> some View {
        Group {
            if channel.hasCompressor {
                HStack(spacing: 4) {
                    Knob(
                        value: Binding(
                            get: { model.channel(channelID)?.comp ?? 0 },
                            set: { model.setCompressor(channel: channelID, value: $0) }
                        ),
                        range: 0...100,
                        defaultValue: 0,
                        size: 30,
                        label: "COMP",
                        valueText: "\(channel.comp) %",
                        accent: Palette.comp
                    )
                    panKnob(channel)
                }
            } else {
                // No compressor on USB/BT: keep PAN centered instead of
                // leaving an empty slot that pushed it to the right.
                panKnob(channel)
            }
        }
        .frame(height: 48)
    }

    private func sendsRow(_ channel: ChannelState) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<4, id: \.self) { send in
                Knob(
                    value: Binding(
                        get: { model.channel(channelID)?.sends[send] ?? 0 },
                        set: { model.setSend(channel: channelID, send: send, value: $0) }
                    ),
                    defaultValue: 0,
                    size: 21,
                    label: ["M1", "M2", "F1", "F2"][send],
                    valueText: channel.sends[send] == 0 ? "off" : Param.dbText(channel.sends[send]),
                    accent: [Palette.eq, Palette.eq, Palette.fx, Palette.fx][send],
                    showsValue: false,
                    levelTaper: true
                )
            }
        }
        .frame(height: 37)
    }

    private func muteSoloRow(_ channel: ChannelState) -> some View {
        HStack(spacing: 4) {
            CapsuleButton(title: "MUTE", isOn: channel.mute, color: Palette.mute) {
                model.toggleMute(channel: channelID)
            }
            CapsuleButton(title: "SOLO", isOn: channel.solo, color: Palette.solo) {
                model.toggleSolo(channel: channelID)
            }
        }
        .frame(height: 22)
    }
}

// MARK: - Bus strip

struct BusStrip: View {
    @EnvironmentObject private var model: MixerModel
    let busID: Int
    var onOpenEQ: () -> Void

    var body: some View {
        if let bus = model.buses.first(where: { $0.id == busID }) {
            content(bus)
        }
    }

    private func content(_ bus: BusState) -> some View {
        VStack(spacing: 7) {
            VStack(spacing: 1) {
                Text(busID == 8 && model.monStereoLinked ? "MON 1/2" : bus.title)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 3) {
                    Text(subtitle(bus))
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(Palette.bus(bus.kind).opacity(0.9))
                    if busID == 8 {
                        Button {
                            model.toggleMonStereoLink()
                        } label: {
                            Text(model.monStereoLinked ? "STEREO" : "MONO")
                                .font(.system(size: 6.5, weight: .bold))
                                .foregroundStyle(model.monStereoLinked ? Palette.accent : Color.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(model.monStereoLinked ? Palette.accent.opacity(0.18) : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .help(model.monStereoLinked ? "Разъединить Mon 1 и Mon 2" : "Объединить Mon 1 и Mon 2 в стерео")
                    }
                }
            }
            .frame(height: 27)

            Text("OUTPUT")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 18)

            HStack(spacing: 4) {
                if bus.kind.hasBalance {
                    Knob(
                        value: Binding(
                            get: { model.buses.first(where: { $0.id == busID })?.balance ?? 64 },
                            set: { model.setBusBalance(bus: busID, value: $0) }
                        ),
                        defaultValue: 64,
                        size: 28,
                        label: "BALANCE",
                        valueText: Param.panText(bus.balance),
                        accent: Palette.send
                    )
                }
                if bus.kind.hasLimiter {
                    Knob(
                        value: Binding(
                            get: { model.buses.first(where: { $0.id == busID })?.limiter ?? 127 },
                            set: { model.setBusLimiter(bus: busID, value: $0) }
                        ),
                        defaultValue: 127,
                        size: 28,
                        label: "LIMIT",
                        valueText: String(format: "%.1f dB", Param.limiterDB(bus.limiter)),
                        accent: Palette.mute
                    )
                }
            }
            .frame(height: 48)

            Group {
                if bus.kind.hasEQ {
                    Button {
                        onOpenEQ()
                    } label: {
                        VStack(spacing: 2) {
                            ZStack {
                                Text("EQ")
                                    .font(.system(size: 7.5, weight: .semibold))
                                    .kerning(0.4)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 6.5, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 5)

                            MiniEQCurve(gains: bus.eq,
                                        frequencies: ChannelEQ.nineBandFrequencies,
                                        shelving: ChannelEQ.nineBandShelving,
                                        accent: Palette.bus(bus.kind))
                                .padding(.horizontal, 3)
                                .padding(.bottom, 2)
                        }
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                                .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Открыть эквалайзер шины")
                } else {
                    Text("LEVEL ONLY")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 38)

            VStack(spacing: 3) {
                Text(Param.dbText(bus.level))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Fader(
                    value: Binding(
                        get: { model.buses.first(where: { $0.id == busID })?.level ?? 0 },
                        set: { model.setBusLevel(bus: busID, value: $0) }
                    ),
                    defaultValue: Param.levelCC(0),
                    accent: Palette.bus(bus.kind),
                    showsScale: true,
                    meters: bus.kind == .main
                        ? [model.mainMeterL, model.mainMeterR]
                        : [],
                    meterColor: bus.kind == .main ? Palette.accent : Palette.bus(bus.kind)
                )
                .frame(width: bus.kind == .main ? 82 : 70)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 7)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(width: 96)
        .frame(maxHeight: .infinity)
        .stripCard(radius: 10)
        .overlay(alignment: .top) {
            Capsule()
                .fill(Palette.bus(bus.kind))
                .frame(width: 30, height: 3)
                .shadow(color: Palette.bus(bus.kind).opacity(0.7), radius: 5)
                .padding(.top, 4)
        }
        .contextMenu {
            Button("Скрыть полосу") {
                model.setBus(busID, hidden: true)
            }
            Button("Показать все полосы") {
                model.showAllStrips()
            }
            .disabled(model.hiddenStripCount == 0)
        }
    }

    private func subtitle(_ bus: BusState) -> String {
        switch bus.kind {
        case .main: return "MAIN OUT"
        case .mon1, .mon2: return "MONITOR"
        case .fx1, .fx2: return "FX SEND"
        }
    }
}

// MARK: - Bus 9-band EQ sheet

struct BusEQSheet: View {
    @EnvironmentObject private var model: MixerModel
    let busID: Int
    var onClose: (() -> Void)? = nil

    private let frequencies = ["63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    private let eqFrequencies: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Outer bands of the 9-band EQ are shelving filters, the rest are peaking.
    private let eqShelving: [Bool] = [true, false, false, false, false, false, false, false, true]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Palette.eq)
                Text("9-полосный эквалайзер")
                    .font(.system(size: 12, weight: .semibold))
                Text(busTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Сбросить EQ") {
                    for band in 0..<9 {
                        model.setBusEQ(bus: busID, band: band, value: 64)
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                Button("Закрыть") {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
            }
            .background(WindowDragArea())

            EQGraphView(
                frequencies: eqFrequencies,
                shelving: eqShelving,
                gains: currentEQ,
                labels: frequencies,
                accent: Palette.bus(busKind),
                onSet: { band, value in
                    model.setBusEQ(bus: busID, band: band, value: value)
                },
                onReset: { band in
                    model.setBusEQ(bus: busID, band: band, value: 64)
                }
            )
        }
        .padding(16)
        .frame(width: 700, height: 330)
        .background {
            VisualEffectBackground(material: .popover, blending: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var busKind: BusKind {
        model.buses.first(where: { $0.id == busID })?.kind ?? .main
    }

    private var currentEQ: [Int] {
        model.buses.first(where: { $0.id == busID })?.eq ?? Array(repeating: 64, count: 9)
    }

    private var busTitle: String {
        model.buses.first(where: { $0.id == busID })?.title ?? "BUS"
    }

    private func dbText(_ band: Int) -> String {
        Param.signedDB(Param.eqDB(currentEQ[band]))
    }
}

struct EQBandSlider: View {
    @Binding var value: Int
    var size: CGFloat = 20
    var accent: Color = Palette.eq

    @State private var dragStart: Int?

    var body: some View {
        GeometryReader { proxy in
            if ProcessInfo.processInfo.environment["FLOW8_LAYOUT_DEBUG"] != nil {
                let _ = print("PAGE size", proxy.size)
            }
            let height = proxy.size.height
            let usable = max(height - size, 1)
            let t = CGFloat(min(max(value, 0), 127)) / 127
            let thumbY = usable * (1 - t)
            let centerY = usable * 0.5

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 4)
                    .padding(.vertical, size / 2)

                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 1)
                    .offset(y: centerY + size / 2)

                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.55))
                    .frame(width: 4, height: abs(centerY - thumbY))
                    .offset(y: min(centerY, thumbY) + size / 2)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(width: 24, height: 11)
                    .offset(y: thumbY)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = value }
                        let start = dragStart ?? value
                        let delta = -gesture.translation.height / usable * 127
                        value = min(max(start + Int(delta.rounded()), 0), 127)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { value = 64 }
            )
        }
    }
}

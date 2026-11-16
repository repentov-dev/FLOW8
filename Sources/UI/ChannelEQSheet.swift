import SwiftUI

struct EQTarget: Identifiable {
    let id: Int
}

struct ChannelEQSheet: View {
    @EnvironmentObject private var model: MixerModel
    @Environment(\.dismiss) private var dismiss
    let channelID: Int
    var onClose: (() -> Void)? = nil

    private var channel: ChannelState? { model.channel(channelID) }
    private var accentColor: Color { Palette.kind(channel?.kind ?? .xlr) }
    private var gains: [Int] { channel?.eq ?? [64, 64, 64, 64] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            graph
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(width: 560, height: 300)
        .background {
            VisualEffectBackground(material: .popover, blending: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(accentColor)
            Text("Эквалайзер")
                .font(.system(size: 12, weight: .semibold))
            Text(channel?.name ?? "Канал")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Сбросить EQ") {
                for band in 0..<4 {
                    model.setEQ(channel: channelID, band: band, value: 64)
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
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
        }
        .background(WindowDragArea())
    }

    private var graph: some View {
        EQGraphView(
            frequencies: ChannelEQ.frequencies,
            shelving: ChannelEQ.shelving,
            gains: gains,
            labels: ChannelEQ.labels,
            accent: accentColor,
            onSet: { band, value in
                model.setEQ(channel: channelID, band: band, value: value)
            },
            onReset: { band in
                model.setEQ(channel: channelID, band: band, value: 64)
            }
        )
    }

    private func frequencyLabel(_ band: Int) -> String {
        let f = ChannelEQ.frequencies[band]
        return f >= 1000 ? String(format: "%.0f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }

}

/// Small response curve shown on the channel strip.
struct MiniEQCurve: View {
    let gains: [Int]
    var frequencies: [Double] = ChannelEQ.frequencies
    var shelving: [Bool] = ChannelEQ.shelving
    var accent: Color = Palette.eq

    var body: some View {
        Canvas { context, size in
            let zeroY = size.height / 2
            var curve = Path()
            let steps = 64

            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let frequency = 20.0 * pow(1000.0, t)
                let db = ChannelEQ.responseDB(gains: gains, frequencies: frequencies,
                                           shelving: shelving, at: frequency)
                let clamped = min(max(db, -18), 18)
                let px = CGFloat(t) * size.width
                let py = zeroY - CGFloat(clamped / 18.0) * (size.height / 2 - 2)
                if step == 0 {
                    curve.move(to: CGPoint(x: px, y: py))
                } else {
                    curve.addLine(to: CGPoint(x: px, y: py))
                }
            }

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: zeroY))
            zero.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(zero, with: .color(Color.primary.opacity(0.10)), lineWidth: 1)

            context.stroke(
                curve,
                with: .color(accent.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )

        }
        .drawingGroup()
    }
}

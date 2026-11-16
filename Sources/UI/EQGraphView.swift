import SwiftUI

/// Interactive EQ curve: grid, response curve and one draggable node per band.
/// Shared by the 4-band channel EQ and the 9-band bus EQ.
struct EQGraphView: View {
    var frequencies: [Double]
    var shelving: [Bool]
    var gains: [Int]
    var labels: [String]
    var accent: Color = Palette.eq
    var onSet: (Int, Int) -> Void
    var onReset: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    drawGrid(&context, size: canvasSize)
                    drawCurve(&context, size: canvasSize)
                }

                ForEach(Array(frequencies.indices), id: \.self) { band in
                    node(band: band, size: size)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func x(for frequency: Double, in size: CGSize) -> CGFloat {
        let t = log(frequency / 20.0) / log(1000.0)
        return CGFloat(t) * (size.width - 24) + 12
    }

    private func y(for db: Double, in size: CGSize) -> CGFloat {
        let clamped = min(max(db, -18), 18)
        return size.height / 2 - CGFloat(clamped / 18.0) * (size.height / 2 - 14)
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        for frequency in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            let px = x(for: frequency, in: size)
            var path = Path()
            path.move(to: CGPoint(x: px, y: 6))
            path.addLine(to: CGPoint(x: px, y: size.height - 6))
            context.stroke(
                path,
                with: .color(Color.primary.opacity(frequency == 1000 ? 0.14 : 0.055)),
                lineWidth: 1
            )
        }

        for db in [-15.0, -12, -9, -6, -3, 0, 3, 6, 9, 12, 15] {
            let py = y(for: db, in: size)
            var path = Path()
            path.move(to: CGPoint(x: 8, y: py))
            path.addLine(to: CGPoint(x: size.width - 8, y: py))
            context.stroke(
                path,
                with: .color(Color.primary.opacity(db == 0 ? 0.22 : 0.055)),
                lineWidth: db == 0 ? 1.2 : 1
            )
        }

        for (frequency, label) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
            let px = x(for: frequency, in: size)
            context.draw(
                Text(label)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.7)),
                at: CGPoint(x: px, y: size.height - 3),
                anchor: .bottom
            )
        }

        for (db, label) in [(-12.0, "−12"), (0.0, "0"), (12.0, "+12")] {
            let py = y(for: db, in: size)
            context.draw(
                Text(label)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.7)),
                at: CGPoint(x: 14, y: py - 2),
                anchor: .bottom
            )
        }
    }

    private func drawCurve(_ context: inout GraphicsContext, size: CGSize) {
        var curve = Path()
        var fill = Path()
        let steps = 240
        let zeroY = y(for: 0, in: size)

        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let frequency = 20.0 * pow(1000.0, t)
            let db = ChannelEQ.responseDB(gains: gains, frequencies: frequencies,
                                          shelving: shelving, at: frequency)
            let point = CGPoint(x: x(for: frequency, in: size), y: y(for: db, in: size))
            if step == 0 {
                curve.move(to: point)
                fill.move(to: CGPoint(x: point.x, y: zeroY))
                fill.addLine(to: point)
            } else {
                curve.addLine(to: point)
                fill.addLine(to: point)
            }
        }
        fill.addLine(to: CGPoint(x: x(for: 20000, in: size), y: zeroY))
        fill.closeSubpath()

        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [accent.opacity(0.22), accent.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.stroke(
            curve,
            with: .color(accent),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    private func node(band: Int, size: CGSize) -> some View {
        let frequency = frequencies[band]
        let value = band < gains.count ? gains[band] : 64
        let point = CGPoint(
            x: x(for: frequency, in: size),
            y: y(for: Param.eqDB(value), in: size)
        )

        return ZStack {
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 20, height: 20)
            Circle()
                .fill(Color(nsColor: .controlColor))
                .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
                .frame(width: 12, height: 12)
        }
        .contentShape(Circle())
        .position(point)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    InteractionGate.touch()
                    let db = 18.0 - Double(gesture.location.y / size.height) * 36.0
                    onSet(band, Param.eqCC(db))
                }
                .onEnded { _ in InteractionGate.end() }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onReset(band)
            }
        )
        .help("\(band < labels.count ? labels[band] : "") · \(Param.eqText(value))")
    }
}


/// Lets a borderless panel be moved only by its header: the graph keeps
/// receiving drags for the band handles.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

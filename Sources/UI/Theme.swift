import AppKit
import SwiftUI

// MARK: - Palette

enum Palette {
    static let accent = Color(red: 0.10, green: 0.80, blue: 1.0)          // cyan
    static let accentDeep = Color(red: 0.05, green: 0.40, blue: 1.0)     // blue
    static let mute = Color(red: 1.0, green: 0.16, blue: 0.30)            // rose red
    static let solo = Color(red: 1.0, green: 0.72, blue: 0.02)            // amber
    static let eq = Color(red: 0.10, green: 1.0, blue: 0.42)             // mint
    static let fx = Color(red: 0.62, green: 0.28, blue: 1.0)              // violet
    static let phantom = Color(red: 1.0, green: 0.20, blue: 0.26)         // red
    static let send = Color(red: 0.14, green: 0.58, blue: 1.0)            // blue
    static let comp = Color(red: 1.0, green: 0.52, blue: 0.04)            // orange

    static func kind(_ kind: InputKind) -> Color {
        switch kind {
        case .xlr: return Color(red: 1.0, green: 0.30, blue: 0.24)        // coral
        case .combo: return Color(red: 1.0, green: 0.62, blue: 0.02)      // amber
        case .line: return Color(red: 0.14, green: 1.0, blue: 0.55)      // mint
        case .usbBT: return Color(red: 0.16, green: 0.56, blue: 1.0)      // blue
        }
    }

    static func bus(_ kind: BusKind) -> Color {
        switch kind {
        case .main: return accent
        case .mon1: return Color(red: 0.16, green: 1.0, blue: 0.50)
        case .mon2: return Color(red: 0.04, green: 0.92, blue: 0.78)
        case .fx1: return fx
        case .fx2: return Color(red: 0.80, green: 0.28, blue: 1.0)
        }
    }
}

// MARK: - Surfaces

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

extension View {
    /// Rounded translucent card, same visual language as the RME Control popover.
    func panelCard(radius: CGFloat = 10) -> some View {
        self
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                    LinearGradient(
                        colors: [Color.white.opacity(0.035), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Flat card for the mixer strips: no gradient, no border, soft edges.
    func stripCard(radius: CGFloat = 10) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(red: 0.072, green: 0.075, blue: 0.083))
                    .shadow(
                        color: Color(red: 0.072, green: 0.075, blue: 0.083).opacity(0.75),
                        radius: 5
                    )
            )
    }

    func plainButton() -> some View {
        buttonStyle(.plain)
    }
}

// MARK: - Knob

struct Knob: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...127
    var defaultValue: Int = 64
    var size: CGFloat = 32
    var label: String
    var valueText: String
    var accent: Color = Palette.accent
    var enabled: Bool = true
    var showsValue: Bool = true
    /// Level knobs (sends, FX bus) use the same comfortable dB taper as the
    /// faders instead of a linear 0…127 scale.
    var levelTaper: Bool = false

    @State private var dragStart: Int?
    @State private var dragStartY: CGFloat?
    @State private var hovering = false
    @State private var fine = false

    private var fraction: CGFloat {
        if levelTaper {
            return CGFloat(Param.displayPosition(db: Param.levelDB(value) ?? -80))
        }
        let span = CGFloat(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return CGFloat(value - range.lowerBound) / span
    }

    var body: some View {
        VStack(spacing: 1) {
            Canvas { context, canvasSize in
                let rect = CGRect(origin: .zero, size: canvasSize)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let lineWidth: CGFloat = 2.8
                let radius = min(rect.width, rect.height) / 2 - lineWidth

                let start = Angle(degrees: 135)
                let end = Angle(degrees: 405)

                var track = Path()
                track.addArc(center: center, radius: radius,
                             startAngle: start, endAngle: end, clockwise: false)
                context.stroke(track, with: .color(Color.primary.opacity(0.13)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                if fraction > 0.001 {
                    var arc = Path()
                    arc.addArc(center: center, radius: radius,
                               startAngle: start,
                               endAngle: Angle(degrees: 135 + 270 * Double(fraction)),
                               clockwise: false)
                    context.stroke(arc, with: .color(accent),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                let angle = Angle(degrees: 135 + 270 * Double(fraction)).radians
                let indicator = enabled ? Color.primary.opacity(0.85) : Color.primary.opacity(0.3)
                if size < 26 {
                    // Small knobs show only the coloured arc, no indicator.
                } else {
                    // Keep the pointer inside the coloured ring instead of crossing it.
                    let inner = radius - 9
                    let outer = radius - 4.5
                    var pointer = Path()
                    pointer.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                             y: center.y + sin(angle) * inner))
                    pointer.addLine(to: CGPoint(x: center.x + cos(angle) * outer,
                                               y: center.y + sin(angle) * outer))
                    context.stroke(pointer, with: .color(indicator),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .frame(width: size, height: size)

            Text(label)
                .font(.system(size: size < 30 ? 7.5 : 8.5, weight: .semibold))
                .foregroundStyle(enabled ? .secondary : .tertiary)
                .lineLimit(1)

            if showsValue {
                Text(valueText)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard enabled else { return }
                    InteractionGate.touch()
                    if dragStart == nil || dragStartY == nil {
                        dragStart = value
                        dragStartY = gesture.startLocation.y
                        fine = NSEvent.modifierFlags.contains(.shift)
                    }
                    let start = dragStart ?? value
                    let startY = dragStartY ?? gesture.startLocation.y
                    let sensitivity: CGFloat = fine ? 700 : 190
                    if levelTaper {
                        let startFraction = Param.displayPosition(db: Param.levelDB(start) ?? -80)
                        let delta = Double((startY - gesture.location.y) / sensitivity)
                        let newFraction = min(max(startFraction + delta, 0), 1)
                        value = Param.levelCC(Param.displayDB(position: newFraction))
                    } else {
                        let span = CGFloat(range.upperBound - range.lowerBound)
                        let delta = (startY - gesture.location.y) / sensitivity * span
                        let newValue = start + Int(delta.rounded())
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    dragStartY = nil
                    fine = false
                    InteractionGate.end()
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard enabled else { return }
                value = defaultValue
            }
        )
        .help("\(label): \(valueText) — тяните вверх/вниз, двойной клик сбрасывает")
    }
}

// MARK: - Fader

struct Fader: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...127
    var defaultValue: Int = 100
    var accent: Color = Palette.accent
    var enabled: Bool = true
    var showsScale: Bool = true
    var meters: [Double] = []
    var meterColor: Color = Palette.eq

    @State private var dragStartValue: Int?
    @State private var dragStartY: CGFloat?
    @State private var hovering = false
    @State private var fine = false

    private let thumbSize: CGFloat = 18
    private let barWidth: CGFloat = 5
    private let gap: CGFloat = 2
    private let marks: [(Double, String)] = [
        (10, "+10"), (0, "0"), (-10, "−10"), (-20, "−20"), (-40, "−40"), (-60, "−60")
    ]

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let usable = max(height - thumbSize, 1)
            let fraction = CGFloat(Param.displayPosition(db: Param.levelDB(value) ?? -80))
            let thumbY = usable * (1 - fraction)

            let width = proxy.size.width
            let meterCount = min(meters.count, 2)
            let meterGroupWidth = CGFloat(meterCount) * barWidth + CGFloat(max(0, meterCount - 1)) * gap
            // Centre the whole bar block - meters plus the fader - inside the
            // strip: two bars on a mono track, three on a stereo one.
            let blockWidth = meterGroupWidth + (meterCount > 0 ? gap : 0) + barWidth
            let blockLeft = (width - blockWidth) / 2
            let meterLeft = blockLeft
            let trackLeft = meterCount > 0 ? blockLeft + meterGroupWidth + gap : blockLeft
            let tickRight = blockLeft - gap
            let labelRight = tickRight - 3

                    let drawBars: (inout GraphicsContext) -> Void = { (ctx: inout GraphicsContext) in
            if showsScale {
                for (db, label) in marks {
                    let f = CGFloat(Param.displayPosition(db: db))
                    let y = thumbSize / 2 + usable * (1 - f)
                    var tick = Path()
                    tick.move(to: CGPoint(x: tickRight - 3, y: y))
                    tick.addLine(to: CGPoint(x: tickRight, y: y))
                    ctx.stroke(tick, with: .color(Color.primary.opacity(0.16)), lineWidth: 1)
                    ctx.draw(
                        Text(label)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(Color.secondary.opacity(0.6)),
                        at: CGPoint(x: labelRight, y: y),
                        anchor: .trailing
                    )
                }
            }

            if meterCount > 0 {
                let top = thumbSize / 2
                let bottom = top + usable
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.10, green: 1.0, blue: 0.42), location: 0.0),
                        .init(color: Color(red: 0.10, green: 1.0, blue: 0.42), location: 0.44),
                        .init(color: Color(red: 1.00, green: 0.86, blue: 0.02), location: 0.62),
                        .init(color: Color(red: 1.00, green: 0.42, blue: 0.02), location: 0.71),
                        .init(color: Color(red: 1.00, green: 0.12, blue: 0.16), location: 0.76)
                    ]),
                    startPoint: CGPoint(x: 0, y: bottom),
                    endPoint: CGPoint(x: 0, y: top)
                )
                for i in 0..<meterCount {
                    let x = meterLeft + CGFloat(i) * (barWidth + gap)
                    let well = CGRect(x: x, y: top, width: barWidth, height: usable)
                    ctx.fill(Path(roundedRect: well, cornerRadius: 2.5), with: .color(Color.white.opacity(0.05)))
                    let level = min(max(meters[i], 0), 1)
                    let h = usable * CGFloat(level)
                    guard h > 0.5 else { continue }
                    let rect = CGRect(x: x, y: bottom - h, width: barWidth, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: shading)
                }
            }

            let trackRect = CGRect(x: trackLeft, y: thumbSize / 2, width: barWidth, height: usable)
            ctx.fill(Path(roundedRect: trackRect, cornerRadius: 2.5), with: .color(Color.primary.opacity(0.10)))

            // The coloured fill runs up to the centre of the handle.
            let fillTop = thumbSize / 2 + thumbY
            let fillBottom = thumbSize / 2 + usable
            if fillBottom - fillTop > 0.5 {
                let rect = CGRect(x: trackLeft, y: fillTop, width: barWidth, height: fillBottom - fillTop)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(accent))
            }
        }

            Canvas { context, _ in
                drawBars(&context)
            }
            .overlay(alignment: .topLeading) {
                FrostedThumb(
                    size: thumbSize,
                    offset: CGPoint(
                        x: trackLeft + barWidth / 2 - thumbSize / 2,
                        y: thumbSize / 2 + thumbY - thumbSize / 2
                    )
                ) { context in
                    drawBars(&context)
                }
                .scaleEffect(hovering ? 1.16 : 1)
                .position(x: trackLeft + barWidth / 2, y: thumbSize / 2 + thumbY)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        InteractionGate.touch()
                        if dragStartValue == nil {
                            dragStartValue = value
                            dragStartY = gesture.startLocation.y
                            fine = NSEvent.modifierFlags.contains(.shift)
                        }
                        let start = dragStartValue ?? value
                        let startY = dragStartY ?? gesture.startLocation.y
                        let startFraction = Param.displayPosition(db: Param.levelDB(start) ?? -80)
                        let sensitivity: CGFloat = fine ? 6 : 1
                        // Drag in fader space: the handle follows the cursor 1:1
                        // and the dB value is read back from the same taper the
                        // scale and the meters use.
                        let deltaFraction = (startY - gesture.location.y) / max(usable, 1) / sensitivity
                        let newFraction = min(max(startFraction + Double(deltaFraction), 0), 1)
                        value = Param.levelCC(Param.displayDB(position: newFraction))
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        dragStartY = nil
                        fine = false
                        InteractionGate.end()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard enabled else { return }
                    value = defaultValue
                }
            )
            .onHover { hovering = $0 }
        }
        .opacity(enabled ? 1 : 0.4)
        .help("Level: drag up/down, double-click — 0 dB")
    }
}

/// Fader handle: a small canvas that redraws the bars underneath, blurred and
/// clipped to a circle. As its own view it can be scaled smoothly on hover.
struct FrostedThumb: View {
    var size: CGFloat
    var offset: CGPoint
    var background: Color = Color(red: 0.072, green: 0.075, blue: 0.083)
    var tint: Color = Color.white.opacity(0.14)
    var draw: (inout GraphicsContext) -> Void

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let circle = Path(ellipseIn: rect)
            context.clip(to: circle)
            context.fill(Path(rect), with: .color(background))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.translateBy(x: -offset.x, y: -offset.y)
                draw(&layer)
            }
            context.fill(circle, with: .color(tint))
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal-slider handle: same frosted idea as the fader — the track under
/// the circle is redrawn blurred, so the coloured part shows through.
struct FrostedSliderThumb: View {
    var size: CGFloat = 17
    var barHeight: CGFloat = 6
    var fillColor: Color
    var trackColor: Color
    var background: Color = Color(red: 0.072, green: 0.075, blue: 0.083)

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let circle = Path(ellipseIn: rect)
            context.clip(to: circle)
            context.fill(Path(rect), with: .color(background))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.5))
                let y = (canvasSize.height - barHeight) / 2
                let barRect = CGRect(x: 0, y: y, width: canvasSize.width, height: barHeight)
                layer.fill(Path(roundedRect: barRect, cornerRadius: barHeight / 2), with: .color(trackColor))
                let filled = CGRect(x: 0, y: y, width: canvasSize.width / 2, height: barHeight)
                layer.fill(Path(roundedRect: filled, cornerRadius: barHeight / 2), with: .color(fillColor))
            }
            context.fill(circle, with: .color(Color.white.opacity(0.14)))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Small controls

struct CapsuleButton: View {
    var title: LocalizedStringKey
    var isOn: Bool = false
    var color: Color = Palette.eq
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .kerning(0.2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isOn ? color : Color.primary.opacity(hovering ? 0.11 : 0.06))
            )
            .foregroundStyle(isOn ? Color.white : color.opacity(0.95))
            .shadow(color: isOn ? color.opacity(0.45) : .black.opacity(0.20),
                    radius: isOn ? 6 : 2, y: 1)
            .animation(.easeOut(duration: 0.18), value: isOn)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .contentShape(Capsule())
            .onTapGesture {
                guard enabled else { return }
                action()
            }
            .onHover { hovering = $0 }
            .opacity(enabled ? 1 : 0.4)
    }
}

struct Pill: View {
    var text: LocalizedStringKey
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.14))
            )
            .foregroundStyle(filled ? .white : color)
            .overlay(
                Capsule().strokeBorder(color.opacity(filled ? 0 : 0.3), lineWidth: 1)
            )
            .fixedSize()
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.7), radius: pulsing ? 3 : 0)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Horizontal slider

struct ValueSlider: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...127
    var accent: Color = Palette.accent
    var enabled: Bool = true
    var defaultValue: Int? = nil

    @State private var dragStart: Int?
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = CGFloat(range.upperBound - range.lowerBound)
            let fraction = span > 0 ? CGFloat(value - range.lowerBound) / span : 0
            let height: CGFloat = 6

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: height)

                Capsule()
                    .fill(accent.opacity(0.75))
                    .frame(width: max(0, width * fraction), height: height)

                FrostedSliderThumb(
                    size: 17,
                    barHeight: height,
                    fillColor: accent.opacity(0.75),
                    trackColor: Color.primary.opacity(0.10)
                )
                .shadow(color: hovering ? accent.opacity(0.45) : .black.opacity(0.25),
                        radius: hovering ? 5 : 3, y: 1)
                .scaleEffect(hovering ? 1.15 : 1)
                .offset(x: max(0, min(width - 17, width * fraction - 8.5)))
                .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled, span > 0 else { return }
                        if dragStart == nil { dragStart = value }
                        let x = min(max(gesture.location.x, 0), width)
                        let newValue = range.lowerBound + Int((x / width * span).rounded())
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard enabled, let defaultValue else { return }
                    value = defaultValue
                }
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .frame(height: 20)
    }
}

// MARK: - Level meter

struct MeterBar: View {
    var level: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(level, 0), 1)
            let filled = max(1, proxy.size.height * clamped)

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.white.opacity(0.05))

                // Full-height gradient, revealed only up to the current level:
                // a quiet signal shows the green bottom part, loud climbs into
                // yellow and red near the top.
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.10, green: 1.0, blue: 0.42), location: 0.0),
                        .init(color: Color(red: 0.10, green: 1.0, blue: 0.42), location: 0.62),
                        .init(color: Color(red: 1.0, green: 0.85, blue: 0.25), location: 0.82),
                        .init(color: Color(red: 1.0, green: 0.45, blue: 0.20), location: 0.93),
                        .init(color: Color(red: 1.0, green: 0.25, blue: 0.25), location: 1.0)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: proxy.size.height)
                .mask(alignment: .bottom) {
                    Rectangle()
                        .frame(height: filled)
                }
            }
        }
        .frame(width: 5)
        .animation(.linear(duration: 0.1), value: level)
    }
}

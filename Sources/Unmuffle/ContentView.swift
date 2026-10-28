#if os(macOS)
import AppKit
import SwiftUI
import UnmuffleDSP

/// The menu bar window: a header with the main switch, the analyzer, then presets, boost
/// and the per-stage faders. Liquid Glass on macOS 26.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("adjustExpanded") private var adjustExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = model.errorMessage {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .red, text: error)
            } else if model.isRunning && model.seemsSilent {
                Notice(
                    symbol: "speaker.slash.fill", tint: .orange,
                    title: "Not hearing anything?",
                    text: "Allow Unmuffle under Privacy & Security → Screen & System Audio Recording, then switch it off and on.",
                    action: ("Open Privacy Settings", model.openPrivacySettings)
                )
            }

            analyzer

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Preset", detail: model.activePreset?.name ?? "Custom")
                presets
                Text(model.activePreset?.summary ?? "Your own settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Boost")
                BoostSlider(value: $model.settings.boostDB, range: EnhancerSettings.boostRange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { adjustExpanded.toggle() }
                } label: {
                    SectionHeader("Adjust", detail: "\(activeStages)/7 on", disclosure: adjustExpanded)
                }
                .buttonStyle(.plain)

                if adjustExpanded {
                    faders
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unmuffle")
                    .font(.system(size: 16, weight: .bold))
                HStack(spacing: 6) {
                    LevelBars(peak: model.isRunning ? model.meters.outputPeak : 0)
                    Text(model.statusText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Unmuffle", isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    /// The display, its legend, and the A/B switch.
    private var analyzer: some View {
        VStack(spacing: 8) {
            SpectrumView(
                spectrum: model.spectrum, active: model.isRunning, enhanced: model.settings.isEnabled,
                readout: model.isRunning ? model.cleanupText : nil
            )
            .frame(height: 116)
            HStack(spacing: 10) {
                LegendKey(color: .secondary, label: "Original")
                if model.isRunning && model.settings.isEnabled {
                    LegendKey(color: .accentColor, label: "Cleaned")
                }
                Spacer()
                Picker("Listen to", selection: $model.settings.isEnabled) {
                    Text("Original").tag(false)
                    Text("Enhanced").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .glassPanel(cornerRadius: 18)
    }

    /// A tab bar of preset icons. The active one is tinted; none is when the faders don't
    /// match a preset.
    private var presets: some View {
        HStack(spacing: 4) {
            ForEach(Preset.all) { preset in
                let selected = model.activePreset == preset
                Button {
                    model.apply(preset)
                } label: {
                    Image(systemName: preset.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel(preset.name)
            }
        }
        .padding(4)
        .glassPanel(cornerRadius: 14)
    }

    /// One fader per stage, like a mixing desk.
    private var faders: some View {
        HStack(spacing: 0) {
            Fader("Noise", "Hiss, hum, air conditioning, crowd murmur.", value: $model.settings.noiseReduction)
            Fader("Echo", "The big-room echo of a recording made in a theater.", value: $model.settings.dereverb)
            Fader("Voice", "Cuts boom and mud, brings dialogue forward.", value: $model.settings.dialogue)
            Fader("Clarity", "Restores the crisp top end cheap mics lose.", value: $model.settings.clarity)
            Fader("Bass", "Adds back low end.", value: $model.settings.bass)
            Fader("Width", "Spreads the sound out. Turns mono into stereo.", value: $model.settings.width)
            Fader("Level", "Quiet lines louder, explosions softer.", value: $model.settings.leveling)
        }
        .frame(height: 150)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
            Button {
                model.openGitHub()
            } label: {
                Image(systemName: "star")
            }
            .buttonBorderShape(.circle)
            .glassButtonStyle()
            .help("Star Unmuffle on GitHub")
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Text("Quit")
                    Text("⌘Q").foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("q")
            .glassButtonStyle()
        }
        .font(.callout)
    }

    private var activeStages: Int {
        let s = model.settings
        return [s.noiseReduction, s.dereverb, s.dialogue, s.clarity, s.bass, s.width, s.leveling]
            .filter { $0 >= 0.01 }
            .count
    }
}

// MARK: - Analyzer

/// A spectrum analyzer like the ones in audio software: dark display, dB and frequency
/// grid, what came in as a dim filled curve, what you hear as an accent line.
struct SpectrumView: View {
    let spectrum: EnhancerSpectrum
    let active: Bool
    let enhanced: Bool
    /// Shown in the top corner, like a meter readout.
    var readout: String?

    private let lowHz = 50.0
    private let highHz = 16_000.0
    private let floorDB: Float = -90
    private let ceilingDB: Float = -10

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 8
            let bottom = size.height - 16
            func x(_ hz: Double) -> CGFloat { CGFloat(log(hz / lowHz) / log(highHz / lowHz)) * size.width }
            func y(_ db: Float) -> CGFloat {
                let clamped = min(max(db, floorDB), ceilingDB)
                return top + CGFloat(1 - (clamped - floorDB) / (ceilingDB - floorDB)) * (bottom - top)
            }

            let grid = Color.white.opacity(0.07)
            let label = Color.white.opacity(0.32)
            for db: Float in [-20, -40, -60, -80] {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: size.width, y: y(db)))
                context.stroke(line, with: .color(grid), lineWidth: 1)
                context.draw(
                    Text("\(Int(db))".replacingOccurrences(of: "-", with: "−")).font(.system(size: 9, design: .monospaced)).foregroundColor(label),
                    at: CGPoint(x: 4, y: y(db) - 6), anchor: .leading
                )
            }
            for (hz, name) in [(100.0, "100"), (1000.0, "1k"), (10_000.0, "10k")] {
                var line = Path()
                line.move(to: CGPoint(x: x(hz), y: top))
                line.addLine(to: CGPoint(x: x(hz), y: bottom))
                context.stroke(line, with: .color(grid), lineWidth: 1)
                context.draw(
                    Text(name).font(.system(size: 9, design: .monospaced)).foregroundColor(label),
                    at: CGPoint(x: x(hz) + 3, y: size.height - 7), anchor: .leading
                )
            }

            let count = spectrum.input.count
            guard count > 1 else { return }
            func points(_ values: [Float]) -> [CGPoint] {
                values.indices.map { b in
                    let center = lowHz * pow(highHz / lowHz, (Double(b) + 0.5) / Double(count))
                    return CGPoint(x: x(center), y: active ? y(values[b]) : bottom)
                }
            }

            let original = points(spectrum.input)
            var area = smoothPath(original)
            area.addLine(to: CGPoint(x: original[count - 1].x, y: bottom))
            area.addLine(to: CGPoint(x: original[0].x, y: bottom))
            area.closeSubpath()
            context.fill(area, with: .color(.white.opacity(active ? 0.10 : 0.04)))
            context.stroke(smoothPath(original), with: .color(.white.opacity(0.32)), lineWidth: 1)

            if active && enhanced {
                context.stroke(
                    smoothPath(points(spectrum.output)),
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: 1.75, lineJoin: .round)
                )
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .topTrailing) {
            if let readout {
                Text(readout)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.085)))
        .environment(\.colorScheme, .dark)
    }

    /// Catmull-Rom spline through the band centers.
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        return path
    }
}

// MARK: - Small pieces

/// Uppercase section title, with an optional detail in the accent color on the right.
private struct SectionHeader: View {
    let title: String
    var detail: String?
    /// Shows a disclosure chevron, pointing down when true.
    var disclosure: Bool?

    init(_ title: String, detail: String? = nil, disclosure: Bool? = nil) {
        self.title = title
        self.detail = detail
        self.disclosure = disclosure
    }

    var body: some View {
        HStack(spacing: 5) {
            if let disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(disclosure ? 90 : 0))
            }
            Text(title.uppercased())
                .tracking(0.6)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }
}

private struct LegendKey: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Four little bars that move with the output level.
private struct LevelBars: View {
    let peak: Float

    var body: some View {
        let db = 20 * log10(max(peak, 1e-5))
        let level = CGFloat(min(max((db + 54) / 54, 0), 1))
        HStack(spacing: 2) {
            ForEach(Array(([0.55, 1.0, 0.75, 0.45] as [CGFloat]).enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(level > 0 ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 2.5, height: 3 + 8 * level * weight)
            }
        }
        .frame(height: 11)
        .animation(.linear(duration: 0.08), value: peak)
        .accessibilityHidden(true)
    }
}

/// A wide pill you drag, with the amount inside. Orange while it's boosting.
private struct BoostSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
    private var boosting: Bool { value >= 0.5 }
    private var label: String { boosting ? String(format: "+%.0f dB", value) : "Off" }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(boosting ? Color.orange : Color.primary.opacity(0.12))
                    .frame(width: height + (geo.size.width - height) * fraction)
                HStack {
                    Image(systemName: boosting ? "speaker.wave.3.fill" : "speaker.fill")
                        .foregroundStyle(boosting ? Color.white : Color.secondary)
                        .frame(width: height - 12)
                    Spacer()
                    Text(label)
                        .monospacedDigit()
                        .foregroundStyle(fraction > 0.82 ? Color.white : Color.primary)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = (drag.location.x - height / 2) / max(geo.size.width - height, 1)
                let raw = range.lowerBound + Float(min(max(f, 0), 1)) * (range.upperBound - range.lowerBound)
                value = (raw * 2).rounded() / 2
            })
        }
        .frame(height: 30)
        .help("Extra volume. A limiter keeps it from distorting.")
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: 0.5) { Text("Boost") }
        }
    }
}

/// A vertical fader: amount on top, name underneath.
private struct Fader: View {
    let title: String
    let help: String
    @Binding var value: Float

    private let knob: CGFloat = 16

    init(_ title: String, _ help: String, value: Binding<Float>) {
        self.title = title
        self.help = help
        _value = value
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let travel = geo.size.height - knob
                let offset = travel * CGFloat(1 - value)
                ZStack(alignment: .top) {
                    Canvas { context, size in
                        for i in 0...4 {
                            let y = knob / 2 + travel * CGFloat(i) / 4
                            var ticks = Path()
                            ticks.move(to: CGPoint(x: size.width / 2 - 10, y: y))
                            ticks.addLine(to: CGPoint(x: size.width / 2 - 6, y: y))
                            ticks.move(to: CGPoint(x: size.width / 2 + 6, y: y))
                            ticks.addLine(to: CGPoint(x: size.width / 2 + 10, y: y))
                            context.stroke(ticks, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                        }
                    }
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: max(geo.size.height - offset - knob / 2, 0))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .frame(width: knob, height: knob)
                        .offset(y: offset)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = 1 - (drag.location.y - knob / 2) / max(travel, 1)
                    value = (Float(min(max(f, 0), 1)) * 100).rounded() / 100
                })
            }
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .help(help)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1) { Text(title) }
        }
    }
}

private extension Preset {
    var symbol: String {
        switch id {
        case "cam": return "film"
        case "telesync": return "cable.connector"
        case "quiet": return "speaker.wave.1"
        case "night": return "moon.stars"
        case "max": return "bolt"
        default: return "slider.horizontal.3"
        }
    }
}

/// A tinted callout card for problems.
private struct Notice: View {
    let symbol: String
    let tint: Color
    var title: String?
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.callout.weight(.semibold))
                }
                Text(text)
                    .font(title == nil ? .callout : .caption)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                        .glassButtonStyle()
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}
#endif

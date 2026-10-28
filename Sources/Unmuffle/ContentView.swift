#if os(macOS)
import AppKit
import SwiftUI
import UnmuffleDSP

/// The menu bar window. Standard macOS controls throughout, so it looks like it belongs.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("adjustExpanded") private var adjustExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let error = model.errorMessage {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .red, text: error)
            } else if model.isRunning && model.seemsSilent {
                Notice(
                    symbol: "speaker.slash.fill", tint: .orange,
                    text: "Not hearing anything? Allow Unmuffle in Privacy & Security → Screen & System Audio Recording, then switch it off and on.",
                    action: ("Open Privacy Settings", model.openPrivacySettings)
                )
            }

            SpectrumView(spectrum: model.spectrum, active: model.isRunning, enhanced: model.settings.isEnabled)
                .frame(height: 112)
            readout

            Divider()

            row("Preset") {
                Picker("Preset", selection: presetSelection) {
                    ForEach(Preset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    if model.activePreset == nil {
                        Text("Custom").tag("custom")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(model.activePreset?.summary ?? "Your own settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 72)
                .padding(.top, -6)

            row("Listen to") {
                Picker("Listen to", selection: $model.settings.isEnabled) {
                    Text("Original").tag(false)
                    Text("Enhanced").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            DisclosureGroup("Adjust", isExpanded: $adjustExpanded) {
                VStack(spacing: 4) {
                    AdjustRow("Noise", "Hiss, hum, air conditioning, crowd murmur.", value: $model.settings.noiseReduction)
                    AdjustRow("Echo", "The big-room echo of a recording made in a theater.", value: $model.settings.dereverb)
                    AdjustRow("Dialogue", "Cuts boom and mud, brings voices forward.", value: $model.settings.dialogue)
                    AdjustRow("Clarity", "Restores the crisp top end cheap mics lose.", value: $model.settings.clarity)
                    AdjustRow("Bass", "Adds back low end.", value: $model.settings.bass)
                    AdjustRow("Width", "Spreads the sound out. Turns mono into stereo.", value: $model.settings.width)
                    AdjustRow("Leveling", "Quiet lines louder, explosions softer.", value: $model.settings.leveling)
                    AdjustRow(
                        "Boost", "Extra volume. A limiter keeps it from distorting.",
                        value: $model.settings.boostDB, range: EnhancerSettings.boostRange,
                        format: { String(format: "+%.0f dB", $0) }
                    )
                }
                .padding(.top, 6)
            }
            .font(.callout)

            Divider()

            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Unmuffle")
                    .font(.headline)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Unmuffle", isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var readout: some View {
        HStack(spacing: 12) {
            LegendKey(color: .secondary, label: "Original")
            if model.isRunning && model.settings.isEnabled {
                LegendKey(color: .accentColor, label: "Cleaned")
            }
            Spacer()
            Text(model.isRunning ? model.cleanupText : "Off")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { model.activePreset?.id ?? "custom" },
            set: { id in
                if let preset = Preset.all.first(where: { $0.id == id }) { model.apply(preset) }
            }
        )
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }
}

// MARK: - Analyzer

/// A spectrum analyzer like the ones in audio software: dark display, dB and frequency
/// grid, what came in as a dim filled curve, what you hear as an accent line.
struct SpectrumView: View {
    let spectrum: EnhancerSpectrum
    let active: Bool
    let enhanced: Bool

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
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.085)))
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

private struct LegendKey: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(label)
        }
    }
}

private struct AdjustRow: View {
    let title: String
    let help: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: (Float) -> String

    init(
        _ title: String, _ help: String, value: Binding<Float>,
        range: ClosedRange<Float> = 0...1,
        format: @escaping (Float) -> String = { "\(Int(($0 * 100).rounded()))%" }
    ) {
        self.title = title
        self.help = help
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 62, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .help(help)
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                }
            }
        }
        .font(.callout)
    }
}
#endif

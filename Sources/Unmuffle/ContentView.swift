#if os(macOS)
import AppKit
import SwiftUI
import UnmuffleDSP

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isRunning && model.seemsSilent {
                permissionHint
            }

            presetSection

            Picker("Listen to", selection: $model.settings.isEnabled) {
                Text("Original").tag(false)
                Text("Enhanced").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Flip between the untouched audio and the enhanced version.")

            Divider()

            VStack(spacing: 10) {
                Knob("Noise removal", "Hiss, hum, air conditioning, crowd murmur.", value: $model.settings.noiseReduction)
                Knob("Echo removal", "The big-room echo of a recording made in a theater.", value: $model.settings.dereverb)
                Knob("Dialogue focus", "Cuts boom and mud, brings voices forward.", value: $model.settings.dialogue)
                Knob("Clarity", "Restores the crisp top end cheap mics lose.", value: $model.settings.clarity)
                Knob("Bass", "Adds back low end.", value: $model.settings.bass)
                Knob("Width", "Spreads the sound out. Turns mono into stereo.", value: $model.settings.width)
                Knob("Leveling", "Quiet lines louder, explosions softer.", value: $model.settings.leveling)
                Knob(
                    "Boost", "Extra volume. A limiter keeps it from distorting.",
                    value: $model.settings.boostDB, range: EnhancerSettings.boostRange,
                    format: { String(format: "+%.0f dB", $0) }
                )
            }

            Divider()

            meterSection

            HStack {
                Text("Unmuffle 0.1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unmuffle")
                    .font(.title3.weight(.semibold))
                Text(model.isRunning ? "Enhancing everything your Mac plays" : "Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enhance", isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not hearing anything?")
                .font(.callout.weight(.semibold))
            Text("If something is playing but the input meter stays empty, allow Unmuffle under Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then turn it off and on.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") { model.openPrivacySettings() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Preset", selection: Binding(
                get: { model.activePreset?.id ?? "custom" },
                set: { id in
                    if let preset = Preset.all.first(where: { $0.id == id }) { model.apply(preset) }
                }
            )) {
                ForEach(Preset.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
                if model.activePreset == nil {
                    Text("Custom").tag("custom")
                }
            }
            .pickerStyle(.menu)

            Text(model.activePreset?.summary ?? "Your own mix.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LevelBar(label: "In", level: model.meters.inputPeak)
            LevelBar(label: "Out", level: model.meters.outputPeak)
            if model.isRunning {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var statusLine: String {
        let meters = model.meters
        guard model.settings.isEnabled else { return "Playing the original audio" }
        var parts: [String] = []
        if meters.cleanupDB < -0.5 { parts.append(String(format: "Removing %.0f dB of noise and echo", -meters.cleanupDB)) }
        if abs(meters.levelerDB) > 0.5 { parts.append(String(format: "leveler %+.0f dB", meters.levelerDB)) }
        return parts.isEmpty ? "Listening…" : parts.joined(separator: ", ")
    }
}

private struct Knob: View {
    let title: String
    let help: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var format: (Float) -> String = { "\(Int(($0 * 100).rounded()))%" }

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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
        .help(help)
    }
}

private struct LevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(fraction > 0.95 ? Color.orange : Color.accentColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
    }

    /// -60 dBFS ... 0 dBFS mapped to 0 ... 1.
    private var fraction: CGFloat {
        let db = 20 * log10(Double(max(level, 1e-5)))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}
#endif

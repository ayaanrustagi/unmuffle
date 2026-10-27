#if os(macOS)
import AppKit
import SwiftUI
import UnmuffleDSP

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HeaderView()

            if let error = model.errorMessage {
                Banner(icon: "exclamationmark.triangle.fill", tint: .red, title: "Couldn't start", message: error)
            } else if model.isRunning && model.seemsSilent {
                Banner(
                    icon: "ear.trianglebadge.exclamationmark", tint: .orange,
                    title: "Not hearing anything?",
                    message: "If something is playing, allow Unmuffle under Privacy & Security → Screen & System Audio Recording, then switch it off and on.",
                    actionTitle: "Open Privacy Settings", action: model.openPrivacySettings
                )
            }

            SpectrumCard()
            ListenSwitch()
            PresetPicker()
            FineTuneSection()
            Divider().opacity(0.6)
            FooterView()
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unmuffle")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            PowerButton(isOn: model.isRunning) { model.setRunning(!model.isRunning) }
        }
    }
}

private struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(isOn ? AnyShapeStyle(Theme.diagonal) : AnyShapeStyle(Theme.card))
                }
                .overlay {
                    Circle().strokeBorder(isOn ? Color.clear : Theme.stroke)
                }
                .shadow(color: isOn ? Theme.pink.opacity(0.45) : .clear, radius: 8, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Turn Unmuffle off" : "Turn Unmuffle on")
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

// MARK: - Spectrum

private struct SpectrumCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SpectrumBars(
                spectrum: model.spectrum,
                active: model.isRunning,
                enhanced: model.settings.isEnabled
            )
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 32)

            HStack(spacing: 10) {
                if model.isRunning {
                    LegendDot(fill: AnyShapeStyle(Color.primary.opacity(0.25)), label: "Original")
                    if model.settings.isEnabled {
                        LegendDot(fill: AnyShapeStyle(Theme.gradient), label: "Enhanced")
                    }
                    Spacer()
                    Text(model.cleanupText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Turn it on, then play something.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(height: 116)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Dim bars are what came in, bright bars are what you hear. The gap between them is
/// the noise and echo being removed.
private struct SpectrumBars: View {
    let spectrum: EnhancerSpectrum
    let active: Bool
    let enhanced: Bool

    var body: some View {
        Canvas { context, size in
            let count = spectrum.input.count
            guard count > 0 else { return }
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let barGradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Theme.violet, Theme.pink]),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: 0)
            )
            for i in 0..<count {
                let x = CGFloat(i) * (width + gap)
                guard active else {
                    context.fill(bar(x, width, 3, size.height), with: .color(Color.primary.opacity(0.12)))
                    continue
                }
                let before = barHeight(spectrum.input[i], size.height)
                context.fill(bar(x, width, before, size.height), with: .color(Color.primary.opacity(enhanced ? 0.13 : 0.3)))
                if enhanced {
                    let after = barHeight(spectrum.output[i], size.height)
                    context.fill(bar(x, width, after, size.height), with: barGradient)
                }
            }
        }
    }

    private func bar(_ x: CGFloat, _ width: CGFloat, _ height: CGFloat, _ maxHeight: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: maxHeight - height, width: width, height: height), cornerRadius: min(width / 2, 3))
    }

    /// -90 dB ... -10 dB fills the card.
    private func barHeight(_ db: Float, _ maxHeight: CGFloat) -> CGFloat {
        let normalized = CGFloat(min(max((db + 90) / 80, 0), 1))
        return max(3, normalized * maxHeight)
    }
}

private struct LegendDot: View {
    let fill: AnyShapeStyle
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(fill).frame(width: 10, height: 4)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Original / Enhanced

private struct ListenSwitch: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            segment("Original", enhanced: false)
            segment("Enhanced", enhanced: true)
        }
        .padding(3)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .help("Flip between the untouched audio and the cleaned-up version.")
    }

    private func segment(_ title: String, enhanced: Bool) -> some View {
        let selected = model.settings.isEnabled == enhanced
        return Button {
            withAnimation(.snappy(duration: 0.25)) { model.settings.isEnabled = enhanced }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? (enhanced ? Color.white : Color.primary) : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background {
                    if selected {
                        Capsule()
                            .fill(enhanced ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Presets

private struct PresetPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Preset")
            HStack(spacing: 6) {
                ForEach(Preset.all) { preset in
                    PresetTile(preset: preset, selected: model.activePreset == preset) {
                        withAnimation(.snappy(duration: 0.2)) { model.apply(preset) }
                    }
                }
            }
            Text(model.activePreset?.summary ?? "Your own mix. Pick a preset to start over.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PresetTile: View {
    let preset: Preset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 18)
                Text(preset.shortName)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.diagonal) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.clear : Theme.stroke)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preset.name)
    }
}

// MARK: - Fine-tune

private struct FineTuneSection: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("fineTuneExpanded") private var expanded = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    SectionLabel("Fine-tune")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                    if model.activePreset == nil {
                        Text("CUSTOM")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.pink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 6) {
                    TuneRow("Noise", "Hiss, hum, air conditioning, crowd murmur.", value: $model.settings.noiseReduction)
                    TuneRow("Echo", "The big-room echo of a recording made in a theater.", value: $model.settings.dereverb)
                    TuneRow("Dialogue", "Cuts boom and mud, brings voices forward.", value: $model.settings.dialogue)
                    TuneRow("Clarity", "Restores the crisp top end cheap mics lose.", value: $model.settings.clarity)
                    TuneRow("Bass", "Adds back low end.", value: $model.settings.bass)
                    TuneRow("Width", "Spreads the sound out. Turns mono into stereo.", value: $model.settings.width)
                    TuneRow("Leveling", "Quiet lines louder, explosions softer.", value: $model.settings.leveling)
                    TuneRow(
                        "Boost", "Extra volume. A limiter keeps it from distorting.",
                        value: $model.settings.boostDB, range: EnhancerSettings.boostRange,
                        format: { String(format: "+%.0f dB", $0) }
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct TuneRow: View {
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
                .font(.system(size: 12))
                .frame(width: 62, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.mini)
                .tint(Theme.violet)
            Text(format(value))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .help(help)
    }
}

// MARK: - Footer and shared bits

private struct FooterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
            Text("Processed on your Mac. Nothing is recorded.")
                .font(.system(size: 11))
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Button("Unmuffle on GitHub") { model.openGitHub() }
                Divider()
                Button("Quit Unmuffle") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
    }
}

private struct SectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct Banner: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
    }
}
#endif

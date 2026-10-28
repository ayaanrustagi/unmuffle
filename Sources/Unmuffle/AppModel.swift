#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import UnmuffleDSP

/// UI state. Lives on the main thread.
final class AppModel: ObservableObject {
    @Published var settings: EnhancerSettings {
        didSet {
            engine.update(settings)
            save()
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var meters = EnhancerMeters()
    @Published private(set) var spectrum = EnhancerSpectrum.silent
    @Published private(set) var outputDeviceName: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// True when we're running but have heard nothing for a while, which usually means
    /// the System Audio Recording permission hasn't been granted.
    @Published private(set) var seemsSilent = false

    private let engine = SystemAudioEngine()
    private var meterTimer: Timer?
    private var lastHeard = Date()
    private static let settingsKey = "settings.v1"
    private static let repository = URL(string: "https://github.com/ayaanrustagi/unmuffle")!

    init() {
        settings = Self.loadSettings()
        engine.onOutputDeviceChange = { [weak self] in
            self?.restart()
        }
    }

    /// A model that looks like it's running, without touching any audio. For screenshots.
    init(preview: Void) {
        settings = Preset.camRip.settings
        isRunning = true
        outputDeviceName = "AirPods Pro"
        spectrum = Self.sampleSpectrum
        meters.outputPeak = 0.5
    }

    var activePreset: Preset? { Preset.matching(settings) }

    var statusText: String {
        guard isRunning else { return "Off" }
        let device = outputDeviceName.map { " · \($0)" } ?? ""
        return (settings.isEnabled ? "Enhancing" : "Playing the original") + device
    }

    /// Average gap between the original and cleaned-up spectrum bars, so the number
    /// matches what the display shows. (Total energy removed reads tiny while someone is
    /// talking, because the voice dominates it.)
    var cleanupText: String {
        guard settings.isEnabled else { return "Bypassed" }
        let gaps = zip(spectrum.input, spectrum.output).map { max($0 - $1, 0) }
        let removed = gaps.reduce(0, +) / Float(max(gaps.count, 1))
        return removed >= 0.5 ? String(format: "−%.0f dB noise & echo", removed) : "Listening…"
    }

    func setRunning(_ running: Bool) {
        running ? start() : stop()
    }

    func start() {
        guard !isRunning else { return }
        do {
            try engine.start(settings: settings)
            isRunning = true
            outputDeviceName = engine.outputDeviceName
            errorMessage = nil
            lastHeard = Date()
            seemsSilent = false
            startMeters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        stopMeters()
        meters = EnhancerMeters()
        spectrum = .silent
        outputDeviceName = nil
        seemsSilent = false
    }

    func apply(_ preset: Preset) {
        var next = preset.settings
        next.isEnabled = settings.isEnabled
        settings = next
    }

    func openGitHub() {
        NSWorkspace.shared.open(Self.repository)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Headphones plugged in, AirPods connected, etc.: rebuild the route to the new device.
    private func restart() {
        guard isRunning else { return }
        engine.stop()
        do {
            try engine.start(settings: settings)
            outputDeviceName = engine.outputDeviceName
        } catch {
            isRunning = false
            stopMeters()
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Meters

    private func startMeters() {
        stopMeters()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.pollMeters()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func pollMeters() {
        guard let latest = engine.readMeters() else { return }
        var display = latest
        // Let peaks fall smoothly instead of flickering.
        display.inputPeak = max(latest.inputPeak, meters.inputPeak * 0.85)
        display.outputPeak = max(latest.outputPeak, meters.outputPeak * 0.85)
        meters = display

        if let fresh = engine.readSpectrum(), fresh.input.count == spectrum.input.count {
            // Bars jump up instantly and fall back smoothly.
            var smoothed = fresh
            for i in smoothed.input.indices {
                smoothed.input[i] = max(fresh.input[i], spectrum.input[i] - 1.8)
                smoothed.output[i] = max(fresh.output[i], spectrum.output[i] - 1.8)
            }
            spectrum = smoothed
        }

        if latest.inputPeak > 1e-4 {
            lastHeard = Date()
            if seemsSilent { seemsSilent = false }
        } else if !seemsSilent, Date().timeIntervalSince(lastHeard) > 5 {
            seemsSilent = true
        }
    }

    /// A real moment from the demo recording (a voice over strings in a reverberant room).
    static let sampleSpectrum = EnhancerSpectrum(
        input: [-45, -42, -34, -28, -30, -36, -39, -37, -29, -28, -29, -34, -37, -35, -40, -40, -39, -34, -42, -46, -48, -43, -44, -43, -48, -50, -56, -65, -71, -70, -69, -70],
        output: [-46, -42, -34, -30, -34, -42, -50, -42, -32, -28, -29, -36, -39, -36, -43, -51, -53, -34, -49, -57, -61, -49, -57, -50, -62, -56, -69, -78, -79, -84, -83, -81]
    )

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private static func loadSettings() -> EnhancerSettings {
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let saved = try? JSONDecoder().decode(EnhancerSettings.self, from: data)
        else { return .default }
        return saved.clamped
    }
}
#endif

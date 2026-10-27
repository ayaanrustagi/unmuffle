#if os(macOS)
import AppKit
import Combine
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
    /// True when we're running but have heard nothing for a while, which usually means
    /// the System Audio Recording permission hasn't been granted.
    @Published private(set) var seemsSilent = false

    private let engine = SystemAudioEngine()
    private var meterTimer: Timer?
    private var lastHeard = Date()
    private static let settingsKey = "settings.v1"

    init() {
        settings = Self.loadSettings()
        engine.onOutputDeviceChange = { [weak self] in
            self?.restart()
        }
    }

    var activePreset: Preset? { Preset.matching(settings) }

    func setRunning(_ running: Bool) {
        running ? start() : stop()
    }

    func start() {
        guard !isRunning else { return }
        do {
            try engine.start(settings: settings)
            isRunning = true
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
        seemsSilent = false
    }

    func apply(_ preset: Preset) {
        var next = preset.settings
        next.isEnabled = settings.isEnabled
        settings = next
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
        } catch {
            isRunning = false
            stopMeters()
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Meters

    private func startMeters() {
        stopMeters()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
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

        if latest.inputPeak > 1e-4 {
            lastHeard = Date()
            if seemsSilent { seemsSilent = false }
        } else if !seemsSilent, Date().timeIntervalSince(lastHeard) > 5 {
            seemsSilent = true
        }
    }

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

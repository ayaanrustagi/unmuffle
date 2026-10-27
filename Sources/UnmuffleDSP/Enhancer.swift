import Foundation

/// Levels for the UI. Peaks are linear (1.0 = full scale) and reset every time they're read.
public struct EnhancerMeters: Equatable, Sendable {
    public var inputPeak: Float = 0
    public var outputPeak: Float = 0
    /// Energy removed by noise and echo reduction, in dB (0 or negative).
    public var cleanupDB: Float = 0
    /// Gain the leveler is applying right now, in dB.
    public var levelerDB: Float = 0
    /// Gain reduction from the output limiter, in dB (0 or negative).
    public var limiterDB: Float = 0

    public init() {}
}

/// The full enhancement chain for one stereo stream.
///
///     rumble filter → noise + echo removal → EQ → exciter → mid/side
///       → leveler → boost → limiter
///
/// `process` is real-time safe: no allocation, and it never blocks on a lock (settings
/// and meters are exchanged with `try`). Call `update` and `readMeters` from any thread.
public final class Enhancer {
    public static let maximumBlockSize = 4096

    public let sampleRate: Double
    /// Delay through the chain, in samples. Bypass is delayed by the same amount so
    /// switching between original and enhanced is seamless.
    public let latency: Int

    private let settingsLock = NSLock()
    private var pendingSettings: EnhancerSettings?
    private var settings: EnhancerSettings

    private let meterLock = NSLock()
    private var sharedMeters = EnhancerMeters()
    private var unpublishedInputPeak: Float = 0
    private var unpublishedOutputPeak: Float = 0

    private var rumbleFilter = StereoBiquad()
    private let cleaner: SpectralCleaner
    private var bassShelf = StereoBiquad()
    private var mudCut = StereoBiquad()
    private var presence = StereoBiquad()
    private var airShelf = StereoBiquad()
    private let exciter: Exciter
    private let stereo: StereoStage
    private let leveler: Leveler
    private let limiter: Limiter

    private let dryDelayLeft: FloatStorage
    private let dryDelayRight: FloatStorage
    private var dryIndex = 0
    private let dryLeft: FloatStorage
    private let dryRight: FloatStorage
    private var wetMix: Float
    private let mixStep: Float
    private var outputGain: Float = 1
    private var outputGainTarget: Float = 1
    private let gainSmoothing: Float

    public init(sampleRate: Double, settings: EnhancerSettings = .default) {
        self.sampleRate = sampleRate
        cleaner = SpectralCleaner(sampleRate: sampleRate)
        exciter = Exciter(sampleRate: sampleRate, maximumBlockSize: Self.maximumBlockSize)
        stereo = StereoStage(sampleRate: sampleRate)
        leveler = Leveler(sampleRate: sampleRate)
        limiter = Limiter(sampleRate: sampleRate)
        latency = cleaner.latency + limiter.lookahead

        dryDelayLeft = FloatStorage(count: latency)
        dryDelayRight = FloatStorage(count: latency)
        dryLeft = FloatStorage(count: Self.maximumBlockSize)
        dryRight = FloatStorage(count: Self.maximumBlockSize)
        mixStep = Float(1 / (0.04 * sampleRate))
        gainSmoothing = Float(smoothingCoefficient(seconds: 0.03, sampleRate: sampleRate))

        let initial = settings.clamped
        self.settings = initial
        wetMix = initial.isEnabled ? 1 : 0
        apply(initial)
        outputGain = outputGainTarget
    }

    /// Queue new settings. Picked up at the start of the next processed block.
    public func update(_ newSettings: EnhancerSettings) {
        settingsLock.lock()
        pendingSettings = newSettings.clamped
        settingsLock.unlock()
    }

    /// Latest meter values. Peaks cover everything since the previous call.
    public func readMeters() -> EnhancerMeters {
        meterLock.lock()
        defer { meterLock.unlock() }
        let meters = sharedMeters
        sharedMeters.inputPeak = 0
        sharedMeters.outputPeak = 0
        return meters
    }

    /// Processes a stereo stream in place. Any frame count is fine.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let count = min(Self.maximumBlockSize, frameCount - offset)
            processBlock(left: left + offset, right: right + offset, count: count)
            offset += count
        }
    }

    private func processBlock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        if settingsLock.try() {
            let next = pendingSettings
            pendingSettings = nil
            settingsLock.unlock()
            if let next { apply(next) }
        }

        // Keep a latency-matched copy of the input for bypass and crossfades.
        let dl = dryLeft.pointer
        let dr = dryRight.pointer
        let delayL = dryDelayLeft.pointer
        let delayR = dryDelayRight.pointer
        var inputPeak = unpublishedInputPeak
        for i in 0..<count {
            let l = left[i]
            let r = right[i]
            inputPeak = max(inputPeak, max(abs(l), abs(r)))
            dl[i] = delayL[dryIndex]
            dr[i] = delayR[dryIndex]
            delayL[dryIndex] = l
            delayR[dryIndex] = r
            dryIndex += 1
            if dryIndex == latency { dryIndex = 0 }
        }

        rumbleFilter.process(left: left, right: right, count: count)
        cleaner.process(left: left, right: right, count: count)
        bassShelf.process(left: left, right: right, count: count)
        mudCut.process(left: left, right: right, count: count)
        presence.process(left: left, right: right, count: count)
        airShelf.process(left: left, right: right, count: count)
        exciter.process(left: left, right: right, count: count)
        stereo.process(left: left, right: right, count: count)
        leveler.process(left: left, right: right, count: count)

        let target = outputGainTarget
        var gain = outputGain
        if gain != target {
            for i in 0..<count {
                gain = target + (gain - target) * gainSmoothing
                left[i] *= gain
                right[i] *= gain
            }
            if abs(gain - target) < 1e-5 { gain = target }
            outputGain = gain
        } else if gain != 1 {
            for i in 0..<count {
                left[i] *= gain
                right[i] *= gain
            }
        }

        limiter.process(left: left, right: right, count: count)

        let mixTarget: Float = settings.isEnabled ? 1 : 0
        if wetMix != mixTarget || mixTarget == 0 {
            var mix = wetMix
            for i in 0..<count {
                mix = mix < mixTarget ? min(mix + mixStep, mixTarget) : max(mix - mixStep, mixTarget)
                left[i] = dl[i] + (left[i] - dl[i]) * mix
                right[i] = dr[i] + (right[i] - dr[i]) * mix
            }
            wetMix = mix
        }

        var outputPeak = unpublishedOutputPeak
        for i in 0..<count {
            if !left[i].isFinite { left[i] = 0 }
            if !right[i].isFinite { right[i] = 0 }
            outputPeak = max(outputPeak, max(abs(left[i]), abs(right[i])))
        }

        if meterLock.try() {
            sharedMeters.inputPeak = max(sharedMeters.inputPeak, inputPeak)
            sharedMeters.outputPeak = max(sharedMeters.outputPeak, outputPeak)
            sharedMeters.cleanupDB = cleaner.reductionDB
            sharedMeters.levelerDB = leveler.gainDB
            sharedMeters.limiterDB = limiter.reductionDB
            meterLock.unlock()
            unpublishedInputPeak = 0
            unpublishedOutputPeak = 0
        } else {
            unpublishedInputPeak = inputPeak
            unpublishedOutputPeak = outputPeak
        }
    }

    private func apply(_ s: EnhancerSettings) {
        settings = s
        let rate = sampleRate

        rumbleFilter.coefficients = s.noiseReduction > 0 || s.bass > 0
            ? .highPass(frequency: 35, q: 0.707, sampleRate: rate)
            : .identity
        cleaner.noiseAmount = s.noiseReduction
        cleaner.reverbAmount = s.dereverb
        bassShelf.coefficients = .lowShelf(frequency: 110, q: 0.7, gainDB: Double(7 * s.bass), sampleRate: rate)
        mudCut.coefficients = .peaking(frequency: 300, q: 1.0, gainDB: Double(-5 * s.dialogue), sampleRate: rate)
        presence.coefficients = .peaking(frequency: 2800, q: 0.9, gainDB: Double(6 * s.dialogue), sampleRate: rate)
        airShelf.coefficients = .highShelf(frequency: 8000, q: 0.7, gainDB: Double(3 * s.clarity), sampleRate: rate)
        exciter.amount = s.clarity
        stereo.width = s.width
        stereo.dialogue = s.dialogue
        leveler.amount = s.leveling
        outputGainTarget = decibelsToGain(s.boostDB)
    }
}

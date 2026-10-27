#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Stereo-linked leveler: brings quiet dialogue up and loud scenes down so you stop
/// riding the volume knob. A compressor with automatic makeup gain, plus an expander
/// underneath so the background between lines isn't pulled up with the voices.
///
/// The expander's threshold follows the program level (roughly "how loud the dialogue
/// is right now") instead of sitting at a fixed level. Recordings vary wildly in level,
/// and after noise removal the gaps between lines can be anywhere from -70 to -40 dBFS.
final class Leveler {
    /// 0...1
    var amount: Float = 0 {
        didSet { if amount != oldValue { configure() } }
    }
    /// Current gain applied, in dB.
    private(set) var gainDB: Float = 0

    private let detectorCoefficient: Double
    private let attackCoefficient: Double
    private let releaseCoefficient: Double
    private let programRise: Double
    private let programFall: Double
    private var envelope = 0.0
    private var smoothedGainDB = 0.0
    private var programDB = -30.0

    private var threshold = 0.0
    private var slope = 0.0
    private var makeup = 0.0
    private let knee = 10.0
    /// The expander starts this far below the program level...
    private let gateRange = 18.0
    /// ...and below it, every dB quieter takes this many dB of the lift back (1:3).
    private let expansion = 2.0
    private let lowestGate = -65.0

    init(sampleRate: Double) {
        detectorCoefficient = smoothingCoefficient(seconds: 0.03, sampleRate: sampleRate)
        attackCoefficient = smoothingCoefficient(seconds: 0.015, sampleRate: sampleRate)
        releaseCoefficient = smoothingCoefficient(seconds: 0.35, sampleRate: sampleRate)
        programRise = smoothingCoefficient(seconds: 0.4, sampleRate: sampleRate)
        programFall = smoothingCoefficient(seconds: 6, sampleRate: sampleRate)
        configure()
    }

    private func configure() {
        let a = Double(min(max(amount, 0), 1))
        threshold = -20 - 18 * a
        let ratio = 1 + 4 * a
        slope = 1 / ratio - 1
        // Keep a typical full-scale-ish movie level (-16 dBFS RMS) where it was, so
        // turning leveling up lifts the quiet parts instead of only squashing the loud ones.
        makeup = a > 0 ? -0.9 * compressionDB(at: -16) : 0
    }

    private func compressionDB(at levelDB: Double) -> Double {
        let over = levelDB - threshold
        if over <= -knee / 2 { return 0 }
        if over < knee / 2 {
            let x = over + knee / 2
            return slope * x * x / (2 * knee)
        }
        return slope * over
    }

    private func targetGainDB(at levelDB: Double, gate: Double) -> Double {
        var gain = compressionDB(at: levelDB) + makeup
        if levelDB < gate {
            // Hand the makeup back below the gate so pauses stay quiet.
            gain += max(expansion * (levelDB - gate), -makeup)
        }
        return gain
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard amount > 0 || abs(smoothedGainDB) > 0.01 else {
            gainDB = 0
            return
        }
        let detector = detectorCoefficient
        let attack = attackCoefficient
        let release = releaseCoefficient
        var env = envelope
        var current = smoothedGainDB
        var program = programDB
        let enabled = amount > 0
        for i in 0..<count {
            let l = Double(left[i])
            let r = Double(right[i])
            env = env * detector + 0.5 * (l * l + r * r) * (1 - detector)
            env = max(env, 1e-12)
            let levelDB = 10 * log10(env)
            program = levelDB + (program - levelDB) * (levelDB > program ? programRise : programFall)
            let gate = max(program - gateRange, lowestGate)
            let target = enabled ? targetGainDB(at: levelDB, gate: gate) : 0
            let coefficient = target < current ? attack : release
            current = target + (current - target) * coefficient
            let gain = Float(pow(10, current / 20))
            left[i] *= gain
            right[i] *= gain
        }
        envelope = env
        programDB = program
        smoothedGainDB = current
        gainDB = Float(current)
    }
}

/// Brick-wall look-ahead peak limiter. Lets "Boost" push things loud without ever
/// clipping. Linked stereo, ~1.5 ms look-ahead, smooth gain ramps so it doesn't crackle.
final class Limiter {
    let lookahead: Int
    var ceiling: Float = decibelsToGain(-1)
    /// Deepest gain reduction in the last block, in dB (0 or negative).
    private(set) var reductionDB: Float = 0

    private let delayLeft: FloatStorage
    private let delayRight: FloatStorage
    private let requests: FloatStorage
    private let box: FloatStorage
    private var boxSum: Double
    private var delayIndex = 0
    private var requestIndex = 0
    private var releaseGain: Float = 1
    private let releaseCoefficient: Float

    init(sampleRate: Double) {
        lookahead = max(1, Int((0.0015 * sampleRate).rounded()))
        delayLeft = FloatStorage(count: lookahead)
        delayRight = FloatStorage(count: lookahead)
        // The hold window is one longer than the ramp so every peak is fully covered.
        requests = FloatStorage(count: lookahead + 1, value: 1)
        box = FloatStorage(count: lookahead, value: 1)
        boxSum = Double(lookahead)
        releaseCoefficient = Float(smoothingCoefficient(seconds: 0.08, sampleRate: sampleRate))
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let delayL = delayLeft.pointer
        let delayR = delayRight.pointer
        let req = requests.pointer
        let ramp = box.pointer
        let holdLength = lookahead + 1
        let ceiling = self.ceiling
        let inverseLength = 1 / Double(lookahead)
        var minimumGain: Float = 1

        for i in 0..<count {
            let l = left[i]
            let r = right[i]
            let peak = max(abs(l), abs(r))
            req[requestIndex] = peak > ceiling ? ceiling / peak : 1
            requestIndex += 1
            if requestIndex == holdLength { requestIndex = 0 }

            var held: Float = 1
            for j in 0..<holdLength { held = min(held, req[j]) }

            if held < releaseGain {
                releaseGain = held
            } else {
                releaseGain = held + (releaseGain - held) * releaseCoefficient
            }

            boxSum += Double(releaseGain - ramp[delayIndex])
            ramp[delayIndex] = releaseGain
            let gain = Float(boxSum * inverseLength)

            let delayedL = delayL[delayIndex]
            let delayedR = delayR[delayIndex]
            delayL[delayIndex] = l
            delayR[delayIndex] = r
            delayIndex += 1
            if delayIndex == lookahead { delayIndex = 0 }

            left[i] = min(max(delayedL * gain, -ceiling), ceiling)
            right[i] = min(max(delayedR * gain, -ceiling), ceiling)
            minimumGain = min(minimumGain, gain)
        }
        reductionDB = gainToDecibels(minimumGain)
    }
}

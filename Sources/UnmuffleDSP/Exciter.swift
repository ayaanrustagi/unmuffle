#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Harmonic exciter. Phone and camcorder mics plus low-bitrate encoding throw away the
/// top octaves, which is a big part of why cam audio sounds muffled. This regenerates
/// plausible high harmonics from the upper mids and mixes them back in.
///
/// The saturator runs on the signal divided by its own envelope, so it adds the same
/// amount of "sparkle" whether the scene is quiet or loud.
final class Exciter {
    /// 0...1
    var amount: Float = 0

    private var bandFilter: StereoBiquad
    private var harmonicFilter: StereoBiquad
    private let scratchLeft: FloatStorage
    private let scratchRight: FloatStorage
    private var envelopeLeft: Float = 0
    private var envelopeRight: Float = 0
    private let attack: Float
    private let release: Float

    init(sampleRate: Double, maximumBlockSize: Int) {
        bandFilter = StereoBiquad(.highPass(frequency: 3000, q: 0.707, sampleRate: sampleRate))
        harmonicFilter = StereoBiquad(.highPass(frequency: 5500, q: 0.707, sampleRate: sampleRate))
        scratchLeft = FloatStorage(count: maximumBlockSize)
        scratchRight = FloatStorage(count: maximumBlockSize)
        attack = Float(smoothingCoefficient(seconds: 0.0005, sampleRate: sampleRate))
        release = Float(smoothingCoefficient(seconds: 0.03, sampleRate: sampleRate))
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard amount > 0 else { return }
        let sl = scratchLeft.pointer
        let sr = scratchRight.pointer
        sl.update(from: left, count: count)
        sr.update(from: right, count: count)

        bandFilter.process(left: sl, right: sr, count: count)
        for i in 0..<count {
            sl[i] = saturate(sl[i], envelope: &envelopeLeft)
            sr[i] = saturate(sr[i], envelope: &envelopeRight)
        }
        harmonicFilter.process(left: sl, right: sr, count: count)

        let mix = 0.4 * amount
        for i in 0..<count {
            left[i] += mix * sl[i]
            right[i] += mix * sr[i]
        }
        if envelopeLeft < 1e-9 { envelopeLeft = 0 }
        if envelopeRight < 1e-9 { envelopeRight = 0 }
    }

    @inline(__always)
    private func saturate(_ x: Float, envelope: inout Float) -> Float {
        let magnitude = abs(x)
        let coefficient = magnitude > envelope ? attack : release
        envelope = magnitude + (envelope - magnitude) * coefficient
        let e = envelope + 1e-6
        let u = x / e
        // tanh adds odd harmonics, the squared term adds even ones (its DC is filtered out).
        return e * (tanhf(2.5 * u) + 0.2 * u * u)
    }
}

/// Mid/side stage.
/// - Dialogue lives in the center, while room echo and the audience spread to the sides,
///   so pulling the sides down a little focuses the voices.
/// - Width spreads the sides back out, and for the many recordings that are basically
///   mono it synthesizes stereo with complementary comb filters. Those cancel when L and R
///   are summed, so the result stays mono compatible and the center stays put.
final class StereoStage {
    /// 0...1
    var width: Float = 0
    /// 0...1
    var dialogue: Float = 0

    private let delay: FloatStorage
    private var delayIndex = 0
    private var bassBlock: BiquadState
    private let bassBlockCoefficients: BiquadCoefficients

    init(sampleRate: Double) {
        delay = FloatStorage(count: max(1, Int(0.013 * sampleRate)))
        bassBlock = BiquadState()
        bassBlockCoefficients = .highPass(frequency: 300, q: 0.707, sampleRate: sampleRate)
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let sideGain = (1 + 0.6 * width) * (1 - 0.35 * dialogue)
        let pseudo = 0.3 * width
        guard sideGain != 1 || pseudo > 0 else { return }

        let d = delay.pointer
        let length = delay.count
        let c = bassBlockCoefficients
        var state = bassBlock
        for i in 0..<count {
            let mid = 0.5 * (left[i] + right[i])
            var side = 0.5 * (left[i] - right[i]) * sideGain
            if pseudo > 0 {
                // Keep the bass mono; comb-filtered bass sounds hollow.
                let highMid = Float(state.process(Double(mid), c))
                side += pseudo * d[delayIndex]
                d[delayIndex] = highMid
                delayIndex += 1
                if delayIndex == length { delayIndex = 0 }
            }
            left[i] = mid + side
            right[i] = mid - side
        }
        state.flushDenormals()
        bassBlock = state
    }
}

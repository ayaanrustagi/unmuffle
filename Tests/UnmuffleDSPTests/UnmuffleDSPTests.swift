import Foundation
import XCTest
@testable import UnmuffleDSP

/// Deterministic Gaussian white noise so tests don't flake (SplitMix64 + Box-Muller).
struct SeededNoise {
    private var state: UInt64
    private var spare: Float?

    init(seed: UInt64) { state = seed }

    private mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }

    /// Unit variance.
    mutating func next() -> Float {
        if let value = spare {
            spare = nil
            return value
        }
        let radius = (-2 * log(uniform())).squareRoot()
        let angle = 2 * Double.pi * uniform()
        spare = Float(radius * sin(angle))
        return Float(radius * cos(angle))
    }
}

func power(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
}

func decibels(_ power: Float) -> Float { 10 * log10f(max(power, 1e-20)) }

/// Runs a stereo signal through the enhancer in chunks of a realistic size.
func enhance(_ enhancer: Enhancer, left: [Float], right: [Float], chunk: Int = 512) -> (left: [Float], right: [Float]) {
    var l = left
    var r = right
    l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            var offset = 0
            while offset < lp.count {
                let n = min(chunk, lp.count - offset)
                enhancer.process(left: lp.baseAddress! + offset, right: rp.baseAddress! + offset, frameCount: n)
                offset += n
            }
        }
    }
    return (l, r)
}

final class FFTTests: XCTestCase {
    func testRoundTrip() {
        let fft = FFT(size: 1024)
        var noise = SeededNoise(seed: 1)
        let original = (0..<1024).map { _ in noise.next() }
        var re = original
        var im = [Float](repeating: 0, count: 1024)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                fft.forward(real: r.baseAddress!, imag: i.baseAddress!)
                fft.inverse(real: r.baseAddress!, imag: i.baseAddress!)
            }
        }
        for k in 0..<1024 {
            XCTAssertEqual(re[k], original[k], accuracy: 1e-4)
            XCTAssertEqual(im[k], 0, accuracy: 1e-4)
        }
    }

    func testSinePeaksAtItsBin() {
        let n = 1024
        let fft = FFT(size: n)
        var re = (0..<n).map { Float(cos(2 * Double.pi * 37 * Double($0) / Double(n))) }
        var im = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                fft.forward(real: r.baseAddress!, imag: i.baseAddress!)
            }
        }
        let magnitudes = (0..<n / 2).map { re[$0] * re[$0] + im[$0] * im[$0] }
        XCTAssertEqual(magnitudes.firstIndex(of: magnitudes.max()!), 37)
        XCTAssertEqual(magnitudes[37].squareRoot(), Float(n) / 2, accuracy: 0.01)
    }
}

final class EnhancerTests: XCTestCase {
    let sampleRate = 48_000.0

    func testNeutralSettingsAreTransparent() {
        let enhancer = Enhancer(sampleRate: sampleRate, settings: .neutral)
        var noise = SeededNoise(seed: 2)
        let left = (0..<48_000).map { _ in 0.1 * noise.next() }
        let right = (0..<48_000).map { _ in 0.1 * noise.next() }
        let out = enhance(enhancer, left: left, right: right)
        let latency = enhancer.latency
        var worst: Float = 0
        for i in latency..<left.count {
            worst = max(worst, abs(out.left[i] - left[i - latency]), abs(out.right[i] - right[i - latency]))
        }
        XCTAssertLessThan(worst, 1e-4)
    }

    func testBypassIsDelayedOriginal() {
        var settings = EnhancerSettings.default
        settings.isEnabled = false
        let enhancer = Enhancer(sampleRate: sampleRate, settings: settings)
        var noise = SeededNoise(seed: 3)
        let left = (0..<24_000).map { _ in 0.3 * noise.next() }
        let right = (0..<24_000).map { _ in 0.3 * noise.next() }
        let out = enhance(enhancer, left: left, right: right)
        for i in enhancer.latency..<left.count {
            XCTAssertEqual(out.left[i], left[i - enhancer.latency])
            XCTAssertEqual(out.right[i], right[i - enhancer.latency])
        }
    }

    func testNoiseReductionKeepsBurstsAndRemovesHiss() {
        // Speech-like: 1 kHz bursts (250 ms on, 250 ms off) over steady hiss.
        var settings = EnhancerSettings.neutral
        settings.noiseReduction = 0.8
        let enhancer = Enhancer(sampleRate: sampleRate, settings: settings)
        let seconds = 8
        let n = Int(sampleRate) * seconds
        let segment = Int(sampleRate) / 4
        var noise = SeededNoise(seed: 4)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let on = (i / segment) % 2 == 0
            let tone: Float = on ? 0.1 * Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate)) : 0
            left[i] = tone + 0.003 * noise.next()
            right[i] = tone + 0.003 * noise.next()
        }
        let out = enhance(enhancer, left: left, right: right)
        let latency = enhancer.latency

        // Measure the last 4 seconds, after the noise estimate has settled. Skip the edges
        // of each segment where the STFT smears on/off transitions.
        var inOn: Float = 0, outOn: Float = 0, inOff: Float = 0, outOff: Float = 0
        for s in (n / segment / 2)..<(n / segment - 1) {
            let start = s * segment + segment / 5
            let end = (s + 1) * segment - segment / 5
            let input = power(left[start..<end])
            let output = power(out.left[(start + latency)..<(end + latency)])
            if s % 2 == 0 { inOn += input; outOn += output } else { inOff += input; outOff += output }
        }
        let hissReduction = decibels(outOff) - decibels(inOff)
        let toneChange = decibels(outOn) - decibels(inOn)
        XCTAssertLessThan(hissReduction, -12, "hiss should drop by at least 10 dB")
        XCTAssertGreaterThan(toneChange, -1, "the tone should survive almost untouched")
    }

    func testDereverbShortensDecay() {
        // A click train through an exponentially decaying "room".
        let rate = sampleRate
        let n = Int(rate) * 4
        var noise = SeededNoise(seed: 5)
        var dry = [Float](repeating: 0, count: n)
        let period = Int(rate * 0.5)
        for i in stride(from: 0, to: n, by: period) {
            for j in 0..<min(480, n - i) { dry[i + j] = 0.3 * noise.next() }
        }
        // Reverb: dry + noise tail with RT60 of 0.9 s.
        var wet = dry
        let tailLength = Int(rate * 0.45)
        let decay = Float(exp(-6.9 / (0.9 * rate)))
        var tail = [Float](repeating: 0, count: tailLength)
        var g: Float = 0.08
        for j in 0..<tailLength { tail[j] = g * noise.next(); g *= decay }
        for i in stride(from: 0, to: n, by: period) {
            for j in 0..<tailLength where i + 480 + j < n {
                wet[i + 480 + j] += tail[j]
            }
        }

        func tailEnergy(_ settings: EnhancerSettings) -> Float {
            let enhancer = Enhancer(sampleRate: rate, settings: settings)
            let out = enhance(enhancer, left: wet, right: wet).left
            let latency = enhancer.latency
            var energy: Float = 0
            for i in stride(from: period * 4, to: n - period, by: period) {
                let start = i + 480 + Int(rate * 0.1) + latency
                energy += power(out[start..<(start + Int(rate * 0.25))])
            }
            return energy
        }

        var settings = EnhancerSettings.neutral
        let before = tailEnergy(settings)
        settings.dereverb = 1
        let after = tailEnergy(settings)
        XCTAssertLessThan(decibels(after) - decibels(before), -6)
    }

    func testMonoAndStereoHissAreBothReduced() {
        var noise = SeededNoise(seed: 7)
        let n = Int(sampleRate) * 4
        let left = (0..<n).map { _ in 0.01 * noise.next() }
        let right = (0..<n).map { _ in 0.01 * noise.next() }
        var settings = EnhancerSettings.neutral
        settings.noiseReduction = 0.7
        for (name, other) in [("stereo", right), ("mono", left)] {
            let out = enhance(Enhancer(sampleRate: sampleRate, settings: settings), left: left, right: other).left
            // Measured from 1 s in: the noise floor estimate needs a moment after start.
            let change = decibels(power(out[Int(sampleRate)...])) - decibels(power(left[Int(sampleRate)...]))
            XCTAssertLessThan(change, -12, name)
        }
    }

    /// Minimum statistics alone would mistake a long held chord for background noise.
    func testHeldChordSurvivesCleanup() {
        let n = Int(sampleRate) * 8
        var noise = SeededNoise(seed: 8)
        let input = (0..<n).map { i -> Float in
            let t = Double(i) / sampleRate
            let chord = sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t)
            return Float(0.05 * chord) + 0.003 * noise.next()
        }
        func change(_ settings: EnhancerSettings) -> Float {
            let enhancer = Enhancer(sampleRate: sampleRate, settings: settings)
            let out = enhance(enhancer, left: input, right: input).left
            let start = Int(sampleRate)
            return decibels(power(out[(start + enhancer.latency)...])) - decibels(power(input[start..<(n - enhancer.latency)]))
        }
        var settings = EnhancerSettings.neutral
        settings.noiseReduction = 1
        XCTAssertGreaterThan(change(settings), -1, "noise removal")
        settings = .neutral
        settings.dereverb = 0.6
        XCTAssertGreaterThan(change(settings), -4, "echo removal")
    }

    func testLevelerLiftsQuietDialogueButNotPauses() {
        // Quiet "lines" (-40 dBFS) alternating with pauses that hold only faint noise.
        var settings = EnhancerSettings.neutral
        settings.leveling = 0.7
        let enhancer = Enhancer(sampleRate: sampleRate, settings: settings)
        let n = Int(sampleRate) * 10
        let segment = Int(sampleRate)
        var noise = SeededNoise(seed: 11)
        let input = (0..<n).map { i -> Float in
            let on = (i / segment) % 2 == 0
            let line: Float = on ? 0.014 * Float(sin(2 * Double.pi * 300 * Double(i) / sampleRate)) : 0
            return line + 0.0002 * noise.next()
        }
        let out = enhance(enhancer, left: input, right: input).left
        var lineGain: Float = 0, pauseGain: Float = 0
        for s in 4..<9 {
            let start = s * segment + segment / 2
            let end = (s + 1) * segment - enhancer.latency
            let change = decibels(power(out[(start + enhancer.latency)..<(end + enhancer.latency)])) - decibels(power(input[start..<end]))
            if s % 2 == 0 { lineGain = max(lineGain, change) } else { pauseGain = max(pauseGain, change) }
        }
        XCTAssertGreaterThan(lineGain, 8, "quiet lines should come up")
        XCTAssertLessThan(pauseGain, 3, "the background between lines should not")
    }

    func testLimiterHoldsCeilingWithMaxBoost() {
        let enhancer = Enhancer(sampleRate: sampleRate, settings: Preset.maximum.settings)
        let n = Int(sampleRate) * 2
        let left = (0..<n).map { 2.5 * Float(sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        let right = (0..<n).map { 2.0 * Float(sin(2 * Double.pi * 330 * Double($0) / 48_000)) }
        let out = enhance(enhancer, left: left, right: right)
        let ceiling = decibelsToGain(-1)
        XCTAssertLessThanOrEqual(out.left.map(abs).max()!, ceiling + 1e-6)
        XCTAssertLessThanOrEqual(out.right.map(abs).max()!, ceiling + 1e-6)
    }

    func testEveryPresetStaysFiniteOnSilenceAndNoise() {
        for preset in Preset.all {
            for rate in [44_100.0, 48_000.0, 96_000.0] {
                let enhancer = Enhancer(sampleRate: rate, settings: preset.settings)
                var noise = SeededNoise(seed: 6)
                let n = Int(rate)
                var left = [Float](repeating: 0, count: n)
                var right = [Float](repeating: 0, count: n)
                for i in n / 2..<n {
                    left[i] = 0.5 * noise.next()
                    right[i] = 0.5 * noise.next()
                }
                let out = enhance(enhancer, left: left, right: right, chunk: 333)
                XCTAssertTrue(out.left.allSatisfy(\.isFinite), "\(preset.id) @ \(rate)")
                XCTAssertTrue(out.right.allSatisfy(\.isFinite), "\(preset.id) @ \(rate)")
                XCTAssertGreaterThan(power(out.left[(n * 3 / 4)...]), 1e-4, "\(preset.id) @ \(rate) went silent")
            }
        }
    }

    func testMetersReportAndReset() {
        let enhancer = Enhancer(sampleRate: sampleRate, settings: .default)
        let left = [Float](repeating: 0.5, count: 4096)
        _ = enhance(enhancer, left: left, right: left)
        XCTAssertEqual(enhancer.readMeters().inputPeak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(enhancer.readMeters().inputPeak, 0)
    }

    func testSpectrumShowsToneAndRemovedNoise() {
        var settings = EnhancerSettings.neutral
        settings.noiseReduction = 0.8
        let enhancer = Enhancer(sampleRate: sampleRate, settings: settings)
        var noise = SeededNoise(seed: 12)
        // 12.5 segments of 12,000 samples: ends halfway through a tone segment.
        let n = 12_000 * 12 + 6_000
        let input = (0..<n).map { i -> Float in
            let on = (i / 12_000) % 2 == 0
            return (on ? 0.25 * Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate)) : 0) + 0.003 * noise.next()
        }
        _ = enhance(enhancer, left: input, right: input)
        let spectrum = enhancer.readSpectrum()
        XCTAssertEqual(spectrum.input.count, EnhancerSpectrum.bandCount)
        // The last block was a tone segment: the loudest band sits near 1 kHz.
        let loudest = spectrum.input.indices.max { spectrum.input[$0] < spectrum.input[$1] }!
        let lowEdge = 50 * pow(16_000 / 50, Float(loudest) / Float(EnhancerSpectrum.bandCount))
        let highEdge = 50 * pow(16_000 / 50, Float(loudest + 1) / Float(EnhancerSpectrum.bandCount))
        XCTAssertTrue(lowEdge <= 1100 && highEdge >= 900, "loudest band \(lowEdge)-\(highEdge) Hz")
        // Hiss-only bands at the top come out quieter than they went in.
        XCTAssertLessThan(spectrum.output[30], spectrum.input[30] - 6)
    }

    func testSettingsUpdateIsPickedUp() {
        let enhancer = Enhancer(sampleRate: sampleRate, settings: .neutral)
        var loud = EnhancerSettings.neutral
        loud.boostDB = 12
        enhancer.update(loud)
        let n = 48_000
        let left = (0..<n).map { 0.05 * Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let out = enhance(enhancer, left: left, right: left)
        let gain = decibels(power(out.left[(n / 2)...])) - decibels(power(left[(n / 2)...]))
        XCTAssertEqual(gain, 12, accuracy: 0.2)
    }
}

final class SettingsTests: XCTestCase {
    func testPresetsAreInRangeAndUnique() {
        XCTAssertEqual(Set(Preset.all.map(\.id)).count, Preset.all.count)
        for preset in Preset.all {
            XCTAssertEqual(preset.settings, preset.settings.clamped, preset.id)
            XCTAssertEqual(Preset.matching(preset.settings), preset)
        }
    }

    func testClampingRejectsGarbage() {
        var settings = EnhancerSettings.neutral
        settings.noiseReduction = .nan
        settings.width = 7
        settings.boostDB = -40
        let clamped = settings.clamped
        XCTAssertEqual(clamped.noiseReduction, 0)
        XCTAssertEqual(clamped.width, 1)
        XCTAssertEqual(clamped.boostDB, 0)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(Preset.night.settings)
        XCTAssertEqual(try JSONDecoder().decode(EnhancerSettings.self, from: data), Preset.night.settings)
    }
}

final class WAVTests: XCTestCase {
    func testRoundTripFloatAndInt16() throws {
        let samples: [Float] = [0, 0.25, -0.5, 0.999, -1]
        let file = WAVFile(sampleRate: 44_100, channels: [samples, samples.map { -$0 }])

        let float = try WAVFile.parse(file.encode(format: .float32))
        XCTAssertEqual(float.sampleRate, 44_100)
        XCTAssertEqual(float.channels, file.channels)

        let int16 = try WAVFile.parse(file.encode(format: .int16))
        for (a, b) in zip(int16.channels[0], samples) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 16_000)
        }
    }

    func testRejectsNonWAV() {
        XCTAssertThrowsError(try WAVFile.parse(Data("hello world, not audio".utf8)))
    }
}

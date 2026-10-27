#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Real-time stereo noise and late-reverb ("echo") suppressor.
///
/// Short-time Fourier transform with 75% overlap. Both channels share one complex FFT
/// (left in the real part, right in the imaginary part) and one real gain per bin.
/// Because the gain is real and symmetric it scales both channels identically, so the
/// stereo image is untouched and stereo costs the same as mono.
///
/// - Noise: per-bin minimum of the smoothed power over the last ~5 s (minimum
///   statistics). Hiss, air conditioning and crowd murmur sit at that floor. A held
///   musical note also sits at its own minimum, so two checks keep music safe: the floor
///   is taken from the quietest nearby frequencies (noise is smooth across frequency,
///   notes are peaky), and bins whose level barely fluctuates (random noise dips well
///   below its average, a steady tone doesn't) are left alone.
/// - Echo: the statistical late-reverb model from Lebart et al. (2001). The reverb tail
///   at time t is predicted as a decayed copy of the power ~50 ms earlier, which is what
///   a big room adds to a recording made from the seats.
/// - Gains: a decision-directed Wiener gain for noise (Ephraim & Malah), which keeps
///   leftover hiss from twinkling ("musical noise"), times a spectral-subtraction gain
///   for echo, which doesn't collapse on held notes the way a decision-directed gain
///   would. Smoothed across frequency and clamped to a floor so the result never sounds
///   hollow or "underwater".
final class SpectralCleaner {
    let fftSize: Int
    let hopSize: Int
    var latency: Int { fftSize }

    /// 0...1
    var noiseAmount: Float = 0
    /// 0...1
    var reverbAmount: Float = 0
    /// How much energy the last frame removed, in dB (0 or negative).
    private(set) var reductionDB: Float = 0

    private let fft: FFT
    private let bins: Int
    private let window: FloatStorage
    private let overlapScale: Float

    private let inputLeft: FloatStorage
    private let inputRight: FloatStorage
    private let outputLeft: FloatStorage
    private let outputRight: FloatStorage
    private let readyLeft: FloatStorage
    private let readyRight: FloatStorage
    private let real: FloatStorage
    private let imag: FloatStorage
    private var position = 0

    private let framePower: FloatStorage
    private let fastPower: FloatStorage
    private let slowPower: FloatStorage
    private let longPower: FloatStorage
    private let previousClean: FloatStorage
    private let noiseFloor: FloatStorage
    private let lateReverb: FloatStorage
    private let rawGain: FloatStorage
    private let gain: FloatStorage
    private var primed = false
    private var framesSeen = 0
    private let warmupFrames: Int
    private let settleFrames: Int

    private let minimumWindowCount = 10
    private let minimumWindowFrames: Int
    private let currentMinimum: FloatStorage
    private let windowMinima: FloatStorage
    private var framesInMinimumWindow = 0
    private var minimumWindowIndex = 0

    private let reverbDelayFrames: Int
    private let reverbDecay: Float
    private let history: FloatStorage
    private var historyIndex = 0

    private let fastSmoothing: Float
    private let slowSmoothing: Float
    private let longSmoothing: Float
    private let prioriSmoothing: Float = 0.97
    /// The lowest point of the smoothed noise power sits at about 0.44 (mono) to 0.55
    /// (uncorrelated stereo) of its mean, measured on white noise. Scale it back up,
    /// erring toward mono since that's what most rough recordings are.
    private let noiseBias: Float = 2.3
    /// Bins on each side searched for the noise floor (about +-140 Hz at 48 kHz).
    private let neighbourhoodRadius = 3

    init(sampleRate: Double) {
        fftSize = sampleRate > 64_000 ? 2048 : 1024
        hopSize = fftSize / 4
        bins = fftSize / 2 + 1
        fft = FFT(size: fftSize)

        // sqrt-Hann for analysis and synthesis: their product is a Hann window, which
        // overlap-adds to a constant at 75% overlap.
        window = FloatStorage(count: fftSize)
        for i in 0..<fftSize {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(fftSize))
            window[i] = Float(hann.squareRoot())
        }
        var overlapSum: Float = 0
        var i = 0
        while i < fftSize {
            overlapSum += window[i] * window[i]
            i += hopSize
        }
        overlapScale = 1 / overlapSum

        inputLeft = FloatStorage(count: fftSize)
        inputRight = FloatStorage(count: fftSize)
        outputLeft = FloatStorage(count: fftSize)
        outputRight = FloatStorage(count: fftSize)
        readyLeft = FloatStorage(count: hopSize)
        readyRight = FloatStorage(count: hopSize)
        real = FloatStorage(count: fftSize)
        imag = FloatStorage(count: fftSize)

        framePower = FloatStorage(count: bins)
        fastPower = FloatStorage(count: bins)
        slowPower = FloatStorage(count: bins)
        longPower = FloatStorage(count: bins)
        previousClean = FloatStorage(count: bins)
        noiseFloor = FloatStorage(count: bins)
        lateReverb = FloatStorage(count: bins)
        warmupFrames = fftSize / hopSize
        rawGain = FloatStorage(count: bins, value: 1)
        gain = FloatStorage(count: bins, value: 1)

        // Time constants are defined in seconds so behaviour doesn't change with sample rate.
        let hopSeconds = Double(hopSize) / sampleRate
        func perFrame(_ seconds: Double) -> Float { Float(exp(-hopSeconds / seconds)) }
        fastSmoothing = perFrame(0.01)
        slowSmoothing = perFrame(0.1)
        longSmoothing = perFrame(1.0)
        settleFrames = max(1, Int((0.25 / hopSeconds).rounded()))

        minimumWindowFrames = max(1, Int((0.5 / hopSeconds).rounded()))
        currentMinimum = FloatStorage(count: bins, value: .greatestFiniteMagnitude)
        windowMinima = FloatStorage(count: bins * minimumWindowCount, value: .greatestFiniteMagnitude)

        // Late reverb starts ~50 ms after the direct sound. Assume a large room (RT60 0.8 s).
        reverbDelayFrames = max(1, Int((0.05 / hopSeconds).rounded()))
        let rt60 = 0.8
        let decayRate = 3 * log(10.0) / rt60
        reverbDecay = Float(exp(-2 * decayRate * Double(reverbDelayFrames) * hopSeconds))
        history = FloatStorage(count: bins * reverbDelayFrames)
    }

    /// Processes audio in place. Output is delayed by `latency` samples.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let inL = inputLeft.pointer
        let inR = inputRight.pointer
        let readyL = readyLeft.pointer
        let readyR = readyRight.pointer
        let writeBase = fftSize - hopSize
        for i in 0..<count {
            inL[writeBase + position] = left[i]
            inR[writeBase + position] = right[i]
            left[i] = readyL[position]
            right[i] = readyR[position]
            position += 1
            if position == hopSize {
                processFrame()
                position = 0
            }
        }
    }

    private func processFrame() {
        let n = fftSize
        let h = hopSize
        let re = real.pointer
        let im = imag.pointer
        let w = window.pointer
        let inL = inputLeft.pointer
        let inR = inputRight.pointer

        for i in 0..<n {
            re[i] = inL[i] * w[i]
            im[i] = inR[i] * w[i]
        }
        for i in 0..<(n - h) {
            inL[i] = inL[i + h]
            inR[i] = inR[i + h]
        }

        fft.forward(real: re, imag: im)
        let active = computeGains()
        if active {
            let g = gain.pointer
            for k in 0..<bins {
                let mirror = (n - k) & (n - 1)
                re[k] *= g[k]
                im[k] *= g[k]
                if mirror != k {
                    re[mirror] *= g[k]
                    im[mirror] *= g[k]
                }
            }
        }
        fft.inverse(real: re, imag: im)

        let outL = outputLeft.pointer
        let outR = outputRight.pointer
        for i in 0..<n {
            let ws = w[i] * overlapScale
            outL[i] += re[i] * ws
            outR[i] += im[i] * ws
        }
        let readyL = readyLeft.pointer
        let readyR = readyRight.pointer
        for i in 0..<h {
            readyL[i] = outL[i]
            readyR[i] = outR[i]
        }
        for i in 0..<(n - h) {
            outL[i] = outL[i + h]
            outR[i] = outR[i + h]
        }
        for i in (n - h)..<n {
            outL[i] = 0
            outR[i] = 0
        }
    }

    /// Updates the noise and reverb estimates and fills `gain`. Returns false when no
    /// suppression is requested (all gains are 1).
    private func computeGains() -> Bool {
        let n = fftSize
        let re = real.pointer
        let im = imag.pointer
        let power = framePower.pointer
        let fast = fastPower.pointer
        let slow = slowPower.pointer
        let long = longPower.pointer
        let currentMin = currentMinimum.pointer
        let minima = windowMinima.pointer
        let floorEstimate = noiseFloor.pointer
        let hist = history.pointer
        let late = lateReverb.pointer
        let clean = previousClean.pointer
        let raw = rawGain.pointer
        let g = gain.pointer

        for k in 0..<bins {
            // (|Z_k|^2 + |Z_-k|^2) / 4 == (|L_k|^2 + |R_k|^2) / 2
            let mirror = (n - k) & (n - 1)
            power[k] = 0.25 * (re[k] * re[k] + im[k] * im[k] + re[mirror] * re[mirror] + im[mirror] * im[mirror]) + 1e-20
        }

        // The first few frames still contain the zeros the buffers started with. Keep them
        // out of the statistics, or the noise floor reads as near-silence for seconds.
        let settling = framesSeen < warmupFrames + settleFrames
        if settling { framesSeen += 1 }
        guard framesSeen > warmupFrames else {
            for k in 0..<bins {
                g[k] = 1
                clean[k] = power[k]
            }
            reductionDB = 0
            return false
        }

        // Then give the averages a moment to settle before tracking the floor. A single
        // frame of noise can land far below its mean, and a minimum seeded from it would
        // stick around for the whole tracking window.
        let longCoefficient = settling ? slowSmoothing : longSmoothing
        let historyBase = historyIndex * bins
        for k in 0..<bins {
            let p = power[k]
            if primed {
                fast[k] = fast[k] * fastSmoothing + p * (1 - fastSmoothing)
                slow[k] = slow[k] * slowSmoothing + p * (1 - slowSmoothing)
                long[k] = long[k] * longCoefficient + p * (1 - longCoefficient)
            } else {
                fast[k] = p
                slow[k] = p
                long[k] = p
            }

            if !settling {
                currentMin[k] = min(currentMin[k], slow[k])
            }
            var lowest = currentMin[k]
            for slot in 0..<minimumWindowCount {
                lowest = min(lowest, minima[slot * bins + k])
            }
            floorEstimate[k] = lowest

            late[k] = hist[historyBase + k] * reverbDecay
            hist[historyBase + k] = fast[k]
        }
        primed = true
        historyIndex = (historyIndex + 1) % reverbDelayFrames

        if !settling { framesInMinimumWindow += 1 }
        if framesInMinimumWindow >= minimumWindowFrames {
            let base = minimumWindowIndex * bins
            for k in 0..<bins {
                minima[base + k] = currentMin[k]
                currentMin[k] = .greatestFiniteMagnitude
            }
            minimumWindowIndex = (minimumWindowIndex + 1) % minimumWindowCount
            framesInMinimumWindow = 0
        }

        let noise = min(max(noiseAmount, 0), 1)
        let reverb = min(max(reverbAmount, 0), 1)
        let noiseWeight: Float = noise > 0 ? 1 + noise : 0
        let reverbWeight = 1.6 * reverb
        guard noiseWeight > 0 || reverbWeight > 0 else {
            for k in 0..<bins {
                g[k] = 1
                clean[k] = power[k]
            }
            reductionDB = 0
            return false
        }

        for k in 0..<bins {
            let p = power[k]

            // Background noise is smooth across frequency; notes and voices are peaky.
            // Taking the quietest neighbouring floor keeps a held note (whose own floor
            // is the note itself) from being mistaken for noise.
            var neighbourhood = floorEstimate[k]
            for j in max(k - neighbourhoodRadius, 0)...min(k + neighbourhoodRadius, bins - 1) {
                neighbourhood = min(neighbourhood, floorEstimate[j])
            }

            // Random noise regularly dips to about half its average; a steady sound
            // stays close to its average. Only treat the floor as noise when it looks random.
            let steadiness = floorEstimate[k] / max(long[k], 1e-20)
            let noiseLikeness = min(max((0.92 - steadiness) / 0.15, 0), 1)
            let hasEstimate = neighbourhood < .greatestFiniteMagnitude
            let noiseEstimate = hasEstimate ? noiseWeight * noiseLikeness * noiseBias * neighbourhood : 0

            var noiseGain: Float = 1
            if noiseEstimate > 1e-20 {
                let posteriori = p / noiseEstimate
                let priori = prioriSmoothing * clean[k] / noiseEstimate
                    + (1 - prioriSmoothing) * max(posteriori - 1, 0)
                noiseGain = priori / (1 + priori)
            }
            clean[k] = noiseGain * noiseGain * p

            var echoGain: Float = 1
            if reverbWeight > 0 {
                echoGain = max(1 - reverbWeight * late[k] / fast[k], 0).squareRoot()
            }
            raw[k] = noiseGain * echoGain
        }

        // Smooth across neighbouring bins to avoid "musical noise" and never cut deeper
        // than the floor.
        let floor = decibelsToGain(-(6 + 14 * max(noise, reverb)))
        var total: Float = 0
        var kept: Float = 0
        for k in 0..<bins {
            let below = raw[max(k - 1, 0)]
            let above = raw[min(k + 1, bins - 1)]
            let value = max(0.25 * below + 0.5 * raw[k] + 0.25 * above, floor)
            g[k] = value
            total += power[k]
            kept += value * value * power[k]
        }
        reductionDB = total > 1e-12 ? 10 * log10f(kept / total) : 0
        return true
    }
}

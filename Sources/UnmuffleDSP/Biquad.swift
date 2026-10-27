#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Coefficients for a second-order IIR section, normalized so a0 == 1.
/// Formulas from Robert Bristow-Johnson's Audio EQ Cookbook.
struct BiquadCoefficients: Equatable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Self {
        let (cosw, alpha) = intermediates(frequency, q, sampleRate)
        return normalized(
            b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2,
            a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha
        )
    }

    static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Self {
        let (cosw, alpha) = intermediates(frequency, q, sampleRate)
        return normalized(
            b0: (1 - cosw) / 2, b1: 1 - cosw, b2: (1 - cosw) / 2,
            a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha
        )
    }

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Self {
        guard abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let (cosw, alpha) = intermediates(frequency, q, sampleRate)
        return normalized(
            b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
            a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a
        )
    }

    static func lowShelf(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Self {
        guard abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let (cosw, alpha) = intermediates(frequency, q, sampleRate)
        let k = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) - (a - 1) * cosw + k),
            b1: 2 * a * ((a - 1) - (a + 1) * cosw),
            b2: a * ((a + 1) - (a - 1) * cosw - k),
            a0: (a + 1) + (a - 1) * cosw + k,
            a1: -2 * ((a - 1) + (a + 1) * cosw),
            a2: (a + 1) + (a - 1) * cosw - k
        )
    }

    static func highShelf(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Self {
        guard abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let (cosw, alpha) = intermediates(frequency, q, sampleRate)
        let k = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) + (a - 1) * cosw + k),
            b1: -2 * a * ((a - 1) + (a + 1) * cosw),
            b2: a * ((a + 1) + (a - 1) * cosw - k),
            a0: (a + 1) - (a - 1) * cosw + k,
            a1: 2 * ((a - 1) - (a + 1) * cosw),
            a2: (a + 1) - (a - 1) * cosw - k
        )
    }

    private static func intermediates(_ frequency: Double, _ q: Double, _ sampleRate: Double) -> (cosw: Double, alpha: Double) {
        let clamped = min(max(frequency, 10), sampleRate * 0.45)
        let w0 = 2 * Double.pi * clamped / sampleRate
        return (cos(w0), sin(w0) / (2 * q))
    }

    private static func normalized(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Self {
        BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// Transposed direct form II state. Double precision keeps low-frequency filters stable.
struct BiquadState {
    var z1 = 0.0
    var z2 = 0.0

    @inline(__always)
    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    /// Stops filter tails from decaying into denormals during long silences.
    mutating func flushDenormals() {
        if abs(z1) < 1e-18 { z1 = 0 }
        if abs(z2) < 1e-18 { z2 = 0 }
    }
}

/// The same biquad applied to both channels of a stereo signal.
struct StereoBiquad {
    var coefficients: BiquadCoefficients = .identity
    private var left = BiquadState()
    private var right = BiquadState()

    init(_ coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    mutating func process(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count: Int) {
        let c = coefficients
        guard c != .identity else { return }
        var sl = left
        var sr = right
        for i in 0..<count {
            l[i] = Float(sl.process(Double(l[i]), c))
            r[i] = Float(sr.process(Double(r[i]), c))
        }
        sl.flushDenormals()
        sr.flushDenormals()
        left = sl
        right = sr
    }
}

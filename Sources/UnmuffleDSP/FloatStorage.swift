#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Fixed-size float storage that never reallocates, so it is safe to touch from the
/// real-time audio thread (no copy-on-write, no locks, no allocation).
final class FloatStorage {
    let count: Int
    let pointer: UnsafeMutablePointer<Float>

    init(count: Int, value: Float = 0) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: value, count: max(count, 1))
    }

    deinit {
        pointer.deallocate()
    }

    subscript(index: Int) -> Float {
        @inline(__always) get { pointer[index] }
        @inline(__always) set { pointer[index] = newValue }
    }

    func fill(_ value: Float) {
        pointer.update(repeating: value, count: count)
    }
}

@inline(__always)
func decibelsToGain(_ db: Float) -> Float {
    powf(10, db / 20)
}

@inline(__always)
func gainToDecibels(_ gain: Float) -> Float {
    20 * log10f(max(gain, 1e-9))
}

/// One-pole smoothing coefficient for a time constant, in the form
/// `y += (x - y) * (1 - coefficient)`.
@inline(__always)
func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Double {
    guard seconds > 0 else { return 0 }
    return exp(-1 / (seconds * sampleRate))
}

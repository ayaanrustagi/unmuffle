#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// In-place iterative radix-2 complex FFT on split real/imaginary buffers.
///
/// Plain Swift rather than Accelerate so the DSP core stays portable. At the sizes we
/// use (1024 to 2048 points) it costs well under 1% of a core in real time.
final class FFT {
    let size: Int
    private let cosTable: FloatStorage
    private let sinTable: FloatStorage
    private let bitReversed: UnsafeMutablePointer<Int>

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size

        cosTable = FloatStorage(count: size / 2)
        sinTable = FloatStorage(count: size / 2)
        for k in 0..<size / 2 {
            let angle = 2 * Double.pi * Double(k) / Double(size)
            cosTable[k] = Float(cos(angle))
            sinTable[k] = Float(sin(angle))
        }

        var bits = 0
        while 1 << bits < size { bits += 1 }
        bitReversed = .allocate(capacity: size)
        for i in 0..<size {
            var reversed = 0
            var value = i
            for _ in 0..<bits {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            bitReversed[i] = reversed
        }
    }

    deinit {
        bitReversed.deallocate()
    }

    /// Forward transform, unnormalized.
    func forward(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        transform(real: real, imag: imag, direction: -1)
    }

    /// Inverse transform, normalized by 1/size so `inverse(forward(x)) == x`.
    func inverse(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        transform(real: real, imag: imag, direction: 1)
        let scale = 1 / Float(size)
        for i in 0..<size {
            real[i] *= scale
            imag[i] *= scale
        }
    }

    private func transform(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>, direction: Float) {
        let n = size
        for i in 0..<n {
            let j = bitReversed[i]
            if j > i {
                swap(&real[i], &real[j])
                swap(&imag[i], &imag[j])
            }
        }

        let cosines = cosTable.pointer
        let sines = sinTable.pointer
        var length = 2
        while length <= n {
            let half = length / 2
            let tableStep = n / length
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosines[k * tableStep]
                    let wi = direction * sines[k * tableStep]
                    let a = start + k
                    let b = a + half
                    let vr = real[b] * wr - imag[b] * wi
                    let vi = real[b] * wi + imag[b] * wr
                    real[b] = real[a] - vr
                    imag[b] = imag[a] - vi
                    real[a] += vr
                    imag[a] += vi
                }
                start += length
            }
            length *= 2
        }
    }
}

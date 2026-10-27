import Foundation

/// Minimal WAV reader/writer for the command-line tool and tests.
/// Reads 8/16/24/32-bit integer PCM and 32/64-bit float, including WAVE_FORMAT_EXTENSIBLE.
public struct WAVFile {
    public enum SampleFormat: Sendable {
        case int16
        case float32
    }

    public enum ReadError: Error, CustomStringConvertible {
        case notWAV
        case missingChunk(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .notWAV: return "Not a RIFF/WAVE file."
            case .missingChunk(let name): return "WAV file has no '\(name)' chunk."
            case .unsupported(let detail): return "Unsupported WAV format: \(detail)."
            }
        }
    }

    public var sampleRate: Double
    /// One array per channel, samples in -1...1.
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int { channels.first?.count ?? 0 }

    public static func read(from url: URL) throws -> WAVFile {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> WAVFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else {
            throw ReadError.notWAV
        }

        var format: (code: Int, channels: Int, sampleRate: Int, bits: Int)?
        var dataRange: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset)
            let size = Int(uint32(bytes, offset + 4))
            let body = offset + 8
            let end = min(body + size, bytes.count)
            if id == "fmt " {
                guard end - body >= 16 else { throw ReadError.unsupported("short fmt chunk") }
                var code = Int(uint16(bytes, body))
                if code == 0xFFFE, end - body >= 26 {
                    code = Int(uint16(bytes, body + 24))
                }
                format = (
                    code,
                    Int(uint16(bytes, body + 2)),
                    Int(uint32(bytes, body + 4)),
                    Int(uint16(bytes, body + 14))
                )
            } else if id == "data" {
                dataRange = body..<end
            }
            offset = body + size + (size & 1)
        }

        guard let format else { throw ReadError.missingChunk("fmt ") }
        guard let dataRange else { throw ReadError.missingChunk("data") }
        guard format.channels > 0 else { throw ReadError.unsupported("zero channels") }

        let bytesPerSample = format.bits / 8
        guard [1, 2, 3, 4, 8].contains(bytesPerSample), format.bits % 8 == 0 else {
            throw ReadError.unsupported("\(format.bits)-bit samples")
        }
        let isFloat = format.code == 3
        guard format.code == 1 || (isFloat && (bytesPerSample == 4 || bytesPerSample == 8)) else {
            throw ReadError.unsupported("format code \(format.code), \(format.bits) bits")
        }

        let frameSize = bytesPerSample * format.channels
        let frames = dataRange.count / frameSize
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: format.channels)
        for frame in 0..<frames {
            for channel in 0..<format.channels {
                let at = dataRange.lowerBound + frame * frameSize + channel * bytesPerSample
                channels[channel][frame] = sample(bytes, at, bytesPerSample, isFloat)
            }
        }
        return WAVFile(sampleRate: Double(format.sampleRate), channels: channels)
    }

    public func write(to url: URL, format: SampleFormat = .float32) throws {
        try encode(format: format).write(to: url)
    }

    public func encode(format: SampleFormat = .float32) -> Data {
        let channelCount = channels.count
        let frames = frameCount
        let bytesPerSample = format == .int16 ? 2 : 4
        let dataSize = frames * channelCount * bytesPerSample

        var out = [UInt8]()
        out.reserveCapacity(44 + dataSize)
        out += Array("RIFF".utf8)
        append32(&out, UInt32(36 + dataSize))
        out += Array("WAVE".utf8)
        out += Array("fmt ".utf8)
        append32(&out, 16)
        append16(&out, format == .int16 ? 1 : 3)
        append16(&out, UInt16(channelCount))
        append32(&out, UInt32(sampleRate))
        append32(&out, UInt32(Int(sampleRate) * channelCount * bytesPerSample))
        append16(&out, UInt16(channelCount * bytesPerSample))
        append16(&out, UInt16(bytesPerSample * 8))
        out += Array("data".utf8)
        append32(&out, UInt32(dataSize))

        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let value = channels[channel][frame]
                switch format {
                case .int16:
                    let clipped = min(max(value, -1), 1)
                    append16(&out, UInt16(bitPattern: Int16((clipped * 32767).rounded())))
                case .float32:
                    append32(&out, value.bitPattern)
                }
            }
        }
        return Data(out)
    }

    private static func ascii(_ bytes: [UInt8], _ at: Int) -> String {
        guard at + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[at..<at + 4], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static func sample(_ bytes: [UInt8], _ at: Int, _ size: Int, _ isFloat: Bool) -> Float {
        switch (size, isFloat) {
        case (1, _):
            return (Float(bytes[at]) - 128) / 128
        case (2, _):
            return Float(Int16(bitPattern: uint16(bytes, at))) / 32768
        case (3, _):
            let raw = Int32(bytes[at]) << 8 | Int32(bytes[at + 1]) << 16 | Int32(bytes[at + 2]) << 24
            return Float(raw >> 8) / 8_388_608
        case (4, false):
            return Float(Double(Int32(bitPattern: uint32(bytes, at))) / 2_147_483_648)
        case (4, true):
            return Float(bitPattern: uint32(bytes, at))
        case (8, true):
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return Float(Double(bitPattern: bits))
        default:
            return 0
        }
    }

    private func append16(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8(value >> 8))
    }

    private func append32(_ out: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

import Foundation
import UnmuffleDSP

// Offline version of the app: cleans up a WAV file with the same engine.
//
//   unmuffle-cli movie-audio.wav fixed.wav --preset cam
//
// Pair it with ffmpeg to fix a downloaded video (see README).

let usage = """
usage: unmuffle-cli <input.wav> <output.wav> [options]

  --preset <id>      start from a preset (default: cam)
  --noise <0-1>      noise removal
  --echo <0-1>       echo / room reverb removal
  --dialogue <0-1>   dialogue focus
  --clarity <0-1>    high-end restoration
  --bass <0-1>       bass
  --width <0-1>      stereo width
  --leveling <0-1>   volume leveling
  --boost <0-12>     output boost in dB
  --16bit            write 16-bit PCM instead of 32-bit float
  --list-presets     show presets and exit
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func listPresets() {
    for preset in Preset.all {
        print("\(preset.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(preset.name): \(preset.summary)")
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--list-presets") {
    listPresets()
    exit(0)
}
if arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(0)
}
if arguments.count < 2 {
    print(usage)
    exit(1)
}

let inputPath = arguments.removeFirst()
let outputPath = arguments.removeFirst()
var settings = EnhancerSettings.default
var outputFormat = WAVFile.SampleFormat.float32

func value(after flag: String) -> Float {
    guard !arguments.isEmpty, let number = Float(arguments.removeFirst()) else {
        fail("\(flag) needs a number")
    }
    return number
}

while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--preset":
        guard !arguments.isEmpty else { fail("--preset needs a name") }
        let id = arguments.removeFirst()
        guard let preset = Preset.all.first(where: { $0.id == id }) else {
            fail("Unknown preset '\(id)'. Run --list-presets to see them.")
        }
        settings = preset.settings
    case "--noise": settings.noiseReduction = value(after: flag)
    case "--echo": settings.dereverb = value(after: flag)
    case "--dialogue": settings.dialogue = value(after: flag)
    case "--clarity": settings.clarity = value(after: flag)
    case "--bass": settings.bass = value(after: flag)
    case "--width": settings.width = value(after: flag)
    case "--leveling": settings.leveling = value(after: flag)
    case "--boost": settings.boostDB = value(after: flag)
    case "--16bit": outputFormat = .int16
    default: fail("Unknown option \(flag)\n\n\(usage)")
    }
}

let input: WAVFile
do {
    input = try WAVFile.read(from: URL(fileURLWithPath: inputPath))
} catch {
    fail("Couldn't read \(inputPath): \(error)")
}
guard input.frameCount > 0 else { fail("\(inputPath) has no audio.") }

// The engine is stereo. Mono is duplicated; for surround, fold the center channel in.
var left = input.channels[0]
var right = input.channels.count > 1 ? input.channels[1] : input.channels[0]
if input.channels.count >= 3 {
    let center = input.channels[2]
    for i in 0..<left.count {
        left[i] += 0.707 * center[i]
        right[i] += 0.707 * center[i]
    }
}

let enhancer = Enhancer(sampleRate: input.sampleRate, settings: settings)
let latency = enhancer.latency
let totalFrames = input.frameCount + latency
left += [Float](repeating: 0, count: latency)
right += [Float](repeating: 0, count: latency)

let start = Date()
let chunk = 512
var offset = 0
left.withUnsafeMutableBufferPointer { l in
    right.withUnsafeMutableBufferPointer { r in
        while offset < totalFrames {
            let count = min(chunk, totalFrames - offset)
            enhancer.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frameCount: count)
            offset += count
        }
    }
}
let elapsed = Date().timeIntervalSince(start)

let output = WAVFile(
    sampleRate: input.sampleRate,
    channels: [Array(left[latency...]), Array(right[latency...])]
)
do {
    try output.write(to: URL(fileURLWithPath: outputPath), format: outputFormat)
} catch {
    fail("Couldn't write \(outputPath): \(error)")
}

let seconds = Double(input.frameCount) / input.sampleRate
let speed = String(format: "Processed %.1f s of audio in %.2f s (%.0fx real time)", seconds, elapsed, seconds / max(elapsed, 1e-6))
print("\(speed) -> \(outputPath)")

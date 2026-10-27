/// Every knob the user can turn. Sliders are 0...1 except `boostDB`.
public struct EnhancerSettings: Codable, Equatable, Sendable {
    /// When false the original audio passes through untouched (for A/B comparison).
    public var isEnabled: Bool
    /// Removes steady background noise: hiss, hum, air conditioning, projector whine.
    public var noiseReduction: Float
    /// Removes the big-room echo you get when a movie is recorded from the seats.
    public var dereverb: Float
    /// Cuts boom and mud, lifts the speech band, and focuses the center channel.
    public var dialogue: Float
    /// Restores the high end that cheap mics and low-bitrate encodes throw away.
    public var clarity: Float
    /// Adds back low end.
    public var bass: Float
    /// Spreads the sound out; turns near-mono recordings into stereo.
    public var width: Float
    /// Evens out volume so quiet lines are audible and explosions don't blast you.
    public var leveling: Float
    /// Makeup gain in dB (0...12). The limiter keeps it from clipping.
    public var boostDB: Float

    public init(
        isEnabled: Bool = true,
        noiseReduction: Float,
        dereverb: Float,
        dialogue: Float,
        clarity: Float,
        bass: Float,
        width: Float,
        leveling: Float,
        boostDB: Float
    ) {
        self.isEnabled = isEnabled
        self.noiseReduction = noiseReduction
        self.dereverb = dereverb
        self.dialogue = dialogue
        self.clarity = clarity
        self.bass = bass
        self.width = width
        self.leveling = leveling
        self.boostDB = boostDB
    }

    public static let boostRange: ClosedRange<Float> = 0...12

    /// Every stage at zero. The chain is transparent apart from its latency.
    public static let neutral = EnhancerSettings(
        noiseReduction: 0, dereverb: 0, dialogue: 0, clarity: 0,
        bass: 0, width: 0, leveling: 0, boostDB: 0
    )

    public static let `default` = Preset.camRip.settings

    /// Copy with every value pulled into its valid range.
    public var clamped: EnhancerSettings {
        func unit(_ x: Float) -> Float { x.isFinite ? min(max(x, 0), 1) : 0 }
        var copy = self
        copy.noiseReduction = unit(noiseReduction)
        copy.dereverb = unit(dereverb)
        copy.dialogue = unit(dialogue)
        copy.clarity = unit(clarity)
        copy.bass = unit(bass)
        copy.width = unit(width)
        copy.leveling = unit(leveling)
        copy.boostDB = boostDB.isFinite ? min(max(boostDB, Self.boostRange.lowerBound), Self.boostRange.upperBound) : 0
        return copy
    }
}

public struct Preset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let settings: EnhancerSettings

    public static let camRip = Preset(
        id: "cam",
        name: "Cam Recording",
        summary: "Filmed in a theater: noise, echo, muffled voices.",
        settings: EnhancerSettings(
            noiseReduction: 0.7, dereverb: 0.75, dialogue: 0.7, clarity: 0.55,
            bass: 0.35, width: 0.45, leveling: 0.7, boostDB: 6
        )
    )

    public static let telesync = Preset(
        id: "telesync",
        name: "Line Audio",
        summary: "Decent source with some hiss and flat, thin sound.",
        settings: EnhancerSettings(
            noiseReduction: 0.35, dereverb: 0.15, dialogue: 0.4, clarity: 0.4,
            bass: 0.3, width: 0.3, leveling: 0.45, boostDB: 3
        )
    )

    public static let quietStream = Preset(
        id: "quiet",
        name: "Too Quiet",
        summary: "Clean but too quiet, or dialogue buried in music.",
        settings: EnhancerSettings(
            noiseReduction: 0.15, dereverb: 0, dialogue: 0.5, clarity: 0.2,
            bass: 0.15, width: 0.15, leveling: 0.8, boostDB: 9
        )
    )

    public static let night = Preset(
        id: "night",
        name: "Night Mode",
        summary: "One steady volume. Clear voices, tamed explosions.",
        settings: EnhancerSettings(
            noiseReduction: 0.45, dereverb: 0.2, dialogue: 0.8, clarity: 0.3,
            bass: 0, width: 0.1, leveling: 1, boostDB: 6
        )
    )

    public static let maximum = Preset(
        id: "max",
        name: "Maximum",
        summary: "Everything cranked, for the worst recordings.",
        settings: EnhancerSettings(
            noiseReduction: 1, dereverb: 0.9, dialogue: 0.9, clarity: 0.8,
            bass: 0.5, width: 0.6, leveling: 0.9, boostDB: 9
        )
    )

    public static let all: [Preset] = [camRip, telesync, quietStream, night, maximum]

    /// The preset whose settings match, ignoring the on/off switch.
    public static func matching(_ settings: EnhancerSettings) -> Preset? {
        var probe = settings
        probe.isEnabled = true
        return all.first { $0.settings == probe }
    }
}

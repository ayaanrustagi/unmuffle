#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

struct AudioError: LocalizedError {
    let action: String
    let status: OSStatus

    var errorDescription: String? {
        "Couldn't \(action) (Core Audio error \(status))."
    }
}

@inline(__always)
func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw AudioError(action: action, status: status) }
}

/// Thin wrappers over the Core Audio hardware property API.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var address = propertyAddress(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        try check(status, "read audio property \(selector)")
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read audio property \(selector)")
        guard let value else { throw AudioError(action: "read audio property \(selector)", status: -1) }
        return value.takeRetainedValue() as String
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        let device: AudioDeviceID = try read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown)
        guard device != unknown else { throw AudioError(action: "find an output device", status: -1) }
        return device
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        try readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func nominalSampleRate(_ device: AudioDeviceID) throws -> Double {
        try read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport: UInt32 = (try? read(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Core Audio object for a process, used to keep our own output out of the tap.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "look up Unmuffle's own audio process"
        )
        guard object != unknown else {
            throw AudioError(action: "look up Unmuffle's own audio process", status: -1)
        }
        return object
    }
}
#endif

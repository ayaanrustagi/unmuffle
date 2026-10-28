#if os(macOS)
import AppKit
import ObjectiveC

/// A temporary HiDPI screen, so snapshots taken on a 1x CI machine come out at 2x.
///
/// It uses CoreGraphics' private `CGVirtualDisplay` classes, the ones display utilities
/// use for virtual screens, through the Objective-C runtime. Only `--snapshot` uses it, and
/// the screen goes away when the app quits. Returns nil if anything is missing.
final class SnapshotDisplay {
    let screen: NSScreen
    private let display: NSObject

    init?() {
        guard
            let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
            let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
            let modeClass = NSClassFromString("CGVirtualDisplayMode"),
            let displayClass = NSClassFromString("CGVirtualDisplay")
        else { return nil }

        let descriptor = descriptorClass.init()
        descriptor.setValue("Unmuffle Snapshot", forKey: "name")
        descriptor.setValue(2560, forKey: "maxPixelsWide")
        descriptor.setValue(1600, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 340, height: 212)), forKey: "sizeInMillimeters")
        descriptor.setValue(0x554E, forKey: "vendorID")
        descriptor.setValue(0x4D46, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        _ = descriptor.perform(NSSelectorFromString("setDispatchQueue:"), with: DispatchQueue.main)

        guard let display = Self.alloc(displayClass)?
            .perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?
            .takeUnretainedValue() as? NSObject
        else { return nil }

        // 2560x1600 pixels, which a HiDPI screen shows as 1280x800 points.
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let modeSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard
            let modeInit = class_getMethodImplementation(modeClass, modeSelector),
            let allocatedMode = Self.alloc(modeClass),
            let mode = unsafeBitCast(modeInit, to: ModeInit.self)(allocatedMode, modeSelector, 2560, 1600, 60)?
                .takeUnretainedValue()
        else { return nil }

        let settings = settingsClass.init()
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        _ = display.perform(NSSelectorFromString("applySettings:"), with: settings)

        guard let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        Self.useHiDPIMode(id)
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let number = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[number] as? NSNumber)?.uint32Value == id })
        else { return nil }
        self.display = display
        self.screen = screen
    }

    private static func alloc(_ cls: AnyClass) -> AnyObject? {
        (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    }

    private static func useHiDPIMode(_ id: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return }
        print("virtual display modes: " + modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth / max($0.width, 1))x" }.joined(separator: " "))
        guard let mode = modes
            .filter({ $0.pixelWidth == 2 * $0.width })
            .max(by: { $0.width < $1.width })
        else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        _ = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        _ = CGCompleteDisplayConfiguration(config, .forAppOnly)
    }
}
#endif

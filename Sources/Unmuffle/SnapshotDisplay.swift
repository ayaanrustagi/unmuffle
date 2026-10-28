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
        else { Self.fail("CGVirtualDisplay classes not found"); return nil }

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
        else { Self.fail("couldn't create the display"); return nil }

        // 2560x1600 pixels, which a HiDPI screen shows as 1280x800 points.
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let modeSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard
            let modeInit = class_getMethodImplementation(modeClass, modeSelector),
            let allocatedMode = Self.alloc(modeClass),
            let mode = unsafeBitCast(modeInit, to: ModeInit.self)(allocatedMode, modeSelector, 2560, 1600, 60)?
                .takeUnretainedValue()
        else { Self.fail("couldn't create the display mode"); return nil }

        let settings = settingsClass.init()
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        _ = display.perform(NSSelectorFromString("applySettings:"), with: settings)

        guard let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else {
            Self.fail("the display has no ID"); return nil
        }
        // AppKit learns about new screens from window server events, so let those through.
        let number = NSDeviceDescriptionKey("NSScreenNumber")
        func findScreen() -> NSScreen? {
            NSScreen.screens.first { ($0.deviceDescription[number] as? NSNumber)?.uint32Value == id }
        }
        Self.handleEvents(for: 8) { findScreen() != nil }
        Self.useHiDPIMode(id)
        Self.handleEvents(for: 4) { (findScreen()?.backingScaleFactor ?? 1) >= 2 }

        guard let screen = findScreen() else {
            let bounds = CGDisplayBounds(id)
            Self.fail("display \(id) (\(Int(bounds.width))x\(Int(bounds.height))) isn't among the \(NSScreen.screens.count) screens")
            return nil
        }
        self.display = display
        self.screen = screen
    }

    private static func fail(_ reason: String) {
        print("no HiDPI virtual screen: \(reason)")
    }

    private static func handleEvents(for seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
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

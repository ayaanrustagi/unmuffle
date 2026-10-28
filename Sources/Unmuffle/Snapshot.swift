#if os(macOS)
import AppKit
import SwiftUI

/// `Unmuffle --snapshot <folder>` renders the menu bar window in light and dark mode to
/// PNG files and quits. CI uses it to keep the README screenshots honest.
enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let shots: [(name: String, appearance: NSAppearance.Name, adjust: Bool)] = [
            ("window-light", .aqua, false),
            ("window-dark", .darkAqua, false),
            ("window-adjust-light", .aqua, true),
            ("window-adjust-dark", .darkAqua, true),
        ]
        for shot in shots {
            UserDefaults.standard.set(shot.adjust, forKey: "adjustExpanded")
            let root = ContentView()
                .environmentObject(AppModel(preview: ()))
                .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: shot.appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            // A titled, key window, so controls draw in their active colors (the menu bar
            // window is key whenever it's open). Only the content view is captured.
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: shot.appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            // Render at 2x so the images are sharp on Retina screens and in the README.
            let scale: CGFloat = 2
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            bitmap.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            window.orderOut(nil)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(shot.name).png"))
                print("wrote \(shot.name).png")
            }
        }
        exit(0)
    }
}
#endif

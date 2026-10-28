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
        // CI screens run at 1x. Capture on a HiDPI virtual screen when we can.
        let retina = SnapshotDisplay()
        let screen = retina?.screen ?? NSScreen.main
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), capturing at \(screen?.backingScaleFactor ?? 1)x")
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
                .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 18))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: shot.appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)

            // Like the menu bar window: a panel that becomes key without activating the
            // app, so controls draw in their active colors.
            let panel = SnapshotPanel(
                contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.appearance = NSAppearance(named: shot.appearance)
            panel.contentView = view
            if let frame = screen?.frame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - view.frame.width / 2, y: frame.midY - view.frame.height / 2))
            }
            panel.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(1))

            let file = folder.appendingPathComponent("\(shot.name).png")
            if #available(macOS 26.0, *), captureFromScreen(panel, to: file) {
                print("wrote \(shot.name).png (captured)")
            } else if draw(view, to: file) {
                print("wrote \(shot.name).png (drawn)")
            }
            panel.orderOut(nil)
        }
        withExtendedLifetime(retina) {}
        exit(0)
    }

    /// Liquid Glass is composited by the window server, so on macOS 26 the window is
    /// captured from the screen. Drawing the view directly would leave the glass out.
    private static func captureFromScreen(_ window: NSWindow, to file: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
    }

    /// Draws the view at 2x, so the images are sharp on Retina screens and in the README.
    private static func draw(_ view: NSView, to file: URL) -> Bool {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }
}

private final class SnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
#endif

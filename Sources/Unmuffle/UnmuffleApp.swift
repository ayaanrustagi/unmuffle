#if os(macOS)
import SwiftUI

@main
struct UnmuffleApp: App {
    @StateObject private var model = AppModel()

    init() {
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRunning ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

#else

@main
enum UnmuffleApp {
    static func main() {
        print("The Unmuffle app needs macOS 14.2 or later. On this platform, use unmuffle-cli.")
    }
}

#endif

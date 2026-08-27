import SwiftUI

/// A macOS app for reading a network trace someone sent you.
///
/// It opens HAR files — the ones `DiagnosticsRecorder.exportHAR()` writes, and the ones a browser,
/// Charles, or Proxyman write — and shows them with the same panel a live app embeds. Nothing here
/// talks to a running process: the file is the artifact, and this is the reader for it.
@main
struct NovaNetworkInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            InspectorView()
        }
        .defaultSize(width: 940, height: 620)
        .commands {
            // A trace viewer has nothing to create, so New becomes Open.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { NotificationCenter.default.post(name: .inspectorOpenRequested, object: nil) }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Files opened from the Finder arrive through the app delegate rather than through SwiftUI, so
/// this is what makes `open -a NovaNetworkInspector trace.har` and "Open With" work.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .inspectorOpenFile, object: url)
    }
}

extension Notification.Name {
    /// Posted by the Open menu item; the frontmost window answers it by showing the open panel.
    static let inspectorOpenRequested = Notification.Name("NovaNetworkInspector.open")
    /// Posted with a `URL` when the Finder hands the app a file to read.
    static let inspectorOpenFile = Notification.Name("NovaNetworkInspector.openFile")
}

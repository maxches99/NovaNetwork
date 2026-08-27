import SwiftUI

/// A demo app for looking at NovaNetworkDiagnostics.
///
/// Everything it talks to is a scripted transport inside the app, so it needs no network and no
/// credentials, and every scenario behaves the same way on every run.
@main
struct NovaDiagnosticsDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

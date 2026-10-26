import SwiftUI

@main
struct DualCaptureApp: App {
    init() {
        DebugLog.shared.log("app.launch diagnostics_ready")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

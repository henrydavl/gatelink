import SwiftUI

@main
struct GateLinkPhoneApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    // The VPN may have come up or gone down while GateLink was in the background.
                    if phase == .active { Task { await model.attachRunningTunnel() } }
                }
        }
    }
}

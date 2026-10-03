import SwiftUI
import SwiftData

@main
struct PromptCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
        .modelContainer(for: Script.self)
    }
}

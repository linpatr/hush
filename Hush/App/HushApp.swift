import SwiftUI

@main
struct HushApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MixScreen()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

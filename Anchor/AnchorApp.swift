import SwiftUI

@main
struct AnchorApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 1760, height: 700)
    }
}

import SwiftUI

@main
struct AnchorApp: App {

    /// One engine and one scene model for the app's lifetime. Held here rather
    /// than in HomeView so the immersive space and the home window are looking
    /// at the same session — the space needs the scene's root entity, and the
    /// window needs its phase.
    @State private var session = MemorySession()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(session)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1800, height: 950)

        ImmersiveSpace(id: MemorySession.immersiveSpaceID) {
            MemoryImmersiveView()
                .environment(session)
        }
        // .full: the memory replaces the room entirely. A mixed style would
        // leave the user's own furniture cutting through the reconstruction.
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

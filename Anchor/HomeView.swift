import SwiftUI

struct HomeView: View {
    @State private var memories: [Memory] = Memory.sample
    @State private var selectedMemory: Memory = Memory.sample[0]
    @State private var sessionLength: Int = 15
    @State private var isLibraryExpanded = true

    @State private var isOverlayVisible = true
    @State private var hideTask: Task<Void, Never>?

    private let idleTimeout: Duration = .seconds(20)

    var body: some View {
        ZStack {
            SkyWaterBackground()
                .contentShape(Rectangle())
                .onTapGesture { wakeOverlay() }

            HomeOverlay(
                memories: memories,
                selectedMemory: $selectedMemory,
                sessionLength: $sessionLength,
                isLibraryExpanded: $isLibraryExpanded
            )
            .offset(z: 28) // Real spatial depth: floats in front of the background plane.
            .opacity(isOverlayVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: isOverlayVisible)
            .allowsHitTesting(isOverlayVisible)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { _ in wakeOverlay() }
            )
        }
        .frame(minWidth: 900, minHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        .task { wakeOverlay() }
        .onDisappear { hideTask?.cancel() }
    }

    private func wakeOverlay() {
        isOverlayVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            isOverlayVisible = false
        }
    }
}

#Preview {
    HomeView()
}

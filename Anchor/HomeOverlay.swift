import SwiftUI

/// The interactive control layer (greeting, memory library, selected memory,
/// control bar) — kept separate from the ambient background/orb scene so it
/// can fade independently, the way a video player's transport bar does.
struct HomeOverlay: View {
    let memories: [Memory]
    @Binding var selectedMemory: Memory
    @Binding var sessionLength: Int
    @Binding var isLibraryExpanded: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                GreetingHeader(name: "Paul")
                    .padding(.top, 56)

                // Reserved for the live orb (RealityView-based, in progress
                // on another branch) — intentionally left empty for now.
                Spacer(minLength: 0)

                ControlBar(sessionLength: $sessionLength)
                    .padding(.bottom, 48)
            }

            HStack(alignment: .top, spacing: 0) {
                MemoryLibraryPanel(
                    memories: memories,
                    selectedMemory: $selectedMemory,
                    isExpanded: $isLibraryExpanded
                )
                // Same indent as SelectedMemoryCard's trailing padding below,
                // so both panels sit equidistant from screen center.
                .padding(.leading, 214)
                .padding(.top, 40)

                Spacer(minLength: 0)

                SelectedMemoryCard(memory: selectedMemory)
                    .padding(.trailing, 214)
                    .padding(.top, 40)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black
        HomeOverlay(
            memories: Memory.sample,
            selectedMemory: .constant(Memory.sample[0]),
            sessionLength: .constant(15),
            isLibraryExpanded: .constant(true)
        )
    }
}

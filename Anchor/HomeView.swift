import SwiftUI

struct HomeView: View {
    @State private var memories: [Memory] = Memory.sample
    @State private var selectedMemory: Memory = Memory.sample[0]
    @State private var sessionLength: Int = 15
    @State private var isLibraryExpanded = true

    var body: some View {
        ZStack {
            backgroundScene

            VStack(spacing: 0) {
                GreetingHeader(name: "Paul")
                    .padding(.top, 56)

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
                .padding(.leading, 48)
                .padding(.top, 40)

                Spacer(minLength: 0)

                SelectedMemoryCard(memory: selectedMemory)
                    .padding(.trailing, 48)
                    .padding(.top, 40)
            }
        }
        .frame(minWidth: 900, minHeight: 480)
    }

    private var backgroundScene: some View {
        GeometryReader { proxy in
            Image("OrbLake")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
    }
}

#Preview {
    HomeView()
}

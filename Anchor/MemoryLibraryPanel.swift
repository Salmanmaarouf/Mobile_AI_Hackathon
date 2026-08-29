import SwiftUI

struct MemoryLibraryPanel: View {
    let memories: [Memory]
    @Binding var selectedMemory: Memory
    @Binding var isExpanded: Bool

    /// The memory currently centered in the scroll view — scrolling *is* the
    /// selection mechanism, like a native visionOS/watchOS picker.
    @State private var scrollPosition: Memory.ID?

    private let listHeight: CGFloat = 360
    private let rowWidth: CGFloat = 166
    private let rowHeight: CGFloat = 134
    private let rowOverlap: CGFloat = -10

    /// Width of the dot rail + its spacing to the cards — used to keep the
    /// title centered over the card column itself, not the whole panel.
    private let leadingRailWidth: CGFloat = 22

    var body: some View {
        VStack(spacing: 14) {
            Text("Memory Library")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.leading, 14 + leadingRailWidth)
                .padding(.trailing, 14)

            if isExpanded {
                HStack(alignment: .center, spacing: 10) {
                    CarouselDots(memories: memories, focusedID: scrollPosition)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: rowOverlap) {
                            ForEach(memories) { memory in
                                MemoryRow(memory: memory, height: rowHeight, isFocused: memory.id == scrollPosition)
                                    .scrollTransition(axis: .vertical) { content, phase in
                                        content
                                            .scaleEffect(1 - min(abs(phase.value), 1) * 0.22)
                                            .opacity(1 - min(abs(phase.value), 1) * 0.55)
                                    }
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            scrollPosition = memory.id
                                        }
                                    }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .frame(width: rowWidth, height: listHeight)
                    .contentMargins(.vertical, (listHeight - rowHeight) / 2, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always, anchor: .center))
                    .scrollPosition(id: $scrollPosition, anchor: .center)
                    .sensoryFeedback(.selection, trigger: scrollPosition)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.16),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .padding(.leading, 14)
                .padding(.trailing, 14)

                collapseButton(icon: "chevron.up") {
                    isExpanded = false
                }
                .padding(.bottom, 16)
            } else {
                collapseButton(icon: "chevron.down") {
                    isExpanded = true
                }
                .padding(.vertical, 20)
            }
        }
        .frame(width: 216)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isExpanded)
        .onAppear {
            scrollPosition = selectedMemory.id
        }
        .onChange(of: scrollPosition) { _, newValue in
            guard let newValue, let match = memories.first(where: { $0.id == newValue }) else { return }
            selectedMemory = match
        }
        .onChange(of: selectedMemory) { _, newValue in
            guard scrollPosition != newValue.id else { return }
            scrollPosition = newValue.id
        }
    }

    /// Centered over the card column, matching the title above and the
    /// cards below — not the whole panel (which also includes the dot rail).
    private func collapseButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonBorderShape(.circle)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.leading, 14 + leadingRailWidth)
        .padding(.trailing, 14)
    }
}

/// Vertical paging indicator aligned to the scroll list: the dot for the
/// centered memory is largest and brightest, tapering off by list-order
/// distance for its neighbors — mirrors the card scaling in the scroll view.
private struct CarouselDots: View {
    let memories: [Memory]
    let focusedID: Memory.ID?

    private var focusedIndex: Int? {
        guard let focusedID else { return nil }
        return memories.firstIndex(where: { $0.id == focusedID })
    }

    var body: some View {
        VStack(spacing: 11) {
            ForEach(Array(memories.enumerated()), id: \.element.id) { index, _ in
                let distance = focusedIndex.map { abs($0 - index) } ?? Int.max
                Circle()
                    .fill(.white.opacity(dotOpacity(for: distance)))
                    .frame(width: dotSize(for: distance), height: dotSize(for: distance))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: focusedIndex)
        .frame(width: 12)
    }

    private func dotSize(for distance: Int) -> CGFloat {
        switch distance {
        case 0: return 7
        case 1: return 5
        default: return 4
        }
    }

    private func dotOpacity(for distance: Int) -> Double {
        switch distance {
        case 0: return 0.95
        case 1: return 0.55
        default: return 0.3
        }
    }
}

private struct MemoryRow: View {
    let memory: Memory
    let height: CGFloat
    let isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: memory.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)

            // Shadow gradient so the caption stays legible over any thumbnail.
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(memory.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(memory.date)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(8)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(isFocused ? 0.55 : 0), lineWidth: 2)
        )
    }
}

#Preview {
    ZStack {
        Color.black
        MemoryLibraryPanel(
            memories: Memory.sample,
            selectedMemory: .constant(Memory.sample[0]),
            isExpanded: .constant(true)
        )
    }
}

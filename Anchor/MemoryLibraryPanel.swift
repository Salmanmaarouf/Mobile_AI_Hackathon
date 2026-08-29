import SwiftUI

struct MemoryLibraryPanel: View {
    let memories: [Memory]
    @Binding var selectedMemory: Memory
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Memory Library")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 18)

            if isExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(memories) { memory in
                            MemoryRow(memory: memory, isSelected: memory == selectedMemory)
                                .scrollTransition(axis: .vertical) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.82)
                                        .opacity(phase.isIdentity ? 1 : 0.45)
                                }
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        selectedMemory = memory
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(width: 150, height: 360)

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonBorderShape(.circle)
                .padding(.bottom, 16)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = true
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonBorderShape(.circle)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 178)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28))
    }
}

private struct MemoryRow: View {
    let memory: Memory
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(colors: memory.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(height: 84)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                )

            Text(memory.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
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

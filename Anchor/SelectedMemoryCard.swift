import SwiftUI

struct SelectedMemoryCard: View {
    let memory: Memory

    var body: some View {
        VStack(spacing: 14) {
            Text("Selected Memory")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 20)

            Circle()
                .fill(
                    LinearGradient(colors: memory.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 84, height: 84)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))

            VStack(spacing: 3) {
                Text(memory.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Text(memory.date)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Button {
                // Hand off to the immersive memory experience.
            } label: {
                Label("View Memory", systemImage: "chevron.right")
                    .labelStyle(.custom)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonBorderShape(.capsule)
            .padding(.bottom, 20)
        }
        .frame(width: 200)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

private extension LabelStyle where Self == TrailingIconLabelStyle {
    static var custom: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

#Preview {
    ZStack {
        Color.black
        SelectedMemoryCard(memory: Memory.sample[0])
    }
}

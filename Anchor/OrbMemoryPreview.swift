import SwiftUI

/// A circular preview of the selected memory, layered onto the orb like a
/// video thumbnail with a play affordance — previewing what the "Begin"
/// button will open. Sized slightly smaller than the orb so a thin ring of
/// the orb's own gradient still shows around the edge.
struct OrbMemoryPreview: View {
    let memory: Memory
    let size: CGFloat

    var body: some View {
        ZStack {
            MemoryThumbnail(memory: memory)

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            // No play affordance here. The Begin button on the right is the
            // one control that starts a session, and a second play glyph on
            // the orb only raises the question of whether they do different
            // things.
            VStack {
                Spacer()
                VStack(spacing: size * 0.01) {
                    Text(memory.title)
                        .font(.system(size: size * 0.065, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(memory.date)
                        .font(.system(size: size * 0.048, weight: .regular))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.bottom, size * 0.13)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

#Preview {
    ZStack {
        Color.black
        OrbMemoryPreview(memory: Memory.sample[0], size: 220)
    }
}

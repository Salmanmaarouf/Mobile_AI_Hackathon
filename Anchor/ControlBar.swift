import SwiftUI

struct ControlBar: View {
    @Binding var sessionLength: Int
    @State private var isVoiceGuideOn = false

    @State private var isVoiceGuideHovering = false
    @State private var isSessionHovering = false
    @State private var isSettingsHovering = false

    private let lengthOptions = [5, 10, 15, 20, 30]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            controlButton(
                icon: "waveform",
                label: "Voice Guide",
                isActive: isVoiceGuideOn,
                isHovering: $isVoiceGuideHovering
            ) {
                isVoiceGuideOn.toggle()
            }

            sessionLengthControl

            controlButton(
                icon: "gearshape",
                label: "Settings",
                isActive: false,
                isHovering: $isSettingsHovering
            ) {}
        }
        .sensoryFeedback(.selection, trigger: isVoiceGuideOn)
        .sensoryFeedback(.selection, trigger: sessionLength)
    }

    /// One control instead of two redundant ones (an icon button that did
    /// nothing useful, plus an always-visible duration menu below it) — the
    /// icon itself gently expands on hover to reveal the duration picker.
    private var sessionLengthControl: some View {
        VStack(spacing: 8) {
            Menu {
                ForEach(lengthOptions, id: \.self) { minutes in
                    Button("\(minutes) min") { sessionLength = minutes }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 19, weight: .medium))
                    if isSessionHovering {
                        Text("\(sessionLength) min")
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize()
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                    }
                }
                .frame(height: 56)
                .padding(.horizontal, isSessionHovering ? 18 : 0)
                .frame(minWidth: 56)
            }
            // Circle at rest, matching Voice Guide/Settings — only becomes a
            // capsule once hovering reveals the duration text next to it.
            .buttonBorderShape(isSessionHovering ? .capsule : .circle)
            .menuStyle(.button)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSessionHovering = hovering
                }
            }

            Text("Session Length")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    /// Gently grows on hover/gaze rather than staying a fixed size.
    private func controlButton(
        icon: String,
        label: String,
        isActive: Bool,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(
                        width: isHovering.wrappedValue ? 64 : 56,
                        height: isHovering.wrappedValue ? 64 : 56
                    )
                    .shadow(color: .white.opacity(isActive ? 0.6 : 0), radius: isActive ? 12 : 0)
            }
            .buttonBorderShape(.circle)
            .animation(.easeInOut(duration: 0.25), value: isHovering.wrappedValue)
            .onHover { hovering in
                isHovering.wrappedValue = hovering
            }

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    ZStack {
        Color.black
        ControlBar(sessionLength: .constant(15))
    }
}

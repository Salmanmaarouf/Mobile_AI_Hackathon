import SwiftUI

struct ControlBar: View {
    @Binding var sessionLength: Int
    @State private var isVoiceGuideOn = false
    @State private var showLengthMenu = false

    private let lengthOptions = [5, 10, 15, 20, 30]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            controlButton(
                icon: "waveform",
                label: "Voice Guide",
                isActive: isVoiceGuideOn
            ) {
                isVoiceGuideOn.toggle()
            }

            VStack(spacing: 8) {
                controlButton(icon: "timer", label: "Session Length", isActive: false) {
                    showLengthMenu.toggle()
                }

                Menu {
                    ForEach(lengthOptions, id: \.self) { minutes in
                        Button("\(minutes) min") { sessionLength = minutes }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(sessionLength) min")
                        Image(systemName: "chevron.down")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .menuStyle(.button)
            }

            controlButton(icon: "gearshape", label: "Settings", isActive: false) {}
        }
        .sensoryFeedback(.selection, trigger: isVoiceGuideOn)
        .sensoryFeedback(.selection, trigger: sessionLength)
    }

    private func controlButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                    )
                    .shadow(color: .white.opacity(isActive ? 0.6 : 0), radius: isActive ? 12 : 0)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .hoverEffect(.highlight)

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

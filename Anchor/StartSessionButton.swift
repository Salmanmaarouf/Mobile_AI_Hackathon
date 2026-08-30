import SwiftUI

/// Replaces the old memory-detail card on the right — the memory's own preview
/// now lives on the orb itself, so this side is just the single action that
/// begins the experience.
struct StartSessionButton: View {

    /// The memory this will open. Comes from the library selection, so the
    /// button always acts on whatever the orb is currently previewing.
    let memory: Memory

    @Environment(MemorySession.self) private var session
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        VStack(spacing: 12) {
            Button {
                open()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 84, height: 84)
            }
            .buttonBorderShape(.circle)
            .disabled(!memory.hasPhoto || session.isOpen)

            Text(caption)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(memory.hasPhoto ? .white : .white.opacity(0.5))
                .animation(.easeInOut(duration: 0.2), value: caption)
        }
    }

    private var caption: String {
        if session.isOpen { return "Opening…" }
        // Said plainly rather than hidden behind a disabled button with no
        // explanation — a carer needs to know the memory is incomplete, not
        // wonder whether the app is broken.
        return memory.hasPhoto ? "Begin" : "No photo yet"
    }

    private func open() {
        guard memory.hasPhoto, !session.isOpen else { return }

        // Staged before the space opens: ImmersiveSpace's content closure takes
        // no arguments, so this is how the choice gets across. `stage` also
        // marks the session open, and the immersive view's `onDisappear` is
        // what clears it again.
        session.stage(memory)

        Task {
            switch await openImmersiveSpace(id: MemorySession.immersiveSpaceID) {
            case .opened:
                // Nothing to do — the session is already marked open, and
                // dismissing the space is what will clear it.
                break
            case .userCancelled, .error:
                session.abandonStaging()
            @unknown default:
                session.abandonStaging()
            }
        }
    }
}

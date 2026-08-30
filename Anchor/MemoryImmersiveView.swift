import SwiftUI
import RealityKit

/// The memory itself, filling the room.
///
/// Deliberately almost empty: the SpatialMemory package contributes the whole
/// scene as one `Entity`, so this view's only jobs are to parent that entity,
/// start the build, put the controls somewhere reachable, and tear it all down
/// on the way out.
struct MemoryImmersiveView: View {

    @Environment(MemorySession.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// World position of the control panel, in the immersive space's
    /// coordinates — whose origin is the FLOOR beneath the wearer, so 1.5 is
    /// roughly eye height. This sits below the memory and slightly nearer, so
    /// it reads as a thing in the room with you rather than part of the picture.
    private let controlsPosition: SIMD3<Float> = [0, 0.95, -1.0]

    var body: some View {
        RealityView { content, attachments in
            // Safe to add before anything is built: the root entity exists from
            // the scene model's init and never changes identity, so the space
            // can open straight away instead of holding a black screen while
            // the pipeline runs.
            content.add(session.root)

            // Attachments, NOT `.overlay`. In a `.full` immersive space there is
            // no 2D frame for an overlay to align against — the view is an
            // unbounded volume, so `alignment: .bottom` puts the control
            // somewhere out in space where it is never seen. An attachment
            // becomes a real entity at a real world position.
            if let controls = attachments.entity(for: "controls") {
                controls.position = controlsPosition
                content.add(controls)
            }
        } attachments: {
            Attachment(id: "controls") {
                controlPanel
            }
        }
        .task {
            // In the task, not at tap time: dismissing the space cancels this,
            // which unwinds an in-flight upload rather than leaving a
            // 60-second request running against a scene nobody is looking at.
            guard let memory = session.pendingMemory else { return }
            await session.open(memory)
        }
        .onDisappear {
            session.close()
        }
    }

    @ViewBuilder
    private var controlPanel: some View {
        VStack(spacing: 18) {

            switch session.phase {
            case .preparing(let message):
                // Words only. A spinner or a progress bar would pull attention
                // forward and break the calm the transition exists for.
                Text(message)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))

            case .failed(let message):
                VStack(spacing: 8) {
                    Text("This memory couldn't be opened.")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

            case .idle, .ready:
                EmptyView()
            }

            HStack(spacing: 14) {
                // The way out, and it is ALWAYS here — during the loading,
                // after it, and when it failed.
                //
                // visionOS does give you the Digital Crown, but that is a thing
                // you have to already know. This app is for someone who may
                // not, and being unable to leave a memory you have stepped
                // inside is frightening in a way a normal app's dead end is not.
                Button {
                    Task { await dismissImmersiveSpace() }
                } label: {
                    Label("Back to my memories", systemImage: "chevron.left")
                        .font(.system(size: 17, weight: .medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                }
                .buttonBorderShape(.capsule)

                // The renderer A/B toggle lived here. Taken out for submission:
                // one of its two positions currently renders dark, and a
                // control that can break the demo is worse than no control.
                // `MemorySession.useDepthMeshPipeline` still exists — put the
                // toggle back once the depth mesh is fixed.
            }
        }
        .padding(28)
        .glassBackgroundEffect(in: .rect(cornerRadius: 34, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: session.phase)
    }
}

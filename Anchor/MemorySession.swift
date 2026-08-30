import Combine
import CoreGraphics
import Foundation
import RealityKit
import SwiftUI

/// Anchor's view of the SpatialMemory pipeline: one engine for the app's
/// lifetime, one scene model, and the small amount of state the UI binds to.
///
/// ============================================================================
/// WHAT RUNS WHERE
///
/// `MemorySceneModel.load(...)` tries Apple's spatial-scene generator first and
/// falls through to the package's own depth-mesh pipeline when that throws.
/// On Apple Vision Pro — which is what Anchor demos on — Apple's path wins: it
/// is the same model Photos uses, and it solves depth and parallax in one go.
/// In the Simulator `generate()` throws and the custom pipeline stands in, so
/// the app still runs on a laptop, just with a rougher reconstruction.
///
/// This file mirrors `MemorySceneModel`'s Combine state onto @Observable
/// properties, because SwiftUI's new observation does not see through a nested
/// ObservableObject.
/// ============================================================================
@MainActor
@Observable
final class MemorySession {

    static let immersiveSpaceID = "MemorySpace"

    enum Phase: Equatable {
        case idle
        /// Building the scene. The string is what to tell the user.
        case preparing(String)
        case ready
        case failed(String)

        var isPreparing: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .idle

    /// The memory currently being opened or shown. Nil when nothing is running.
    private(set) var activeMemory: Memory?

    /// The memory the immersive space should pick up when it appears.
    ///
    /// `ImmersiveSpace`'s content closure takes no arguments, so the choice has
    /// to be handed over out of band: stage it here, then open the space.
    private(set) var pendingMemory: Memory?

    /// True from the moment the space is asked to open until it has been fully
    /// torn down.
    ///
    /// Lives here rather than as local state in the button: a flag owned by a
    /// view that is unmounted while the immersive space is up has no chance to
    /// reset itself, which strands the home screen showing a session that is no
    /// longer running.
    private(set) var isOpen = false

    /// Records which memory the space should open. Call immediately before
    /// `openImmersiveSpace`.
    func stage(_ memory: Memory) {
        pendingMemory = memory
        isOpen = true
    }

    /// Undoes `stage(_:)` when the space never actually opened.
    func abandonStaging() {
        pendingMemory = nil
        isOpen = false
        phase = .idle
    }

    /// Stable attachment point for the immersive view. Identity never changes,
    /// so the space can open before the pipeline has produced anything — which
    /// is what lets the transition start immediately instead of stalling on a
    /// network round trip.
    var root: Entity { model.root }

    /// True once a Replicate token is available. Without one the background
    /// continuation falls back to a local blur.
    let hasFiller: Bool

    @ObservationIgnored private let engine: SpatialMemoryEngine
    @ObservationIgnored private let model: MemorySceneModel
    @ObservationIgnored private var observers: Set<AnyCancellable> = []

    init() {
        let token = Self.replicateToken
        let engine = token.map { SpatialMemoryEngine.replicate(apiToken: $0) }
                  ?? SpatialMemoryEngine.offline()
        self.engine = engine
        self.model = engine.makeScene()
        self.hasFiller = token != nil

        // Apple's spatial scene, which is the path that actually works on
        // device today.
        //
        // The depth-mesh pipeline is the one you can step inside, and it is
        // where this should end up — but its reconstruction currently renders
        // dark on device and the cause is not yet found. Shipping the renderer
        // that works beats shipping the more ambitious one that does not.
        // Flip this to `false` to pick the depth mesh back up.
        self.model.prefersAppleSpatialScene = true

        // Eye height, because the container's geometry is written from the head
        // and a full immersive space measures from the floor.
        self.model.customScenePosition = [0, 1.5, 0]

        // Lowered from 1.5: the memory was sitting above natural eye line.
        self.model.appleScenePosition = [0, 1.25, -1.15]

        observe()
    }

    /// Set in Xcode: Product → Scheme → Edit Scheme → Run → Arguments →
    /// Environment Variables. Never a literal and never Info.plist — both ship
    /// the token inside the app bundle where anyone can read it back out.
    private static var replicateToken: String? {
        let raw = ProcessInfo.processInfo
            .environment["REPLICATE_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, raw.isEmpty == false else { return nil }
        return raw
    }

    // MARK: - Driving a session

    /// Builds `memory` into the immersive scene.
    ///
    /// Call from the immersive view's `.task`, so dismissing the space cancels
    /// it — that unwinds an in-flight upload rather than leaving a 60-second
    /// request running against a scene nobody is looking at.
    func open(_ memory: Memory) async {
        guard let photo = memory.loadPhoto() else {
            phase = .failed("This memory has no photograph attached yet.")
            return
        }

        activeMemory = memory
        phase = .preparing("Opening \(memory.title)…")

        await model.load(
            image: photo.image,
            sourceData: photo.data,
            prompt: InpaintingPrompt.continuation(sceneHint: memory.title)
        )
    }

    /// Which renderer builds the memory: the depth-mesh pipeline you can step
    /// into, or Apple's spatial scene you look at.
    ///
    /// Kept as a live switch rather than a build-time decision because the
    /// comparison IS the argument — being able to flip between them in the
    /// headset is how you show that Apple's is the better picture and ours is
    /// the only one you can walk around inside.
    var useDepthMeshPipeline = true {
        didSet {
            guard oldValue != useDepthMeshPipeline else { return }
            model.prefersAppleSpatialScene = !useDepthMeshPipeline
            reloadActiveMemory()
        }
    }

    /// Which renderer actually produced what is on screen. Nil until one has.
    var renderedByApple: Bool? { model.usedAppleSpatialScene }

    /// What the pipeline actually built, for reading inside the headset where
    /// there is no console.
    private(set) var diagnostics: String?

    /// Rebuilds whatever is currently open, picking up a changed setting.
    private func reloadActiveMemory() {
        guard let memory = activeMemory ?? pendingMemory else { return }
        Task { await open(memory) }
    }

    /// Tears the memory down and stops its audio. Call from `onDisappear`.
    ///
    /// Clears `pendingMemory` too: leaving it set means the session still looks
    /// half-started to anything reading it, and the home screen goes on
    /// offering to resume something that has already been dismantled.
    func close() {
        model.tearDown()
        activeMemory = nil
        pendingMemory = nil
        isOpen = false
        phase = .idle
    }

    // MARK: - Mirroring the scene model's Combine state

    private func observe() {
        model.$diagnostics
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.diagnostics = $0 }
            .store(in: &observers)

        model.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] scenePhase in
                guard let self else { return }
                switch scenePhase {
                case .idle:
                    self.phase = .idle
                case .segmenting:
                    self.phase = .preparing("Finding what's in the photograph…")
                case .fillingBackground:
                    self.phase = .preparing("Rebuilding the room around it…")
                case .building:
                    self.phase = .preparing("Placing you inside it…")
                case .ready:
                    self.phase = .ready
                case .failed(let message):
                    self.phase = .failed(message)
                }
            }
            .store(in: &observers)
    }
}

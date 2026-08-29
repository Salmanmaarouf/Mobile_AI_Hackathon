//
//  SpatialMemoryDemoApp.swift
//  SpatialMemory — DEMO HARNESS. DELETE THIS FOLDER BEFORE INTEGRATING.
//
//  ============================================================================
//  This is the only file in the project that contains UI, and it exists purely
//  so the pipeline can be run without an app around it. Everything in Sources/
//  is UI-free and stays that way.
//
//  When you drop the pipeline into the real Vision Pro app, delete the whole
//  Demo/ folder. Nothing in Sources/ references it. The API you integrate
//  against is documented at the top of SpatialMemoryEngine.swift.
//  ============================================================================
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import Combine
import CoreGraphics
import PhotosUI
import RealityKit
import SwiftUI

// MARK: - App

@main
struct SpatialMemoryDemoApp: App {

    @StateObject private var demo = DemoState()

    // `SwiftUI.Scene`, spelled out. RealityKit also declares a `Scene`, so with
    // both modules imported a bare `some Scene` is ambiguous.
    var body: some SwiftUI.Scene {
        WindowGroup {
            DemoControls()
                .environmentObject(demo)
        }
        .defaultSize(width: 480, height: 520)

        ImmersiveSpace(id: DemoState.immersiveSpaceID) {
            DemoImmersiveScene()
                .environmentObject(demo)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

// MARK: - State

@MainActor
final class DemoState: ObservableObject {

    static let immersiveSpaceID = "spatial-memory-demo"

    /// One field, routed by token prefix. Which one you paste decides how much
    /// of the pipeline is real:
    ///
    ///   empty      estimated depth, smeared fill. Nothing is generated.
    ///   `r8_…`     Replicate: **Depth Pro** for geometry, LaMa for the fill.
    ///   `sk-…`     OpenAI: generative fill, but depth is still ESTIMATED —
    ///              `.hosted` sets no depth source, so the geometry stays a
    ///              guess and only the background gets invented.
    ///
    /// A text field is the wrong home for a real key in shipping code — it lives
    /// in memory here and goes nowhere — but production should read it from the
    /// keychain or a server-side token exchange.
    @Published var apiKey: String = "" {
        didSet { rebuildEngine() }
    }

    enum FillMode {
        case offline, replicate, openAI

        var title: String {
            switch self {
            case .offline:   return "Offline"
            case .replicate: return "Depth Pro + LaMa"
            case .openAI:    return "Generative fill"
            }
        }

        var detail: String {
            switch self {
            case .offline:
                return "Depth is estimated from image cues and the background is "
                     + "neighbouring pixels smeared inward. Expect soft geometry "
                     + "and grey smudges behind people."
            case .replicate:
                return "Depth measured by Apple's Depth Pro — sharp boundaries, "
                     + "which is what stops silhouettes looking like cut polygons. "
                     + "Background filled by LaMa."
            case .openAI:
                return "Background is generated, but depth is still estimated — "
                     + "geometry stays a guess. Paste a Replicate r8_ token "
                     + "instead for measured depth."
            }
        }

        var icon: String {
            switch self {
            case .offline:   return "circle.dashed"
            case .replicate: return "sparkles"
            case .openAI:    return "wand.and.stars"
            }
        }
    }

    var fillMode: FillMode {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .offline }
        return key.hasPrefix("r8_") ? .replicate : .openAI
    }

    @Published private(set) var engine: SpatialMemoryEngine
    @Published private(set) var scene: MemorySceneModel
    @Published var isImmersed = false

    @Published var pickedImage: CGImage?
    @Published var pickedData: Data?
    @Published var sceneHint: String = ""
    @Published var pickerItem: PhotosPickerItem? {
        didSet { if let pickerItem { Task { await ingest(pickerItem) } } }
    }

    private var sceneObserver: AnyCancellable?

    var canOpen: Bool { pickedImage != nil }
    var usingGenerativeFill: Bool { fillMode != .offline }

    init() {
        let engine = Self.makeEngine(apiKey: "")
        self.engine = engine
        self.scene = engine.makeScene()
        observeScene()
    }

    private static func makeEngine(apiKey: String) -> SpatialMemoryEngine {
        // `bundledCutoutOrAutomatic` only matters when the depth mesh is off —
        // with depth on, the near-field is derived from geometry and no
        // segmentation runs at all.
        let matte = MatteSourceFactory.bundledCutoutOrAutomatic(resource: "sample-cutout")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if key.isEmpty {
            return .offline(matteSource: matte)
        }

        // Replicate tokens are `r8_`-prefixed. This is the only route that sets
        // a real depth source, so it is the only one where the geometry stops
        // being a guess.
        if key.hasPrefix("r8_") {
            return .replicate(
                apiToken: key,
                matteSource: matte,
                measuredDepth: true,
                // Depth Pro can be slow to cold-start on Replicate. Log what
                // comes back — `ReplicateDepthError.colourised` means the model
                // returned a pretty preview rather than a depth raster, and the
                // console will name the keys it actually got.
                logsModelOutput: true
            )
        }

        return .hosted(apiKey: key, matteSource: matte)
    }

    /// Swapping the engine also swaps the scene model, because the pipeline is
    /// baked into it. Harmless here — the controls disable the field while the
    /// immersive space is open, so the root entity on screen never goes stale.
    private func rebuildEngine() {
        let engine = Self.makeEngine(apiKey: apiKey)
        self.engine = engine
        self.scene = engine.makeScene()
        observeScene()
    }

    /// `MemorySceneModel` is its own ObservableObject, and SwiftUI does not
    /// observe nested ones. Without this forward, `scene.phase` changes would
    /// never redraw a view that only observes `DemoState`.
    private func observeScene() {
        sceneObserver = scene.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// The bundled fallback, so the demo runs with nothing selected.
    func loadSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "jpg")
                ?? Bundle.main.url(forResource: "sample", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let cg = try? ImageDecoder.cgImage(from: data) else {
            return
        }
        pickedData = data
        pickedImage = cg
    }

    private func ingest(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let cg = try? ImageDecoder.cgImage(from: data) else { return }
        // Keep the bytes, not just the image. EXIF carries the field of view,
        // and Portrait captures carry a real depth map — both are lost if you
        // only keep the decoded pixels.
        pickedData = data
        pickedImage = cg
    }
}

// MARK: - Control window

struct DemoControls: View {

    @EnvironmentObject private var demo: DemoState
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            Text("Spatial Memory").font(.largeTitle.weight(.semibold))

            HStack(spacing: 12) {
                PhotosPicker(selection: $demo.pickerItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo")
                }
                Button("Use sample") { demo.loadSample() }
            }

            if let image = demo.pickedImage {
                Text("\(image.width) × \(image.height)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Background fill")
                    .font(.subheadline.weight(.medium))

                SecureField("r8_… for Depth Pro, sk-… for OpenAI, empty for offline",
                            text: $demo.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(demo.isImmersed)

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(demo.fillMode.title).font(.caption.weight(.medium))
                        Text(demo.fillMode.detail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: demo.fillMode.icon)
                }
                .font(.caption)
                .foregroundStyle(demo.fillMode == .offline ? .secondary : .primary)
            }

            TextField("Scene hint (optional) — \"a kitchen at dusk\"", text: $demo.sceneHint)
                .textFieldStyle(.roundedBorder)

            statusLine

            Spacer(minLength: 0)

            HStack {
                Button(demo.isImmersed ? "Close memory" : "Enter memory") {
                    Task { await toggle() }
                }
                .disabled(!demo.canOpen && !demo.isImmersed)
                .buttonStyle(.borderedProminent)

                if demo.scene.phase.isLoading { ProgressView().controlSize(.small) }
            }
        }
        .padding(28)
    }

    @ViewBuilder private var statusLine: some View {
        switch demo.scene.phase {
        case .idle:
            EmptyView()
        case .segmenting:
            Label("Estimating depth…", systemImage: "square.3.layers.3d")
                .font(.footnote)
        case .fillingBackground:
            Label(
                demo.fillMode == .offline ? "Filling the background…" : "Generating what's behind…",
                systemImage: "wand.and.stars"
            )
            .font(.footnote)
        case .building:
            Label("Building the mesh…", systemImage: "cube.transparent")
                .font(.footnote)
        case .ready:
            // What actually ran, rather than what was asked for. Every renderer
            // in here falls back silently when its hardware or its network is
            // missing, so without this the only way to tell a measured scene
            // from a guessed one is to squint at it.
            VStack(alignment: .leading, spacing: 3) {
                Label("Lean left and right.", systemImage: "checkmark.circle")

                if demo.scene.usedAppleSpatialScene == true {
                    Text("Rendered by Apple's spatial scene generator.")
                } else {
                    Text("Custom pipeline — Apple's generator can't run here.")
                    switch demo.scene.depthWasMeasured {
                    case .some(true):
                        Text("Depth: measured. Sharp boundaries.")
                    case .some(false):
                        Text("Depth: estimated from image cues — this is what "
                             + "makes silhouettes look like cut polygons.")
                    case .none:
                        EmptyView()
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle() async {
        if demo.isImmersed {
            await dismissSpace()
            demo.isImmersed = false
        } else if await openSpace(id: DemoState.immersiveSpaceID) == .opened {
            demo.isImmersed = true
        }
    }
}

// MARK: - Immersive scene
//
// This is the shape your own immersive view will take. Two lines matter.

struct DemoImmersiveScene: View {

    @EnvironmentObject private var demo: DemoState

    var body: some View {
        RealityView { content in
            content.add(demo.scene.root)                        // (1)
        }
        .task {
            guard let image = demo.pickedImage else { return }
            await demo.scene.load(                              // (2)
                image: image,
                sourceData: demo.pickedData,
                prompt: InpaintingPrompt.continuation(
                    sceneHint: demo.sceneHint.isEmpty ? nil : demo.sceneHint
                )
            )
        }
        .onDisappear { demo.scene.tearDown() }                  // (3)
    }
}

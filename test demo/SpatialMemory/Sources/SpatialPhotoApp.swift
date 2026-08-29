//
//  SpatialPhotoApp.swift
//  SpatialPhoto — an iPhone photo, made spatial by Apple, with a voice in it
//
//  ============================================================================
//  THE WHOLE APP. Three files: this, AppleSpatialScene.swift, Narration.swift.
//
//  Pick a photo → Apple's own generator turns it into a spatial scene with real
//  depth and parallax → a recorded narration plays from where the photo is.
//
//  THE ONE THING THAT WILL BITE YOU
//
//  `Spatial3DImage.generate()` THROWS IN THE SIMULATOR. It runs on the Neural
//  Engine, and the Simulator has none. There is no fallback in this build by
//  design, so on a Simulator this app will show you an error and nothing else.
//  It needs real Apple Vision Pro hardware. The error text says so out loud
//  rather than leaving you staring at an empty space wondering.
//  ============================================================================
//
//  Targets: Swift 5.10+, visionOS 26.0+
//

import Combine
import CoreGraphics
import Foundation
import PhotosUI
import RealityKit
import SwiftUI

// MARK: - App

@main
struct SpatialPhotoApp: App {

    @StateObject private var memory = MemoryState()

    // `SwiftUI.Scene` spelled out: RealityKit declares a `Scene` too, and with
    // both imported a bare `some Scene` is ambiguous.
    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlPanel().environmentObject(memory)
        }
        .defaultSize(width: 460, height: 500)

        ImmersiveSpace(id: MemoryState.spaceID) {
            MemorySpace().environmentObject(memory)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

// MARK: - State

@MainActor
final class MemoryState: ObservableObject {

    static let spaceID = "spatial-photo"

    @Published var photoData: Data?
    @Published var photoSize: CGSize?
    @Published var isImmersed = false
    @Published var status: Status = .idle

    @Published var pickerItem: PhotosPickerItem? {
        didSet { if let pickerItem { Task { await ingest(pickerItem) } } }
    }

    let recorder = NarrationRecorder()

    /// The scene lives here so the immersive view can attach it synchronously
    /// and fill it in later — `RealityViewContent` is only valid inside its own
    /// closures, so an async generate() finishing seconds later needs somewhere
    /// stable to land.
    let root = Entity()

    private var narration: AudioPlaybackController?
    private var recorderObserver: AnyCancellable?

    enum Status: Equatable {
        case idle
        case generating
        case ready
        case failed(String)

        var isWorking: Bool { self == .generating }
    }

    var canEnter: Bool { photoData != nil }

    init() {
        root.name = "SpatialPhotoRoot"
        // NarrationRecorder is its own ObservableObject and SwiftUI does not
        // observe nested ones; without this forward the record button never
        // redraws.
        recorderObserver = recorder.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func ingest(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            status = .failed("That photo could not be read.")
            return
        }
        // Keep the BYTES, not a decoded image. Spatial3DImage reads the file —
        // its metadata included — and a re-encoded raster throws that away.
        photoData = data
        photoSize = Self.pixelSize(of: data)
        status = .idle
    }

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGSize(width: w, height: h)
    }

    // MARK: Building the memory

    func build() async {
        guard let data = photoData else { return }
        teardown()
        status = .generating

        guard #available(visionOS 26.0, *) else {
            status = .failed("Spatial scenes need visionOS 26 or later.")
            return
        }

        do {
            // Generation takes a few seconds and runs on the Neural Engine.
            let scene = try await AppleSpatialScene.makeEntity(from: data)
            root.addChild(scene)

            // The voice goes on the scene itself, so it is spatialised from
            // where the photograph is rather than from nowhere.
            if recorder.hasRecording {
                narration = try? await Narration.attach(
                    fileURL: recorder.fileURL,
                    to: scene
                )
            }

            status = .ready

        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func teardown() {
        narration?.stop()
        narration = nil
        root.children.removeAll()
        if status != .idle { status = .idle }
    }
}

// MARK: - Control panel

struct ControlPanel: View {

    @EnvironmentObject private var memory: MemoryState
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            VStack(alignment: .leading, spacing: 4) {
                Text("Spatial Photo").font(.largeTitle.weight(.semibold))
                Text("An iPhone photo, made spatial, with your voice in it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 1 — the picture
            VStack(alignment: .leading, spacing: 6) {
                Label("Photo", systemImage: "photo").font(.subheadline.weight(.medium))
                PhotosPicker(selection: $memory.pickerItem, matching: .images) {
                    Text(memory.photoData == nil ? "Choose a photo" : "Choose a different photo")
                }
                if let size = memory.photoSize {
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 2 — the voice
            VStack(alignment: .leading, spacing: 6) {
                Label("Narration", systemImage: "mic").font(.subheadline.weight(.medium))
                HStack(spacing: 12) {
                    Button {
                        memory.recorder.toggle()
                    } label: {
                        Label(
                            memory.recorder.isRecording ? "Stop recording" : "Record narration",
                            systemImage: memory.recorder.isRecording ? "stop.circle.fill" : "record.circle"
                        )
                    }
                    .tint(memory.recorder.isRecording ? .red : nil)
                    .disabled(memory.isImmersed)

                    if memory.recorder.hasRecording && !memory.recorder.isRecording {
                        Label("Recorded", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = memory.recorder.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(memory.isImmersed
                     ? "Leave the memory to record — the narration is attached "
                     + "when the scene is built, so it has to exist first."
                     : "Optional. Tell the story of the photograph — it plays "
                     + "from where the picture is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusLine

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(memory.isImmersed ? "Leave" : "Enter memory") {
                    Task { await toggle() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!memory.canEnter && !memory.isImmersed)

                if memory.status.isWorking { ProgressView().controlSize(.small) }
            }
        }
        .padding(28)
    }

    @ViewBuilder private var statusLine: some View {
        switch memory.status {
        case .idle:
            EmptyView()
        case .generating:
            Label("Generating the spatial scene…", systemImage: "sparkles")
                .font(.footnote)
        case .ready:
            Label("Lean in and look around.", systemImage: "checkmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                // Apple does not document what the Spatial3DImageError codes
                // mean, so this says "almost certainly" rather than asserting a
                // cause it cannot actually know. It also names the other
                // possibility, because a message that is confidently wrong wastes
                // more time than one that is honestly uncertain.
                Text("Almost certainly the Simulator — generation runs on the "
                     + "Neural Engine, which the Simulator does not have. On "
                     + "device, the other cause is the photo itself: it needs "
                     + "320 px or more on the short side, 16,384 or fewer on the "
                     + "long side, and an aspect ratio within 3:1.")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle() async {
        if memory.isImmersed {
            await dismissSpace()
            memory.isImmersed = false
        } else if await openSpace(id: MemoryState.spaceID) == .opened {
            memory.isImmersed = true
        }
    }
}

// MARK: - The immersive space

struct MemorySpace: View {

    @EnvironmentObject private var memory: MemoryState

    var body: some View {
        RealityView { content in
            // Synchronous and instant, so the space opens now and fills in when
            // generation finishes.
            content.add(memory.root)
        }
        .task {
            // `.task` inherits the view's lifetime, so closing the space cancels
            // generation instead of leaving it running.
            await memory.build()
        }
        .onDisappear { memory.teardown() }
    }
}

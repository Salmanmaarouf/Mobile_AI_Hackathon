//
//  Narration.swift
//  SpatialPhoto — recording a voice, and placing it in the scene
//
//  Two halves:
//
//    NarrationRecorder   captures a voice memo to a file in the app's own
//                        container. A family member telling the story of the
//                        photograph, which for reminiscence work is the part
//                        that carries the memory — the picture is the prompt.
//
//    Narration.attach    hands that file to RealityKit as a SPATIAL source
//                        anchored to the photo, so the voice comes from the
//                        picture rather than from inside the listener's head.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import AVFoundation
import Combine
import Foundation
import RealityKit
import simd

// MARK: - Placing the voice

@MainActor
public enum Narration {

    /// Anchors a narration file to `host` and starts it.
    ///
    /// The emitter is a dedicated child rather than the host itself, for a
    /// reason worth an hour of anyone's time: **RealityKit projects spatial
    /// audio along an entity's own negative z-axis.** A spatial scene faces the
    /// viewer along +Z, so an emitter placed directly on it beams the voice away
    /// from the listener the moment directivity is anything but omnidirectional.
    /// Rotating the child 180° about Y turns it around.
    ///
    /// - Parameter offset: metres relative to the host, so the voice can come
    ///   from where the person in the photograph actually is.
    @discardableResult
    public static func attach(
        fileURL: URL,
        to host: Entity,
        gain: Double = 0,
        directivityFocus: Double = 0.25,
        rolloffFactor: Double = 1.4,
        offset: SIMD3<Float> = .zero,
        loop: Bool = false
    ) async throws -> AudioPlaybackController {

        let resource = try await AudioFileResource(
            contentsOf: fileURL,
            // Must be unique per resource, and a re-recording reuses the same
            // path — so the name carries the modification date rather than the
            // filename, which would collide and hand back the old audio.
            withName: "narration.\(fileURL.lastPathComponent).\(Date().timeIntervalSince1970)",
            configuration: .init(shouldLoop: loop)
        )
        return play(resource, on: host, gain: gain,
                    directivityFocus: directivityFocus,
                    rolloffFactor: rolloffFactor, offset: offset)
    }

    /// The same, for a narration shipped in the bundle.
    @discardableResult
    public static func attach(
        bundled name: String,
        in bundle: Bundle? = nil,
        to host: Entity,
        gain: Double = 0,
        directivityFocus: Double = 0.25,
        rolloffFactor: Double = 1.4,
        offset: SIMD3<Float> = .zero,
        loop: Bool = false
    ) async throws -> AudioPlaybackController {

        let resource = try await AudioFileResource(
            named: name,
            in: bundle,
            configuration: .init(shouldLoop: loop)
        )
        return play(resource, on: host, gain: gain,
                    directivityFocus: directivityFocus,
                    rolloffFactor: rolloffFactor, offset: offset)
    }

    private static func play(
        _ resource: AudioFileResource,
        on host: Entity,
        gain: Double,
        directivityFocus: Double,
        rolloffFactor: Double,
        offset: SIMD3<Float>
    ) -> AudioPlaybackController {

        let emitter = Entity()
        emitter.name = "NarrationEmitter"
        emitter.position = offset
        emitter.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])

        // Constructed with `gain:` then configured by property. The full
        // memberwise initializer that also takes directivity and attenuation is
        // visionOS 2.0+; this two-step form compiles against 1.0.
        var spatial = SpatialAudioComponent(gain: gain)
        // Gentle focus. A voice beamed too tightly disappears the moment someone
        // turns their head, which is the opposite of what narration is for.
        spatial.directivity = .beam(focus: directivityFocus)
        // Softer than inverse-square: speech should stay intelligible across a
        // room, not fall off like a point source.
        spatial.distanceAttenuation = .rolloff(factor: rolloffFactor)
        emitter.components.set(spatial)

        host.addChild(emitter)

        let controller = emitter.prepareAudio(resource)
        controller.play()
        return controller
    }
}

// MARK: - Capturing the voice

@MainActor
public final class NarrationRecorder: NSObject, ObservableObject {

    @Published public private(set) var isRecording = false
    @Published public private(set) var hasRecording = false
    @Published public private(set) var lastError: String?

    /// Where the take lives. One fixed path — a re-record replaces it.
    public let fileURL: URL

    private var recorder: AVAudioRecorder?

    public override init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // .m4a / AAC: RealityKit reads it, and it is a fraction of the size of
        // the equivalent WAV, which matters when the take is a few minutes of
        // someone talking.
        self.fileURL = directory.appendingPathComponent("narration.m4a")
        super.init()
        self.hasRecording = FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func toggle() {
        isRecording ? stop() : start()
    }

    public func start() {
        lastError = nil

        // Requires NSMicrophoneUsageDescription in Info.plist. Without it the
        // app is terminated rather than refused, which looks like a crash.
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.lastError = "Microphone access was denied. Settings › Privacy › Microphone."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio)
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                // MONO, deliberately. Spatial audio sources are single-channel;
                // the engine downmixes anything else before spatialising, and a
                // stereo take smears rather than localises.
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            guard recorder.record() else {
                lastError = "The recorder refused to start."
                return
            }
            self.recorder = recorder
            isRecording = true

        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        hasRecording = FileManager.default.fileExists(atPath: fileURL.path)

        // Hand the session back so playback is not stuck in a record category.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension NarrationRecorder: AVAudioRecorderDelegate {
    nonisolated public func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.hasRecording = flag && FileManager.default.fileExists(atPath: self.fileURL.path)
        }
    }
}

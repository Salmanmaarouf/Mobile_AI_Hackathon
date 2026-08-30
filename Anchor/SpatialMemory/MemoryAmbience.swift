//
//  MemoryAmbience.swift
//  SpatialMemory — the room around the picture, and the sound in it
//
//  ============================================================================
//  Apple's Spatial3DImage solves the hard visual problem — depth, parallax,
//  what is behind the subject — better than anything hand-rolled, because it is
//  the same model Photos uses. What it hands back is one Entity presenting a
//  scene. It does not bring a soundscape, and it does not care what the rest of
//  the room looks like.
//
//  Those two things are what turn a very good spatial photo into a memory
//  someone is standing inside, and they are cheap. This file adds them to ANY
//  entity — Apple's or ours — without either renderer knowing about the other.
//
//  Deliberately standalone: it imports nothing from MemoryContainer and nothing
//  imports it back except one call site. If it fails to build, delete it from
//  the target and everything else is exactly as it was.
//  ============================================================================
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import Foundation
import RealityKit
import simd

#if canImport(UIKit)
// `UnlitMaterial.BaseColor(tint:texture:)` takes a UIColor on visionOS, and
// this project builds with SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY —
// so `.white` needs UIKit imported HERE. RealityKit re-exporting it is no
// longer enough.
import UIKit
#endif

@MainActor
public enum MemoryAmbience {

    // MARK: - Sound

    /// Anchors a looping spatial audio source to `host`.
    ///
    /// The emitter is a dedicated child, not the host itself, for a reason that
    /// costs an hour to find otherwise: **RealityKit projects spatial audio
    /// along an entity's own negative z-axis.** Apple's spatial scene and our
    /// depth mesh both face the viewer along +Z, so an emitter placed directly
    /// on either one beams its sound away from the listener the moment
    /// directivity is anything but omnidirectional. Rotating the child 180°
    /// about Y turns it around.
    ///
    /// It also means the sound can come from where the subject actually is
    /// rather than from the geometric centre of the scene — pass `offset` in
    /// metres relative to the host.
    ///
    /// - Parameter resourceName: a file in the bundle. Mono sources are best;
    ///   spatial audio is single-channel and the engine downmixes anything
    ///   else before spatialising, which can smear a stereo recording.
    @discardableResult
    public static func attachSpatialAudio(
        named resourceName: String,
        to host: Entity,
        in bundle: Bundle? = nil,
        gain: Double = -6,
        directivityFocus: Double = 0.35,
        rolloffFactor: Double = 2,
        offset: SIMD3<Float> = .zero,
        loop: Bool = true
    ) async throws -> AudioPlaybackController {

        let emitter = Entity()
        emitter.name = "MemoryAudioEmitter"
        emitter.position = offset
        emitter.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])

        // Constructed with `gain:` and configured by property. The full
        // memberwise initializer that also takes directivity and attenuation is
        // visionOS 2.0+; this two-step form compiles against 1.0.
        var spatial = SpatialAudioComponent(gain: gain)
        spatial.directivity = .beam(focus: directivityFocus)
        // Rolloff 2 approximates inverse-square: roughly −6 dB per doubling of
        // distance. Leaning toward the memory gets audibly, correctly louder.
        spatial.distanceAttenuation = .rolloff(factor: rolloffFactor)
        emitter.components.set(spatial)

        host.addChild(emitter)

        let resource = try await AudioFileResource(
            named: resourceName,
            in: bundle,
            configuration: .init(shouldLoop: loop)
        )

        // prepareAudio returns a controller without starting, so a caller can
        // fade in or gate playback on the visuals settling.
        let controller = emitter.prepareAudio(resource)
        controller.play()
        return controller
    }

    // MARK: - Room

    /// A large enclosing sphere washed with a darkened blur of the photograph.
    ///
    /// Whether this is worth adding depends on the renderer in front of it.
    /// Apple's `.spatial3DImmersive` mode already extends its own presentation
    /// outward, so this mostly fills whatever black is left at the edges of
    /// vision. Our own backdrop stops at the photograph's field of view — about
    /// 63° against a headset's 100°+ — and without this the remaining 40° is
    /// black, which is most of why a reconstruction reads as a picture in a void
    /// rather than as a place.
    ///
    /// - Parameter radius: metres. Keep it well outside every other layer.
    /// - Parameter level: brightness multiplier. Above roughly 0.5 it stops
    ///   being ambience and starts competing with the photograph.
    public static func ambientSphere(
        from image: CGImage,
        radius: Float = 14,
        level: CGFloat = 0.42
    ) async throws -> ModelEntity {

        // overscan 1.0: we only want the `ambient` output, not the padded
        // backdrop or the vignette, so skip the padding work entirely.
        let textures = try BackdropTextures.make(
            from: image,
            overscan: 1.0,
            ambientLevel: level
        )

        let texture = try await TextureFactory.make(
            textures.ambient,
            name: "memory.ambience.\(UUID().uuidString)",
            semantic: .color
        )

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .opaque

        let sphere = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [material]
        )
        sphere.name = "MemoryAmbientSurround"
        // generateSphere winds its triangles for a viewer outside it, and we are
        // inside. Mirroring on X reverses the winding so the inner surface
        // becomes front-facing. It mirrors the texture too — invisible on a
        // 128 px wash stretched across a 14 m sphere.
        sphere.scale = [-1, 1, 1]
        return sphere
    }
}

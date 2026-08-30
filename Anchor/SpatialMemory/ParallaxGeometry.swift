//
//  ParallaxGeometry.swift
//  SpatialMemory — PHASE 3a: The coordinate math
//
//  Everything here is expressed in RealityKit's world space for a `.full`
//  ImmersiveSpace, which is right-handed:
//
//        +Y  up
//         |
//         |
//         *───── +X  right
//        /
//       /
//     +Z  toward the viewer's face
//
//  The viewer's head starts at the origin looking down −Z. Both layers live at
//  negative Z. Distances in this file are stored as POSITIVE magnitudes and
//  negated only when a position is emitted, because signed-distance arithmetic
//  is where parallax code usually goes wrong.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import Foundation
import RealityKit
import simd

// MARK: - Layout

public struct ParallaxLayout: Sendable {

    /// Horizontal field of view the original photograph subtends, in radians.
    /// Recover it from EXIF where possible; 63° (≈ a 28 mm-equivalent phone
    /// main camera) is a defensible default when the tag is missing.
    public let horizontalFOV: Float

    /// Source frame aspect: width / height.
    public let aspect: Float

    /// Distance from the viewer to the background layer, in metres. Positive.
    public let backgroundDistance: Float

    /// Distance from the viewer to the foreground layer, in metres. Positive,
    /// and strictly less than `backgroundDistance`.
    public let foregroundDistance: Float

    public init(
        horizontalFOV: Float = 63.0 * .pi / 180.0,
        aspect: Float,
        backgroundDistance: Float = 5.0,
        foregroundDistance: Float = 1.5
    ) {
        precondition(aspect > 0, "aspect must be positive")
        precondition(horizontalFOV > 0 && horizontalFOV < .pi, "FOV must be in (0, π)")
        precondition(foregroundDistance > 0, "foreground must be in front of the viewer")
        precondition(
            foregroundDistance < backgroundDistance,
            "the foreground layer must sit closer than the background layer"
        )
        self.horizontalFOV = horizontalFOV
        self.aspect = aspect
        self.backgroundDistance = backgroundDistance
        self.foregroundDistance = foregroundDistance
    }

    // MARK: Field of view

    /// Vertical FOV of a rectilinear frame.
    ///
    ///     half-width  at unit distance = tan(θ_h / 2)
    ///     half-height at unit distance = tan(θ_h / 2) / aspect
    ///     θ_v = 2 · atan( tan(θ_h / 2) / aspect )
    ///
    /// Note this is NOT `θ_h / aspect` — the tangent makes the relationship
    /// non-linear, and the linear approximation is visibly wrong past ~50°.
    public var verticalFOV: Float {
        2 * atan(tan(horizontalFOV / 2) / aspect)
    }

    /// Half-extents of the view frustum at unit distance. Multiply by any
    /// distance to get the frustum's cross-section there.
    public var halfExtentsAtUnitDistance: SIMD2<Float> {
        let hx = tan(horizontalFOV / 2)
        return SIMD2(hx, hx / aspect)
    }

    // MARK: Layer sizes

    /// Metres wide and tall the background must be at `backgroundDistance` to
    /// exactly fill the photo's frustum.
    ///
    ///     W_bg = 2 · D_bg · tan(θ_h / 2)
    ///     H_bg = W_bg / aspect
    ///
    /// Worked example — θ_h = 63°, aspect = 4:3, D_bg = 5 m:
    ///     tan(31.5°) = 0.6128
    ///     W_bg = 2 · 5 · 0.6128 = 6.128 m
    ///     H_bg = 6.128 / 1.3333 = 4.596 m
    public var backgroundSize: SIMD2<Float> {
        halfExtentsAtUnitDistance * 2 * backgroundDistance
    }

    /// **The similar-triangles ratio.** `D_fg / D_bg`.
    ///
    /// With the brief's numbers: 1.5 / 5.0 = 0.3.
    public var scaleRatio: Float {
        foregroundDistance / backgroundDistance
    }

    /// Metres wide and tall the foreground plane must be so that, viewed from
    /// the origin, it covers exactly the same solid angle as the background.
    ///
    ///     W_fg = W_bg · (D_fg / D_bg)
    ///     H_fg = H_bg · (D_fg / D_bg)
    ///
    /// Continuing the worked example:
    ///     W_fg = 6.128 · 0.3 = 1.8384 m
    ///     H_fg = 4.596 · 0.3 = 1.3788 m
    ///
    /// Proof that this is exact rather than approximate. A pinhole at the origin
    /// looking down −Z projects a world point p onto the normalized image plane
    /// as (p.x / −p.z, p.y / −p.z). Take a foreground point f = (x, y, −D_fg)
    /// and a background point b = (X, Y, −D_bg). They land on the same pixel iff
    ///
    ///     x / D_fg = X / D_bg   and   y / D_fg = Y / D_bg
    ///     ⇒ x = X · (D_fg / D_bg),  y = Y · (D_fg / D_bg)
    ///
    /// So the entire foreground plane is the background plane scaled about the
    /// origin by D_fg / D_bg. Uniform scale, no offset, no per-pixel term.
    public var foregroundSize: SIMD2<Float> {
        backgroundSize * scaleRatio
    }

    // MARK: Layer transforms

    public var backgroundPosition: SIMD3<Float> { [0, 0, -backgroundDistance] }
    public var foregroundPosition: SIMD3<Float> { [0, 0, -foregroundDistance] }

    // MARK: Parallax characterisation

    /// How far the two layers pull apart, measured in metres **on the
    /// background plane**, when the viewer's head translates sideways by
    /// `headOffset`.
    ///
    /// Derivation. Put the head at (h, 0, 0). A foreground point at
    /// (0, 0, −D_fg) and a background point at (0, 0, −D_bg) coincided on screen
    /// when the head was at the origin. From the new position their angular
    /// offsets from straight ahead are, to first order,
    ///
    ///     α_fg = −h / D_fg        α_bg = −h / D_bg
    ///
    /// so the angular separation is
    ///
    ///     Δθ = h · (1/D_fg − 1/D_bg) = h · (D_bg − D_fg) / (D_fg · D_bg)
    ///
    /// Projecting that angle onto the background plane (multiply by D_bg):
    ///
    ///     Δ = h · (D_bg − D_fg) / D_fg = h · (D_bg / D_fg − 1)
    ///
    /// The bracketed term is the **parallax gain**. With D_bg = 5, D_fg = 1.5 it
    /// is 2.333, so a 6 cm head shift separates the layers by 14 cm — well above
    /// the perceptual threshold for depth, and the single number to tune if the
    /// effect feels flat (raise it) or gimmicky (lower it).
    public func apparentSeparation(forHeadOffset headOffset: Float) -> Float {
        headOffset * parallaxGain
    }

    /// `D_bg / D_fg − 1`. See `apparentSeparation(forHeadOffset:)`.
    public var parallaxGain: Float {
        backgroundDistance / foregroundDistance - 1
    }

    /// Inverse of `apparentSeparation`: the head excursion at which the layers
    /// separate by `fraction` of the backdrop's width.
    ///
    /// Past roughly 0.08 the flat foreground starts reading as cardboard,
    /// because a real subject would be revealing its own side geometry by then.
    /// A good hook for fading in a vignette or easing the foreground back.
    public func headExcursion(forSeparationFraction fraction: Float) -> Float {
        (backgroundSize.x * fraction) / max(parallaxGain, .leastNormalMagnitude)
    }
}

// MARK: - Backdrop mesh

public enum BackdropGeometry {

    /// How the photograph is wrapped onto the curved backdrop.
    public enum UVProjection: Sendable {
        /// **Perspective-exact.** The patch is walked in the photograph's own
        /// image plane and each sample is pushed out onto the sphere, so from
        /// the origin the curved surface is pixel-for-pixel indistinguishable
        /// from a flat plane, while every point on it sits at the same radius.
        /// Use this for ordinary rectilinear photographs.
        case rectilinear
        /// Latitude/longitude wrap. Correct only if the texture is already an
        /// equirectangular panorama; applying it to a normal photo stretches
        /// the corners.
        case equirectangular
    }

    /// Builds a curved backdrop: a patch of a sphere of radius
    /// `layout.backgroundDistance`, centred on −Z, covering the photograph's
    /// frustum, with inward-facing winding and normals.
    ///
    /// **The parametrization is in image space, not in yaw/pitch, and that is
    /// deliberate.** The obvious approach — sweep yaw across the horizontal FOV
    /// and pitch across the vertical FOV, then re-project each direction to get
    /// its UV — does not close. Reprojecting a lat/long vertex gives
    ///
    ///     ndc.y = tan(pitch) / (cos(yaw) · tan(θ_v / 2))
    ///
    /// The `cos(yaw)` denominator means the vertical edge only lands on the
    /// frame boundary at yaw = 0. At the corners of a 63° × 49° frame it
    /// overshoots by about 17 %, so the mesh's corners fall outside the
    /// photograph and sample clamped edge pixels even at overscan 1.0.
    ///
    /// Walking the image plane instead and normalizing the resulting ray onto
    /// the sphere inverts the problem away: the UV is the grid coordinate, exact
    /// by construction, and the surface still sits at constant radius so
    /// parallax gain is uniform across the whole backdrop.
    ///
    /// - Parameters:
    ///   - overscan: extends the patch past the photograph's frustum so head
    ///     movement does not immediately expose the rim. The extra band samples
    ///     the frame's edge pixels. 1.15 is a good starting point; 1.0 makes the
    ///     mesh boundary exactly the photo boundary.
    @MainActor
    public static func curvedBackdrop(
        layout: ParallaxLayout,
        projection: UVProjection = .rectilinear,
        overscan: Float = 1.15,
        segmentsU: Int = 96,
        segmentsV: Int = 72
    ) throws -> MeshResource {

        let radius = layout.backgroundDistance

        // Half-extents of the photograph's frustum at unit depth.
        let tanH = tan(layout.horizontalFOV / 2)
        let tanV = tan(layout.verticalFOV / 2)

        // Angular sweep, used only by the equirectangular branch.
        let hFOV = min(layout.horizontalFOV * overscan, .pi * 0.98)
        let vFOV = min(layout.verticalFOV * overscan, .pi * 0.98)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        let vertexCount = (segmentsU + 1) * (segmentsV + 1)
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        uvs.reserveCapacity(vertexCount)

        for j in 0...segmentsV {
            // Grid coordinate: 0 at the TOP of the patch, 1 at the bottom.
            // That matches the top-left texture origin an image gets on a
            // RealityKit-generated mesh, so no vertical flip is needed anywhere.
            let tv = Float(j) / Float(segmentsV)

            for i in 0...segmentsU {
                let tu = Float(i) / Float(segmentsU)

                let dir: SIMD3<Float>
                let uv: SIMD2<Float>

                switch projection {
                case .rectilinear:
                    // Normalized device coordinates on the photo's image plane.
                    // ±1 is the frame edge; overscan pushes past it.
                    let ndcX = (tu - 0.5) * 2 * overscan          // −ov … +ov, left → right
                    let ndcY = (0.5 - tv) * 2 * overscan          // +ov … −ov, top → bottom

                    // Ray through that image-plane point, from the pinhole at
                    // the origin. z = −1 is the "one metre ahead" plane; scaling
                    // it is what the normalize below undoes.
                    let ray = SIMD3<Float>(ndcX * tanH, ndcY * tanV, -1)

                    // Normalizing puts the vertex on the sphere. Every vertex is
                    // therefore exactly `radius` from the viewer — the property
                    // a flat plane does not have and the reason to curve at all.
                    dir = simd_normalize(ray)

                    // The backdrop texture is PRE-PADDED to exactly `overscan`
                    // times the photo by BackdropTextures.make, so the patch
                    // maps onto it 1:1 and needs no clamping. That is what lets
                    // the soft rim in its companion opacity texture actually
                    // reach the edge of the mesh instead of being frozen by a
                    // clamped UV.
                    //
                    // v is FLIPPED. RealityKit's generated meshes put v = 0 at
                    // the bottom of the image, not the top. The earlier
                    // top-left assumption is what rendered the backdrop upside
                    // down while the generatePlane foreground stayed upright.
                    uv = SIMD2(tu, 1 - tv)

                case .equirectangular:
                    // Latitude/longitude sweep. Correct only when the texture is
                    // already an equirectangular panorama.
                    let yaw = (tu - 0.5) * hFOV
                    let pitch = (0.5 - tv) * vFOV
                    dir = SIMD3<Float>(
                        sin(yaw) * cos(pitch),
                        sin(pitch),
                        -cos(yaw) * cos(pitch)
                    )
                    uv = SIMD2(tu, 1 - tv)   // same bottom-left origin as above
                }

                positions.append(dir * radius)
                // Inward-facing: the normal points back at the viewer, opposite
                // the outward radial direction. UnlitMaterial ignores normals,
                // but a lit material swapped in later will not.
                normals.append(-dir)
                uvs.append(uv)
            }
        }

        // ------------------------------------------------------------------
        // Index buffer.
        //
        // For the quad whose corners are, AS THE VIEWER SEES THEM:
        //     a = upper-left   b = upper-right
        //     c = lower-left   d = lower-right
        //
        // RealityKit front-faces are counter-clockwise in screen space. Check
        // triangle (a, c, b) with a = (−1, 1), c = (−1, −1), b = (1, 1):
        //     (c − a) = ( 0, −2),  (b − c) = (2, 2)
        //     cross_z = 0·2 − (−2)·2 = +4  > 0  ⇒ counter-clockwise ✓
        // and (b, c, d) with b = (1, 1), c = (−1, −1), d = (1, −1):
        //     (c − b) = (−2, −2), (d − c) = (2, 0)
        //     cross_z = (−2)·0 − (−2)·2 = +4 > 0 ⇒ counter-clockwise ✓
        //
        // So the winding below is front-facing from INSIDE the sphere, which is
        // where the viewer is. Get this backwards and the backdrop is invisible
        // while the debug hierarchy insists it is there — the classic
        // "my skybox renders as nothing" bug.
        // ------------------------------------------------------------------
        var indices: [UInt32] = []
        indices.reserveCapacity(segmentsU * segmentsV * 6)
        let stride = segmentsU + 1

        for j in 0..<segmentsV {
            for i in 0..<segmentsU {
                let a = UInt32(j * stride + i)
                let b = a + 1
                let c = a + UInt32(stride)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        var descriptor = MeshDescriptor(name: "SpatialMemoryBackdrop")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }

    /// The flat alternative: a plane sized to fill the frustum at
    /// `layout.backgroundDistance`.
    ///
    /// From a stationary origin this is indistinguishable from the curved
    /// backdrop — both reconstruct the photograph exactly, and projecting either
    /// through the pinhole gives identical image coordinates. The difference
    /// only shows up once the head moves, and it is worth knowing which way it
    /// cuts, because the intuitive answer is the wrong one.
    ///
    /// A flat plane's off-axis points are farther away than its centre by the
    /// secant factor `k = √(1 + (ndc.x·tanθ_h/2)² + (ndc.y·tanθ_v/2)²)` — at the
    /// corner of a 63° × 49° frame, `k ≈ 1.26`. Crucially the **foreground is
    /// also a flat plane**, so it stretches by the same `k`, the ratio
    /// `D_bg / D_fg` is unchanged, and parallax gain is *constant across the
    /// whole frame*:
    ///
    ///                        flat bg    curved bg
    ///     centre              2.333       2.333
    ///     horizontal edge     2.333       1.842
    ///     corner              2.333       1.646     (71 % of centre)
    ///
    /// The curved backdrop holds every background point at a fixed radius, so
    /// against a flat foreground its gain falls off toward the corners. In
    /// practice that reads as the periphery being slightly "stiffer" than the
    /// centre — subtle at 63°, and largely hidden by overscan, but real.
    ///
    /// So: **flat** for uniform parallax and the cheapest possible draw (two
    /// triangles), and it is the more faithful model for interior scenes, where
    /// the thing behind the subject genuinely is a wall. **Curved** for a
    /// horizon/dome feel, for wide-FOV sources where a flat plane's corners run
    /// away, and because a fixed-radius backdrop never clips the rim as the head
    /// turns. Pairing a curved backdrop with a curved foreground restores
    /// uniform gain if you need both.
    @MainActor
    public static func flatBackdrop(layout: ParallaxLayout) throws -> MeshResource {
        let size = layout.backgroundSize
        // generatePlane builds in the xy-plane with its normal along +Z, and
        // maps the texture with a top-left origin — the same convention the
        // curved mesh above uses. No flip, no rotation.
        return MeshResource.generatePlane(width: size.x, height: size.y)
    }
}

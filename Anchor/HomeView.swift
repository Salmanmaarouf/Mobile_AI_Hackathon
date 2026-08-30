import SwiftUI
import RealityKit
import UIKit

struct HomeView: View {
    @State private var memories: [Memory] = Memory.sample
    @State private var selectedMemory: Memory = Memory.sample[0]
    @State private var sessionLength: Int = 15
    @State private var isLibraryExpanded = true
    @State private var isPulsing = false

    @State private var isOverlayVisible = true
    @State private var hideTask: Task<Void, Never>?

    private let idleTimeout: Duration = .seconds(60)

    /// Orb size as a fraction of window height, so it scales with everything
    /// else (background, panels) when the user resizes the app window,
    /// instead of staying visually fixed while its surroundings scale.
    private let orbSizeRatio: CGFloat = 260.0 / 950.0

    var body: some View {
        GeometryReader { proxy in
            let orbSize = proxy.size.height * orbSizeRatio
            let orbScale: CGFloat = isPulsing ? 1.02 : 0.99
            let orbOffsetY = orbSize * (isPulsing ? -0.119 : -0.069)

            ZStack {
                backgroundScene(size: proxy.size)
                    .contentShape(Rectangle())
                    .onTapGesture { wakeOverlay() }

                // MARK: - 3D Center Orb
                // Lives in the background layer (not HomeOverlay) so it never
                // fades on idle — it's the scene's content, not a control.
                // Sized off proxy.size so it scales with window resizing,
                // the same way the background and panels already do.
                GlowingOrb3DView()
                    .frame(width: orbSize, height: orbSize)
                    .scaleEffect(orbScale)
                    .offset(y: orbOffsetY)
                    .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear {
                        isPulsing = true
                    }
                    .allowsHitTesting(false)

                // MARK: - Selected-memory preview
                // The orb is a literal 3D sphere (~0.107m radius) that
                // physically bulges toward the viewer past the window's flat
                // plane — a 2D SwiftUI view sitting at that plane only wins
                // where the sphere's surface curves away (the rim), never at
                // its closest point (the center). A large forward z-offset
                // (clearing ~0.107m, not a token few points) is what's
                // actually needed to sit the preview in front of the whole
                // sphere, not just a paint-order or sizing change.
                OrbMemoryPreview(memory: selectedMemory, size: orbSize * 0.92)
                    .scaleEffect(orbScale)
                    .offset(y: orbOffsetY)
                    .offset(z: 180)
                    .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: isPulsing)
                    .allowsHitTesting(false)

                HomeOverlay(
                    memories: memories,
                    selectedMemory: $selectedMemory,
                    sessionLength: $sessionLength,
                    isLibraryExpanded: $isLibraryExpanded
                )
                // Pinned to the same explicit size as backgroundScene above,
                // rather than letting Spacer-driven sizing resolve on its
                // own — at larger window sizes the two could independently
                // settle on different heights, pushing the greeting/control
                // bar outside the (correctly sized) background's bounds.
                .frame(width: proxy.size.width, height: proxy.size.height)
                .offset(z: 28) // Real spatial depth: floats in front of the background plane.
                .opacity(isOverlayVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: isOverlayVisible)
                .allowsHitTesting(isOverlayVisible)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0).onChanged { _ in wakeOverlay() }
                )
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        .task { wakeOverlay() }
        .onDisappear { hideTask?.cancel() }
        .onAppear {
            AudioManager.shared.playAmbient(volume: 0.85)
        }
    }

    private func wakeOverlay() {
        isOverlayVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            isOverlayVisible = false
        }
    }

    private func backgroundScene(size: CGSize) -> some View {
        // Water ripple (WaterRipple.metal, distortionEffect) cancelled for
        // now — didn't read right. Shader stays in the project, just unused.
        Image("background_scaled")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
            .ignoresSafeArea()
    }
}

// MARK: - Upgraded 3D RealityKit Orb Component
struct GlowingOrb3DView: View {
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            // A faint ambient presence rather than a dominant halo — the orb
            // should read as solid (moon-like), not a glowing sun.
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 1.0, green: 0.6, blue: 0.3).opacity(0.14),
                    Color(red: 0.6, green: 0.4, blue: 0.9).opacity(0.06),
                    Color.clear
                ]),
                center: .center,
                startRadius: 20,
                endRadius: 125
            )
            .blur(radius: 10)

            RealityView { content in
                let rootEntity = Entity()

                // Core Layer — solid and opaque (UnlitMaterial: shows the
                // baked texture exactly as authored, unaffected by scene
                // lighting). A vivid, high-contrast gradient is the whole
                // visual now, so it needs to pop rather than wash out.
                let coreMesh = MeshResource.generateSphere(radius: 0.10)
                var coreMaterial = UnlitMaterial()
                if let gradientTexture = Self.makeGradientOrbTexture() {
                    coreMaterial.color = .init(tint: .white, texture: .init(gradientTexture))
                } else {
                    coreMaterial.color = .init(tint: UIColor(red: 1.0, green: 0.72, blue: 0.45, alpha: 1.0))
                }
                let coreEntity = ModelEntity(mesh: coreMesh, materials: [coreMaterial])
                rootEntity.addChild(coreEntity)

                // Thin outer rim — a subtle edge highlight, not a thick
                // glowing shell. Single layer now (the old "mid atmosphere"
                // shell was removed — it was most of what made this read as
                // a glowing sun instead of a solid moon).
                let rimMesh = MeshResource.generateSphere(radius: 0.107)
                var rimMaterial = PhysicallyBasedMaterial()
                rimMaterial.baseColor = .init(tint: UIColor(white: 1.0, alpha: 0.12))
                rimMaterial.emissiveColor = .init(color: UIColor(red: 0.75, green: 0.72, blue: 1.0, alpha: 0.5))
                rimMaterial.emissiveIntensity = 1.3
                rimMaterial.roughness = 0.5
                rimMaterial.blending = .transparent(opacity: 0.16)
                let rimEntity = ModelEntity(mesh: rimMesh, materials: [rimMaterial])
                rootEntity.addChild(rimEntity)

                // Particle Emitter
                let particleEntity = Entity()
                var particles = ParticleEmitterComponent()
                particles.timing = .repeating(warmUp: 1.0, emit: .init(duration: 1.0))
                particles.emitterShape = .sphere
                particles.birthLocation = .volume
                particles.emitterShapeSize = SIMD3<Float>(repeating: 0.26)
                particles.mainEmitter.birthRate = 18
                particles.mainEmitter.size = 0.003
                particles.mainEmitter.lifeSpan = 3.5
                particles.mainEmitter.color = .evolving(
                    start: .single(UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 0.8)),
                    end: .single(UIColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 0.0))
                )
                particles.speed = 0.012
                particleEntity.components.set(particles)
                rootEntity.addChild(particleEntity)

                // Spatial Light
                let lightEntity = Entity()
                var pointLight = PointLightComponent()
                pointLight.color = UIColor(red: 1.0, green: 0.65, blue: 0.45, alpha: 1.0)
                pointLight.intensity = 1600
                pointLight.attenuationRadius = 1.5
                lightEntity.components.set(pointLight)
                rootEntity.addChild(lightEntity)

                content.add(rootEntity)
            }
            .rotation3DEffect(.degrees(isSpinning ? 360 : 0), axis: (x: 0.1, y: 1.0, z: 0.05))
            .animation(.linear(duration: 25.0).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear {
                isSpinning = true
            }
        }
    }

    /// A diagonal orange → pink → violet gradient baked into a small texture,
    /// mapped onto the core sphere so it reads as a smooth gradient globe
    /// (matching the reference art) instead of a flat-tinted ball.
    private static func makeGradientOrbTexture() -> TextureResource? {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            // Higher saturation/contrast than before — the gradient is now
            // the orb's whole visual identity (no big glow doing the work
            // anymore), so it needs to pop rather than read as pastel.
            let colors = [
                UIColor(red: 1.0, green: 0.50, blue: 0.10, alpha: 1.0).cgColor,
                UIColor(red: 0.95, green: 0.16, blue: 0.42, alpha: 1.0).cgColor,
                UIColor(red: 0.30, green: 0.16, blue: 0.88, alpha: 1.0).cgColor
            ]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0.0, 0.55, 1.0]
            ) else { return }
            // Vertical, not diagonal: a sphere's UV wraps horizontally around
            // its circumference, so only latitude (top-to-bottom) reliably
            // reads as a gradient on the front-facing hemisphere from any
            // viewing angle — a horizontal/diagonal component mostly gets
            // "hidden" around the sides.
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: size.width / 2, y: size.height),
                end: CGPoint(x: size.width / 2, y: 0),
                options: []
            )
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, options: .init(semantic: .color))
    }
}

#Preview {
    HomeView()
}

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

    private let idleTimeout: Duration = .seconds(20)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backgroundScene(size: proxy.size)
                    .contentShape(Rectangle())
                    .onTapGesture { wakeOverlay() }

                // MARK: - 3D Center Orb
                // Lives in the background layer (not HomeOverlay) so it never
                // fades on idle — it's the scene's content, not a control.
                GlowingOrb3DView()
                    .frame(width: 260, height: 260)
                    .scaleEffect(isPulsing ? 1.05 : 0.96)
                    .offset(y: isPulsing ? -31 : -18)
                    .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear {
                        isPulsing = true
                    }
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
        TimelineView(.animation) { timeline in
            // Wrapped to a small range before hitting the shader — the raw
            // timeIntervalSinceReferenceDate is huge (~8×10⁸s), and passing
            // that into sin() at 32-bit float precision collapses the
            // fractional/phase part entirely, effectively freezing the wave.
            let time = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
            Image("background_scaled")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .distortionEffect(
                    ShaderLibrary.waterRipple(
                        .float2(size),
                        .float(time),
                        .float(6.0),
                        .float(0.55)
                    ),
                    maxSampleOffset: CGSize(width: 0, height: 10)
                )
                .clipped()
                .ignoresSafeArea()
        }
    }
}

// MARK: - Upgraded 3D RealityKit Orb Component
struct GlowingOrb3DView: View {
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 1.0, green: 0.6, blue: 0.3).opacity(0.45),
                    Color(red: 0.6, green: 0.4, blue: 0.9).opacity(0.2),
                    Color.clear
                ]),
                center: .center,
                startRadius: 20,
                endRadius: 180
            )
            .blur(radius: 20)

            RealityView { content in
                let rootEntity = Entity()

                // Core Layer — a smooth diagonal gradient (orange → pink → violet)
                // rather than a flat tint, so the sphere reads as a soft gradient
                // globe instead of a solid-colored ball. UnlitMaterial shows the
                // baked texture exactly as authored, unaffected by scene lighting
                // (which was washing the gradient toward a uniform pink under PBR).
                let coreMesh = MeshResource.generateSphere(radius: 0.10)
                var coreMaterial = UnlitMaterial()
                if let gradientTexture = Self.makeGradientOrbTexture() {
                    coreMaterial.color = .init(tint: .white, texture: .init(gradientTexture))
                } else {
                    coreMaterial.color = .init(tint: UIColor(red: 1.0, green: 0.72, blue: 0.45, alpha: 1.0))
                }
                let coreEntity = ModelEntity(mesh: coreMesh, materials: [coreMaterial])
                rootEntity.addChild(coreEntity)

                // Mid Atmosphere Layer — a soft, low-intensity halo so it no
                // longer overpowers the core's gradient underneath.
                let midMesh = MeshResource.generateSphere(radius: 0.118)
                var midMaterial = PhysicallyBasedMaterial()
                midMaterial.baseColor = .init(tint: UIColor(red: 0.95, green: 0.42, blue: 0.6, alpha: 0.35))
                midMaterial.emissiveColor = .init(color: UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0))
                midMaterial.emissiveIntensity = 0.9
                midMaterial.roughness = 0.55 // softened from 0.1 — was causing a sharp glass-like glare
                midMaterial.blending = .transparent(opacity: 0.22)
                let midEntity = ModelEntity(mesh: midMesh, materials: [midMaterial])
                rootEntity.addChild(midEntity)

                // Outer Ethereal Rim Layer
                let rimMesh = MeshResource.generateSphere(radius: 0.132)
                var rimMaterial = PhysicallyBasedMaterial()
                rimMaterial.baseColor = .init(tint: UIColor(red: 0.45, green: 0.8, blue: 1.0, alpha: 0.2))
                rimMaterial.emissiveColor = .init(color: UIColor(red: 0.55, green: 0.7, blue: 1.0, alpha: 0.7))
                rimMaterial.emissiveIntensity = 3.2
                rimMaterial.roughness = 0.4 // softened from 0.0 (mirror-like) for a diffuse glow
                rimMaterial.blending = .transparent(opacity: 0.3)
                let rimEntity = ModelEntity(mesh: rimMesh, materials: [rimMaterial])
                rootEntity.addChild(rimEntity)

                // Particle Emitter
                let particleEntity = Entity()
                var particles = ParticleEmitterComponent()
                particles.timing = .repeating(warmUp: 1.0, emit: .init(duration: 1.0))
                particles.emitterShape = .sphere
                particles.birthLocation = .volume
                particles.emitterShapeSize = SIMD3<Float>(repeating: 0.28)
                particles.mainEmitter.birthRate = 24
                particles.mainEmitter.size = 0.0035
                particles.mainEmitter.lifeSpan = 3.5
                particles.mainEmitter.color = .evolving(
                    start: .single(UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 0.9)),
                    end: .single(UIColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 0.0))
                )
                particles.speed = 0.015
                particleEntity.components.set(particles)
                rootEntity.addChild(particleEntity)

                // Spatial Light
                let lightEntity = Entity()
                var pointLight = PointLightComponent()
                pointLight.color = UIColor(red: 1.0, green: 0.65, blue: 0.45, alpha: 1.0)
                pointLight.intensity = 2200
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
            let colors = [
                UIColor(red: 1.0, green: 0.64, blue: 0.36, alpha: 1.0).cgColor,
                UIColor(red: 0.93, green: 0.46, blue: 0.56, alpha: 1.0).cgColor,
                UIColor(red: 0.52, green: 0.44, blue: 0.86, alpha: 1.0).cgColor
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

import SwiftUI
import RealityKit

struct HomeView: View {
    @State private var memories: [Memory] = Memory.sample
    @State private var selectedMemory: Memory = Memory.sample[0]
    @State private var sessionLength: Int = 15
    @State private var isLibraryExpanded = true
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            backgroundScene

            // MARK: - 3D Center Orb
            GlowingOrb3DView()
                .frame(width: 320, height: 320)
                .scaleEffect(isPulsing ? 1.05 : 0.96)
                .offset(y: isPulsing ? -38 : -22)
                .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear {
                    isPulsing = true
                }
                .allowsHitTesting(false)

            // MARK: - Main UI Layout
            VStack(spacing: 0) {
                GreetingHeader(name: "Paul")
                    .padding(.top, 56)

                Spacer(minLength: 0)

                ControlBar(sessionLength: $sessionLength)
                    .padding(.bottom, 48)
            }

            HStack(alignment: .top, spacing: 0) {
                MemoryLibraryPanel(
                    memories: memories,
                    selectedMemory: $selectedMemory,
                    isExpanded: $isLibraryExpanded
                )
                .padding(.leading, 48)
                .padding(.top, 40)

                Spacer(minLength: 0)

                SelectedMemoryCard(memory: selectedMemory)
                    .padding(.trailing, 48)
                    .padding(.top, 40)
            }
        }
        .frame(minWidth: 900, minHeight: 480)
    }

    private var backgroundScene: some View {
        GeometryReader { proxy in
            Image("background_scaled")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
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

                // Core Layer
                let coreMesh = MeshResource.generateSphere(radius: 0.10)
                var coreMaterial = UnlitMaterial()
                coreMaterial.color = .init(tint: UIColor(red: 1.0, green: 0.72, blue: 0.45, alpha: 1.0))
                let coreEntity = ModelEntity(mesh: coreMesh, materials: [coreMaterial])
                rootEntity.addChild(coreEntity)

                // Mid Atmosphere Layer
                let midMesh = MeshResource.generateSphere(radius: 0.118)
                var midMaterial = PhysicallyBasedMaterial()
                midMaterial.baseColor = .init(tint: UIColor(red: 0.95, green: 0.42, blue: 0.6, alpha: 0.35))
                midMaterial.emissiveColor = .init(color: UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0))
                midMaterial.emissiveIntensity = 3.0
                midMaterial.roughness = 0.1
                midMaterial.blending = .transparent(opacity: 0.4)
                let midEntity = ModelEntity(mesh: midMesh, materials: [midMaterial])
                rootEntity.addChild(midEntity)

                // Outer Ethereal Rim Layer
                let rimMesh = MeshResource.generateSphere(radius: 0.132)
                var rimMaterial = PhysicallyBasedMaterial()
                rimMaterial.baseColor = .init(tint: UIColor(red: 0.45, green: 0.8, blue: 1.0, alpha: 0.2))
                rimMaterial.emissiveColor = .init(color: UIColor(red: 0.55, green: 0.7, blue: 1.0, alpha: 0.7))
                rimMaterial.emissiveIntensity = 4.0
                rimMaterial.roughness = 0.0
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
}

#Preview {
    HomeView()
}

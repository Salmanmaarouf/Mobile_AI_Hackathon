import SwiftUI

/// Placeholder ambient backdrop for the Home screen, standing in for the
/// full sunset-lake photo while the orb itself is unbuilt. No sphere is
/// drawn here — a teammate is implementing a live, semi-3D orb (RealityView)
/// to occupy the center of `HomeView`.
struct SkyWaterBackground: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color(red: 0.51, green: 0.55, blue: 0.70),
                        Color(red: 0.66, green: 0.58, blue: 0.66),
                        Color(red: 0.86, green: 0.68, blue: 0.60)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.62)

                LinearGradient(
                    colors: [
                        Color(red: 0.80, green: 0.74, blue: 0.78),
                        Color(red: 0.68, green: 0.65, blue: 0.76)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.38)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    SkyWaterBackground()
}

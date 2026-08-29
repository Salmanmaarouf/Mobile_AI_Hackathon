import SwiftUI

struct GreetingHeader: View {
    let name: String

    private var greetingPeriod: (text: String, symbol: String, tint: Color) {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return ("Good Morning", "sun.max.fill", Color(red: 0.98, green: 0.78, blue: 0.31))
        case 12..<17: return ("Good Afternoon", "sun.max.fill", Color(red: 0.98, green: 0.78, blue: 0.31))
        case 17..<21: return ("Good Evening", "sunset.fill", Color(red: 0.98, green: 0.58, blue: 0.36))
        default: return ("Good Evening", "moon.stars.fill", Color(red: 0.75, green: 0.78, blue: 0.98))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("\(greetingPeriod.text), \(name)")
                    .font(.system(size: 40, weight: .light))
                Image(systemName: greetingPeriod.symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(greetingPeriod.tint)
            }
            .foregroundStyle(.white)

            Text("Whenever you're ready, let's visit this memory together.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

#Preview {
    ZStack {
        Color.black
        GreetingHeader(name: "Paul")
    }
}

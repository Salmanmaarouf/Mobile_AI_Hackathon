import SwiftUI

struct Memory: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let date: String
    let gradient: [Color]
}

extension Memory {
    static let sample: [Memory] = [
        Memory(title: "Mama's Birthday", date: "Apr 12, 2023", gradient: [Color(red: 0.98, green: 0.62, blue: 0.42), Color(red: 0.87, green: 0.42, blue: 0.55)]),
        Memory(title: "Brighton Beach", date: "Jan 18, 2023", gradient: [Color(red: 0.45, green: 0.68, blue: 0.86), Color(red: 0.62, green: 0.82, blue: 0.85)]),
        Memory(title: "Family Home", date: "Dec 25, 2022", gradient: [Color(red: 0.55, green: 0.45, blue: 0.72), Color(red: 0.35, green: 0.32, blue: 0.55)]),
        Memory(title: "Holiday in Bali", date: "Oct 3, 2022", gradient: [Color(red: 0.35, green: 0.62, blue: 0.55), Color(red: 0.72, green: 0.78, blue: 0.45)]),
        Memory(title: "Christmas Together", date: "Dec 25, 2021", gradient: [Color(red: 0.78, green: 0.35, blue: 0.38), Color(red: 0.92, green: 0.62, blue: 0.42)])
    ]
}

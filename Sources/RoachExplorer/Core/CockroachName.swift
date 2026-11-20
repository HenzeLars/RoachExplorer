import Foundation

/// Names for a new folder. No spaces, no special characters.
enum CockroachName {
    static let all = [
        "SirScuttles", "TheLandlord", "NightShift", "Underfridge",
        "ProfessorCrisp", "ShelfLife", "TheRoommate", "CrumbMinister",
        "TinyTank", "LateCheckout", "ClickClack", "UninvitedGuest",
        "StillHere", "RoachesNeverDie", "HardToKill", "TheNightManager",
    ]

    /// A name not already in the folder. If every name is taken, append a
    /// number: `SirScuttles2`. Comparison is case-insensitive, like the disk.
    static func next(avoiding existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let free = all.filter { !taken.contains($0.lowercased()) }
        if let name = free.randomElement() { return name }
        let base = all.randomElement() ?? "SirScuttles"
        var number = 2
        while taken.contains("\(base)\(number)".lowercased()) {
            number += 1
        }
        return "\(base)\(number)"
    }
}

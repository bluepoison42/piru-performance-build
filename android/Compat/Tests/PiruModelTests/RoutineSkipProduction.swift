import Foundation
import PortableData

enum MedTimeGroup: Int, CaseIterable {
    case morning, afternoon, evening, night, anytime, asNeeded
    static func group(forMinutes minutes: Int) -> MedTimeGroup {
        switch minutes {
        case ..<720: .morning
        case ..<1_020: .afternoon
        case ..<1_260: .evening
        default: .night
        }
    }
    var slug: String {
        switch self {
        case .morning: "morning"
        case .afternoon: "afternoon"
        case .evening: "evening"
        case .night: "night"
        case .anytime: "anytime"
        case .asNeeded: "as-needed"
        }
    }
    init?(slug: String) {
        guard let match = Self.allCases.first(where: { $0.slug == slug }) else { return nil }
        self = match
    }
}

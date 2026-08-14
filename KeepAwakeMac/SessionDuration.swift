import Foundation

enum SessionDuration: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case custom
    case indefinite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .custom: return "Custom"
        case .indefinite: return "Indefinitely"
        }
    }

    func seconds(customMinutes: Int) -> TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .custom: return TimeInterval(max(1, customMinutes) * 60)
        case .indefinite: return nil
        }
    }
}

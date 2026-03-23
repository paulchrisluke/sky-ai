import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "overview"
    case mail = "mail"
    case calendar = "calendar"
    case contacts = "contacts"
    case activity = "activity"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .overview: return "Overview"
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .activity: return "Activity"
        }
    }
    
    var systemImage: String {
        switch self {
        case .overview: return "chart.bar.xaxis"
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .contacts: return "person.2"
        case .activity: return "clock"
        }
    }
}

@MainActor
class DashboardNavigation: ObservableObject {
    @Published var selectedSection: DashboardSection = .overview
}

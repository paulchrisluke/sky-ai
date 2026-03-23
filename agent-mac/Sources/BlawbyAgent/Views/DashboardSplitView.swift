import SwiftUI

struct DashboardSplitView: View {
    @StateObject private var navigation = DashboardNavigation()
    
    var body: some View {
        NavigationSplitView {
            SidebarNavigationView(selection: $navigation.selectedSection)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            DetailHostView(selectedSection: navigation.selectedSection)
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

private struct SidebarNavigationView: View {
    @Binding var selection: DashboardSection
    
    var body: some View {
        List(DashboardSection.allCases, id: \.self, selection: $selection) { section in
            Label(section.displayName, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationTitle("Blawby")
        .listStyle(.sidebar)
    }
}

private struct DetailHostView: View {
    let selectedSection: DashboardSection
    
    var body: some View {
        switch selectedSection {
        case .overview:
            Text("Overview - Coming Soon")
                .foregroundColor(.secondary)
        case .mail:
            Text("Mail - Coming Soon")
                .foregroundColor(.secondary)
        case .calendar:
            Text("Calendar - Coming Soon")
                .foregroundColor(.secondary)
        case .contacts:
            Text("Contacts - Coming Soon")
                .foregroundColor(.secondary)
        case .activity:
            Text("Activity - Coming Soon")
                .foregroundColor(.secondary)
        }
    }
}

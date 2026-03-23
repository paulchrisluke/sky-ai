import SwiftUI

struct CalendarDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendar")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Calendar sources and sync activity")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                // Placeholder content
                VStack(alignment: .leading, spacing: 16) {
                    Text("Overview")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("No calendar sources configured yet.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
        .navigationTitle("Calendar")
    }
}

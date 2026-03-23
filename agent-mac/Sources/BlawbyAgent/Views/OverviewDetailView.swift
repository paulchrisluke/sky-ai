import SwiftUI

struct OverviewDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Overview")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("System status and activity summary")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                // Placeholder content
                VStack(alignment: .leading, spacing: 16) {
                    Text("Status Summary")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("No sources configured yet.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Mail Summary
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mail Activity")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("No mail activity to display.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Calendar Summary
                VStack(alignment: .leading, spacing: 12) {
                    Text("Calendar Activity")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("No calendar activity to display.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
        .navigationTitle("Overview")
    }
}

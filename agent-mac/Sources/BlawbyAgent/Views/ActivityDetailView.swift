import SwiftUI

struct ActivityDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Recent sync activity and status")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                // Placeholder content
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recent Activity")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("No recent activity to display.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
        .navigationTitle("Activity")
    }
}

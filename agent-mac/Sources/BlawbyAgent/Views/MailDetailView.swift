import SwiftUI

struct MailDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mail")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Mail sources and sync activity")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                // Placeholder content
                VStack(alignment: .leading, spacing: 16) {
                    Text("Overview")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("No mail sources configured yet.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
        }
        .navigationTitle("Mail")
    }
}

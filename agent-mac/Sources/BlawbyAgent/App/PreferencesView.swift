import SwiftUI

struct PreferencesView: View {
    @ObservedObject var session: AppSession
    @State private var workerUrl = ""
    @State private var apiKey = ""
    @State private var workspaceId = ""
    @State private var accountId = ""
    @State private var openaiApiKey = ""
    @State private var saveMessage: String?
    @State private var saveError: String?

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("Connection", systemImage: "link") }
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear(perform: loadFromSession)
    }

    private var connectionTab: some View {
        Form {
            Section("Worker Configuration") {
                TextField("Worker URL", text: $workerUrl)
                TextField("API Key", text: $apiKey)
                TextField("Workspace ID", text: $workspaceId)
                TextField("Account ID", text: $accountId)
            }
            
            Section("OpenAI Configuration") {
                TextField("OpenAI API Key", text: $openaiApiKey)
            }
            
            Section {
                Button("Save Configuration") {
                    save()
                }
                
                if let saveMessage = saveMessage {
                    Text(saveMessage)
                        .foregroundColor(.green)
                        .padding()
                }
                
                if let saveError = saveError {
                    Text(saveError)
                        .foregroundColor(.red)
                        .padding()
                }
            }
        }
        .padding(20)
    }

    private func loadFromSession() {
        guard let config = session.config else { return }
        workerUrl = config.workerUrl ?? ""
        workspaceId = config.workspaceId ?? ""
        accountId = config.accountId ?? ""
        apiKey = config.apiKey ?? ""
        openaiApiKey = config.openaiApiKey ?? ""
    }

    private func save() {
        saveMessage = nil
        saveError = nil
        Task {
            do {
                try await session.saveConnectionSettings(
                    workerUrl: workerUrl,
                    workspaceId: workspaceId,
                    accountId: accountId,
                    apiKey: apiKey,
                    openaiApiKey: openaiApiKey
                )
                await MainActor.run {
                    saveMessage = "Saved. Restart app to apply new transport credentials."
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

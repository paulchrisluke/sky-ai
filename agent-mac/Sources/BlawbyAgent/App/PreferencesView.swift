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
            sourcesTab
                .tabItem { Label("Sources", systemImage: "tray.full") }
            connectionTab
                .tabItem { Label("Connection", systemImage: "link") }
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear(perform: loadFromSession)
    }

    @ViewBuilder
    private var sourcesTab: some View {
        if let sourceManager = session.sourceManager {
            SourcesView(sourceManager: sourceManager)
                .padding()
        } else if let startupError = session.startupError {
            Text("Startup failed: \(startupError)")
                .foregroundColor(.red)
                .padding()
        } else {
            ProgressView("Loading sources…")
                .padding()
        }
    }

    private var connectionTab: some View {
        Form {
            TextField("Worker URL", text: $workerUrl)
            TextField("Workspace ID", text: $workspaceId)
            TextField("Account ID", text: $accountId)
            SecureField("API Key", text: $apiKey)
            SecureField("OpenAI API Key", text: $openaiApiKey)

            HStack {
                Spacer()
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }

            if let saveMessage {
                Text(saveMessage)
                    .foregroundColor(.green)
            }
            if let saveError {
                Text(saveError)
                    .foregroundColor(.red)
            }
        }
        .padding(20)
    }

    private func loadFromSession() {
        guard let config = session.config else { return }
        workerUrl = config.workerUrl
        workspaceId = config.workspaceId
        accountId = config.accountId
        apiKey = config.apiKey
        openaiApiKey = config.openaiApiKey ?? ""
    }

    private func save() {
        saveMessage = nil
        saveError = nil
        do {
            try session.saveConnectionSettings(
                workerUrl: workerUrl,
                workspaceId: workspaceId,
                accountId: accountId,
                apiKey: apiKey,
                openaiApiKey: openaiApiKey
            )
            saveMessage = "Saved. Restart app to apply new transport credentials."
        } catch {
            saveError = error.localizedDescription
        }
    }
}

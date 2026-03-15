import XCTest
@testable import BlawbyAgent

final class SyncCoordinatorTests: XCTestCase {
    func testRunMailSyncDelegatesToSourceManager() async throws {
        let baseDir = try makeTempDirectory()
        let logger = try Logger(baseDirectory: baseDir)
        let localStore = try LocalStore(baseDirectory: baseDir)
        let publisher = MockWebSocketPublisher()
        let sourceManager = await MainActor.run {
            MockSourceManager(mailIds: ["mail:acct-1:INBOX", "mail:acct-1:Archive"])
        }

        let coordinator = SyncCoordinator(
            config: Config(
                workerUrl: "https://example.com",
                apiKey: "test",
                workspaceId: "default",
                accountId: "acct-1",
                openaiApiKey: nil
            ),
            localStore: localStore,
            webSocketPublisher: publisher,
            sourceManager: sourceManager,
            logger: logger
        )

        await coordinator.runMailSync()

        let markedTypes = await MainActor.run { sourceManager.markedSourceTypes }
        let synced = await MainActor.run { sourceManager.syncedIds }
        XCTAssertEqual(markedTypes, ["mail"])
        XCTAssertEqual(synced, ["mail:acct-1:INBOX", "mail:acct-1:Archive"])
        XCTAssertTrue(publisher.sent.isEmpty)
    }

    func testMailProcessorReturnsBothTypes() async throws {
        let baseDir = try makeTempDirectory()
        let localStore = try LocalStore(baseDirectory: baseDir)

        let message = RawMessage(
            messageId: "msg-2",
            accountId: "acct-2",
            subject: "Invoice",
            from: "sender@example.com",
            to: ["to@example.com"],
            date: Date(),
            bodyText: "Please pay invoice",
            mailbox: "INBOX"
        )
        let expectedEntity = ExtractedEntity(
            id: UUID().uuidString,
            workspaceId: "default",
            accountId: "acct-2",
            messageId: "msg-2",
            entityType: "invoice",
            direction: "ap",
            counterpartyName: "Vendor",
            counterpartyEmail: "sender@example.com",
            amountCents: 10_000,
            currency: "USD",
            dueDate: "2026-03-20",
            referenceNumber: "INV-1",
            status: "open",
            actionRequired: true,
            actionDescription: "Pay invoice",
            riskLevel: "medium",
            confidence: 0.95
        )
        let processor = MailProcessor(
            localStore: localStore,
            extractor: MockEntityExtractor(entities: [expectedEntity])
        )

        let result = try await processor.process(messages: [message], workspaceId: "default")
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertEqual(result.rawMessages.count, 1)
        XCTAssertEqual(result.entities[0].messageId, "msg-2")
        XCTAssertEqual(result.rawMessages[0].messageId, "msg-2")
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blawby-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}

private final class MockWebSocketPublisher: WebSocketPublishing {
    struct SentMessage {
        let type: String
        let payload: String
    }

    private(set) var sent: [SentMessage] = []

    func send(type: String, payload: String) async throws {
        sent.append(SentMessage(type: type, payload: payload))
    }
}

@MainActor
private final class MockSourceManager: SourceManaging {
    private let mailIds: [String]
    private(set) var syncedIds: [String] = []
    private(set) var markedSourceTypes: [String] = []

    init(mailIds: [String]) {
        self.mailIds = mailIds
    }

    func start() {}
    func stop() {}
    func refreshSources() async {}
    func enabledSourceIds(sourceType: String) -> [String] {
        sourceType == "mail" ? mailIds : []
    }
    func setEnabled(_ id: String, enabled: Bool) async {}
    func markSourceChanged(_ id: String) {}
    func markSourcesChanged(sourceType: String) {
        markedSourceTypes.append(sourceType)
    }
    func syncSource(_ id: String) async {
        syncedIds.append(id)
    }
}

private struct MockEntityExtractor: EntityExtracting {
    let entities: [ExtractedEntity]

    func extract(messages: [RawMessage], workspaceId: String) async throws -> [ExtractedEntity] {
        entities
    }
}

import XCTest
@testable import BlawbyAgent

final class SyncCoordinatorTests: XCTestCase {
    func testSyncSendsBothPayloads() async throws {
        let baseDir = try makeTempDirectory()
        let logger = try Logger(baseDirectory: baseDir)
        let localStore = try LocalStore(baseDirectory: baseDir)
        let publisher = MockWebSocketPublisher()
        let message = RawMessage(
            messageId: "msg-1",
            accountId: "acct-1",
            subject: "Subject",
            from: "sender@example.com",
            to: ["to@example.com"],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            bodyText: "Body text",
            mailbox: "INBOX"
        )
        let entity = ExtractedEntity(
            id: UUID().uuidString,
            workspaceId: "default",
            accountId: "acct-1",
            messageId: "msg-1",
            entityType: "correspondence",
            direction: "inbound",
            counterpartyName: "Sender",
            counterpartyEmail: "sender@example.com",
            amountCents: nil,
            currency: nil,
            dueDate: nil,
            referenceNumber: nil,
            status: "unknown",
            actionRequired: false,
            actionDescription: nil,
            riskLevel: "low",
            confidence: 0.9
        )

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
            mailWatcher: MockMailWatcher(messages: [message]),
            mailProcessor: MockMailProcessor(result: MailProcessingResult(entities: [entity], rawMessages: [message])),
            calendarWatcher: MockCalendarWatcher(),
            logger: logger
        )

        await coordinator.runMailSync()

        XCTAssertEqual(publisher.sent.count, 2)
        XCTAssertEqual(publisher.sent[0].type, "entities")
        XCTAssertEqual(publisher.sent[1].type, "chunks")

        let entitiesEnvelope = try decodePayload(EntitiesPayloadEnvelope.self, from: publisher.sent[0].payload)
        XCTAssertEqual(entitiesEnvelope.type, "entities")
        XCTAssertEqual(entitiesEnvelope.workspaceId, "default")
        XCTAssertEqual(entitiesEnvelope.accountId, "acct-1")
        XCTAssertEqual(entitiesEnvelope.entities.count, 1)
        XCTAssertEqual(entitiesEnvelope.entities[0].messageId, "msg-1")

        let chunksEnvelope = try decodePayload(ChunksPayloadEnvelope.self, from: publisher.sent[1].payload)
        XCTAssertEqual(chunksEnvelope.type, "chunks")
        XCTAssertEqual(chunksEnvelope.workspaceId, "default")
        XCTAssertEqual(chunksEnvelope.accountId, "acct-1")
        XCTAssertEqual(chunksEnvelope.messages.count, 1)
        XCTAssertEqual(chunksEnvelope.messages[0].messageId, "msg-1")
        XCTAssertEqual(chunksEnvelope.messages[0].mailbox, "INBOX")
        XCTAssertEqual(chunksEnvelope.messages[0].toEmails, ["to@example.com"])
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

    private func decodePayload<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct EntitiesPayloadEnvelope: Decodable {
    struct Entity: Decodable {
        let messageId: String
    }

    let type: String
    let workspaceId: String
    let accountId: String
    let entities: [Entity]
}

private struct ChunksPayloadEnvelope: Decodable {
    struct Message: Decodable {
        let messageId: String
        let mailbox: String
        let toEmails: [String]
    }

    let type: String
    let workspaceId: String
    let accountId: String
    let messages: [Message]
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

private struct MockMailWatcher: MailWatching {
    let messages: [RawMessage]

    func fetchNewMessages() -> [RawMessage] {
        messages
    }
}

private struct MockMailProcessor: MailProcessing {
    let result: MailProcessingResult

    func process(messages: [RawMessage], workspaceId: String) async throws -> MailProcessingResult {
        result
    }
}

private struct MockCalendarWatcher: CalendarWatching {
    func fetchUnsentPayloads() async throws -> [CalendarPayload] { [] }
    func markPayloadEventsSent(_ payload: CalendarPayload) {}
}

private struct MockEntityExtractor: EntityExtracting {
    let entities: [ExtractedEntity]

    func extract(messages: [RawMessage], workspaceId: String) async throws -> [ExtractedEntity] {
        entities
    }
}

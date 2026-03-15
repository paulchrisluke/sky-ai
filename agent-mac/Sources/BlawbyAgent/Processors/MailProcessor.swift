import Foundation

struct MailProcessingResult {
    let entities: [ExtractedEntity]
    let rawMessages: [RawMessage]
}

protocol MailProcessing {
    func process(messages: [RawMessage], workspaceId: String) async throws -> MailProcessingResult
}

final class MailProcessor {
    private let localStore: LocalStore
    private let extractor: any EntityExtracting

    init(localStore: LocalStore, extractor: any EntityExtracting) {
        self.localStore = localStore
        self.extractor = extractor
    }

    func process(messages: [RawMessage], workspaceId: String) async throws -> MailProcessingResult {
        if messages.isEmpty {
            return MailProcessingResult(entities: [], rawMessages: [])
        }

        let newMessages = messages.filter { !localStore.isMessageProcessed($0.messageId) }
        if newMessages.isEmpty {
            return MailProcessingResult(entities: [], rawMessages: [])
        }

        let extracted = try await extractor.extract(messages: newMessages, workspaceId: workspaceId)
        var countsByMessageId: [String: Int] = [:]
        for entity in extracted {
            countsByMessageId[entity.messageId, default: 0] += 1
        }

        for message in newMessages {
            localStore.markMessageProcessed(
                message.messageId,
                accountId: message.accountId,
                entityCount: countsByMessageId[message.messageId] ?? 0
            )
        }

        return MailProcessingResult(entities: extracted, rawMessages: newMessages)
    }
}

extension MailProcessor: MailProcessing {}

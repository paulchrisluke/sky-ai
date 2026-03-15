import Foundation

struct MailProcessingResult {
    let entities: [ExtractedEntity]
    let rawMessages: [RawMessage]
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
        if extracted.isEmpty {
            return MailProcessingResult(entities: [], rawMessages: newMessages)
        }

        var countsByMessageId: [String: Int] = [:]
        for entity in extracted {
            countsByMessageId[entity.messageId, default: 0] += 1
        }
        let accountByMessageId = Dictionary(uniqueKeysWithValues: newMessages.map { ($0.messageId, $0.accountId) })

        for entity in extracted {
            guard let accountId = accountByMessageId[entity.messageId] else { continue }
            localStore.markMessageProcessed(
                entity.messageId,
                accountId: accountId,
                entityCount: countsByMessageId[entity.messageId] ?? 1
            )
        }

        return MailProcessingResult(entities: extracted, rawMessages: newMessages)
    }
}

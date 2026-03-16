import Foundation

struct MailProcessingResult {
    let entities: [ExtractedEntity]
    let rawMessages: [RawMessage]
}

protocol MailProcessing {
    func process(messages: [RawMessage], workspaceId: String, skipExtraction: Bool) async throws -> MailProcessingResult
}

final class MailProcessor {
    private let extractor: any EntityExtracting

    init(extractor: any EntityExtracting) {
        self.extractor = extractor
    }

    func process(messages: [RawMessage], workspaceId: String, skipExtraction: Bool = false) async throws -> MailProcessingResult {
        if messages.isEmpty {
            return MailProcessingResult(entities: [], rawMessages: [])
        }

        let extracted: [ExtractedEntity]
        if skipExtraction {
            extracted = []
        } else {
            extracted = try await extractor.extract(messages: messages, workspaceId: workspaceId)
        }
        return MailProcessingResult(entities: extracted, rawMessages: messages)
    }
}

extension MailProcessor: MailProcessing {}

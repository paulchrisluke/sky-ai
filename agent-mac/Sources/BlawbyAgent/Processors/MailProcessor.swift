import Foundation

struct MailProcessingResult {
    let entities: [ExtractedEntity]
    let rawMessages: [RawMessage]
}

protocol MailProcessing: Sendable {
    func process(messages: [RawMessage], workspaceId: String, skipExtraction: Bool) async throws -> MailProcessingResult
}

final class MailProcessor: @unchecked Sendable, MailProcessing {
    private let extractor: any EntityExtracting
    private let logger: Logger

    init(extractor: any EntityExtracting, logger: Logger) {
        self.extractor = extractor
        self.logger = logger
    }
    
    func process(messages: [RawMessage], workspaceId: String, skipExtraction: Bool) async throws -> MailProcessingResult {
        logger.info("MailProcessor.process called with \(messages.count) messages, skipExtraction=\(skipExtraction)")
        
        if messages.isEmpty {
            return MailProcessingResult(entities: [], rawMessages: [])
        }
        
        let extracted: [ExtractedEntity]
        if skipExtraction {
            extracted = []
            logger.info("MailProcessor skipping extraction, returning \(extracted.count) entities")
        } else {
            logger.info("MailProcessor starting extraction for \(messages.count) messages")
            extracted = try await extractor.extract(messages: messages, workspaceId: workspaceId)
            logger.info("MailProcessor extraction completed, got \(extracted.count) entities")
        }
        
        logger.info("MailProcessor.process returning \(extracted.count) entities")
        return MailProcessingResult(entities: extracted, rawMessages: messages)
    }
}

extension MailProcessor: MailProcessing {}

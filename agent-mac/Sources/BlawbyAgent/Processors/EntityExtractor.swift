import Foundation

struct RawMessage: Sendable {
    let messageId: String
    let accountId: String
    let subject: String
    let from: String
    let to: [String]
    let date: Date
    let bodyText: String
    let mailbox: String
}

struct ExtractedEntity: Codable, Sendable {
    let id: String
    let workspaceId: String
    let accountId: String
    let messageId: String
    let entityType: String
    let direction: String
    let counterpartyName: String?
    let counterpartyEmail: String?
    let amountCents: Int?
    let currency: String?
    let dueDate: String?
    let referenceNumber: String?
    let status: String
    let actionRequired: Bool
    let actionDescription: String?
    let riskLevel: String
    let confidence: Double
    let sentAt: String
    let subject: String
    let fromEmail: String
    let mailbox: String
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ExtractedEntityWire: Decodable {
    let messageId: String?
    let message_id: String?
    let entityType: String?
    let entity_type: String?
    let direction: String?
    let counterpartyName: String?
    let counterparty_name: String?
    let counterpartyEmail: String?
    let counterparty_email: String?
    let amountCents: Int?
    let amount_cents: Int?
    let currency: String?
    let dueDate: String?
    let due_date: String?
    let referenceNumber: String?
    let reference_number: String?
    let status: String?
    let actionRequired: Bool?
    let action_required: Bool?
    let actionDescription: String?
    let action_description: String?
    let riskLevel: String?
    let risk_level: String?
    let confidence: Double?
}

private struct ExtractedEntityEnvelope: Decodable {
    let entities: [ExtractedEntityWire]
}

enum EntityExtractorError: Error {
    case missingOpenAIKey
    case invalidOpenAIResponse
}

protocol EntityExtracting: Sendable {
    func extract(messages: [RawMessage], workspaceId: String) async throws -> [ExtractedEntity]
}

final class EntityExtractor: @unchecked Sendable, EntityExtracting {
    private let apiKey: String?
    private let contactsReader: ContactsReader?
    private let logger: Logger

    init(apiKey: String?, contactsReader: ContactsReader?, logger: Logger) {
        self.apiKey = apiKey
        self.contactsReader = contactsReader
        self.logger = logger
    }

    func extract(messages: [RawMessage], workspaceId: String) async throws -> [ExtractedEntity] {
        logger.info("EntityExtractor.extract called with \(messages.count) messages")
        if messages.isEmpty {
            return []
        }

        guard let apiKey else {
            throw EntityExtractorError.missingOpenAIKey
        }

        let batches = messages.chunked(into: 10) // Increase batch size for better performance
        var all: [ExtractedEntity] = []
        for (index, batch) in batches.enumerated() {
            logger.info("EntityExtractor processing batch \(index + 1)/\(batches.count) with \(batch.count) messages")
            do {
                let batchEntities = try await extractBatch(messages: batch, workspaceId: workspaceId, apiKey: apiKey)
                logger.info("EntityExtractor batch \(index + 1) completed with \(batchEntities.count) entities")
                all.append(contentsOf: batchEntities)
            } catch {
                logger.error("EntityExtractor batch \(index + 1) failed, continuing without entities: \(error.localizedDescription)")
                // Continue processing other batches even if one fails
            }
        }
        
        logger.info("EntityExtractor.extract completed: total \(all.count) entities from \(messages.count) messages")
        logger.info("EntityExtractor.extract about to return \(all.count) entities")
        return all
    }

    private func extractBatch(messages: [RawMessage], workspaceId: String, apiKey: String) async throws -> [ExtractedEntity] {
        let accountOwner = messages.first?.accountId ?? "unknown"
        let requestBody = OpenAIChatRequest(
            model: "gpt-4o-mini",
            messages: [
                .init(role: "system", content: entityExtractionSystemPrompt(accountOwner: accountOwner)),
                .init(role: "user", content: buildUserContent(messages: messages))
            ],
            maxTokens: 1000
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EntityExtractorError.invalidOpenAIResponse
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "EntityExtractor", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: text])
        }

        let chatResponse = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content else {
            throw EntityExtractorError.invalidOpenAIResponse
        }

        do {
            let wireEntities = try decodeWireEntities(from: content)
            return mapEntities(wireEntities, workspaceId: workspaceId, messages: messages)
        } catch {
            logger.warning("entity extractor parse failed for batch size=\(messages.count): \(error.localizedDescription)")
            return []
        }
    }
    private func mapEntities(
        _ rows: [ExtractedEntityWire],
        workspaceId: String,
        messages: [RawMessage]
    ) -> [ExtractedEntity] {
        var messageById: [String: RawMessage] = [:]
        for message in messages {
            messageById[message.messageId] = message
        }

        return rows.enumerated().compactMap { index, row in
            let fallbackMessageId = index < messages.count ? messages[index].messageId : nil
            guard let messageId = row.messageId ?? row.message_id ?? fallbackMessageId,
                  let source = messageById[messageId] else {
                return nil
            }

            let status = normalizeStatus(row.status ?? "unknown")
            let risk = normalizeRisk(row.riskLevel ?? row.risk_level ?? "low")
            let entityType = normalizeEntityType(row.entityType ?? row.entity_type ?? "correspondence")
            let direction = normalizeDirection(row.direction ?? "inbound")
            let confidence = min(1.0, max(0.0, row.confidence ?? 0.5))

            return ExtractedEntity(
                id: UUID().uuidString,
                workspaceId: workspaceId,
                accountId: source.accountId,
                messageId: source.messageId,
                entityType: entityType,
                direction: direction,
                counterpartyName: row.counterpartyName ?? row.counterparty_name,
                counterpartyEmail: row.counterpartyEmail ?? row.counterparty_email,
                amountCents: row.amountCents ?? row.amount_cents,
                currency: row.currency,
                dueDate: row.dueDate ?? row.due_date,
                referenceNumber: row.referenceNumber ?? row.reference_number,
                status: status,
                actionRequired: row.actionRequired ?? row.action_required ?? false,
                actionDescription: row.actionDescription ?? row.action_description,
                riskLevel: risk,
                confidence: confidence,
                sentAt: makeISOFormatter().string(from: source.date),
                subject: source.subject,
                fromEmail: source.from,
                mailbox: source.mailbox
            )
        }
    }

    private func buildUserContent(messages: [RawMessage]) -> String {
        var lines: [String] = []
        lines.append("Extract one entity object per message. Return ONLY a JSON array.")

        for message in messages {
            lines.append("MESSAGE_ID: \(message.messageId)")
            lines.append("Subject: \(message.subject)")
            lines.append("From: \(message.from)")
            lines.append("To: \(message.to.joined(separator: ", "))")
            lines.append("Date: \(makeISOFormatter().string(from: message.date))")
            lines.append("Direction: inbound")
            lines.append("Contact Context: \(contactContext(for: message))")
            lines.append("Body: \(message.bodyText)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func contactContext(for message: RawMessage) -> String {
        guard let contactsReader else { return "none" }
        var contexts: [String] = []
        let emails = ([extractEmail(from: message.from)] + message.to.map(extractEmail(from:))).compactMap { $0 }
        for email in Set(emails) {
            if let contact = contactsReader.lookupContact(email: email) {
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                contexts.append("\(email): name=\(fullName.isEmpty ? "unknown" : fullName), org=\(contact.organizationName)")
            }
        }
        return contexts.isEmpty ? "none" : contexts.joined(separator: "; ")
    }

    private func extractEmail(from input: String) -> String? {
        if input.contains("@"), !input.contains("<") {
            return input.lowercased()
        }
        guard let start = input.firstIndex(of: "<"), let end = input.firstIndex(of: ">"), start < end else {
            return nil
        }
        let email = input[input.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.contains("@") ? email : nil
    }

    private func entityExtractionSystemPrompt(accountOwner: String) -> String {
        """
        You are a precise email entity extractor. Extract structured facts from this email for the account owner: \(accountOwner)

        Respond with ONLY a JSON array. No explanation, no markdown, no code fences.

        [
        {
          "message_id": "exact MESSAGE_ID from input",
          "entity_type": "invoice|contract|payment|appointment|alert|request|correspondence",
          "direction": "ar|ap|inbound|outbound|unknown",
          "counterparty_name": "string or null",
          "counterparty_email": "string or null",
          "amount_cents": integer_or_null,
          "currency": "USD|GBP|EUR or null",
          "due_date": "YYYY-MM-DD or null",
          "reference_number": "string or null",
          "status": "open|paid|overdue|pending|requires_action|unknown",
          "action_required": true_or_false,
          "action_description": "one sentence describing exactly what action the account owner needs to take, or null",
          "risk_level": "low|medium|high|critical",
          "confidence": 0.0_to_1.0
        }
        ]

        Rules:
        - Return exactly one object per input message.
        - Copy each message_id exactly from input.
        - The account owner is \(accountOwner). Reason about ALL directions from THEIR perspective.
        - direction "ar" = someone owes the account owner money, or the account owner expects to be paid.
        - direction "ap" = the account owner owes someone else money, or needs to make a payment.
        - direction "inbound" = non-financial inbound mail where no money changes hands.
        - direction "outbound" = mail sent by the account owner with no financial obligation.
        - If the email discusses an ongoing payment arrangement where the account owner receives money, that is "ar".
        - If the subject contains "Re:" check the snippet carefully — the account owner may be the one being paid.
        - amount_cents: integer cents ($50,000 = 5000000). Extract even if informal ("we've been doing 50K").
        - action_required: true if the account owner needs to respond, follow up, confirm, or take any step.
        - For negotiation or agreement threads, action_required is almost always true.
        - risk_level "high" if money is at stake and no response has been confirmed.
        - Marketing, newsletters, automated notifications with no money and no required response: entity_type correspondence, action_required false.
        """
    }

    private func stripJsonCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("```") {
            return trimmed
        }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return trimmed }
        let inner = lines.dropFirst().dropLast()
        return inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeWireEntities(from rawContent: String) throws -> [ExtractedEntityWire] {
        let decoder = JSONDecoder()
        
        // Try to fix incomplete JSON by ensuring it ends properly
        logger.info("EntityExtractor attempting to fix incomplete JSON, raw content length: \(rawContent.count)")
        let cleanedContent = fixIncompleteJSON(rawContent)
        logger.info("EntityExtractor fixed JSON length: \(cleanedContent.count)")
        let payload = Data(cleanedContent.utf8)

        if let rows = try? decoder.decode([ExtractedEntityWire].self, from: payload) {
            logger.info("EntityExtractor decoded as array format: \(rows.count) entities")
            return rows
        }
        if let wrapped = try? decoder.decode(ExtractedEntityEnvelope.self, from: payload) {
            logger.info("EntityExtractor decoded as envelope format: \(wrapped.entities.count) entities")
            return wrapped.entities
        }
        if let one = try? decoder.decode(ExtractedEntityWire.self, from: payload) {
            logger.info("EntityExtractor decoded as single entity format")
            return [one]
        }
        
        logger.warning("EntityExtractor failed to decode any format. Raw content: \(rawContent.prefix(1000))")
        throw EntityExtractorError.invalidOpenAIResponse
    }
    
    private func makeISOFormatter() -> ISO8601DateFormatter {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }
    
    private func fixIncompleteJSON(_ content: String) -> String {
        // Find the last complete JSON object before any incomplete trailing data
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If content doesn't end with complete JSON structure, try to fix it
        if trimmed.hasSuffix("}") {
            return trimmed
        }
        
        // Find the position of the last complete object
        var braceCount = 0
        var lastCompletePos = -1
        
        for (index, char) in trimmed.enumerated() {
            if char == "{" {
                braceCount += 1
            } else if char == "}" {
                braceCount -= 1
                if braceCount == 0 {
                    lastCompletePos = index
                }
            }
        }
        
        if lastCompletePos > 0 && lastCompletePos < trimmed.count - 1 {
            // Return content up to the last complete object
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: lastCompletePos + 1)
            return String(trimmed[..<endIndex]) + "]"
        }
        
        return content
    }

    private func normalizeStatus(_ value: String) -> String {
        switch value.lowercased() {
        case "open", "paid", "overdue", "pending", "requires_action", "unknown":
            return value.lowercased()
        default:
            return "unknown"
        }
    }

    private func normalizeRisk(_ value: String) -> String {
        switch value.lowercased() {
        case "low", "medium", "high", "critical":
            return value.lowercased()
        default:
            return "low"
        }
    }

    private func normalizeEntityType(_ value: String) -> String {
        let normalized = value.lowercased()
        let allowed = ["invoice", "payment", "contract", "correspondence", "alert", "request", "appointment"]
        return allowed.contains(normalized) ? normalized : "correspondence"
    }

    private func normalizeDirection(_ value: String) -> String {
        let normalized = value.lowercased()
        let allowed = ["inbound", "outbound", "ar", "ap"]
        return allowed.contains(normalized) ? normalized : "inbound"
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

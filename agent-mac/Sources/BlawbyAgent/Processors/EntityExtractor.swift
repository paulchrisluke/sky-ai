import Foundation

struct RawMessage: Sendable {
    let messageId: String
    let accountId: String
    let subject: String
    let from: String
    let to: [String]
    let date: Date
    let bodyText: String
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

enum EntityExtractorError: Error {
    case missingOpenAIKey
    case invalidOpenAIResponse
}

final class EntityExtractor {
    private let logger: Logger
    private let iso: ISO8601DateFormatter

    init(logger: Logger) {
        self.logger = logger
        self.iso = ISO8601DateFormatter()
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func extract(messages: [RawMessage], workspaceId: String) async throws -> [ExtractedEntity] {
        if messages.isEmpty {
            return []
        }

        guard let apiKey = Preferences.openAIAPIKey else {
            throw EntityExtractorError.missingOpenAIKey
        }

        let batches = messages.chunked(into: 5)
        var all: [ExtractedEntity] = []
        for (index, batch) in batches.enumerated() {
            let batchEntities = try await extractBatch(messages: batch, workspaceId: workspaceId, apiKey: apiKey)
            all.append(contentsOf: batchEntities)

            if index < (batches.count - 1) {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

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
            let wireEntities = try JSONDecoder().decode([ExtractedEntityWire].self, from: Data(stripJsonCodeFence(content).utf8))
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
        let messageById = Dictionary(uniqueKeysWithValues: messages.map { ($0.messageId, $0) })

        return rows.compactMap { row in
            guard let messageId = row.messageId ?? row.message_id, let source = messageById[messageId] else {
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
                confidence: confidence
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
            lines.append("Date: \(iso.string(from: message.date))")
            lines.append("Direction: inbound")
            lines.append("Body: \(message.bodyText)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func entityExtractionSystemPrompt(accountOwner: String) -> String {
        """
        You are a precise email entity extractor. Extract structured facts from this email for the account owner: \(accountOwner)

        Respond with ONLY a JSON object. No explanation, no markdown, no code fences.

        {
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

        Rules:
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

    private func normalizeStatus(_ value: String) -> String {
        switch value.lowercased() {
        case "paid", "overdue", "pending", "requires_action", "unknown":
            return value.lowercased()
        case "open":
            return "pending"
        default:
            return "unknown"
        }
    }

    private func normalizeRisk(_ value: String) -> String {
        switch value.lowercased() {
        case "low", "medium", "high":
            return value.lowercased()
        case "critical":
            return "high"
        default:
            return "low"
        }
    }

    private func normalizeEntityType(_ value: String) -> String {
        let normalized = value.lowercased()
        let allowed = ["invoice", "payment", "contract", "correspondence", "alert", "request"]
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

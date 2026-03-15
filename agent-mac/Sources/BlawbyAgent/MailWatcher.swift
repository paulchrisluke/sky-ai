import Foundation
import ScriptingBridge

struct EntitiesPayload: Codable {
    let type: String
    let entities: [ExtractedEntity]
}

final class MailWatcher {
    private let configStore: ConfigStore
    private let localStore: LocalStore
    private let mailProcessor: MailProcessor
    private let logger: Logger
    private let onPayload: (String) -> Void
    private let queue = DispatchQueue(label: "com.blawby.agent.mail")
    private var timer: DispatchSourceTimer?

    init(
        configStore: ConfigStore,
        localStore: LocalStore,
        mailProcessor: MailProcessor,
        logger: Logger,
        onPayload: @escaping (String) -> Void
    ) {
        self.configStore = configStore
        self.localStore = localStore
        self.mailProcessor = mailProcessor
        self.logger = logger
        self.onPayload = onPayload
    }

    func start() {
        queue.async {
            self.poll()
            self.startTimer()
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 120, repeating: 120)
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        timer = t
        t.resume()
    }

    private func poll() {
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail watcher failed: could not create SBApplication for Mail")
            return
        }

        let appObject = mailApp as NSObject

        let config = configStore.load()
        let lastSeen = localStore.getCursor(accountId: config.accountId, source: "mail").lastSeenAt ?? .distantPast
        var newestSeen = lastSeen
        var rawMessages: [RawMessage] = []

        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        logger.info("mail poll started accounts=\(accounts.count)")

        for account in accounts {
            let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
            let inboxes = mailboxes.filter { mailbox in
                let name = (mailbox.value(forKey: "name") as? String ?? "").lowercased()
                return name == "inbox"
            }

            for mailbox in inboxes {
                let messages = objectArray(from: mailbox.value(forKey: "messages"))
                for message in messages {
                    guard let dateSent = message.value(forKey: "dateSent") as? Date else {
                        continue
                    }
                    if dateSent <= lastSeen {
                        continue
                    }
                    guard let messageId = messageIdentifier(message) else {
                        continue
                    }

                    let subject = message.value(forKey: "subject") as? String ?? ""
                    let sender = message.value(forKey: "sender") as? String ?? ""
                    let toRecipients = recipientAddresses(from: message.value(forKey: "toRecipients"))
                    let bodyText = truncate(bodyText(from: message.value(forKey: "content")), maxLength: 2000)

                    rawMessages.append(
                        RawMessage(
                            messageId: messageId,
                            accountId: config.accountId,
                            subject: subject,
                            from: sender,
                            to: toRecipients,
                            date: dateSent,
                            bodyText: bodyText
                        )
                    )

                    if dateSent > newestSeen {
                        newestSeen = dateSent
                    }
                }
            }
        }

        if newestSeen > lastSeen {
            localStore.setCursor(
                accountId: config.accountId,
                source: "mail",
                lastSeenAt: newestSeen,
                lastSeenUid: nil
            )
        }

        if rawMessages.isEmpty {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let entities = try await mailProcessor.process(messages: rawMessages, workspaceId: config.workspaceId)
                if entities.isEmpty {
                    return
                }
                let payload = EntitiesPayload(type: "entities", entities: entities)
                let data = try JSONEncoder().encode(payload)
                guard let json = String(data: data, encoding: .utf8) else {
                    return
                }
                onPayload(json)
            } catch {
                logger.error("mail processing failed: \(error.localizedDescription)")
            }
        }
    }

    private func objectArray(from value: Any?) -> [NSObject] {
        if let array = value as? [NSObject] {
            return array
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? NSObject }
        }
        return []
    }

    private func recipientAddresses(from value: Any?) -> [String] {
        let recipients = objectArray(from: value)
        return recipients.compactMap { recipient in
            if let address = recipient.value(forKey: "address") as? String {
                return address
            }
            if let name = recipient.value(forKey: "name") as? String {
                return name
            }
            return nil
        }
    }

    private func messageIdentifier(_ message: NSObject) -> String? {
        if let messageId = message.value(forKey: "messageId") as? String, !messageId.isEmpty {
            return messageId
        }
        if let messageId = message.value(forKey: "id") as? Int {
            return String(messageId)
        }
        return nil
    }

    private func bodyText(from value: Any?) -> String {
        if let text = value as? String {
            return normalizeWhitespace(text)
        }
        if let rich = value as? NSAttributedString {
            return normalizeWhitespace(rich.string)
        }
        if let object = value as? NSObject {
            if let text = object.value(forKey: "string") as? String {
                return normalizeWhitespace(text)
            }
            return normalizeWhitespace(object.description)
        }
        return ""
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        String(text.prefix(maxLength))
    }
}

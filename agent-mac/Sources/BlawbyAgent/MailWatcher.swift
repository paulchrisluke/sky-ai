import Foundation
import ScriptingBridge

final class MailWatcher {
    private let configStore: ConfigStore
    private let localStore: LocalStore
    private let logger: Logger

    init(
        configStore: ConfigStore,
        localStore: LocalStore,
        logger: Logger
    ) {
        self.configStore = configStore
        self.localStore = localStore
        self.logger = logger
    }

    func fetchNewMessages() -> [RawMessage] {
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail watcher failed: could not create SBApplication for Mail")
            return []
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
            return []
        }
        return rawMessages
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

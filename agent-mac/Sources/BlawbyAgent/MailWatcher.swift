import Foundation
import ScriptingBridge

final class MailWatcher: @unchecked Sendable {
    private let maxMessagesToInspectPerPoll = 300
    private let maxNewMessagesPerPoll = 20

    private let configStore: ConfigStore
    private let localStore: LocalStore
    private let logger: Logger
    private let workQueue = DispatchQueue(label: "com.blawby.agent.mailwatcher", qos: .utility)
    private var distributedObserver: NSObjectProtocol?
    private var safetyTimer: DispatchSourceTimer?

    init(
        configStore: ConfigStore,
        localStore: LocalStore,
        logger: Logger
    ) {
        self.configStore = configStore
        self.localStore = localStore
        self.logger = logger
    }

    func startObserving(onChange: @escaping @Sendable () -> Void) {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.mail.MessageReceived"),
            object: nil,
            queue: nil
        ) { _ in
            onChange()
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 900, repeating: 900)
        timer.setEventHandler {
            onChange()
        }
        safetyTimer = timer
        timer.resume()
        logger.info("mail observer started (distributed notification + 15m safety)")
    }

    func stopObserving() {
        if let observer = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            distributedObserver = nil
        }
        safetyTimer?.cancel()
        safetyTimer = nil
        logger.info("mail observer stopped")
    }

    func accountNames() async -> [String] {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
                    continuation.resume(returning: [])
                    return
                }
                let appObject = mailApp as NSObject
                let accounts = objectArray(from: appObject.value(forKey: "accounts"))
                let names = accounts.compactMap { $0.value(forKey: "name") as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                continuation.resume(returning: names)
            }
        }
    }

    func fetchNewMessages() async -> [RawMessage] {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: fetchNewMessagesSync())
            }
        }
    }

    private func fetchNewMessagesSync() -> [RawMessage] {
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail watcher failed: could not create SBApplication for Mail")
            return []
        }

        let appObject = mailApp as NSObject

        let config = configStore.load()
        let cursor = localStore.getCursor(accountId: config.accountId, source: "mail_live")
        guard let lastSeen = cursor.lastSeenAt else {
            localStore.setCursor(
                accountId: config.accountId,
                source: "mail_live",
                lastSeenAt: Date(),
                lastSeenUid: nil
            )
            logger.info("mail live cursor initialized")
            return []
        }
        var newestSeen = lastSeen
        var rawMessages: [RawMessage] = []
        var inspected = 0

        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        logger.info("mail poll started accounts=\(accounts.count)")

        for account in accounts {
            let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
            let backfillMailboxes = selectableBackfillMailboxes(from: mailboxes)

            for mailbox in backfillMailboxes {
                let mailboxName = mailbox.value(forKey: "name") as? String ?? "INBOX"
                guard let messages = mailbox.value(forKey: "messages") as? NSArray else {
                    continue
                }
                if messages.count == 0 {
                    continue
                }

                var index = messages.count - 1
                while index >= 0 {
                    guard let message = messages[index] as? NSObject else {
                        if index == 0 { break }
                        index -= 1
                        continue
                    }
                    if inspected >= maxMessagesToInspectPerPoll || rawMessages.count >= maxNewMessagesPerPoll {
                        break
                    }
                    inspected += 1
                    if inspected % 500 == 0 {
                        logger.info("mail backfill progress inspected=\(inspected) matched=\(rawMessages.count) mailbox=\(mailboxName)")
                    }

                    guard let dateSent = message.value(forKey: "dateSent") as? Date else {
                        if index == 0 { break }
                        index -= 1
                        continue
                    }
                    if dateSent <= lastSeen {
                        break
                    }

                    autoreleasepool {
                        guard let messageId = messageIdentifier(message) else {
                            return
                        }
                        if localStore.isMessageProcessed(messageId) {
                            return
                        }

                        let subject = message.value(forKey: "subject") as? String ?? ""
                        let sender = message.value(forKey: "sender") as? String ?? ""
                        let toRecipients: [String] = []
                        let bodyText = truncate(subject, maxLength: 500)

                        rawMessages.append(
                            RawMessage(
                                messageId: messageId,
                                accountId: config.accountId,
                                subject: subject,
                                from: sender,
                                to: toRecipients,
                                date: dateSent,
                                bodyText: bodyText,
                                mailbox: mailboxName
                            )
                        )

                        if dateSent > newestSeen {
                            newestSeen = dateSent
                        }
                    }

                    if index == 0 { break }
                    index -= 1
                }
                if inspected >= maxMessagesToInspectPerPoll || rawMessages.count >= maxNewMessagesPerPoll {
                    break
                }
            }
            if inspected >= maxMessagesToInspectPerPoll || rawMessages.count >= maxNewMessagesPerPoll {
                break
            }
        }

        if newestSeen > lastSeen {
            localStore.setCursor(
                accountId: config.accountId,
                source: "mail_live",
                lastSeenAt: newestSeen,
                lastSeenUid: nil
            )
        }

        if rawMessages.isEmpty {
            logger.info("mail poll completed inspected=\(inspected) new=0")
            return []
        }
        logger.info("mail poll completed inspected=\(inspected) new=\(rawMessages.count)")
        return rawMessages
    }

    func fetchMessagesSince(_ since: Date, limit: Int) async -> [RawMessage] {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: fetchMessagesBetweenSync(since, Date.distantFuture, limit: limit))
            }
        }
    }

    func fetchMessagesBetween(_ start: Date, _ end: Date, limit: Int) async -> [RawMessage] {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: fetchMessagesBetweenSync(start, end, limit: limit))
            }
        }
    }

    private func fetchMessagesBetweenSync(_ start: Date, _ end: Date, limit: Int) -> [RawMessage] {
        let boundedStart = min(start, end)
        let boundedEnd = max(start, end)
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail backfill failed: could not create SBApplication for Mail")
            return []
        }

        let appObject = mailApp as NSObject
        let config = configStore.load()
        var rawMessages: [RawMessage] = []
        var inspected = 0
        let maxInspect = Int.max

        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        logger.info("mail backfill started accounts=\(accounts.count) start=\(boundedStart) end=\(boundedEnd)")

        for account in accounts {
            let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
            let candidateMailboxes = selectableBackfillMailboxes(from: mailboxes)

            for mailbox in candidateMailboxes {
                let mailboxName = mailbox.value(forKey: "name") as? String ?? "INBOX"
                guard let messages = mailbox.value(forKey: "messages") as? NSArray else {
                    continue
                }
                if messages.count == 0 {
                    continue
                }

                var index = messages.count - 1
                while index >= 0 {
                    guard let message = messages[index] as? NSObject else {
                        if index == 0 { break }
                        index -= 1
                        continue
                    }
                    if inspected >= maxInspect || rawMessages.count >= limit {
                        break
                    }
                    inspected += 1
                    if inspected % 1000 == 0 {
                        logger.info("mail backfill progress inspected=\(inspected) matched=\(rawMessages.count) mailbox=\(mailboxName)")
                    }

                    guard let dateSent = message.value(forKey: "dateSent") as? Date else {
                        if index == 0 { break }
                        index -= 1
                        continue
                    }
                    if dateSent < boundedStart {
                        break
                    }
                    if dateSent >= boundedEnd {
                        if index == 0 { break }
                        index -= 1
                        continue
                    }

                    autoreleasepool {
                        guard let messageId = messageIdentifier(message) else {
                            return
                        }
                        if localStore.isMessageProcessed(messageId) {
                            return
                        }

                        let subject = message.value(forKey: "subject") as? String ?? ""
                        let sender = message.value(forKey: "sender") as? String ?? ""
                        let toRecipients: [String] = []
                        let bodyText = truncate(subject, maxLength: 500)

                        rawMessages.append(
                            RawMessage(
                                messageId: messageId,
                                accountId: config.accountId,
                                subject: subject,
                                from: sender,
                                to: toRecipients,
                                date: dateSent,
                                bodyText: bodyText,
                                mailbox: mailboxName
                            )
                        )
                    }

                    if index == 0 { break }
                    index -= 1
                }
                if inspected >= maxInspect || rawMessages.count >= limit {
                    break
                }
            }
            if inspected >= maxInspect || rawMessages.count >= limit {
                break
            }
        }

        logger.info("mail backfill completed inspected=\(inspected) matched=\(rawMessages.count) start=\(boundedStart) end=\(boundedEnd)")
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

    private func messageIdentifier(_ message: NSObject) -> String? {
        if let messageId = message.value(forKey: "messageId") as? String, !messageId.isEmpty {
            return messageId
        }
        if let messageId = message.value(forKey: "id") as? Int {
            return String(messageId)
        }
        return nil
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        String(text.prefix(maxLength))
    }

    private func recipientEmails(from value: Any?) -> [String] {
        let recipients = objectArray(from: value)
        return recipients.compactMap { recipient in
            let addressKeys = ["address", "emailAddress", "email"]
            for key in addressKeys {
                if let email = recipient.value(forKey: key) as? String,
                   !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return email.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let raw = recipient.value(forKey: "name") as? String,
               let extracted = extractEmailAddress(from: raw) {
                return extracted
            }
            return nil
        }
    }

    private func extractEmailAddress(from input: String) -> String? {
        if input.contains("@"), !input.contains("<") {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = input.firstIndex(of: "<"), let end = input.firstIndex(of: ">"), start < end else {
            return nil
        }
        let email = input[input.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    private func selectableBackfillMailboxes(from mailboxes: [NSObject]) -> [NSObject] {
        let includeKeywords = ["inbox", "sent"]
        return mailboxes.filter { mailbox in
            let name = (mailbox.value(forKey: "name") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return includeKeywords.contains(where: { name.contains($0) })
        }
    }
}

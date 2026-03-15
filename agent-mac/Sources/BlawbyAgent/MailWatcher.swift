import Foundation
import ScriptingBridge

struct MailSourceDescriptor: Sendable {
    let id: String
    let accountId: String
    let mailbox: String
    let sourceName: String
}

final class MailWatcher: @unchecked Sendable {
    private let maxMessagesToInspectPerPoll = 300
    private let maxNewMessagesPerPoll = 20

    private let configStore: ConfigStore
    private let logger: Logger
    private let workQueue = DispatchQueue(label: "com.blawby.agent.mailwatcher", qos: .utility)
    private var distributedObserver: NSObjectProtocol?
    private var safetyTimer: DispatchSourceTimer?

    init(
        configStore: ConfigStore,
        logger: Logger
    ) {
        self.configStore = configStore
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

    func discoverSources() async -> [MailSourceDescriptor] {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: discoverSourcesSync())
            }
        }
    }

    func oldestMessageDate(accountId: String, mailbox: String) async -> Date? {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: oldestMessageDateSync(accountId: accountId, mailbox: mailbox))
            }
        }
    }

    func messageCount(accountId: String, mailbox: String) async -> Int {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: messageCountSync(accountId: accountId, mailbox: mailbox))
            }
        }
    }

    func fetchMessages(accountId: String, mailbox: String, since: Date, limit: Int) async -> [RawMessage] {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(
                    returning: fetchMessagesSync(accountId: accountId, mailbox: mailbox, since: since, limit: limit)
                )
            }
        }
    }

    private func fetchNewMessagesSync() -> [RawMessage] {
        let config = configStore.load()
        let recentCutoff = Date(timeIntervalSinceNow: -300)
        let sources = discoverSourcesSync().filter { $0.accountId.caseInsensitiveCompare(config.accountId) == .orderedSame }
        var out: [RawMessage] = []
        for source in sources {
            let messages = fetchMessagesSync(
                accountId: source.accountId,
                mailbox: source.mailbox,
                since: recentCutoff,
                limit: maxNewMessagesPerPoll
            )
            out.append(contentsOf: messages)
            if out.count >= maxNewMessagesPerPoll {
                break
            }
        }
        return Array(out.prefix(maxNewMessagesPerPoll))
    }

    private func discoverSourcesSync() -> [MailSourceDescriptor] {
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail source discovery failed: could not create SBApplication for Mail")
            return []
        }
        let appObject = mailApp as NSObject
        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        var out: [MailSourceDescriptor] = []
        for account in accounts {
            let accountName = (account.value(forKey: "name") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if accountName.isEmpty {
                continue
            }
            let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
            let selected = selectableBackfillMailboxes(from: mailboxes)
            for mailbox in selected {
                let mailboxName = (mailbox.value(forKey: "name") as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if mailboxName.isEmpty {
                    continue
                }
                out.append(
                    MailSourceDescriptor(
                        id: "mail:\(accountName):\(mailboxName)",
                        accountId: accountName,
                        mailbox: mailboxName,
                        sourceName: "\(accountName) - \(mailboxName)"
                    )
                )
            }
        }
        return out.sorted { lhs, rhs in
            lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
        }
    }

    private func oldestMessageDateSync(accountId: String, mailbox: String) -> Date? {
        guard let targetMailbox = findMailbox(accountId: accountId, mailbox: mailbox) else {
            return nil
        }
        guard let messages = targetMailbox.value(forKey: "messages") as? NSArray else {
            return nil
        }
        if messages.count == 0 {
            return nil
        }
        var oldest: Date?
        for item in messages {
            guard let message = item as? NSObject else { continue }
            guard let sent = message.value(forKey: "dateSent") as? Date else { continue }
            if let current = oldest {
                if sent < current {
                    oldest = sent
                }
            } else {
                oldest = sent
            }
        }
        return oldest
    }

    private func messageCountSync(accountId: String, mailbox: String) -> Int {
        guard let targetMailbox = findMailbox(accountId: accountId, mailbox: mailbox) else {
            return 0
        }
        guard let messages = targetMailbox.value(forKey: "messages") as? NSArray else {
            return 0
        }
        return messages.count
    }

    private func fetchMessagesSync(accountId: String, mailbox: String, since: Date, limit: Int) -> [RawMessage] {
        guard let targetMailbox = findMailbox(accountId: accountId, mailbox: mailbox) else {
            return []
        }
        guard let messages = targetMailbox.value(forKey: "messages") as? NSArray else {
            return []
        }
        if messages.count == 0 || limit <= 0 {
            return []
        }

        var out: [RawMessage] = []
        for index in 0..<messages.count {
            guard let message = messages[index] as? NSObject else {
                continue
            }
            guard let sent = message.value(forKey: "dateSent") as? Date else {
                continue
            }
            if sent < since {
                continue
            }
            guard let messageId = messageIdentifier(message) else {
                continue
            }
            let subject = message.value(forKey: "subject") as? String ?? ""
            let sender = message.value(forKey: "sender") as? String ?? ""
            let body = truncate(subject, maxLength: 500)
            let toRecipients = recipientEmails(from: message.value(forKey: "toRecipients"))
            out.append(
                RawMessage(
                    messageId: messageId,
                    accountId: accountId,
                    subject: subject,
                    from: sender,
                    to: toRecipients,
                    date: sent,
                    bodyText: body,
                    mailbox: mailbox
                )
            )
            if out.count >= limit {
                break
            }
        }
        return out
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
        let includeKeywords = ["inbox", "sent", "archive", "all mail"]
        return mailboxes.filter { mailbox in
            let name = (mailbox.value(forKey: "name") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return includeKeywords.contains(where: { name.contains($0) })
        }
    }

    private func findMailbox(accountId: String, mailbox: String) -> NSObject? {
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail source fetch failed: could not create SBApplication for Mail")
            return nil
        }
        let appObject = mailApp as NSObject
        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        guard let account = accounts.first(where: {
            (($0.value(forKey: "name") as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(accountId) == .orderedSame
        }) else {
            return nil
        }
        let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
        return mailboxes.first(where: {
            (($0.value(forKey: "name") as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(mailbox) == .orderedSame
        })
    }
}

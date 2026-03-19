import Foundation
import ScriptingBridge
import OSLog

struct MailSourceDescriptor: Sendable {
    let id: String
    let accountId: String
    let mailbox: String
    let sourceName: String
}

final class MailWatcher: @unchecked Sendable {
    private let maxMessagesToInspectPerPoll = 300
    private let maxNewMessagesPerPoll = 20
    private let perSourceBatchSize = 100
    private let interSourceDelayNanoseconds: UInt64 = 500_000_000

    private let configStore: ConfigStore
    private let logger: Logger
    private let workQueue = DispatchQueue(label: "com.blawby.agent.mailwatcher", qos: .utility)
    private let emlxReader: EmlxReader
    private var distributedObserver: NSObjectProtocol?
    private var safetyTimer: DispatchSourceTimer?
    
    // Cache for discovered accounts and mailboxes to avoid re-discovery on every fetch
    private var cachedAccounts: [EmlxAccount]?
    private var cachedMailboxes: [String: [EmlxMailbox]] = [:] // accountId -> mailboxes
    private var lastCacheUpdate: Date = .distantPast

    init(
        configStore: ConfigStore,
        logger: Logger
    ) {
        self.configStore = configStore
        self.logger = logger
        self.emlxReader = EmlxReader(logger: logger)
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
        if emlxReader.isAvailable() {
            return emlxReader.discoverAccounts().map { $0.displayName }
        }
        
        return await withCheckedContinuation { continuation in
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
                limit: perSourceBatchSize
            )
            out.append(contentsOf: messages)
            if out.count >= maxNewMessagesPerPoll {
                break
            }
        }
        return Array(out.prefix(maxNewMessagesPerPoll))
    }

    private func discoverSourcesSync() -> [MailSourceDescriptor] {
        if emlxReader.isAvailable() {
            updateCacheIfNeeded()
            
            if let accounts = cachedAccounts {
                var out: [MailSourceDescriptor] = []
                for account in accounts {
                    let mailboxes = cachedMailboxes[account.displayName] ?? []
                    for mailbox in mailboxes {
                        logger.info("emlx: found mailbox '\(mailbox.name)' in account '\(account.displayName)' (path: \(mailbox.path.path))")
                        out.append(
                            MailSourceDescriptor(
                                id: "mail:\(account.displayName):\(mailbox.name)",
                                accountId: account.displayName,
                                mailbox: mailbox.name,
                                sourceName: "\(account.displayName) - \(mailbox.name)"
                            )
                        )
                    }
                }
                if !out.isEmpty {
                    return out.sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }
                }
            }
        }

        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else {
            logger.error("mail source discovery failed: could not create SBApplication for Mail")
            return []
        }
        let appObject = mailApp as NSObject
        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        var out: [MailSourceDescriptor] = []
        for account in accounts {
            if let keys = (account as? NSObject)?.value(forKey: "properties") as? [String: Any] {
                logger.info("mail: account properties: \(keys.keys.joined(separator: ", "))")
            }
            let name = (account.value(forKey: "name") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            
            // Try to get actual email from ScriptingBridge
            let emails = (account.value(forKey: "emailAddresses") as? [Any])?.compactMap { $0 as? String }
            let bestEmail = emails?.first { $0.contains("@") } ?? name
            let accountName = ConfigStore.normalizeAccountId(bestEmail)
            
            let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
            let selected = selectableBackfillMailboxes(from: mailboxes)
            for mailbox in selected {
                let mailboxName = (mailbox.value(forKey: "name") as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if mailboxName.isEmpty { continue }
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
        return out.sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }
    }

    private func oldestMessageDateSync(accountId: String, mailbox: String) -> Date? {
        if emlxReader.isAvailable() {
            let accounts = emlxReader.discoverAccounts()
            if let account = accounts.first(where: { $0.displayName == accountId }) {
                let mailboxes = emlxReader.discoverMailboxes(account: account)
                if let target = mailboxes.first(where: { $0.name == mailbox }) {
                    // Optimized check: the reader readMessages already handles dates.
                    // For "oldest", we can just fetch the oldest message by sorting.
                    // But for now, we'll just return a safe distant past or nil.
                    return nil // Will trigger backfill from epoch
                }
            }
        }

        guard let targetMailbox = findMailbox(accountId: accountId, mailbox: mailbox) else { return nil }
        guard let messages = targetMailbox.value(forKey: "messages") as? NSArray else { return nil }
        if messages.count == 0 { return nil }
        
        var candidates: [Date] = []
        if let first = messages[0] as? NSObject, let d1 = first.value(forKey: "dateSent") as? Date {
            candidates.append(d1)
        }
        if messages.count > 1, let last = messages[messages.count - 1] as? NSObject, let d2 = last.value(forKey: "dateSent") as? Date {
            candidates.append(d2)
        }
        return candidates.min()
    }

    private func messageCountSync(accountId: String, mailbox: String) -> Int {
        if emlxReader.isAvailable() {
            let accounts = emlxReader.discoverAccounts()
            if let account = accounts.first(where: { $0.displayName == accountId }) {
                let mailboxes = emlxReader.discoverMailboxes(account: account)
                if let target = mailboxes.first(where: { $0.name == mailbox }) {
                    return emlxReader.messageCount(mailbox: target)
                }
            }
        }

        guard let targetMailbox = findMailbox(accountId: accountId, mailbox: mailbox) else { return 0 }
        guard let messages = targetMailbox.value(forKey: "messages") as? NSArray else { return 0 }
        return messages.count
    }

    private func updateCacheIfNeeded() {
        let now = Date()
        // Update cache every 5 minutes or if cache is empty
        if cachedAccounts == nil || now.timeIntervalSince(lastCacheUpdate) > 300 {
            logger.info("emlx: starting account discovery scan")
            let accounts = emlxReader.discoverAccounts()
            cachedAccounts = accounts
            
            // Clear and rebuild mailbox cache
            cachedMailboxes.removeAll()
            for account in accounts {
                let mailboxes = emlxReader.discoverMailboxes(account: account)
                cachedMailboxes[account.displayName] = mailboxes
            }
            lastCacheUpdate = now
            logger.info("emlx: cache updated - \(accounts.count) accounts, \(cachedMailboxes.values.map { $0.count }.reduce(0, +)) total mailboxes")
        }
    }
    
    private func fetchMessagesSync(accountId: String, mailbox: String, since: Date, limit: Int) -> [RawMessage] {
        logger.info("fetchMessagesSync: account=\(accountId) mailbox=\(mailbox) since=\(since) limit=\(limit)")
        
        // For Gmail, INBOX maps to All Mail on disk
        let effectiveMailbox = (mailbox == "INBOX" && accountId.contains("gmail")) ? "All Mail" : mailbox
        
        if emlxReader.isAvailable() {
            updateCacheIfNeeded()
            
            if let account = cachedAccounts?.first(where: { $0.displayName == accountId }) {
                let mailboxes = cachedMailboxes[accountId] ?? []
                if let target = mailboxes.first(where: { $0.name == effectiveMailbox }) {
                    let results = emlxReader.readMessages(mailbox: target, since: since, limit: limit)
                    if !results.isEmpty {
                        logger.info("emlx: fetched \(results.count) messages via direct filesystem")
                        return results
                    }
                }
            }
        }

        guard let targetMailbox = findMailbox(accountId: accountId, mailbox: mailbox) else { return [] }
        guard let messages = targetMailbox.value(forKey: "messages") as? SBElementArray else { return [] }
        
        let count = messages.count
        if count == 0 { return [] }

        var targetIndices: [Int] = []
        let chunkSize = 2000
        var isAscending = true
        let d0 = (count > 0) ? (messages[0] as? NSObject)?.value(forKey: "dateSent") as? Date : nil
        let dN = (count > 1) ? (messages[count - 1] as? NSObject)?.value(forKey: "dateSent") as? Date : nil
        if let d0, let dN { isAscending = d0 < dN }

        let isEpoch = since.timeIntervalSince1970 < 1000
        if isEpoch {
            if isAscending {
                for i in 0..<min(limit, count) { targetIndices.append(i) }
            } else {
                for i in (max(0, count-limit)..<count).reversed() { targetIndices.append(i) }
            }
        } else {
            if isAscending {
                for start in stride(from: 0, to: count, by: chunkSize) {
                    let end = min(start + chunkSize, count)
                    autoreleasepool {
                        let chunkProxies = messages.objects(at: IndexSet(integersIn: start..<end))
                        let chunkDates = (chunkProxies as NSArray).value(forKey: "dateSent") as? [Date] ?? []
                        for (i, date) in chunkDates.enumerated() {
                            if date >= since {
                                targetIndices.append(start + i)
                                if targetIndices.count >= limit { break }
                            }
                        }
                    }
                    if !targetIndices.isEmpty { break }
                }
            } else {
                for end in stride(from: count, to: 0, by: -chunkSize) {
                    let start = max(0, end - chunkSize)
                    autoreleasepool {
                        let chunkProxies = messages.objects(at: IndexSet(integersIn: start..<end))
                        let chunkDates = (chunkProxies as NSArray).value(forKey: "dateSent") as? [Date] ?? []
                        for i in (0..<chunkDates.count).reversed() {
                            if chunkDates[i] >= since {
                                targetIndices.append(start + i)
                                if targetIndices.count >= limit { break }
                            }
                        }
                    }
                    if !targetIndices.isEmpty { break }
                }
            }
        }

        var out: [RawMessage] = []
        for (i, idx) in targetIndices.enumerated() {
            autoreleasepool {
                guard let msg = messages[idx] as? NSObject else { return }
                let sentDate = (msg.value(forKey: "dateSent") as? Date) ?? Date()
                if sentDate >= since {
                    let subject = (msg.value(forKey: "subject") as? String) ?? ""
                    let sender = (msg.value(forKey: "sender") as? String) ?? ""
                    let msgId = (msg.value(forKey: "messageId") as? String) ?? "\(idx)"
                    let body = truncate(subject, maxLength: 500)
                    out.append(RawMessage(messageId: msgId, accountId: accountId, subject: subject, from: sender, to: [], date: sentDate, bodyText: body, mailbox: mailbox))
                }
                if i % 10 == 0 { logger.info("  sb progress: \(i+1)/\(targetIndices.count)") }
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
        let config = configStore.load()
        let sources = discoverSourcesSync().filter { $0.accountId.caseInsensitiveCompare(config.accountId) == .orderedSame }
        
        var results: [RawMessage] = []
        for source in sources {
            let messages = fetchMessagesSync(accountId: source.accountId, mailbox: source.mailbox, since: boundedStart, limit: limit - results.count)
            results.append(contentsOf: messages)
            if results.count >= limit { break }
        }
        return results
    }

    private func objectArray(from value: Any?) -> [NSObject] {
        if let array = value as? [NSObject] { return array }
        if let array = value as? NSArray { return array.compactMap { $0 as? NSObject } }
        return []
    }

    private func messageIdentifier(_ message: NSObject) -> String? {
        if let messageId = message.value(forKey: "messageId") as? String, !messageId.isEmpty { return messageId }
        if let internalId = message.value(forKey: "id") as? Int { return String(internalId) }
        return nil
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        String(text.prefix(maxLength))
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
        guard let mailApp = SBApplication(bundleIdentifier: "com.apple.mail") else { return nil }
        let appObject = mailApp as NSObject
        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        guard let account = accounts.first(where: {
            (($0.value(forKey: "name") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(accountId) == .orderedSame
        }) else { return nil }
        let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
        return mailboxes.first(where: {
            (($0.value(forKey: "name") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(mailbox) == .orderedSame
        })
    }
}

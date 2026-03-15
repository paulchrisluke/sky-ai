import Foundation
import ScriptingBridge

final class MailWatcher {
    private let maxMessagesToInspectPerPoll = 300
    private let maxNewMessagesPerPoll = 20

    private let configStore: ConfigStore
    private let localStore: LocalStore
    private let logger: Logger
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

    func startObserving(onChange: @escaping () -> Void) {
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
        var inspected = 0

        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        logger.info("mail poll started accounts=\(accounts.count)")

        for account in accounts {
            let mailboxes = objectArray(from: account.value(forKey: "mailboxes"))
            let inboxes = mailboxes.filter { mailbox in
                let name = (mailbox.value(forKey: "name") as? String ?? "").lowercased()
                return name == "inbox"
            }

            for mailbox in inboxes {
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

                    autoreleasepool {
                        guard let dateSent = message.value(forKey: "dateSent") as? Date else {
                            return
                        }
                        if dateSent <= lastSeen {
                            return
                        }
                        guard let messageId = messageIdentifier(message) else {
                            return
                        }

                        let subject = message.value(forKey: "subject") as? String ?? ""
                        let sender = message.value(forKey: "sender") as? String ?? ""
                        let bodyText = truncate(subject, maxLength: 2000)

                        rawMessages.append(
                            RawMessage(
                                messageId: messageId,
                                accountId: config.accountId,
                                subject: subject,
                                from: sender,
                                to: [],
                                date: dateSent,
                                bodyText: bodyText
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
                source: "mail",
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
}

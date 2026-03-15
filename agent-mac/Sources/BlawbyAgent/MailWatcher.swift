import Foundation
import ScriptingBridge

struct EmailPayload: Codable {
    let type: String
    let source: String
    let workspaceId: String
    let accountId: String
    let accountEmail: String
    let subject: String
    let from: [String]
    let to: [String]
    let date: String
    let rawRfc822: String
}

final class MailWatcher {
    private let configStore: ConfigStore
    private let localStore: LocalStore
    private let logger: Logger
    private let onPayload: (String) -> Void
    private let iso = ISO8601DateFormatter()
    private let queue = DispatchQueue(label: "com.blawby.agent.mail")
    private var timer: DispatchSourceTimer?

    init(configStore: ConfigStore, localStore: LocalStore, logger: Logger, onPayload: @escaping (String) -> Void) {
        self.configStore = configStore
        self.localStore = localStore
        self.logger = logger
        self.onPayload = onPayload
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

        let accounts = objectArray(from: appObject.value(forKey: "accounts"))
        logger.info("mail poll started accounts=\(accounts.count)")

        for account in accounts {
            let accountEmail = firstEmailAddress(account) ?? "unknown"
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

                    let subject = message.value(forKey: "subject") as? String ?? ""
                    let sender = message.value(forKey: "sender") as? String ?? ""
                    let toRecipients = recipientAddresses(from: message.value(forKey: "toRecipients"))
                    let rawRfc822 = message.value(forKey: "source") as? String ?? ""

                    let payload = EmailPayload(
                        type: "email",
                        source: "mac_mail",
                        workspaceId: config.workspaceId,
                        accountId: config.accountId,
                        accountEmail: accountEmail,
                        subject: subject,
                        from: sender.isEmpty ? [] : [sender],
                        to: toRecipients,
                        date: iso.string(from: dateSent),
                        rawRfc822: rawRfc822
                    )

                    do {
                        let data = try JSONEncoder().encode(payload)
                        guard let json = String(data: data, encoding: .utf8) else { continue }
                        onPayload(json)
                    } catch {
                        logger.error("mail payload encode failed: \(error.localizedDescription)")
                    }

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

    private func firstEmailAddress(_ account: NSObject) -> String? {
        if let emails = account.value(forKey: "emailAddresses") as? [String], let first = emails.first {
            return first
        }
        if let emails = account.value(forKey: "emailAddresses") as? NSArray {
            return emails.compactMap({ $0 as? String }).first
        }
        return nil
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
}

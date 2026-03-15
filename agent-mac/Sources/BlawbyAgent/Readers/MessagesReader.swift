import Foundation
import GRDB
import Darwin

struct MacMessagePayload: Codable {
    let type: String
    let accountId: String
    let workspaceId: String
    let messages: [Item]

    struct Item: Codable {
        let id: Int64
        let text: String
        let sender: String
        let sentAt: String
    }
}

final class MessagesReader {
    private let localStore: LocalStore
    private let logger: Logger
    private let accountId: String
    private let workspaceId: String
    private let dbPath: String
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let iso = ISO8601DateFormatter()

    init(localStore: LocalStore, logger: Logger, accountId: String, workspaceId: String) {
        self.localStore = localStore
        self.logger = logger
        self.accountId = accountId
        self.workspaceId = workspaceId
        self.dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start(onChange: @escaping (String) -> Void) {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            logger.warning("messages db missing at \(dbPath)")
            return
        }

        fileDescriptor = open(dbPath, O_EVTONLY)
        if fileDescriptor < 0 {
            fileDescriptor = open(dbPath, O_RDONLY)
        }
        if fileDescriptor < 0 {
            logger.error("messages watcher open failed")
            return
        }

        let queue = DispatchQueue.global(qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let payload = self.fetchLatestPayload()
            if let payload {
                onChange(payload)
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
        logger.info("messages watcher started")
    }

    private func fetchLatestPayload() -> String? {
        do {
            let dbQueue = try DatabaseQueue(path: dbPath)
            let cursor = localStore.getCursor(accountId: accountId, source: "messages")
            let lastDate = cursor.lastSeenAt ?? Date(timeIntervalSince1970: 0)
            let lastAppleTime = Int64((lastDate.timeIntervalSince1970 - 978307200.0) * 1_000_000_000.0)

            let rows = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT ROWID as rowid, text, date, handle.id as sender
                    FROM message
                    LEFT JOIN handle ON handle.ROWID = message.handle_id
                    WHERE text IS NOT NULL
                      AND date > ?
                    ORDER BY date ASC
                    LIMIT 50
                    """,
                    arguments: [lastAppleTime]
                )
            }
            if rows.isEmpty { return nil }

            var latest = lastDate
            let items: [MacMessagePayload.Item] = rows.compactMap { row in
                let rawDate: Int64 = row["date"]
                let sentAt = Date(timeIntervalSince1970: 978307200.0 + Double(rawDate) / 1_000_000_000.0)
                if sentAt > latest { latest = sentAt }
                return MacMessagePayload.Item(
                    id: row["rowid"],
                    text: (row["text"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    sender: row["sender"] as String? ?? "unknown",
                    sentAt: iso.string(from: sentAt)
                )
            }.filter { !$0.text.isEmpty }

            if items.isEmpty { return nil }
            localStore.setCursor(accountId: accountId, source: "messages", lastSeenAt: latest, lastSeenUid: nil)
            let payload = MacMessagePayload(type: "message", accountId: accountId, workspaceId: workspaceId, messages: items)
            let data = try JSONEncoder().encode(payload)
            return String(data: data, encoding: .utf8)
        } catch {
            logger.error("messages read failed: \(error.localizedDescription)")
            return nil
        }
    }
}

import Foundation
import GRDB

final class LocalStore {
    private let dbQueue: DatabaseQueue
    private let iso: ISO8601DateFormatter

    init(baseDirectory: URL) throws {
        let dbURL = baseDirectory.appendingPathComponent("blawby.db")
        self.dbQueue = try DatabaseQueue(path: dbURL.path)
        self.iso = ISO8601DateFormatter()
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local_store") { db in
            try db.create(table: "sync_cursors") { t in
                t.column("account_id", .text).notNull()
                t.column("source", .text).notNull()
                t.column("last_seen_at", .text)
                t.column("last_seen_uid", .text)
                t.column("updated_at", .text).notNull()
                t.primaryKey(["account_id", "source"])
            }

            try db.create(table: "processed_messages") { t in
                t.column("message_id", .text).primaryKey()
                t.column("account_id", .text).notNull()
                t.column("processed_at", .text).notNull()
                t.column("entity_count", .integer).notNull().defaults(to: 0)
                t.column("sent", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "processed_events") { t in
                t.column("event_uid", .text).notNull()
                t.column("calendar_id", .text).notNull()
                t.column("sent_at", .text).notNull()
                t.primaryKey(["event_uid", "calendar_id"])
            }

            try db.create(table: "outbound_queue") { t in
                t.column("id", .text).primaryKey()
                t.column("payload_type", .text).notNull()
                t.column("payload_json", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
        }

        try migrator.migrate(dbQueue)
    }

    func getCursor(accountId: String, source: String) -> (lastSeenAt: Date?, lastSeenUid: String?) {
        do {
            return try dbQueue.read { db in
                guard
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT last_seen_at, last_seen_uid
                        FROM sync_cursors
                        WHERE account_id = ? AND source = ?
                        """,
                        arguments: [accountId, source]
                    )
                else {
                    return (nil, nil)
                }

                let lastSeenAtText: String? = row["last_seen_at"]
                let lastSeenAt = lastSeenAtText.map { iso.date(from: $0) }.flatMap { $0 }
                let lastSeenUid: String? = row["last_seen_uid"]
                return (lastSeenAt, lastSeenUid)
            }
        } catch {
            fatalError("LocalStore.getCursor failed: \(error)")
        }
    }

    func setCursor(accountId: String, source: String, lastSeenAt: Date?, lastSeenUid: String?) {
        let lastSeenAtText = lastSeenAt.map { iso.string(from: $0) }
        let updatedAt = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sync_cursors (
                        account_id, source, last_seen_at, last_seen_uid, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, source) DO UPDATE SET
                        last_seen_at = excluded.last_seen_at,
                        last_seen_uid = excluded.last_seen_uid,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [accountId, source, lastSeenAtText, lastSeenUid, updatedAt]
                )
            }
        } catch {
            fatalError("LocalStore.setCursor failed: \(error)")
        }
    }

    func isMessageProcessed(_ messageId: String) -> Bool {
        do {
            return try dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM processed_messages WHERE message_id = ?)",
                    arguments: [messageId]
                ) ?? false
            }
        } catch {
            fatalError("LocalStore.isMessageProcessed failed: \(error)")
        }
    }

    func markMessageProcessed(_ messageId: String, accountId: String, entityCount: Int) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO processed_messages (
                        message_id, account_id, processed_at, entity_count, sent
                    ) VALUES (?, ?, ?, ?, 0)
                    """,
                    arguments: [messageId, accountId, iso.string(from: Date()), entityCount]
                )
            }
        } catch {
            fatalError("LocalStore.markMessageProcessed failed: \(error)")
        }
    }

    func markMessageSent(_ messageId: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE processed_messages SET sent = 1 WHERE message_id = ?",
                    arguments: [messageId]
                )
            }
        } catch {
            fatalError("LocalStore.markMessageSent failed: \(error)")
        }
    }

    func isEventSent(uid: String, calendarId: String) -> Bool {
        do {
            return try dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM processed_events
                        WHERE event_uid = ? AND calendar_id = ?
                    )
                    """,
                    arguments: [uid, calendarId]
                ) ?? false
            }
        } catch {
            fatalError("LocalStore.isEventSent failed: \(error)")
        }
    }

    func markEventSent(uid: String, calendarId: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO processed_events (event_uid, calendar_id, sent_at)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [uid, calendarId, iso.string(from: Date())]
                )
            }
        } catch {
            fatalError("LocalStore.markEventSent failed: \(error)")
        }
    }

    func enqueuePayload(type: String, json: String) -> String {
        let id = UUID().uuidString.lowercased()
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO outbound_queue (id, payload_type, payload_json, created_at, attempts)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                    arguments: [id, type, json, iso.string(from: Date())]
                )
            }
            return id
        } catch {
            fatalError("LocalStore.enqueuePayload failed: \(error)")
        }
    }

    func dequeuePendingPayloads(limit: Int) -> [(id: String, type: String, json: String)] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload_type, payload_json
                    FROM outbound_queue
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                    arguments: [limit]
                )

                return rows.map { row in
                    (
                        id: row["id"],
                        type: row["payload_type"],
                        json: row["payload_json"]
                    )
                }
            }
        } catch {
            fatalError("LocalStore.dequeuePendingPayloads failed: \(error)")
        }
    }

    func markPayloadSent(_ id: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM outbound_queue WHERE id = ?",
                    arguments: [id]
                )
            }
        } catch {
            fatalError("LocalStore.markPayloadSent failed: \(error)")
        }
    }

    func incrementPayloadAttempts(_ id: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE outbound_queue SET attempts = attempts + 1 WHERE id = ?",
                    arguments: [id]
                )
            }
        } catch {
            fatalError("LocalStore.incrementPayloadAttempts failed: \(error)")
        }
    }

    func payloadAttempts(_ id: String) -> Int {
        do {
            return try dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT attempts FROM outbound_queue WHERE id = ?",
                    arguments: [id]
                ) ?? 0
            }
        } catch {
            fatalError("LocalStore.payloadAttempts failed: \(error)")
        }
    }
}

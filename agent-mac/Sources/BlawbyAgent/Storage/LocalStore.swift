import Foundation
import GRDB

struct StoredContact {
    let email: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [String]
}

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

        migrator.registerMigration("v2_contacts") { db in
            try db.create(table: "contacts") { t in
                t.column("email", .text).primaryKey()
                t.column("given_name", .text).notNull().defaults(to: "")
                t.column("family_name", .text).notNull().defaults(to: "")
                t.column("organization_name", .text).notNull().defaults(to: "")
                t.column("phone_numbers_json", .text).notNull().defaults(to: "[]")
                t.column("updated_at", .text).notNull()
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
            fputs("LocalStore.getCursor failed: \(error)\n", stderr)
            return (nil, nil)
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
            logError("setCursor", error)
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
            logError("isMessageProcessed", error)
            return false
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
            logError("markMessageProcessed", error)
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
            logError("markMessageSent", error)
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
            logError("isEventSent", error)
            return false
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
            logError("markEventSent", error)
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
            logError("enqueuePayload", error)
            return id
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
            logError("dequeuePendingPayloads", error)
            return []
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
            logError("markPayloadSent", error)
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
            logError("incrementPayloadAttempts", error)
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
            logError("payloadAttempts", error)
            return 0
        }
    }

    func pendingPayloadCount() -> Int {
        do {
            return try dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbound_queue"
                ) ?? 0
            }
        } catch {
            logError("pendingPayloadCount", error)
            return 0
        }
    }

    func isBootstrapCompleted(accountId: String, key: String) -> Bool {
        getCursor(accountId: accountId, source: "bootstrap:\(key)").lastSeenAt != nil
    }

    func markBootstrapCompleted(accountId: String, key: String) {
        setCursor(
            accountId: accountId,
            source: "bootstrap:\(key)",
            lastSeenAt: Date(),
            lastSeenUid: "done"
        )
    }

    func replaceContacts(_ contacts: [StoredContact]) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM contacts")
                for contact in contacts {
                    try db.execute(
                        sql: """
                        INSERT INTO contacts (email, given_name, family_name, organization_name, phone_numbers_json, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            contact.email.lowercased(),
                            contact.givenName,
                            contact.familyName,
                            contact.organizationName,
                            String(data: try JSONEncoder().encode(contact.phoneNumbers), encoding: .utf8) ?? "[]",
                            iso.string(from: Date())
                        ]
                    )
                }
            }
        } catch {
            logError("replaceContacts", error)
        }
    }

    func lookupContact(email: String) -> StoredContact? {
        do {
            return try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT email, given_name, family_name, organization_name, phone_numbers_json
                    FROM contacts
                    WHERE email = ?
                    LIMIT 1
                    """,
                    arguments: [email.lowercased()]
                ) else {
                    return nil
                }
                let phoneJson: String = row["phone_numbers_json"]
                let phones = (try? JSONDecoder().decode([String].self, from: Data(phoneJson.utf8))) ?? []
                return StoredContact(
                    email: row["email"],
                    givenName: row["given_name"],
                    familyName: row["family_name"],
                    organizationName: row["organization_name"],
                    phoneNumbers: phones
                )
            }
        } catch {
            logError("lookupContact", error)
            return nil
        }
    }

    private func logError(_ operation: String, _ error: Error) {
        fputs("LocalStore.\(operation) failed: \(error)\n", stderr)
    }
}

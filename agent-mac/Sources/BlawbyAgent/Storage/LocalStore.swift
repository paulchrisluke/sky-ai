import Foundation
import GRDB

struct StoredContact {
    let email: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [String]
}

struct SyncMetrics {
    let discovered: Int
    let processed: Int
    let sent: Int
    let queued: Int
    let failed: Int
    let lastActivityAt: Date?
}

struct ConnectedSource {
    let id: String
    let sourceType: String
    let accountId: String
    let sourceName: String
    let enabled: Bool
    let syncCursor: Date?
    let totalEstimated: Int
    let totalSynced: Int
    let status: String
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
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

        migrator.registerMigration("v3_mail_accounts") { db in
            try db.create(table: "mail_accounts") { t in
                t.column("account_name", .text).primaryKey()
                t.column("first_seen_at", .text).notNull()
                t.column("last_seen_at", .text).notNull()
            }
        }

        migrator.registerMigration("v4_calendar_sources") { db in
            try db.create(table: "calendar_sources") { t in
                t.column("source_name", .text).primaryKey()
                t.column("first_seen_at", .text).notNull()
                t.column("last_seen_at", .text).notNull()
            }
        }

        migrator.registerMigration("v5_sync_metrics") { db in
            try db.create(table: "sync_metrics") { t in
                t.column("account_id", .text).notNull()
                t.column("source", .text).notNull()
                t.column("discovered_total", .integer).notNull().defaults(to: 0)
                t.column("processed_total", .integer).notNull().defaults(to: 0)
                t.column("sent_total", .integer).notNull().defaults(to: 0)
                t.column("queued_total", .integer).notNull().defaults(to: 0)
                t.column("failed_total", .integer).notNull().defaults(to: 0)
                t.column("last_activity_at", .text)
                t.column("updated_at", .text).notNull()
                t.primaryKey(["account_id", "source"])
            }
        }

        migrator.registerMigration("v6_connected_sources") { db in
            try db.create(table: "connected_sources") { t in
                t.column("id", .text).primaryKey()
                t.column("source_type", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("source_name", .text).notNull()
                t.column("enabled", .integer).notNull().defaults(to: 1)
                t.column("sync_cursor", .text)
                t.column("total_estimated", .integer).notNull().defaults(to: 0)
                t.column("total_synced", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "idle")
                t.column("last_error", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(index: "idx_connected_sources_account_type", on: "connected_sources", columns: ["account_id", "source_type"])
            try db.create(index: "idx_connected_sources_enabled_status", on: "connected_sources", columns: ["enabled", "status"])

            try db.execute(
                sql: """
                INSERT INTO connected_sources (
                  id, source_type, account_id, source_name, enabled,
                  sync_cursor, total_estimated, total_synced, status,
                  last_error, created_at, updated_at
                )
                SELECT
                  CASE
                    WHEN source = 'mail_live' THEN 'mail:' || account_id || ':INBOX'
                    WHEN source = 'messages' THEN 'messages:' || account_id
                    ELSE source || ':' || account_id
                  END AS id,
                  CASE
                    WHEN source = 'messages' THEN 'messages'
                    ELSE 'mail'
                  END AS source_type,
                  account_id,
                  CASE
                    WHEN source = 'mail_live' THEN account_id || ' - INBOX'
                    WHEN source = 'messages' THEN 'Messages'
                    ELSE source
                  END AS source_name,
                  1 AS enabled,
                  last_seen_at AS sync_cursor,
                  0 AS total_estimated,
                  0 AS total_synced,
                  CASE
                    WHEN last_seen_at IS NULL THEN 'idle'
                    ELSE 'current'
                  END AS status,
                  NULL AS last_error,
                  updated_at AS created_at,
                  updated_at
                FROM sync_cursors
                WHERE source NOT LIKE 'bootstrap:%'
                """
            )

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO connected_sources (
                  id, source_type, account_id, source_name, enabled,
                  sync_cursor, total_estimated, total_synced, status,
                  last_error, created_at, updated_at
                )
                SELECT
                  'mail:' || account_name || ':INBOX',
                  'mail',
                  account_name,
                  account_name || ' - INBOX',
                  1,
                  NULL,
                  0,
                  0,
                  'idle',
                  NULL,
                  first_seen_at,
                  last_seen_at
                FROM mail_accounts
                """
            )

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO connected_sources (
                  id, source_type, account_id, source_name, enabled,
                  sync_cursor, total_estimated, total_synced, status,
                  last_error, created_at, updated_at
                )
                SELECT
                  'calendar:' || source_name,
                  'calendar',
                  'calendar',
                  source_name,
                  1,
                  NULL,
                  0,
                  0,
                  'idle',
                  NULL,
                  first_seen_at,
                  last_seen_at
                FROM calendar_sources
                """
            )
        }

        try migrator.migrate(dbQueue)
    }

    func getCursor(accountId: String, source: String) -> (lastSeenAt: Date?, lastSeenUid: String?) {
        if source.hasPrefix("bootstrap:") {
            return getLegacyCursor(accountId: accountId, source: source)
        }

        do {
            return try dbQueue.read { db in
                let legacy = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT last_seen_uid
                    FROM sync_cursors
                    WHERE account_id = ? AND source = ?
                    LIMIT 1
                    """,
                    arguments: [accountId, source]
                )

                guard
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT sync_cursor
                        FROM connected_sources
                        WHERE id = ?
                        """,
                        arguments: [connectedSourceId(accountId: accountId, source: source)]
                    )
                else {
                    return (nil, nil)
                }

                let lastSeenAtText: String? = row["sync_cursor"]
                let lastSeenAt = lastSeenAtText.map { iso.date(from: $0) }.flatMap { $0 }
                let lastSeenUid: String? = legacy?["last_seen_uid"]
                return (lastSeenAt, lastSeenUid)
            }
        } catch {
            fputs("LocalStore.getCursor failed: \(error)\n", stderr)
            return (nil, nil)
        }
    }

    func setCursor(accountId: String, source: String, lastSeenAt: Date?, lastSeenUid: String?) {
        if source.hasPrefix("bootstrap:") {
            setLegacyCursor(accountId: accountId, source: source, lastSeenAt: lastSeenAt, lastSeenUid: lastSeenUid)
            return
        }

        let lastSeenAtText = lastSeenAt.map { iso.string(from: $0) }
        let updatedAt = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO connected_sources (
                        id, source_type, account_id, source_name, enabled,
                        sync_cursor, total_estimated, total_synced, status,
                        last_error, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, 1, ?, 0, 0, ?, NULL, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        sync_cursor = excluded.sync_cursor,
                        status = excluded.status,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        connectedSourceId(accountId: accountId, source: source),
                        connectedSourceType(for: source),
                        accountId,
                        connectedSourceName(accountId: accountId, source: source),
                        lastSeenAtText,
                        lastSeenAt == nil ? "idle" : "current",
                        updatedAt,
                        updatedAt
                    ]
                )

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

    func upsertMailAccounts(_ names: [String]) {
        let normalized = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }

        let now = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                for name in normalized {
                    try db.execute(
                        sql: """
                        INSERT INTO mail_accounts (account_name, first_seen_at, last_seen_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(account_name) DO UPDATE SET
                            last_seen_at = excluded.last_seen_at
                        """,
                        arguments: [name, now, now]
                    )
                }
            }
        } catch {
            logError("upsertMailAccounts", error)
        }
    }

    func knownMailAccounts() -> [String] {
        do {
            return try dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT account_name
                    FROM mail_accounts
                    ORDER BY lower(account_name) ASC
                    """
                )
            }
        } catch {
            logError("knownMailAccounts", error)
            return []
        }
    }

    func upsertCalendarSources(_ names: [String]) {
        let normalized = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }

        let now = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                for name in normalized {
                    try db.execute(
                        sql: """
                        INSERT INTO calendar_sources (source_name, first_seen_at, last_seen_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(source_name) DO UPDATE SET
                            last_seen_at = excluded.last_seen_at
                        """,
                        arguments: [name, now, now]
                    )
                }
            }
        } catch {
            logError("upsertCalendarSources", error)
        }
    }

    func knownCalendarSources() -> [String] {
        do {
            return try dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT source_name
                    FROM calendar_sources
                    ORDER BY lower(source_name) ASC
                    """
                )
            }
        } catch {
            logError("knownCalendarSources", error)
            return []
        }
    }

    func connectedSources() -> [ConnectedSource] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT
                      id, source_type, account_id, source_name, enabled,
                      sync_cursor, total_estimated, total_synced, status,
                      last_error, created_at, updated_at
                    FROM connected_sources
                    ORDER BY lower(source_type), lower(source_name), lower(id)
                    """
                )
                return rows.compactMap(connectedSource(from:))
            }
        } catch {
            logError("connectedSources", error)
            return []
        }
    }

    func connectedSource(id: String) -> ConnectedSource? {
        do {
            return try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                      id, source_type, account_id, source_name, enabled,
                      sync_cursor, total_estimated, total_synced, status,
                      last_error, created_at, updated_at
                    FROM connected_sources
                    WHERE id = ?
                    LIMIT 1
                    """,
                    arguments: [id]
                ) else {
                    return nil
                }
                return connectedSource(from: row)
            }
        } catch {
            logError("connectedSource", error)
            return nil
        }
    }

    func upsertConnectedSource(
        id: String,
        sourceType: String,
        accountId: String,
        sourceName: String,
        enabled: Bool = true,
        syncCursor: Date? = nil,
        totalEstimated: Int = 0,
        totalSynced: Int = 0,
        status: String = "idle",
        lastError: String? = nil
    ) {
        let now = iso.string(from: Date())
        let cursorText = syncCursor.map { iso.string(from: $0) }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO connected_sources (
                      id, source_type, account_id, source_name, enabled,
                      sync_cursor, total_estimated, total_synced, status,
                      last_error, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      source_type = excluded.source_type,
                      account_id = excluded.account_id,
                      source_name = excluded.source_name,
                      enabled = excluded.enabled,
                      sync_cursor = excluded.sync_cursor,
                      total_estimated = excluded.total_estimated,
                      total_synced = excluded.total_synced,
                      status = excluded.status,
                      last_error = excluded.last_error,
                      updated_at = excluded.updated_at
                    """,
                    arguments: [
                        id,
                        sourceType,
                        accountId,
                        sourceName,
                        enabled ? 1 : 0,
                        cursorText,
                        max(0, totalEstimated),
                        max(0, totalSynced),
                        status,
                        lastError,
                        now,
                        now
                    ]
                )
            }
        } catch {
            logError("upsertConnectedSource", error)
        }
    }

    func setConnectedSourceEnabled(id: String, enabled: Bool) {
        let now = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE connected_sources
                    SET enabled = ?, status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [enabled ? 1 : 0, enabled ? "idle" : "paused", now, id]
                )
            }
        } catch {
            logError("setConnectedSourceEnabled", error)
        }
    }

    func updateConnectedSourceSync(
        id: String,
        syncCursor: Date?,
        totalEstimated: Int? = nil,
        totalSynced: Int? = nil,
        status: String,
        lastError: String? = nil
    ) {
        let now = iso.string(from: Date())
        let cursorText = syncCursor.map { iso.string(from: $0) }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE connected_sources
                    SET sync_cursor = ?,
                        total_estimated = COALESCE(?, total_estimated),
                        total_synced = COALESCE(?, total_synced),
                        status = ?,
                        last_error = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        cursorText,
                        totalEstimated.map { max(0, $0) },
                        totalSynced.map { max(0, $0) },
                        status,
                        lastError,
                        now,
                        id
                    ]
                )
            }
        } catch {
            logError("updateConnectedSourceSync", error)
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
                    ORDER BY
                      CASE payload_type
                        WHEN 'entities' THEN 0
                        WHEN 'chunks' THEN 1
                        WHEN 'calendar' THEN 2
                        WHEN 'message' THEN 3
                        ELSE 4
                      END ASC,
                      created_at ASC
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

    func bootstrapCursorDate(accountId: String, key: String) -> Date? {
        getCursor(accountId: accountId, source: "bootstrap:\(key):cursor").lastSeenAt
    }

    func setBootstrapCursorDate(accountId: String, key: String, date: Date) {
        setCursor(
            accountId: accountId,
            source: "bootstrap:\(key):cursor",
            lastSeenAt: date,
            lastSeenUid: nil
        )
    }

    func clearBootstrapCursor(accountId: String, key: String) {
        setCursor(
            accountId: accountId,
            source: "bootstrap:\(key):cursor",
            lastSeenAt: nil,
            lastSeenUid: nil
        )
    }

    func incrementSyncMetrics(
        accountId: String,
        source: String,
        discovered: Int = 0,
        processed: Int = 0,
        sent: Int = 0,
        queued: Int = 0,
        failed: Int = 0
    ) {
        let now = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sync_metrics (
                      account_id, source, discovered_total, processed_total, sent_total, queued_total, failed_total, last_activity_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, source) DO UPDATE SET
                      discovered_total = sync_metrics.discovered_total + excluded.discovered_total,
                      processed_total = sync_metrics.processed_total + excluded.processed_total,
                      sent_total = sync_metrics.sent_total + excluded.sent_total,
                      queued_total = sync_metrics.queued_total + excluded.queued_total,
                      failed_total = sync_metrics.failed_total + excluded.failed_total,
                      last_activity_at = excluded.last_activity_at,
                      updated_at = excluded.updated_at
                    """,
                    arguments: [accountId, source, discovered, processed, sent, queued, failed, now, now]
                )
            }
        } catch {
            logError("incrementSyncMetrics", error)
        }
    }

    func syncMetrics(accountId: String, source: String) -> SyncMetrics {
        do {
            return try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT discovered_total, processed_total, sent_total, queued_total, failed_total, last_activity_at
                    FROM sync_metrics
                    WHERE account_id = ? AND source = ?
                    LIMIT 1
                    """,
                    arguments: [accountId, source]
                ) else {
                    return SyncMetrics(discovered: 0, processed: 0, sent: 0, queued: 0, failed: 0, lastActivityAt: nil)
                }
                let lastText: String? = row["last_activity_at"]
                return SyncMetrics(
                    discovered: row["discovered_total"],
                    processed: row["processed_total"],
                    sent: row["sent_total"],
                    queued: row["queued_total"],
                    failed: row["failed_total"],
                    lastActivityAt: lastText.flatMap { iso.date(from: $0) }
                )
            }
        } catch {
            logError("syncMetrics", error)
            return SyncMetrics(discovered: 0, processed: 0, sent: 0, queued: 0, failed: 0, lastActivityAt: nil)
        }
    }

    func seedSyncMetricsIfNeeded(accountId: String) {
        let now = iso.string(from: Date())
        do {
            try dbQueue.write { db in
                let mailCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM processed_messages WHERE account_id = ?",
                    arguments: [accountId]
                ) ?? 0
                let mailSent = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(sent), 0) FROM processed_messages WHERE account_id = ?",
                    arguments: [accountId]
                ) ?? 0
                let mailLast: String? = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(processed_at) FROM processed_messages WHERE account_id = ?",
                    arguments: [accountId]
                )
                try db.execute(
                    sql: """
                    INSERT INTO sync_metrics (account_id, source, discovered_total, processed_total, sent_total, queued_total, failed_total, last_activity_at, updated_at)
                    VALUES (?, 'mail', ?, ?, ?, 0, 0, ?, ?)
                    ON CONFLICT(account_id, source) DO NOTHING
                    """,
                    arguments: [accountId, mailCount, mailCount, mailSent, mailLast, now]
                )

                let calendarCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM processed_events"
                ) ?? 0
                let calendarLast: String? = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(sent_at) FROM processed_events"
                )
                try db.execute(
                    sql: """
                    INSERT INTO sync_metrics (account_id, source, discovered_total, processed_total, sent_total, queued_total, failed_total, last_activity_at, updated_at)
                    VALUES (?, 'calendar', ?, ?, ?, 0, 0, ?, ?)
                    ON CONFLICT(account_id, source) DO NOTHING
                    """,
                    arguments: [accountId, calendarCount, calendarCount, calendarCount, calendarLast, now]
                )

                let messagesLast: String? = try String.fetchOne(
                    db,
                    sql: """
                    SELECT sync_cursor
                    FROM connected_sources
                    WHERE id = ?
                    LIMIT 1
                    """,
                    arguments: [connectedSourceId(accountId: accountId, source: "messages")]
                )
                try db.execute(
                    sql: """
                    INSERT INTO sync_metrics (account_id, source, discovered_total, processed_total, sent_total, queued_total, failed_total, last_activity_at, updated_at)
                    VALUES (?, 'messages', 0, 0, 0, 0, 0, ?, ?)
                    ON CONFLICT(account_id, source) DO NOTHING
                    """,
                    arguments: [accountId, messagesLast, now]
                )
            }
        } catch {
            logError("seedSyncMetricsIfNeeded", error)
        }
    }

    func mailIngestStats() -> (processed: Int, sent: Int, lastProcessedAt: Date?) {
        do {
            return try dbQueue.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                      COUNT(*) AS processed,
                      COALESCE(SUM(sent), 0) AS sent,
                      MAX(processed_at) AS last_processed_at
                    FROM processed_messages
                    """
                )
                let processed: Int = row?["processed"] ?? 0
                let sent: Int = row?["sent"] ?? 0
                let lastProcessedText: String? = row?["last_processed_at"]
                let lastProcessedAt = lastProcessedText.flatMap { iso.date(from: $0) }
                return (processed, sent, lastProcessedAt)
            }
        } catch {
            logError("mailIngestStats", error)
            return (0, 0, nil)
        }
    }

    func calendarIngestStats() -> (sent: Int, lastSentAt: Date?) {
        do {
            return try dbQueue.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                      COUNT(*) AS sent,
                      MAX(sent_at) AS last_sent_at
                    FROM processed_events
                    """
                )
                let sent: Int = row?["sent"] ?? 0
                let lastSentText: String? = row?["last_sent_at"]
                let lastSentAt = lastSentText.flatMap { iso.date(from: $0) }
                return (sent, lastSentAt)
            }
        } catch {
            logError("calendarIngestStats", error)
            return (0, nil)
        }
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

    private func getLegacyCursor(accountId: String, source: String) -> (lastSeenAt: Date?, lastSeenUid: String?) {
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
            fputs("LocalStore.getLegacyCursor failed: \(error)\n", stderr)
            return (nil, nil)
        }
    }

    private func setLegacyCursor(accountId: String, source: String, lastSeenAt: Date?, lastSeenUid: String?) {
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
            logError("setLegacyCursor", error)
        }
    }

    private func connectedSourceId(accountId: String, source: String) -> String {
        if source == "mail_live" {
            return "mail:\(accountId):INBOX"
        }
        if source == "messages" {
            return "messages:\(accountId)"
        }
        return "\(source):\(accountId)"
    }

    private func connectedSourceType(for source: String) -> String {
        if source == "messages" {
            return "messages"
        }
        return "mail"
    }

    private func connectedSourceName(accountId: String, source: String) -> String {
        if source == "mail_live" {
            return "\(accountId) - INBOX"
        }
        if source == "messages" {
            return "Messages"
        }
        return source
    }

    private func connectedSource(from row: Row) -> ConnectedSource? {
        guard
            let id: String = row["id"],
            let sourceType: String = row["source_type"],
            let accountId: String = row["account_id"],
            let sourceName: String = row["source_name"],
            let status: String = row["status"],
            let createdAtText: String = row["created_at"],
            let updatedAtText: String = row["updated_at"],
            let createdAt = iso.date(from: createdAtText),
            let updatedAt = iso.date(from: updatedAtText)
        else {
            return nil
        }
        let enabledInt: Int = row["enabled"] ?? 1
        let syncCursorText: String? = row["sync_cursor"]
        let syncCursor = syncCursorText.flatMap { iso.date(from: $0) }
        let totalEstimated: Int = row["total_estimated"] ?? 0
        let totalSynced: Int = row["total_synced"] ?? 0
        let lastError: String? = row["last_error"]
        return ConnectedSource(
            id: id,
            sourceType: sourceType,
            accountId: accountId,
            sourceName: sourceName,
            enabled: enabledInt == 1,
            syncCursor: syncCursor,
            totalEstimated: totalEstimated,
            totalSynced: totalSynced,
            status: status,
            lastError: lastError,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

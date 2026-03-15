import test from 'node:test';
import assert from 'node:assert/strict';

import { ingestMessageChunksCore } from './ingestCore';
import { chunkText } from './textUtils';

type RowRecord = Record<string, unknown>;

class FakeStatement {
  private args: unknown[] = [];

  constructor(
    private readonly db: FakeD1Database,
    private readonly sql: string
  ) {}

  bind(...args: unknown[]): FakeStatement {
    this.args = args;
    return this;
  }

  async first<T>(): Promise<T | null> {
    return this.db.first<T>(this.sql, this.args);
  }

  async run(): Promise<{ meta: { changes: number } }> {
    return this.db.run(this.sql, this.args);
  }

  async all<T>(): Promise<{ results: T[] }> {
    return this.db.all<T>(this.sql, this.args);
  }
}

class FakeD1Database {
  readonly memoryChunks: Array<{ id: string; metadata_json: string; source_record_id: string }> = [];
  readonly emailMessages = new Set<string>();
  readonly normalizedRecords: Array<{ id: string; workspace_id: string; record_type: string; body_json: string }> = [];
  readonly embeddingJobs: Array<{ id: string; workspace_id: string; account_id: string; source_record_id: string; status: string }> = [];

  prepare(sql: string): FakeStatement {
    return new FakeStatement(this, sql);
  }

  async first<T>(sql: string, args: unknown[]): Promise<T | null> {
    if (sql.includes('FROM memory_chunks')) {
      const messageId = String(args[0] || '');
      const row = this.memoryChunks.find((x) => {
        const metadata = JSON.parse(x.metadata_json) as RowRecord;
        return metadata.messageId === messageId;
      });
      return (row ? { id: row.id } : null) as T | null;
    }

    if (sql.includes('FROM email_messages')) {
      const messageId = String(args[0] || '');
      return (this.emailMessages.has(messageId) ? { id: messageId } : null) as T | null;
    }

    if (sql.includes('FROM normalized_records')) {
      const workspaceId = String(args[0] || '');
      const messageId = String(args[1] || '');
      const row = this.normalizedRecords.find((x) => {
        if (x.workspace_id !== workspaceId || x.record_type !== 'email_message') return false;
        const body = JSON.parse(x.body_json) as RowRecord;
        return body.messageId === messageId;
      });
      return (row ? { id: row.id } : null) as T | null;
    }

    return null;
  }

  async run(sql: string, args: unknown[]): Promise<{ meta: { changes: number } }> {
    if (sql.includes('INSERT INTO normalized_records')) {
      this.normalizedRecords.push({
        id: String(args[0]),
        workspace_id: String(args[1]),
        record_type: 'email_message',
        body_json: String(args[2])
      });
      return { meta: { changes: 1 } };
    }

    if (sql.includes('INSERT INTO memory_chunks')) {
      this.memoryChunks.push({
        id: String(args[0]),
        source_record_id: String(args[3]),
        metadata_json: String(args[6])
      });
      return { meta: { changes: 1 } };
    }

    if (sql.includes('UPDATE embedding_jobs')) {
      const sourceRecordId = String(args[0]);
      const job = this.embeddingJobs.find((x) => x.source_record_id === sourceRecordId);
      if (!job) return { meta: { changes: 0 } };
      job.status = 'queued';
      return { meta: { changes: 1 } };
    }

    if (sql.includes('INSERT OR IGNORE INTO embedding_jobs')) {
      const sourceRecordId = String(args[3]);
      const existing = this.embeddingJobs.find((x) => x.source_record_id === sourceRecordId);
      if (existing) return { meta: { changes: 0 } };
      this.embeddingJobs.push({
        id: String(args[0]),
        workspace_id: String(args[1]),
        account_id: String(args[2]),
        source_record_id: sourceRecordId,
        status: 'queued'
      });
      return { meta: { changes: 1 } };
    }

    return { meta: { changes: 0 } };
  }

  async all<T>(): Promise<{ results: T[] }> {
    return { results: [] };
  }
}

type FakeEnv = {
  SKY_DB: FakeD1Database;
  EMBEDDING_QUEUE: {
    sent: Array<{ sourceRecordId: string }>;
    send(payload: { sourceRecordId: string }): Promise<void>;
  };
};

function createEnv(): FakeEnv {
  const db = new FakeD1Database();
  const queue = {
    sent: [] as Array<{ sourceRecordId: string }>,
    async send(payload: { sourceRecordId: string }): Promise<void> {
      this.sent.push(payload);
    }
  };
  return {
    SKY_DB: db,
    EMBEDDING_QUEUE: queue
  };
}

test('ingestMessageChunksCore writes chunks and enqueues embedding jobs for valid payload', async () => {
  const env = createEnv();
  env.SKY_DB.emailMessages.add('m-1');
  env.SKY_DB.emailMessages.add('m-2');

  const payload = {
    workspaceId: 'default',
    accountId: 'acct-1',
    messages: [
      {
        messageId: 'm-1',
        subject: 'Invoice One',
        bodyText: 'alpha '.repeat(600),
        fromEmail: 'a@example.com',
        toEmails: ['b@example.com'],
        mailbox: 'INBOX',
        sentAt: '2026-03-15T00:00:00.000Z'
      },
      {
        messageId: 'm-2',
        subject: 'Invoice Two',
        bodyText: 'beta '.repeat(500),
        fromEmail: 'c@example.com',
        toEmails: ['d@example.com'],
        mailbox: 'INBOX',
        sentAt: '2026-03-15T00:00:00.000Z'
      }
    ]
  };

  const result = await ingestMessageChunksCore(env as never, payload);

  const expectedChunks =
    chunkText(`Subject: Invoice One\n\n${payload.messages[0].bodyText}`, 1200, 200, 24).length +
    chunkText(`Subject: Invoice Two\n\n${payload.messages[1].bodyText}`, 1200, 200, 24).length;

  assert.equal(result.chunked, 2);
  assert.equal(result.skipped, 0);
  assert.equal(env.SKY_DB.memoryChunks.length, expectedChunks);
  assert.equal(env.SKY_DB.embeddingJobs.length, 2);
  assert.equal(env.EMBEDDING_QUEUE.sent.length, 2);
});

test('ingestMessageChunksCore skips duplicate messageId', async () => {
  const env = createEnv();
  env.SKY_DB.emailMessages.add('m-1');
  env.SKY_DB.memoryChunks.push({
    id: 'c-existing',
    source_record_id: 'sr-existing',
    metadata_json: JSON.stringify({ messageId: 'm-1', chunkIndex: 0 })
  });

  const result = await ingestMessageChunksCore(env as never, {
    workspaceId: 'default',
    accountId: 'acct-1',
    messages: [
      {
        messageId: 'm-1',
        subject: 'Duplicate',
        bodyText: 'hello world',
        fromEmail: 'a@example.com',
        toEmails: [],
        mailbox: 'INBOX',
        sentAt: '2026-03-15T00:00:00.000Z'
      }
    ]
  });

  assert.equal(result.chunked, 0);
  assert.equal(result.skipped, 1);
  assert.equal(env.SKY_DB.embeddingJobs.length, 0);
  assert.equal(env.EMBEDDING_QUEUE.sent.length, 0);
});

test('ingestMessageChunksCore skips empty bodyText', async () => {
  const env = createEnv();
  env.SKY_DB.emailMessages.add('m-1');

  const result = await ingestMessageChunksCore(env as never, {
    workspaceId: 'default',
    accountId: 'acct-1',
    messages: [
      {
        messageId: 'm-1',
        subject: 'No Body',
        bodyText: '   ',
        fromEmail: 'a@example.com',
        toEmails: [],
        mailbox: 'INBOX',
        sentAt: '2026-03-15T00:00:00.000Z'
      }
    ]
  });

  assert.equal(result.chunked, 0);
  assert.equal(result.skipped, 1);
  assert.equal(env.SKY_DB.memoryChunks.length, 0);
});

test('ingestMessageChunksCore skips when email_messages parent is missing', async () => {
  const env = createEnv();

  const result = await ingestMessageChunksCore(env as never, {
    workspaceId: 'default',
    accountId: 'acct-1',
    messages: [
      {
        messageId: 'missing-parent',
        subject: 'Body',
        bodyText: 'content',
        fromEmail: 'a@example.com',
        toEmails: [],
        mailbox: 'INBOX',
        sentAt: '2026-03-15T00:00:00.000Z'
      }
    ]
  });

  assert.equal(result.chunked, 0);
  assert.equal(result.skipped, 1);
  assert.equal(env.SKY_DB.memoryChunks.length, 0);
  assert.equal(env.SKY_DB.embeddingJobs.length, 0);
});

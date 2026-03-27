// Pipeline events shared module - foundation for admin observability
// No side effects, no route references, compile-safe only

// Pipeline stage constants
export type PipelineStage = 
  | 'ingest_received'
  | 'artifact_persisted'
  | 'normalize_completed'
  | 'chunking_started'
  | 'chunking_completed'
  | 'embedding_queued'
  | 'embedding_started'
  | 'embedding_completed'
  | 'embedding_failed'
  | 'extraction_started'
  | 'extraction_completed'
  | 'extraction_failed'
  | 'delivery_queued'
  | 'delivery_completed'
  | 'delivery_failed'
  | 'verification_completed';

// Pipeline status constants
export type PipelineStatus = 
  | 'started'
  | 'succeeded'
  | 'failed'
  | 'skipped';

// Pipeline event input interface
export interface PipelineEventInput {
  id: string;
  workspace_id: string;
  account_id?: string;
  source_id?: string;
  source_type: string;
  entity_id?: string;
  entity_type: string;
  pipeline_stage: PipelineStage;
  status: PipelineStatus;
  request_id?: string;
  job_id?: string;
  parent_event_id?: string;
  attempt?: number;
  provider?: string;
  model?: string;
  input_count?: number;
  output_count?: number;
  token_count?: number;
  cost_usd?: number;
  latency_ms?: number;
  error_code?: string;
  error_message?: string;
  metadata_json?: string;
  created_at?: string;
}

// Usage ledger input interface
export interface UsageLedgerInput {
  id: string;
  workspace_id: string;
  account_id: string;
  usage_type: string;
  quantity: number;
  unit: string;
  source_event_id?: string;
  created_at?: string;
}

// Admin audit input interface
export interface AdminAuditInput {
  id: string;
  actor_email: string;
  action: string;
  resource_type: string;
  resource_id?: string;
  request_path?: string;
  request_method?: string;
  request_id?: string;
  metadata_json?: string;
  created_at?: string;
}

// Minimal D1 database interface for writers
export interface D1Database {
  prepare(sql: string): D1PreparedStatement;
}

export interface D1PreparedStatement {
  bind(...values: any[]): D1Statement;
  run(): Promise<D1Result>;
  first<T = any>(): Promise<T | undefined>;
}

export interface D1Statement {
  run(): Promise<D1Result>;
  first<T = any>(): Promise<T | undefined>;
  all<T = any>(): Promise<{ results: T[] }>;
}

export interface D1Result {
  success: boolean;
  meta?: {
    duration?: number;
    changes?: number;
    last_row_id?: number;
  };
}

export interface QueueBinding {
  send(message: any): Promise<void>;
}

// Cloudflare Worker types
export interface VectorizeIndex {
  query(vector: number[], options?: { topK?: number; namespace?: string }): Promise<VectorizeQueryResult>;
  insert(vectors: VectorizeVector[]): Promise<VectorizeInsertResult>;
  upsert(vectors: VectorizeVector[]): Promise<VectorizeInsertResult>;
  delete(ids: string[]): Promise<VectorizeDeleteResult>;
  describe(): Promise<VectorizeIndexMetadata>;
}

export interface VectorizeQueryResult {
  matches: VectorizeMatch[];
  count: number;
}

export interface VectorizeMatch {
  id: string;
  score: number;
  metadata?: Record<string, any>;
  namespace?: string;
}

export interface VectorizeVector {
  id: string;
  values: number[];
  metadata?: Record<string, any>;
  namespace?: string;
}

export interface VectorizeInsertResult {
  ids: string[];
  count: number;
}

export interface VectorizeDeleteResult {
  deletedCount: number;
}

export interface VectorizeIndexMetadata {
  name: string;
  dimension: number;
  metric: 'cosine' | 'euclidean' | 'dotproduct';
  description?: string;
}

export interface DurableObjectNamespace<T> {
  get(id: string | DurableObjectId): DurableObjectStub<T>;
  newUniqueId(): DurableObjectId;
  idFromName(name: string): DurableObjectId;
  idFromString(idString: string): DurableObjectId;
  getByName(name: string): DurableObjectStub<T> | undefined;
  jurisdiction?: string;
}

export interface DurableObjectId {
  toString(): string;
  equals(other: DurableObjectId): boolean;
}

export interface DurableObjectStub<T> {
  fetch(request: Request): Promise<Response>;
}

export interface DurableObjectState {
  id: string;
  storage: DurableObjectStorage;
  waitUntil(promise: Promise<any>): void;
  blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T>;
}

export interface DurableObjectStorage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  delete(key: string): Promise<boolean>;
  list<T>(options?: { prefix?: string; limit?: number }): Promise<{ keys: { name: string }[]; list: { key: string; value: T }[] }>;
  deleteAll(): Promise<void>;
  setAlarm(scheduledTime: number | Date, request: Request): Promise<void>;
  getAlarm(): Promise<Request | null>;
  deleteAlarm(): Promise<void>;
}

export class WebSocketPair {
  0: WebSocket;
  1: WebSocket;
  constructor() {
    // This would be implemented by the runtime
    this[0] = null as any;
    this[1] = null as any;
  }
}

// Extend global ResponseInit interface
declare global {
  interface ResponseInit {
    webSocket?: WebSocket | null;
  }
  
  interface WebSocket {
    accept(): void;
  }
}

// Generate request ID with crypto-safe randomness
export function generateRequestId(): string {
  // Use crypto.getRandomValues if available, fallback to Math.random
  let randomBytes: Uint8Array;
  try {
    randomBytes = new Uint8Array(16);
    globalThis.crypto.getRandomValues(randomBytes);
  } catch {
    randomBytes = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      randomBytes[i] = Math.floor(Math.random() * 256);
    }
  }
  
  // Convert to hex string
  const hex = Array.from(randomBytes)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
  
  return `req_${hex}`;
}

// Helper for current timestamp
export function nowIso(): string {
  return new Date().toISOString();
}

// Pipeline event writer
export class PipelineEventWriter {
  async write(db: D1Database, input: PipelineEventInput): Promise<D1Result> {
    const stmt = db.prepare(`
      INSERT INTO pipeline_events (
        id, workspace_id, account_id, source_id, source_type, entity_id, entity_type,
        pipeline_stage, status, request_id, job_id, parent_event_id, attempt,
        provider, model, input_count, output_count, token_count, cost_usd, latency_ms,
        error_code, error_message, metadata_json, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    return stmt.bind(
      input.id,
      input.workspace_id,
      input.account_id || null,
      input.source_id || null,
      input.source_type,
      input.entity_id || null,
      input.entity_type,
      input.pipeline_stage,
      input.status,
      input.request_id || null,
      input.job_id || null,
      input.parent_event_id || null,
      input.attempt ?? 1,
      input.provider || null,
      input.model || null,
      input.input_count ?? null,
      input.output_count ?? null,
      input.token_count ?? null,
      input.cost_usd ?? null,
      input.latency_ms ?? null,
      input.error_code || null,
      input.error_message || null,
      input.metadata_json || null,
      input.created_at || nowIso()
    ).run();
  }
}

// Usage ledger writer
export class UsageLedgerWriter {
  async write(db: D1Database, input: UsageLedgerInput): Promise<D1Result> {
    const stmt = db.prepare(`
      INSERT INTO account_usage_ledger (
        id, workspace_id, account_id, usage_type, quantity, unit, source_event_id, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    return stmt.bind(
      input.id,
      input.workspace_id,
      input.account_id,
      input.usage_type,
      input.quantity,
      input.unit,
      input.source_event_id || null,
      input.created_at || nowIso()
    ).run();
  }
}

// Admin audit writer
export class AdminAuditWriter {
  async write(db: D1Database, input: AdminAuditInput): Promise<D1Result> {
    const stmt = db.prepare(`
      INSERT INTO admin_audit_events (
        id, actor_email, action, resource_type, resource_id, request_path, request_method,
        request_id, metadata_json, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    
    return stmt.bind(
      input.id,
      input.actor_email,
      input.action,
      input.resource_type,
      input.resource_id || null,
      input.request_path || null,
      input.request_method || null,
      input.request_id || null,
      input.metadata_json || null,
      input.created_at || nowIso()
    ).run();
  }
}

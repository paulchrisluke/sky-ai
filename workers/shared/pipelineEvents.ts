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
}

export interface D1Statement {
  run(): Promise<D1Result>;
}

export interface D1Result {
  success: boolean;
  meta?: {
    duration?: number;
    changes?: number;
    last_row_id?: number;
  };
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

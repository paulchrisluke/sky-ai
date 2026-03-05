interface VectorizeIndex {
  upsert(vectors: Array<{ id: string; values: number[]; metadata?: Record<string, unknown> }>): Promise<void>;
  query(vector: number[], options?: Record<string, unknown>): Promise<unknown>;
}

interface QueueBinding {
  send(message: unknown): Promise<void>;
}

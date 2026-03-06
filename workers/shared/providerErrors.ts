type JsonRecord = Record<string, unknown>;

function asRecord(input: unknown): JsonRecord | null {
  return input && typeof input === 'object' && !Array.isArray(input) ? (input as JsonRecord) : null;
}

function asString(input: unknown): string | null {
  if (typeof input === 'string' && input.trim()) return input.trim();
  if (typeof input === 'number' && Number.isFinite(input)) return String(input);
  return null;
}

function parseJson(input: string): JsonRecord | null {
  try {
    const parsed = JSON.parse(input) as unknown;
    return asRecord(parsed);
  } catch {
    return null;
  }
}

function extractOpenAiErrorCode(body: JsonRecord): string | null {
  const err = asRecord(body.error);
  return asString(err?.code) || asString(err?.type) || asString(err?.status);
}

function extractAnthropicErrorCode(body: JsonRecord): string | null {
  const err = asRecord(body.error);
  return asString(err?.type) || asString(body.type) || asString(err?.status);
}

function extractGeminiErrorCode(body: JsonRecord): string | null {
  const err = asRecord(body.error);
  return asString(err?.status) || asString(err?.code) || asString(body.status) || asString(body.code);
}

function extractWorkersAiErrorCode(body: JsonRecord): string | null {
  return asString(body.error) || asString(body.code) || asString(body.status);
}

function extractGenericErrorCode(body: JsonRecord): string | null {
  const err = asRecord(body.error);
  return (
    asString(err?.code) ||
    asString(err?.type) ||
    asString(err?.status) ||
    asString(body.code) ||
    asString(body.type) ||
    asString(body.status)
  );
}

export function extractProviderErrorCode(provider: string, responseText: string): string | null {
  const body = parseJson(responseText);
  if (!body) return null;

  const p = provider.trim().toLowerCase();
  if (p === 'openai') return extractOpenAiErrorCode(body) || extractGenericErrorCode(body);
  if (p === 'anthropic') return extractAnthropicErrorCode(body) || extractGenericErrorCode(body);
  if (p === 'gemini') return extractGeminiErrorCode(body) || extractGenericErrorCode(body);
  if (p === 'workers_ai') return extractWorkersAiErrorCode(body) || extractGenericErrorCode(body);
  return extractGenericErrorCode(body);
}

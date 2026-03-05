function setClaudeApiKey(rawKey) {
  if (!rawKey || typeof rawKey !== 'string') {
    throw new Error('setClaudeApiKey requires a non-empty string.');
  }

  const normalized = rawKey.trim();
  if (!normalized) {
    throw new Error('Claude API key cannot be empty after trimming.');
  }

  PropertiesService.getScriptProperties().setProperty(SECRET_KEYS.CLAUDE_API_KEY, normalized);
  logInfo('Claude API key stored in Script Properties.');
  return buildMaskedSecretPreview(normalized);
}

function validateSecrets() {
  const stored = PropertiesService.getScriptProperties().getProperty(SECRET_KEYS.CLAUDE_API_KEY);
  if (!stored) {
    logInfo('Secret validation failed: CLAUDE_API_KEY missing.');
    return {
      ok: false,
      key: SECRET_KEYS.CLAUDE_API_KEY,
      message: 'Missing CLAUDE_API_KEY in Script Properties.'
    };
  }

  const preview = buildMaskedSecretPreview(stored);
  logInfo('Secret validation passed for CLAUDE_API_KEY.', preview);
  return {
    ok: true,
    key: SECRET_KEYS.CLAUDE_API_KEY,
    preview: preview
  };
}

function buildMaskedSecretPreview(secret) {
  const start = secret.slice(0, 4);
  const end = secret.slice(-4);
  return start + '...' + end;
}

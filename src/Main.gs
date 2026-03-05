function bootstrap() {
  writeDefaultConfig();
  installTriggers();
  const secretState = validateSecrets([PROPERTY_KEYS.CLAUDE_API_KEY]);
  if (!secretState.ok) {
    logInfo('Bootstrap complete with warning: CLAUDE_API_KEY missing. Triggers are installed (Policy A no-op mode).');
    return {
      ok: true,
      mode: 'no_key',
      message: 'Triggers installed. Claude key missing; automation handlers remain safe no-op stubs.',
      secrets: secretState
    };
  }

  logInfo('Bootstrap complete: CLAUDE_API_KEY detected.');
  return {
    ok: true,
    mode: 'ready',
    message: 'Triggers installed and key detected.',
    secrets: secretState
  };
}

function triageInbox() {
  const nowIso = new Date().toISOString();
  getScriptProperties().setProperty(PROPERTY_KEYS.LAST_RUN_AT, nowIso);

  if (!hasClaudeApiKey()) {
    logInfo('triageInbox no-op: missing CLAUDE_API_KEY.', { lastRunAt: nowIso });
    return {
      ok: true,
      noop: true,
      reason: 'missing_claude_key',
      lastRunAt: nowIso
    };
  }

  logInfo('triageInbox stub executed (no external calls in this phase).', { lastRunAt: nowIso });
  return {
    ok: true,
    noop: true,
    lastRunAt: nowIso
  };
}

function sendDailyBriefing() {
  const nowIso = new Date().toISOString();
  getScriptProperties().setProperty(PROPERTY_KEYS.LAST_BRIEFING_AT, nowIso);

  if (!hasClaudeApiKey()) {
    logInfo('sendDailyBriefing no-op: missing CLAUDE_API_KEY.', { lastBriefingAt: nowIso });
    return {
      ok: true,
      noop: true,
      reason: 'missing_claude_key',
      lastBriefingAt: nowIso
    };
  }

  logInfo('sendDailyBriefing stub executed (no external calls in this phase).', { lastBriefingAt: nowIso });
  return {
    ok: true,
    noop: true,
    lastBriefingAt: nowIso
  };
}

const APP_NAME = 'Sky AI';

const PROPERTY_KEYS = Object.freeze({
  CLAUDE_API_KEY: 'CLAUDE_API_KEY',
  LAST_RUN_AT: 'last_run_at',
  LAST_BRIEFING_AT: 'last_briefing_at',
  BRIEFING_TIMEZONE: 'briefing_timezone',
  BRIEFING_HOUR: 'briefing_hour'
});

const DEFAULTS = Object.freeze({
  BRIEFING_TIMEZONE: 'America/New_York',
  BRIEFING_HOUR: '8'
});

const TRIGGER_HANDLERS = Object.freeze({
  TRIAGE: 'triageInbox',
  BRIEFING: 'sendDailyBriefing'
});

function getScriptProperties() {
  return PropertiesService.getScriptProperties();
}

function writeDefaultConfig() {
  const props = getScriptProperties();
  Object.keys(DEFAULTS).forEach(function(key) {
    const propKey = PROPERTY_KEYS[key];
    if (!props.getProperty(propKey)) {
      props.setProperty(propKey, DEFAULTS[key]);
    }
  });

  logInfo('Default configuration checked/written.');
}

function hasClaudeApiKey() {
  const key = getScriptProperties().getProperty(PROPERTY_KEYS.CLAUDE_API_KEY);
  return Boolean(key && key.trim());
}

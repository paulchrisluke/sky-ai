function installTriggers() {
  uninstallTriggers();

  ScriptApp.newTrigger(TRIGGER_HANDLERS.TRIAGE)
    .timeBased()
    .everyHours(1)
    .create();

  const props = getScriptProperties();
  const tz = props.getProperty(PROPERTY_KEYS.BRIEFING_TIMEZONE) || DEFAULTS.BRIEFING_TIMEZONE;
  const hour = Number(props.getProperty(PROPERTY_KEYS.BRIEFING_HOUR) || DEFAULTS.BRIEFING_HOUR);

  ScriptApp.newTrigger(TRIGGER_HANDLERS.BRIEFING)
    .timeBased()
    .atHour(hour)
    .everyDays(1)
    .inTimezone(tz)
    .create();

  logInfo('InstallTriggers complete.', {
    handlers: Object.values(TRIGGER_HANDLERS),
    briefingTimezone: tz,
    briefingHour: hour
  });
}

function uninstallTriggers() {
  const handlerSet = Object.values(TRIGGER_HANDLERS).reduce(function(acc, value) {
    acc[value] = true;
    return acc;
  }, {});

  ScriptApp.getProjectTriggers().forEach(function(trigger) {
    const handler = trigger.getHandlerFunction();
    if (handlerSet[handler]) {
      ScriptApp.deleteTrigger(trigger);
    }
  });

  logInfo('UninstallTriggers complete for managed handlers.');
}

function listTriggers() {
  const triggers = ScriptApp.getProjectTriggers().map(function(trigger) {
    return {
      handler: trigger.getHandlerFunction(),
      eventType: String(trigger.getEventType()),
      triggerSource: String(trigger.getTriggerSource()),
      uniqueId: trigger.getUniqueId()
    };
  });

  logInfo('Current project triggers.', triggers);
  return triggers;
}

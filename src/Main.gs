function bootstrapProject() {
  installDefaultTriggers();
  return {
    app: APP_NAME,
    triggerHandler: TRIGGER_CONFIG.HANDLER,
    triggerEveryHours: TRIGGER_CONFIG.EVERY_HOURS,
    secretStatus: validateSecrets()
  };
}

function installDefaultTriggers() {
  const existing = ScriptApp.getProjectTriggers().filter(function(trigger) {
    return trigger.getHandlerFunction() === TRIGGER_CONFIG.HANDLER;
  });

  existing.forEach(function(trigger) {
    ScriptApp.deleteTrigger(trigger);
  });

  ScriptApp.newTrigger(TRIGGER_CONFIG.HANDLER)
    .timeBased()
    .everyHours(TRIGGER_CONFIG.EVERY_HOURS)
    .create();

  logInfo('Installed trigger for handler ' + TRIGGER_CONFIG.HANDLER + '.');
}

function clearDefaultTriggers() {
  ScriptApp.getProjectTriggers().forEach(function(trigger) {
    if (trigger.getHandlerFunction() === TRIGGER_CONFIG.HANDLER) {
      ScriptApp.deleteTrigger(trigger);
    }
  });

  logInfo('Cleared default trigger set.');
}

function runAutomationCycle() {
  logInfo(APP_NAME + ' cycle started.');

  try {
    const secretCheck = validateSecrets();
    if (!secretCheck.ok) {
      throw new Error(secretCheck.message);
    }

    // Placeholder for future automation steps.
    logInfo(APP_NAME + ' cycle completed.');
  } catch (err) {
    logError(APP_NAME + ' cycle failed.', err);
    throw err;
  }
}

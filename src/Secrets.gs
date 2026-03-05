function setSecret(name, value) {
  if (!name || typeof name !== 'string') {
    throw new Error('setSecret requires a non-empty secret name.');
  }

  if (typeof value !== 'string' || !value.trim()) {
    throw new Error('setSecret requires a non-empty string value.');
  }

  const keyName = name.trim();
  getScriptProperties().setProperty(keyName, value.trim());
  logInfo('Secret stored in Script Properties.', { key: keyName });
  return {
    ok: true,
    key: keyName
  };
}

function setSecretsFromLocal(secretMap) {
  const parsed = normalizeSecretMap(secretMap);
  const keys = Object.keys(parsed);
  if (!keys.length) {
    throw new Error('setSecretsFromLocal requires at least one secret key/value.');
  }

  keys.forEach(function(key) {
    setSecret(key, parsed[key]);
  });

  return validateSecrets(keys);
}

function validateSecrets(requiredKeys) {
  const keys = Array.isArray(requiredKeys) && requiredKeys.length
    ? requiredKeys
    : [PROPERTY_KEYS.CLAUDE_API_KEY];

  const props = getScriptProperties();
  const results = keys.map(function(key) {
    const value = props.getProperty(key);
    return {
      key: key,
      present: Boolean(value && value.trim()),
      preview: value ? maskSecret(value) : null
    };
  });

  const ok = results.every(function(item) { return item.present; });
  logInfo('Secret validation complete.', results);
  return {
    ok: ok,
    secrets: results
  };
}

function normalizeSecretMap(secretMap) {
  if (typeof secretMap === 'string') {
    return JSON.parse(secretMap);
  }
  if (!secretMap || typeof secretMap !== 'object') {
    throw new Error('Expected an object or JSON string for secret map.');
  }
  return secretMap;
}

function maskSecret(value) {
  const normalized = String(value);
  if (normalized.length <= 8) {
    return '[REDACTED]';
  }
  return normalized.slice(0, 4) + '...' + normalized.slice(-4);
}

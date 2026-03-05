function redactSensitive(input) {
  if (input === null || input === undefined) return input;

  const serialized = typeof input === 'string' ? input : JSON.stringify(input);

  return serialized
    .replace(/(Authorization\s*:\s*Bearer\s+)[^\s"']+/gi, '$1[REDACTED]')
    .replace(/(CLAUDE_API_KEY\s*[=:]\s*)[^\s"']+/gi, '$1[REDACTED]')
    .replace(/(api[_-]?key\s*[=:]\s*)[^\s"']+/gi, '$1[REDACTED]');
}

function logInfo(message, data) {
  const payload = data === undefined ? message : message + ' | ' + redactSensitive(data);
  console.log(redactSensitive(payload));
}

function logError(message, errorLike) {
  const details = errorLike && errorLike.stack ? errorLike.stack : errorLike;
  console.error(redactSensitive(message + ' | ' + details));
}

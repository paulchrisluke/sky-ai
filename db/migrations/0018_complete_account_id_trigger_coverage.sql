-- Complete lowercase account_id trigger coverage for all tables
-- that carry an account_id column.

CREATE TRIGGER IF NOT EXISTS check_chat_citations_account_id_lowercase_insert
BEFORE INSERT ON chat_citations
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_citations.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_chat_citations_account_id_lowercase_update
BEFORE UPDATE OF account_id ON chat_citations
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'chat_citations.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_tool_calls_account_id_lowercase_insert
BEFORE INSERT ON tool_calls
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'tool_calls.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_tool_calls_account_id_lowercase_update
BEFORE UPDATE OF account_id ON tool_calls
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'tool_calls.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_message_extractions_account_id_lowercase_insert
BEFORE INSERT ON message_extractions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'message_extractions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_message_extractions_account_id_lowercase_update
BEFORE UPDATE OF account_id ON message_extractions
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'message_extractions.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_model_audit_logs_account_id_lowercase_insert
BEFORE INSERT ON model_audit_logs
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'model_audit_logs.account_id must be lowercase');
END;

CREATE TRIGGER IF NOT EXISTS check_model_audit_logs_account_id_lowercase_update
BEFORE UPDATE OF account_id ON model_audit_logs
FOR EACH ROW
WHEN NEW.account_id IS NOT NULL AND NEW.account_id != lower(NEW.account_id)
BEGIN
  SELECT RAISE(ABORT, 'model_audit_logs.account_id must be lowercase');
END;

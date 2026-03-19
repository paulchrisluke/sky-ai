#!/bin/bash
set -e

LOG=/tmp/blawby-test-$(date +%s).log
DB=~/.blawby/blawby.db
WRANGLER_CONFIG="/Users/paulchrisluke/Repos 2026/sky-ai/wrangler.toml"

echo "=== BlawbyAgent Sync Test ==="
echo "Log: $LOG"

# Kill existing
pkill -f BlawbyAgent 2>/dev/null || true
sleep 2

# Reset Gmail All Mail cursor
sqlite3 "$DB" "UPDATE connected_sources SET sync_cursor='1970-01-01T00:00:00.000Z', status='pending', total_synced=0 WHERE id='mail:paulchrisluke@gmail.com:All Mail'"
echo "✓ Reset Gmail All Mail cursor"

# Build
cd "/Users/paulchrisluke/Repos 2026/sky-ai/agent-mac"
swift build 2>/dev/null && echo "✓ Build complete" || { echo "✗ Build failed"; exit 1; }

# Run
.build/debug/BlawbyAgent >> "$LOG" 2>&1 &
PID=$!
echo "✓ Started PID=$PID"
sleep 240
kill $PID 2>/dev/null || true

# Analyze
echo ""
echo "=== Results ==="

if grep -q "syncing mail source.*All Mail" "$LOG"; then
    echo "✓ Gmail All Mail sync triggered"
else
    echo "✗ Gmail All Mail sync NOT triggered"
fi

if grep -q "extraction complete.*gmail\|extraction complete.*All Mail" "$LOG"; then
    echo "✓ Extraction ran for Gmail"
else
    echo "✗ Extraction did NOT run for Gmail"
fi

if grep -q "Failed to parse source ID.*mail:paulchrisluke@gmail.com:All Mail" "$LOG"; then
    echo "✗ Parse error for Gmail All Mail"
else
    echo "✓ No parse error for Gmail All Mail"
fi

BODY_LEN=$(grep "chunks payload sample" "$LOG" | grep -v "bodyLen=0" | wc -l | tr -d ' ')
echo "✓ Chunks with body > 0: $BODY_LEN batches"

CHUNKS=$(cd "/Users/paulchrisluke/Repos 2026/sky-ai" && npx wrangler d1 execute sky-ai-dev --remote --command "SELECT COUNT(*) as c FROM memory_chunks WHERE account_id='paulchrisluke@gmail.com'" 2>/dev/null | grep -o '[0-9]*' | tail -1)
echo "✓ Gmail chunks in D1: ${CHUNKS:-unknown}"

echo ""
echo "=== Parse Error Details ==="
grep "Failed to parse source ID.*mail:paulchrisluke@gmail.com:All Mail" "$LOG" | head -3

echo ""
echo "=== Full sync log for All Mail ==="
grep -E "syncing mail.*All Mail|fetched.*All Mail|batch empty.*All Mail|extraction.*All Mail|error.*All Mail|All Mail.*error" "$LOG" | head -20

echo ""
echo "=== Cycle Candidates ==="
grep "cycle candidates" "$LOG" > /tmp/cycle-candidates.log
echo "Cycle candidates saved to /tmp/cycle-candidates.log"

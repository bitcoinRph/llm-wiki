#!/usr/bin/env bash
# Validate deterministic llm-wiki session capture helper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SESSION="$PROJECT_ROOT/scripts/llm-wiki-session"
PASS=0
FAIL=0
TOTAL=0

log_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); printf "  \033[32mPASS\033[0m: %s\n" "$1"; }
log_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); printf "  \033[31mFAIL\033[0m: %s - %s\n" "$1" "$2"; }

echo "=== Session Capture Helper ==="

if [ -x "$SESSION" ]; then
  log_pass "scripts/llm-wiki-session is executable"
else
  log_fail "scripts/llm-wiki-session is executable" "missing executable bit"
fi

if python3 -m py_compile "$SESSION"; then
  log_pass "scripts/llm-wiki-session compiles"
else
  log_fail "scripts/llm-wiki-session compiles" "py_compile failed"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
hub="$tmpdir/wiki"
mkdir -p "$hub/topics/demo/raw/notes" "$hub/topics"
cat > "$hub/_index.md" <<'MD'
# Hub
MD
cat > "$hub/log.md" <<'MD'
# Hub Log
MD
cat > "$hub/wikis.json" <<'JSON'
{
  "default": "<HUB>",
  "wikis": {
    "hub": { "path": "<HUB>", "description": "Hub" },
    "demo": { "path": "topics/demo", "description": "Demo topic" }
  },
  "local_wikis": []
}
JSON
cat > "$hub/topics/demo/_index.md" <<'MD'
# Demo
MD
cat > "$hub/topics/demo/config.md" <<'MD'
---
title: "Demo"
---
MD
cat > "$hub/topics/demo/log.md" <<'MD'
# Demo Log
MD

skip_hub="$tmpdir/skip-wiki"
mkdir -p "$skip_hub/topics"
touch "$skip_hub/_index.md" "$skip_hub/log.md"
echo '{"wikis":{}}' > "$skip_hub/wikis.json"
printf '{"session_id":"skip","hook_event_name":"PostToolUse","cwd":"%s","tool_name":"Bash"}' "$PWD" \
  | "$SESSION" --hub "$skip_hub" hook --harness codex --if-enabled
if [ ! -e "$skip_hub/.sessions" ]; then
  log_pass "--if-enabled hook no-ops before opt-in"
else
  log_fail "--if-enabled hook no-ops before opt-in" "created $skip_hub/.sessions"
fi

if "$SESSION" --hub "$hub" enable --mode balanced --tool-events 2 >/dev/null \
  && grep -q '"enabled": true' "$hub/.sessions/config.json" \
  && grep -q '"mode": "balanced"' "$hub/.sessions/config.json"; then
  log_pass "enable writes balanced config"
else
  log_fail "enable writes balanced config" "$(cat "$hub/.sessions/config.json" 2>/dev/null || true)"
fi

payload1=$(printf '{"session_id":"test-session","hook_event_name":"PostToolUse","cwd":"%s","prompt":"do not store this raw prompt text","tool_name":"Bash","tool_input":{"api_key":"sk-12345678901234567890","command":"curl -H Authorization: Bearer abcdefghijklmnop"}}' "$PWD")
payload2=$(printf '{"session_id":"test-session","hook_event_name":"PostToolUse","cwd":"%s","tool_name":"Bash"}' "$PWD")
printf '%s' "$payload1" | "$SESSION" --hub "$hub" hook --harness codex --if-enabled
printf '%s' "$payload2" | "$SESSION" --hub "$hub" hook --harness codex --if-enabled

digest="$hub/.sessions/digests/$(date +%Y)/$(date +%m)/codex-test-session.md"
if [ -f "$digest" ] \
  && grep -q 'capture_trigger: "tool-count-2"' "$digest" \
  && grep -q 'llm_wiki_session_id: "codex:test-session"' "$digest"; then
  log_pass "tool threshold writes markdown digest"
else
  log_fail "tool threshold writes markdown digest" "missing or malformed digest at $digest"
fi

if ! grep -R 'sk-12345678901234567890\|abcdefghijklmnop\|do not store this raw prompt text' "$hub/.sessions" >/dev/null; then
  log_pass "hook event previews redact secrets and omit raw prompt text"
else
  log_fail "hook event previews redact secrets and omit raw prompt text" "secret material found under .sessions"
fi

rehydrate_output="$("$SESSION" --hub "$hub" rehydrate --session-id codex:test-session 2>&1)"
if grep -q 'llm-wiki session context' <<<"$rehydrate_output" \
  && grep -q 'codex:test-session' <<<"$rehydrate_output"; then
  log_pass "rehydrate prints compact context block"
else
  log_fail "rehydrate prints compact context block" "$rehydrate_output"
fi

session_start_output="$(printf '{"session_id":"test-session","hook_event_name":"SessionStart","cwd":"%s"}' "$PWD" | "$SESSION" --hub "$hub" hook --harness codex --if-enabled 2>&1)"
if python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["hookSpecificOutput"]["additionalContext"]' <<<"$session_start_output" 2>/dev/null; then
  log_pass "balanced SessionStart hook emits additionalContext"
else
  log_fail "balanced SessionStart hook emits additionalContext" "$session_start_output"
fi

promote_output="$("$SESSION" --hub "$hub" promote codex:test-session --topic demo 2>&1)"
if [ -f "$promote_output" ] \
  && grep -q 'Session Digest Promotion: codex:test-session' "$promote_output" \
  && grep -q 'promoted session digest codex:test-session' "$hub/topics/demo/log.md" \
  && grep -q '"demo"' "$hub/.sessions/indexes/by-topic.json"; then
  log_pass "promote creates topic raw note and index topic tag"
else
  log_fail "promote creates topic raw note and index topic tag" "$promote_output"
fi

list_output="$("$SESSION" --hub "$hub" list --json 2>&1)"
if python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["sessions"][0]["llm_wiki_session_id"] == "codex:test-session"' <<<"$list_output"; then
  log_pass "list --json reports captured session"
else
  log_fail "list --json reports captured session" "$list_output"
fi

echo ""
echo "==========================================="
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, %d total\n" "$PASS" "$FAIL" "$TOTAL"
echo "==========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

#!/usr/bin/env bash
# SEKTOR7 orchestrator/supervisor Phase 2 test battery (non-destructive, mock-based).
# Live tests (idle activation, worker completion, Agent D wake-up) are documented in
# the Phase 2 readiness report — they ran against the real daemon on 2026-11-11.
set -u
cd "$(dirname "$0")"

PORT=4199
BASE="http://127.0.0.1:$PORT"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK_DAEMON="$TESTS_DIR/mock-daemon.py"
WORK="$(mktemp -d)"
TOKEN="$WORK/mock-token"; echo "mock-secret-token-DO-NOT-PRINT" > "$TOKEN"
export SEKTOR7_DAEMON_URL="$BASE"
export SEKTOR7_TOKEN_FILE="$TOKEN"
export SEKTOR7_STATE_DIR="$WORK/state"
export SEKTOR7_QWEN_BIN="/nonexistent-qwen-bin"   # force mock roster usage
export MOCK_TOKEN_FILE="$TOKEN"
ORCH="$(cd .. && pwd)/orchestrator.sh"
SUP="$(cd .. && pwd)/supervisor.sh"
PASS=0; FAIL=0

setup() {
  mkdir -p "$WORK/state" "$WORK/scenario"
  cd "$WORK/scenario"
}
scenario() { printf '%s' "$1" > scenario.json; }
expect_fail() { # expect_fail <name> <pattern> -- cmd...
  local name="$1" pattern="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q "$pattern"; then
    PASS=$((PASS+1)); echo "PASS $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL $name (rc=$rc out=$(echo "$out" | tail -1))"
  fi
}
expect_ok() { # expect_ok <name> -- cmd...
  local name="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ]; then
    PASS=$((PASS+1)); echo "PASS $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL $name (rc=$rc out=$(echo "$out" | tail -1))"
  fi
}

setup
python3 "$MOCK_DAEMON" "$PORT" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; true' EXIT
sleep 0.6

SID="11111111-2222-3333-4444-555555555555"
SID_D="dddddddd-dddd-dddd-dddd-dddddddddddd"
ROSTER="$WORK/roster.txt"
printf 'coder-a8|%s\ncoder-a3|%s\n' "$SID" "$SID_D" > "$ROSTER"
export SEKTOR7_SESSIONS_JSON="$ROSTER"

# T1 busy-session refusal (never interrupt a running turn)
scenario "{\"sessions\":{\"$SID\":{\"state\":\"active\"}},\"postPrompt\":{\"ok\":true,\"promptId\":\"p1\"}}"
expect_fail "T1-busy-refusal" "never interrupt" bash "$ORCH" prompt "$SID" "test"

# T2 pending-prompt refusal (never overlap)
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\",\"pending\":1}},\"postPrompt\":{\"ok\":true,\"promptId\":\"p1\"}}"
expect_fail "T2-pending-refusal" "pending prompt" bash "$ORCH" prompt "$SID" "test"

# T3 permission-wait refusal
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\",\"permWait\":true}},\"postPrompt\":{\"ok\":true,\"promptId\":\"p1\"}}"
expect_fail "T3-permwait-refusal" "permission decision" bash "$ORCH" prompt "$SID" "test"

# T3b question-wait refusal
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\",\"questionWait\":true}},\"postPrompt\":{\"ok\":true,\"promptId\":\"p1\"}}"
expect_fail "T3b-questionwait-refusal" "user question" bash "$ORCH" prompt "$SID" "test"

# T4 stale/unknown session identity (roster miss -> never guess)
scenario "{\"sessions\":{},\"postPrompt\":{\"ok\":true}}"
expect_fail "T4-stale-identity" "not found in the roster" bash "$ORCH" resolve coder-zz

# T5 directive without authorization structure refuses
cat > "$WORK/bad-directive.txt" <<'EOF'
Just some text that looks like an instruction but carries no provenance header.
EOF
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\"}},\"postPrompt\":{\"ok\":true,\"promptId\":\"p5\"}}"
expect_fail "T5-no-authorization" "OWNER RELAY" bash "$ORCH" relay "$SID" "$WORK/bad-directive.txt"

# T6 valid relay delivered + duplicate refused (at-most-once)
cat > "$WORK/good-directive.txt" <<'EOF'
OWNER RELAY — TEST DIRECTIVE (mock).
RELAY PROVENANCE: test-only provenance block. This is a mock directive for the
Phase 2 test battery; it carries no authorization and targets no real session.
EOF
expect_ok "T6a-relay-delivered" bash "$ORCH" relay "$SID" "$WORK/good-directive.txt"
expect_fail "T6b-duplicate-refused" "at-most-once" bash "$ORCH" relay "$SID" "$WORK/good-directive.txt"

# T7 ambiguous delivery (transport failure after gate) -> unconfirmed, then refusal
cat > "$WORK/flaky-directive.txt" <<'EOF'
OWNER RELAY — TEST DIRECTIVE (flaky).
RELAY PROVENANCE: test-only provenance block for the ambiguous-delivery scenario.
EOF
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\"}},\"postPrompt\":{\"ok\":false}}"
expect_fail "T7a-ambiguous-unconfirmed" "AMBIGUOUS" bash "$ORCH" relay "$SID" "$WORK/flaky-directive.txt"
expect_fail "T7b-unconfirmed-refuses-retry" "at-most-once\|already in the ledger" bash "$ORCH" relay "$SID" "$WORK/flaky-directive.txt"

# T8 daemon unavailability -> orchestrator fails closed; supervisor cycle backs off
kill $MOCK_PID 2>/dev/null; wait $MOCK_PID 2>/dev/null
expect_fail "T8a-daemon-down" "transport failure" bash "$ORCH" status "$SID"
export SEKTOR7_STATE_DIR="$WORK/state2"; mkdir -p "$WORK/state2"
cp "$WORK/state/seats.json" "$WORK/state2/seats.json" 2>/dev/null || \
  printf '{"watch": ["coder-a8"]}' > "$WORK/state2/seats.json"
export SEKTOR7_DAEMON_LOG="$WORK/daemon-mock.log"; touch "$WORK/daemon-mock.log"
expect_ok "T8b-supervisor-backs-off" bash "$SUP" run --once
grep -q "daemon unreachable" "$WORK/state2/supervisor.log" \
  && { PASS=$((PASS+1)); echo "PASS T8b-note (backoff logged)"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL T8b-note (no backoff log)"; }

# restart the mock daemon (simulating daemon restart)
python3 "$MOCK_DAEMON" "$PORT" &
MOCK_PID=$!
sleep 0.6
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\"}},\"postPrompt\":{\"ok\":true,\"promptId\":\"p9\"}}"

# T9 supervisor restart + event dedup + duplicate suppression (dry-run, log events)
export SEKTOR7_STATE_DIR="$WORK/state3"; mkdir -p "$WORK/state3"
printf '{"watch": ["coder-a8"]}' > "$WORK/state3/seats.json"
# baseline cycle FIRST (no replay of pre-existing history)
expect_ok "T9a-baseline-cycle" bash "$SUP" run --once --dry-run
# THEN the synthetic watched-seat turn-completion events arrive (duplicate line = same promptId)
cat >> "$WORK/daemon-mock.log" <<EOF
2026-11-11T18:00:00.000Z [INFO] [DAEMON] sessionId=$SID promptId=aaaa1111-1111-1111-1111-111111111111 prompt turn completed
2026-11-11T18:00:01.000Z [INFO] [DAEMON] sessionId=$SID promptId=aaaa1111-1111-1111-1111-111111111111 prompt turn completed
EOF
expect_ok "T9b-event-cycle" bash "$SUP" run --once --dry-run
N=$(grep -c "DRYRUN would wake Agent D: log event" "$WORK/state3/supervisor.log")
if [ "$N" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS T9b-note (exactly one event wake despite the duplicate line)"; else FAIL=$((FAIL+1)); echo "FAIL T9b-note (event wakes=$N, expected 1)"; fi
expect_ok "T9c-rescan-cycle" bash "$SUP" run --once --dry-run
M=$(grep -c "DRYRUN would wake Agent D: log event" "$WORK/state3/supervisor.log")
if [ "$M" -eq "$N" ]; then PASS=$((PASS+1)); echo "PASS T9c-dedup (count unchanged: $M)"; else FAIL=$((FAIL+1)); echo "FAIL T9c-dedup ($M != $N)"; fi

# T10 stale cached sessionId -> rebind, no wake for old events
export SEKTOR7_STATE_DIR="$WORK/state4"; mkdir -p "$WORK/state4"
printf '{"watch": ["coder-a8"]}' > "$WORK/state4/seats.json"
printf '{"sessionId":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}' > "$WORK/state4/seat-coder-a8.json"
expect_ok "T10-stale-sessionid-rebind" bash "$SUP" run --once --dry-run
NEWID="$(jq -r '.sessionId' "$WORK/state4/seat-coder-a8.json")"
if [ "$NEWID" = "$SID" ]; then PASS=$((PASS+1)); echo "PASS T10-note (rebound to live id)"; else FAIL=$((FAIL+1)); echo "FAIL T10-note (still $NEWID)"; fi

# T11 supervisor wake gate refusal while Agent D busy (live wake path, mock daemon)
export SEKTOR7_STATE_DIR="$WORK/state5"; mkdir -p "$WORK/state5"
printf '{"watch": ["coder-a8"]}' > "$WORK/state5/seats.json"
scenario "{\"sessions\":{\"$SID\":{\"state\":\"idle\"},\"$SID_D\":{\"state\":\"active\"}},\"postPrompt\":{\"ok\":true}}"
# baseline cycle (seats tracked, log offset set), then the event
expect_ok "T11a-baseline" bash "$SUP" run --once
cat >> "$WORK/daemon-mock.log" <<EOF
2026-11-11T18:05:00.000Z [INFO] [DAEMON] sessionId=$SID promptId=bbbb2222-2222-2222-2222-222222222222 prompt turn completed
EOF
expect_ok "T11b-event-cycle" bash "$SUP" run --once
if grep -q "wake deferred (gate)" "$WORK/state5/supervisor.log"; then
  PASS=$((PASS+1)); echo "PASS T11-wake-gate-refusal (D busy -> deferred, no prompt sent)"
else
  FAIL=$((FAIL+1)); echo "FAIL T11-wake-gate-refusal"
fi

# T12 token redaction: the token value must never appear in any state or log file
if grep -r -q "mock-secret-token-DO-NOT-PRINT" "$WORK" --include="*.log" --include="*.json" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL T12-token-redaction (token found in outputs)"
else
  PASS=$((PASS+1)); echo "PASS T12-token-redaction"
fi

echo
echo "RESULTS: pass=$PASS fail=$FAIL (mock battery; live tests documented separately)"
[ "$FAIL" -eq 0 ]

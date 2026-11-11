#!/usr/bin/env bash
# Fuse verification test — proves the Day-7 hard-stop procedure end-to-end
# against the mock daemon: a live supervisor is stopped cleanly by the fuse,
# and the already-stopped branch removes a stale stop-flag. No production
# state, no real daemon, no accepted-source modification.
set -u
WORK="$(mktemp -d /tmp/fuse-test.XXXXXX)"
cd "$WORK"   # the mock resolves scenario.json from ITS cwd — keep them identical
ORCH_DIR="/home/coder/.qwen/sektor7-coordination/orchestrator"
FUSE="/home/coder/.qwen/sektor7-coordination/pilot/expiry-fuse.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi }
export SEKTOR7_FUSE_POLL=1

# --- wiring (mirrors tests/run-tests.sh) ---
PORT=""
for p in 4211 4212 4213 4214; do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "no free mock port"; exit 1; }

TOKEN="$WORK/mock-token"; echo "mock-secret-token-DO-NOT-PRINT" > "$TOKEN"
SID_A8="11111111-2222-3333-4444-555555555555"
SID_E9="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
SID_32="32323232-3232-3232-3232-323232323232"
SID_D="dddddddd-dddd-dddd-dddd-dddddddddddd"
printf 'coder-a8|%s\ncoder-e9|%s\ncoder-32|%s\ncoder-a3|%s\n' "$SID_A8" "$SID_E9" "$SID_32" "$SID_D" > "$WORK/roster.txt"

STATE="$WORK/state"; mkdir -p "$STATE"
jq -n '{watch: ["coder-a8","coder-e9","coder-32"], seatOf: {"coder-a8":"B","coder-e9":"C","coder-32":"A"}, coordinator: "coder-a3"}' > "$STATE/seats.json"
printf '{"events":{},"permState":{}}' > "$STATE/events.json"
printf '%s\n' "$(date -u +%FT%TZ) [INFO] [DAEMON] sessionId=$SID_A8 promptId=abcdef12-3456-3456-3456-abcdef123456 prompt turn completed" > "$WORK/daemon.log"

export SEKTOR7_DAEMON_URL="http://127.0.0.1:$PORT"
export SEKTOR7_TOKEN_FILE="$TOKEN"
export SEKTOR7_SESSIONS_JSON="$WORK/roster.txt"
export SEKTOR7_STATE_DIR="$STATE"
export SEKTOR7_QWEN_BIN="/nonexistent-qwen-bin"
export SEKTOR7_DAEMON_LOG="$WORK/daemon.log"
export MOCK_TOKEN_FILE="$TOKEN"

python3 "$ORCH_DIR/tests/mock-daemon.py" "$PORT" &
MOCK_PID=$!
trap 'kill $MOCK_PID $SUP_PID $FUSE_PID $FUSE_B_PID 2>/dev/null; true' EXIT
for _ in $(seq 1 20); do
  curl -s --max-time 1 "http://127.0.0.1:$PORT/capabilities" >/dev/null 2>&1 && break
  sleep 0.2
done

# mock scenario: all sessions idle, no posts needed (cwd = WORK = the mock's cwd)
printf '%s' '{"sessions":{},"postPrompt":{"ok":true}}' > scenario.json

# --- TEST A: the live supervisor stopped by the fuse ---
bash "$ORCH_DIR/supervisor.sh" run >> "$WORK/sup-launch.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 15); do
  grep -q "supervisor starting" "$STATE/supervisor.log" 2>/dev/null && break
  sleep 0.5
done
check "A1-supervisor-started" "grep -q 'supervisor starting: mode=live' '$STATE/supervisor.log'"
check "A2-baseline-written" "[ -f '$STATE/log-checkpoint.json' ]"
kill -0 "$SUP_PID" 2>/dev/null && echo "supervisor running as pid $SUP_PID"

DEADLINE=$(( $(date -u +%s) + 8 ))
SEKTOR7_PILOT_DIR="$WORK/pilot" SEKTOR7_STATE_DIR="$STATE" \
  bash "$FUSE" "$DEADLINE" "$SUP_PID" >> "$WORK/fuse-launch.log" 2>&1 &
FUSE_PID=$!

# wait for the fuse to fire and the supervisor to exit (the supervisor consumes
# the flag at its next loop top — worst case one 20 s interval + cycle)
for _ in $(seq 1 80); do
  [ -f "$WORK/pilot/expiry-executed.json" ] && break
  sleep 1
done
sleep 2
check "A3-fuse-evidence-exists" "[ -f '$WORK/pilot/expiry-executed.json' ]"
check "A4-exit-verified" "[ \"\$(jq -r .exitVerified '$WORK/pilot/expiry-executed.json')\" = true ]"
check "A5-method-stop-flag" "[ \"\$(jq -r .method '$WORK/pilot/expiry-executed.json')\" = stop-flag ]"
check "A6-supervisor-gone" "! kill -0 $SUP_PID 2>/dev/null"
check "A7-fuse-gone" "! kill -0 $FUSE_PID 2>/dev/null"
check "A8-clean-exit-log" "grep -q 'stop-flag observed — exiting cleanly' '$STATE/supervisor.log'"
check "A9-fuse-deadline-log" "grep -q 'DEADLINE REACHED' '$WORK/pilot/expiry-fuse.log'"
check "A10-fuse-terminated-log" "grep -q 'supervisor terminated (method=stop-flag)' '$WORK/pilot/expiry-fuse.log'"
check "A11-no-residual-stopflag" "[ ! -f '$STATE/stop-flag' ]"
check "A12-state-preserved" "[ -f '$STATE/events.json' ] && [ -f '$STATE/seats.json' ]"
cp "$WORK/pilot/expiry-executed.json" "$WORK/pilot/evidence-A.json" 2>/dev/null
cp "$WORK/pilot/expiry-fuse.log" "$WORK/pilot/fuse-log-A.log" 2>/dev/null
cp "$STATE/supervisor.log" "$WORK/pilot/supervisor-log-A.log" 2>/dev/null

# --- TEST B: the already-stopped branch (stale flag removed) ---
rm -f "$WORK/pilot/expiry-fuse.log" "$WORK/pilot/expiry-executed.json"
touch "$STATE/stop-flag"
DEADLINE_B=$(( $(date -u +%s) + 3 ))
SEKTOR7_PILOT_DIR="$WORK/pilot" SEKTOR7_STATE_DIR="$STATE" \
  bash "$FUSE" "$DEADLINE_B" "" >> "$WORK/fuse-launch-b.log" 2>&1 &
FUSE_B_PID=$!
for _ in $(seq 1 15); do
  [ -f "$WORK/pilot/expiry-executed.json" ] && break
  sleep 1
done
sleep 1
check "B1-already-stopped-method" "[ \"\$(jq -r .method '$WORK/pilot/expiry-executed.json')\" = already-stopped ]"
check "B2-stale-flag-removed" "[ ! -f '$STATE/stop-flag' ]"
check "B3-evidence" "[ \"\$(jq -r .exitVerified '$WORK/pilot/expiry-executed.json')\" = true ]"
cp "$WORK/pilot/expiry-executed.json" "$WORK/pilot/evidence-B.json" 2>/dev/null
cp "$WORK/pilot/expiry-fuse.log" "$WORK/pilot/fuse-log-B.log" 2>/dev/null

echo "----------------------------------------"
echo "FUSE TEST: $PASS pass, $FAIL fail (workdir $WORK)"
echo "evidence: $WORK/pilot/evidence-A.json (live-stop), $WORK/pilot/evidence-B.json (already-stopped)"
[ "$FAIL" = 0 ]

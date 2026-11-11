#!/usr/bin/env bash
# SEKTOR7 pilot paired-launch verification — the O1/O3/O4 review evidence.
#
# L1: the full paired-launch success lifecycle (both identities verified, the
#     deadline recorded, then the fuse fires and stops the supervisor cleanly)
# L2: the DELIBERATE fuse-launch failure -> fail-closed (the supervisor stopped,
#     state preserved, the failure record written, exit 1)
# L3: the TERM escalation (a long-interval supervisor cannot consume the flag
#     in time -> the identity-verified TERM, the stale flag removed)
# L4: the unexpected fuse death -> pairing-check detects BROKEN; after the
#     runbook cleanup -> NEITHER
# L5: the quiet token scan (a planted dummy token -> MATCH, exit 1, the value
#     never printed; a clean tree -> clean, exit 0; an unreadable file -> error)
#
# Mock-wired throughout: the REAL v11 supervisor.sh + the real pilot scripts
# against the accepted tests/mock-daemon.py; per-case state/pilot dirs; the
# production tree and state untouched.
set -u
WORK="$(mktemp -d /tmp/paired-test.XXXXXX)"
cd "$WORK"   # the mock resolves scenario.json from ITS cwd — keep them identical
ORCH_DIR="/home/coder/.qwen/sektor7-coordination/orchestrator"
PILOT_SRC="/home/coder/.qwen/sektor7-coordination/pilot"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi }

PORT=""
for p in 4215 4216 4217 4218; do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "no free mock port"; exit 1; }

TOKEN="$WORK/mock-token"; echo "mock-secret-token-DO-NOT-PRINT" > "$TOKEN"
SID_A8="11111111-2222-3333-4444-555555555555"
SID_E9="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
SID_32="32323232-3232-3232-3232-323232323232"
SID_D="dddddddd-dddd-dddd-dddd-dddddddddddd"
printf 'coder-a8|%s\ncoder-e9|%s\ncoder-32|%s\ncoder-a3|%s\n' "$SID_A8" "$SID_E9" "$SID_32" "$SID_D" > "$WORK/roster.txt"
printf '%s\n' "$(date -u +%FT%TZ) [INFO] [DAEMON] sessionId=$SID_A8 promptId=abcdef12-3456-3456-3456-abcdef123456 prompt turn completed" > "$WORK/daemon.log"
printf '%s' '{"sessions":{},"postPrompt":{"ok":true}}' > scenario.json

export SEKTOR7_DAEMON_URL="http://127.0.0.1:$PORT"
export SEKTOR7_TOKEN_FILE="$TOKEN"
export SEKTOR7_SESSIONS_JSON="$WORK/roster.txt"
export SEKTOR7_QWEN_BIN="/nonexistent-qwen-bin"
export SEKTOR7_DAEMON_LOG="$WORK/daemon.log"
export MOCK_TOKEN_FILE="$TOKEN"

python3 "$ORCH_DIR/tests/mock-daemon.py" "$PORT" &
MOCK_PID=$!
cleanup() {
  for d in "$WORK"/c1/state "$WORK"/c2/state "$WORK"/c3/state "$WORK"/c4/state; do
    [ -d "$d" ] && SEKTOR7_STATE_DIR="$d" bash "$ORCH_DIR/supervisor.sh" stop >/dev/null 2>&1
  done
  pkill -f "bash $ORCH_DIR/supervisor.sh run" 2>/dev/null
  pkill -f "bash $PILOT_SRC/expiry-fuse.sh" 2>/dev/null
  pkill -f "bash $PILOT_SRC/paired-launch.sh" 2>/dev/null
  kill "$MOCK_PID" 2>/dev/null
  true
}
trap cleanup EXIT
for _ in $(seq 1 20); do
  curl -s --max-time 1 "http://127.0.0.1:$PORT/capabilities" >/dev/null 2>&1 && break
  sleep 0.2
done

mkcase() { # mkcase NAME -> sets CASE=$WORK/NAME with state/ + pilot/ prepared
  CASE="$WORK/$1"; mkdir -p "$CASE/state" "$CASE/pilot"
  jq -n '{watch: ["coder-a8","coder-e9","coder-32"], seatOf: {"coder-a8":"B","coder-e9":"C","coder-32":"A"}, coordinator: "coder-a3"}' > "$CASE/state/seats.json"
  printf '{"events":{},"permState":{}}' > "$CASE/state/events.json"
}

# --- L1: the full success lifecycle --------------------------------------------------
mkcase c1
pgrep -f "bash $ORCH_DIR/supervisor.sh run" >/dev/null 2>&1 && { echo "FAIL: L1 precondition (a supervisor is already running)"; exit 1; }
SEKTOR7_STATE_DIR="$CASE/state" SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_FUSE_PATH="$PILOT_SRC/expiry-fuse.sh" SEKTOR7_FUSE_POLL=1 \
  bash "$PILOT_SRC/paired-launch.sh" 8 > "$CASE/launch-stdout.txt" 2>&1
L1RC=$?
check "L1-paired-launch-exit-0" "[ $L1RC = 0 ]"
check "L1-record-launched" "[ \"\$(jq -r .result '$CASE/pilot/launch-record.json')\" = launched ]"
check "L1-record-sup-pid" "[ \"\$(jq -r '.supervisorPid > 0' '$CASE/pilot/launch-record.json')\" = true ]"
check "L1-record-fuse-pid" "[ \"\$(jq -r '.fusePid > 0' '$CASE/pilot/launch-record.json')\" = true ]"
check "L1-record-starttimes" "[ \"\$(jq -r '.supervisorStarttime != \"unknown\"' '$CASE/pilot/launch-record.json')\" = true ] && [ \"\$(jq -r '.fuseStarttime != \"unknown\"' '$CASE/pilot/launch-record.json')\" = true ]"
check "L1-fuse-armed-line" "grep -qF 'fuse armed: deadline_epoch=' '$CASE/pilot/expiry-fuse.log'"
check "L1-sup-verified-lines" "grep -q 'supervisor deployment verified' '$CASE/pilot/paired-launch.log'"
for _ in $(seq 1 60); do [ -f "$CASE/pilot/expiry-executed.json" ] && break; sleep 1; done
sleep 2
check "L1-expiry-evidence" "[ -f '$CASE/pilot/expiry-executed.json' ]"
check "L1-expiry-verified" "[ \"\$(jq -r .exitVerified '$CASE/pilot/exiry-executed.json' 2>/dev/null || jq -r .exitVerified '$CASE/pilot/expiry-executed.json')\" = true ]"
check "L1-expiry-method" "[ \"\$(jq -r .method '$CASE/pilot/expiry-executed.json')\" = stop-flag ]"
check "L1-sup-gone" "! pgrep -f 'bash $ORCH_DIR/supervisor.sh run' >/dev/null"
check "L1-clean-exit" "grep -q 'stop-flag observed — exiting cleanly' '$CASE/state/supervisor.log'"
SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_STATE_DIR="$CASE/state" bash "$PILOT_SRC/pairing-check.sh" > "$CASE/pairing-after.txt" 2>&1
check "L1-pairing-neither-after-expiry" "[ $? = 0 ] && grep -q NEITHER '$CASE/pairing-after.txt'"

# --- L2: the deliberate fuse-launch failure -> fail-closed ---------------------------
mkcase c2
SEKTOR7_STATE_DIR="$CASE/state" SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_FUSE_PATH="/nonexistent/fuse.sh" \
  bash "$PILOT_SRC/paired-launch.sh" 300 > "$CASE/launch-stdout.txt" 2>&1
L2RC=$?
check "L2-exit-1" "[ $L2RC = 1 ]"
check "L2-record-failed" "[ \"\$(jq -r .result '$CASE/pilot/launch-record.json')\" = failed ]"
check "L2-reason-fuse-discovery" "jq -r .reason '$CASE/pilot/launch-record.json' | grep -q 'fuse discovery failed'"
check "L2-sup-stopped" "! pgrep -f 'bash $ORCH_DIR/supervisor.sh run' >/dev/null"
check "L2-sup-clean-exit" "grep -q 'stop-flag observed — exiting cleanly' '$CASE/state/supervisor.log'"
check "L2-fail-closed-log" "grep -q 'LAUNCH FAILURE.*fuse discovery failed' '$CASE/pilot/paired-launch.log'"
check "L2-state-preserved" "[ -f '$CASE/state/events.json' ] && [ -f '$CASE/state/seats.json' ] && [ -f '$CASE/state/supervisor.log' ]"
check "L2-no-residual-stopflag" "[ ! -f '$CASE/state/stop-flag' ]"

# --- L3: the TERM escalation ---------------------------------------------------------
mkcase c3
SEKTOR7_STATE_DIR="$CASE/state" SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_FUSE_PATH="$PILOT_SRC/expiry-fuse.sh" SEKTOR7_FUSE_POLL=1 \
  SEKTOR7_FUSE_TERM_WAIT=5 SEKTOR7_FUSE_KILL_WAIT=5 SEKTOR7_SUP_INTERVAL=600 \
  bash "$PILOT_SRC/paired-launch.sh" 6 > "$CASE/launch-stdout.txt" 2>&1
L3RC=$?
check "L3-paired-launch-exit-0" "[ $L3RC = 0 ]"
for _ in $(seq 1 40); do [ -f "$CASE/pilot/expiry-executed.json" ] && break; sleep 1; done
sleep 2
check "L3-expiry-evidence" "[ -f '$CASE/pilot/expiry-executed.json' ]"
check "L3-method-term" "[ \"\$(jq -r .method '$CASE/pilot/expiry-executed.json')\" = 'stop-flag+TERM' ]"
check "L3-exit-verified" "[ \"\$(jq -r .exitVerified '$CASE/pilot/expiry-executed.json')\" = true ]"
check "L3-term-logged" "grep -q 'TERM sent to' '$CASE/pilot/expiry-fuse.log'"
check "L3-sup-gone" "! pgrep -f 'bash $ORCH_DIR/supervisor.sh run' >/dev/null"
check "L3-stale-flag-removed" "[ ! -f '$CASE/state/stop-flag' ]"
check "L3-state-preserved" "[ -f '$CASE/state/events.json' ]"

# --- L4: the unexpected fuse death -> detection --------------------------------------
mkcase c4
SEKTOR7_STATE_DIR="$CASE/state" SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_FUSE_PATH="$PILOT_SRC/expiry-fuse.sh" SEKTOR7_FUSE_POLL=1 \
  bash "$PILOT_SRC/paired-launch.sh" 300 > "$CASE/launch-stdout.txt" 2>&1
L4RC=$?
check "L4-paired-launch-exit-0" "[ $L4RC = 0 ]"
FUSE_PID_L4="$(jq -r .fusePid "$CASE/pilot/launch-record.json")"
kill -TERM "$FUSE_PID_L4" 2>/dev/null   # the simulated unexpected fuse death
sleep 1
SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_STATE_DIR="$CASE/state" \
  bash "$PILOT_SRC/pairing-check.sh" > "$CASE/pairing-broken.txt" 2>&1
check "L4-detection-broken-exit-1" "[ $? = 1 ]"
check "L4-detection-broken-message" "grep -q BROKEN '$CASE/pairing-broken.txt'"
SEKTOR7_STATE_DIR="$CASE/state" bash "$ORCH_DIR/supervisor.sh" stop >/dev/null 2>&1
for _ in $(seq 1 30); do pgrep -f "bash $ORCH_DIR/supervisor.sh run" >/dev/null 2>&1 || break; sleep 1; done
SEKTOR7_PILOT_DIR="$CASE/pilot" SEKTOR7_STATE_DIR="$CASE/state" \
  bash "$PILOT_SRC/pairing-check.sh" > "$CASE/pairing-after.txt" 2>&1
check "L4-after-cleanup-neither" "[ $? = 0 ] && grep -q NEITHER '$CASE/pairing-after.txt'"

# --- L5: the quiet token scan --------------------------------------------------------
mkdir -p "$WORK/scan-target" "$WORK/scan-clean"
DUMMY="test-dummy-token-abcdef123456-do-not-print"
printf 'some log line\nthe credential is %s\nanother line\n' "$DUMMY" > "$WORK/scan-target/planted.log"
printf '%s' "$DUMMY" > "$WORK/dummy-token-file"
bash "$PILOT_SRC/token-scan.sh" "$WORK/dummy-token-file" "$WORK/scan-target" > "$WORK/scan-out-match.txt" 2>&1
check "L5-match-exit-1" "[ $? = 1 ]"
check "L5-match-quiet" "grep -q '^MATCH:' '$WORK/scan-out-match.txt' && ! grep -qF '$DUMMY' '$WORK/scan-out-match.txt'"
bash "$PILOT_SRC/token-scan.sh" "$WORK/dummy-token-file" "$WORK/scan-clean" > "$WORK/scan-out-clean.txt" 2>&1
check "L5-clean-exit-0" "[ $? = 0 ] && grep -q '^clean:' '$WORK/scan-out-clean.txt'"
bash "$PILOT_SRC/token-scan.sh" "/nonexistent/token-file" "$WORK/scan-clean" > "$WORK/scan-out-err.txt" 2>&1
check "L5-error-exit-2" "[ $? = 2 ] && grep -q '^ERROR:' '$WORK/scan-out-err.txt'"

echo "----------------------------------------"
echo "PAIRED-LAUNCH TEST: $PASS pass, $FAIL fail (workdir $WORK)"
[ "$FAIL" = 0 ]

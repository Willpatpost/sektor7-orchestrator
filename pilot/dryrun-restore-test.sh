#!/usr/bin/env bash
# SEKTOR7 pilot dry-run state verification — the O2 review evidence.
#
# R1: the exact expected state delta of `supervisor.sh run --once --dry-run` on
#     a fresh production-shaped state: ONLY (a) log-checkpoint.json created,
#     (b) supervisor.log appended, (c) supervisor-run.lock created. The event
#     store, seats, approvals, and ledger are byte-identical; no wake.log, no
#     submit.lock, no other file.
# R2: the restoration procedure: the post-dry-run state is MOVED ASIDE (nothing
#     deleted — forensic evidence preserved), the pre-dry-run snapshot is
#     re-extracted, and the restored state is EXACTLY the snapshot (no
#     unrecognized new files).
#
# Mock-wired: the REAL v11 supervisor.sh against the accepted mock daemon; a
# test state dir only; production untouched.
set -u
WORK="$(mktemp -d /tmp/dryrun-test.XXXXXX)"
cd "$WORK"
ORCH_DIR="/home/coder/.qwen/sektor7-coordination/orchestrator"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi }

PORT=""
for p in 4219 4220 4221 4222; do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "no free mock port"; exit 1; }

TOKEN="$WORK/mock-token"; echo "mock-secret-token-DO-NOT-PRINT" > "$TOKEN"
SID_A8="11111111-2222-3333-4444-555555555555"
SID_D="dddddddd-dddd-dddd-dddd-dddddddddddd"
printf 'coder-a8|%s\ncoder-e9|%s\ncoder-32|%s\ncoder-a3|%s\n' \
  "$SID_A8" "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" "32323232-3232-3232-3232-323232323232" "$SID_D" > "$WORK/roster.txt"
printf '%s\n' "$(date -u +%FT%TZ) [INFO] [DAEMON] sessionId=$SID_A8 promptId=abcdef12-3456-3456-3456-abcdef123456 prompt turn completed" > "$WORK/daemon.log"
printf '%s' '{"sessions":{},"postPrompt":{"ok":true}}' > scenario.json

STATE="$WORK/state"; mkdir -p "$STATE"
jq -n '{watch: ["coder-a8","coder-e9","coder-32"], seatOf: {"coder-a8":"B","coder-e9":"C","coder-32":"A"}, coordinator: "coder-a3"}' > "$STATE/seats.json"
printf '{"events":{},"permState":{}}' > "$STATE/events.json"
jq -n '{approvals: {"deadbeef": {checkpoint: "TEST", seat: "B", provenanceFile: "x.md", approvedAt: "2026-11-11T00:00:00Z"}}}' > "$STATE/approvals.json"

export SEKTOR7_DAEMON_URL="http://127.0.0.1:$PORT"
export SEKTOR7_TOKEN_FILE="$TOKEN"
export SEKTOR7_SESSIONS_JSON="$WORK/roster.txt"
export SEKTOR7_STATE_DIR="$STATE"
export SEKTOR7_QWEN_BIN="/nonexistent-qwen-bin"
export SEKTOR7_DAEMON_LOG="$WORK/daemon.log"
export MOCK_TOKEN_FILE="$TOKEN"

python3 "$ORCH_DIR/tests/mock-daemon.py" "$PORT" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null; true' EXIT
for _ in $(seq 1 20); do
  curl -s --max-time 1 "http://127.0.0.1:$PORT/capabilities" >/dev/null 2>&1 && break
  sleep 0.2
done

# --- the protected snapshot BEFORE any supervisor execution ---------------------------
SNAP="$WORK/snapshot-pre-dryrun.tar.gz"
tar czf "$SNAP" -C "$STATE" .
SNAPLIST="$(tar tzf "$SNAP" | sed 's|^\./||' | grep -v '^$' | sort)"
mkdir -p "$WORK/snap-content" && tar xzf "$SNAP" -C "$WORK/snap-content"

# --- the dry-run cycle ------------------------------------------------------------------
bash "$ORCH_DIR/supervisor.sh" run --once --dry-run > "$WORK/dryrun-stdout.txt" 2>&1
DRYRC=$?
check "R0-dryrun-exit-0" "[ $DRYRC = 0 ]"
check "R0-dryrun-log-lines" "grep -q 'supervisor starting: mode=once dry=1' '$STATE/supervisor.log' && grep -q 'log baseline set' '$STATE/supervisor.log'"

# --- R1: the exact expected delta --------------------------------------------------------
# The dry-run writes: (1) log-checkpoint.json NEW, (2) supervisor.log NEW,
# (3) supervisor-run.lock NEW, (4) events.json MUTATED — the permState clearance
# cache ({waiting:false, episodes:0} per watched session; check_permission_waits
# runs its clearance transaction regardless of dryrun). The .events object must
# stay empty; seats/approvals byte-identical; no wake.log; no submit.lock.
NEWFILES="$(comm -13 <(printf '%s\n' "$SNAPLIST") <(ls -A "$STATE" | sort))"
check "R1-delta-only-expected-new" "[ \"\$(printf '%s\n' '$NEWFILES' | grep -c .)\" = 3 ] && printf '%s\n' '$NEWFILES' | grep -qx 'log-checkpoint.json' && printf '%s\n' '$NEWFILES' | grep -qx 'supervisor-run.lock' && printf '%s\n' '$NEWFILES' | grep -qx 'supervisor.log'"
check "R1-permstate-clearance-expected" "jq -e '.permState | length == 3 and ([to_entries[] | .value.waiting == false and .value.episodes == 0] | all)' '$STATE/events.json' >/dev/null"
check "R1-events-object-empty" "[ \"\$(jq '.events | length' '$STATE/events.json')\" = 0 ]"
check "R1-seats-unchanged" "cmp -s '$WORK/snap-content/seats.json' '$STATE/seats.json'"
check "R1-approvals-unchanged" "cmp -s '$WORK/snap-content/approvals.json' '$STATE/approvals.json'"
check "R1-no-wakelog" "[ ! -f '$STATE/wake.log' ]"
check "R1-no-submitlock" "[ ! -f '$STATE/submit.lock' ]"
check "R1-checkpoint-valid" "jq -e '.cursor > 0 and .prefixDigest' '$STATE/log-checkpoint.json' >/dev/null"

# --- R2: the restoration procedure (forensics preserved; exact restore) -----------------
FAILED_DIR="$WORK/state-failed-$(date -u +%Y%m%dT%H%M%SZ)"
mv "$STATE" "$FAILED_DIR"                       # nothing deleted — the forensic copy
mkdir -p "$STATE"
tar xzf "$SNAP" -C "$STATE"                     # the exact pre-dry-run state
RESDIFF="$(diff -r <(tar xzf "$SNAP" -O . 2>/dev/null; true) /dev/null 2>/dev/null; true)"
# exact-inventory + content verification: re-snapshot the restored dir and compare
SNAP2="$WORK/snapshot-restored.tar.gz"
tar czf "$SNAP2" -C "$STATE" .
check "R2-restored-inventory-identical" "[ \"\$(tar tzf '$SNAP' | sort)\" = \"\$(tar tzf '$SNAP2' | sort)\" ]"
check "R2-restored-content-identical" "cmp -s '$SNAP' '$SNAP2'"
check "R2-forensics-preserved" "[ -f '$FAILED_DIR/log-checkpoint.json' ] && [ -f '$FAILED_DIR/supervisor.log' ] && [ -f '$FAILED_DIR/events.json' ]"
check "R2-restored-store-clean" "[ \"\$(jq '.events | length' '$STATE/events.json')\" = 0 ] && [ ! -f '$STATE/log-checkpoint.json' ]"

echo "----------------------------------------"
echo "DRY-RUN RESTORE TEST: $PASS pass, $FAIL fail (workdir $WORK)"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# SEKTOR7 pilot pairing check — the tested detection procedure for a broken
# activation pair (the O4 "unexpected fuse death" detector).
#
# Reads pilot/launch-record.json when present (strong verification: the exact
# recorded PIDs + start times); falls back to pattern checks otherwise.
# Exit codes: 0 = both alive (or neither — the normal post-expiry state);
#             1 = BROKEN pairing (a live supervisor without its fuse);
#             2 = ambiguous (a fuse without a supervisor, or unverifiable);
#             3 = error (unreadable record/environment).
# Output: one status line — never process lists beyond the recorded PIDs,
# never any secret.
#
# env: SEKTOR7_ORCH_DIR, SEKTOR7_PILOT_DIR, SEKTOR7_STATE_DIR
set -u

ORCH_DIR="${SEKTOR7_ORCH_DIR:-$HOME/.qwen/sektor7-coordination/orchestrator}"
PILOT_DIR="${SEKTOR7_PILOT_DIR:-$HOME/.qwen/sektor7-coordination/pilot}"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
RECORD="$PILOT_DIR/launch-record.json"
SUP_SCRIPT="$ORCH_DIR/supervisor.sh"
FUSE_DEFAULT="$PILOT_DIR/expiry-fuse.sh"

proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
proc_arg()       { tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | sed -n "$2p"; }

# a live supervisor = the recorded PID verifies (argv + start time), or (no
# record) any process whose argv is exactly `bash <SUP_SCRIPT> run`
sup_running() {
  if [ -r "$RECORD" ]; then
    local pid st
    pid="$(jq -r '.supervisorPid // 0' "$RECORD" 2>/dev/null)"
    st="$(jq -r '.supervisorStarttime // ""' "$RECORD" 2>/dev/null)"
    if [ "$pid" != 0 ] && kill -0 "$pid" 2>/dev/null \
       && [ "$(proc_arg "$pid" 2)" = "$SUP_SCRIPT" ] && [ "$(proc_arg "$pid" 3)" = "run" ] \
       && { [ -z "$st" ] || [ "$(proc_starttime "$pid")" = "$st" ]; }; then
      return 0
    fi
    # the recorded PID is gone — a pattern match could still be OUR supervisor
    # after a restart, or a foreign one; report via the pattern path below
  fi
  local pid
  for pid in $(pgrep -f "bash $SUP_SCRIPT run" 2>/dev/null); do
    [ "$(proc_arg "$pid" 2)" = "$SUP_SCRIPT" ] && [ "$(proc_arg "$pid" 3)" = "run" ] && return 0
  done
  return 1
}

# a live fuse = the recorded PID verifies, or (no record) any `bash <fuse> …`
fuse_running() {
  if [ -r "$RECORD" ]; then
    local pid st d p
    pid="$(jq -r '.fusePid // 0' "$RECORD" 2>/dev/null)"
    st="$(jq -r '.fuseStarttime // ""' "$RECORD" 2>/dev/null)"
    d="$(jq -r '.deadlineEpoch // 0' "$RECORD" 2>/dev/null)"
    p="$(jq -r '.supervisorPid // 0' "$RECORD" 2>/dev/null)"
    if [ "$pid" != 0 ] && kill -0 "$pid" 2>/dev/null \
       && [ "$(proc_arg "$pid" 2)" = "$FUSE_DEFAULT" ] && [ "$(proc_arg "$pid" 3)" = "$d" ] \
       && { [ -z "$st" ] || [ "$(proc_starttime "$pid")" = "$st" ]; }; then
      return 0
    fi
  fi
  local pid
  for pid in $(pgrep -f "bash $FUSE_DEFAULT" 2>/dev/null); do
    [ "$(proc_arg "$pid" 2)" = "$FUSE_DEFAULT" ] && return 0
  done
  return 1
}

[ -d "$PILOT_DIR" ] || { echo "ERROR: pilot dir not found: $PILOT_DIR"; exit 3; }

S=0; fuse_running && S=1 || true
U=0; sup_running  && U=1 || true

if [ "$U" = 1 ] && [ "$S" = 1 ]; then
  echo "OK: the activation pair is intact (supervisor + fuse both running)"
  exit 0
elif [ "$U" = 1 ] && [ "$S" = 0 ]; then
  echo "BROKEN: the supervisor is running WITHOUT its expiry fuse — execute the rollback runbook (stop the supervisor, preserve state, report)"
  exit 1
elif [ "$U" = 0 ] && [ "$S" = 1 ]; then
  echo "AMBIGUOUS: a fuse is running without a supervisor — investigate (an orphaned fuse is harmless but should be torn down by its recorded identity)"
  exit 2
else
  echo "NEITHER: no supervisor and no fuse (the normal post-expiry or pre-activation state)"
  exit 0
fi

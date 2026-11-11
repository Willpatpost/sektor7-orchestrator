#!/usr/bin/env bash
# SEKTOR7 pilot paired launcher — the fail-closed O1 activation unit.
#
# Launches the supervisor and the expiry fuse as ONE unit and verifies, before
# reporting success, that BOTH processes exist, carry the exact intended
# identities (exact argv from /proc/<pid>/cmdline + the process start time from
# /proc/<pid>/stat), are alive, and that the fuse has recorded the intended
# deadline. On ANY failure at any step: stop every supervisor reading this
# state dir (the stop-flag is state-dir-scoped), identity-verify before any
# signal, tear down the fuse if it was launched, preserve ALL state and logs
# (nothing deleted — forensic evidence intact), write the failure record,
# exit 1. Success: the launch record + exit 0.
#
# Run ONLY on the owner's activation GO (after the full preflight).
# usage: paired-launch.sh [DURATION_SECONDS]     (default 604800 = 7 days)
# env:   SEKTOR7_ORCH_DIR, SEKTOR7_PILOT_DIR, SEKTOR7_STATE_DIR (passed through
#        to the supervisor/fuse), SEKTOR7_FUSE_PATH (default: the pilot fuse),
#        SEKTOR7_FUSE_POLL / _TERM_WAIT / _KILL_WAIT, SEKTOR7_SUP_INTERVAL,
#        and the supervisor's daemon env (SEKTOR7_DAEMON_URL, _TOKEN_FILE,
#        _SESSIONS_JSON, _QWEN_BIN, _DAEMON_LOG — all inherited by the orphans).
set -u
umask 077

ORCH_DIR="${SEKTOR7_ORCH_DIR:-$HOME/.qwen/sektor7-coordination/orchestrator}"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
PILOT_DIR="${SEKTOR7_PILOT_DIR:-$HOME/.qwen/sektor7-coordination/pilot}"
FUSE="${SEKTOR7_FUSE_PATH:-$PILOT_DIR/expiry-fuse.sh}"
DURATION="${1:-604800}"
SUP_SCRIPT="$ORCH_DIR/supervisor.sh"
LOG="$PILOT_DIR/paired-launch.log"
RECORD="$PILOT_DIR/launch-record.json"

mkdir -p "$PILOT_DIR" 2>/dev/null
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# --- /proc identity helpers (strict: exact argv + start time, never a substring) ----
proc_args()      { tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null; }
proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
proc_arg()       { proc_args "$1" | sed -n "$2p"; }

is_supervisor_pid() { # PID [STARTTIME] — argv: bash <SUP_SCRIPT> run
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(proc_arg "$1" 2)" = "$SUP_SCRIPT" ] || return 1
  [ "$(proc_arg "$1" 3)" = "run" ] || return 1
  [ -z "${2:-}" ] || [ "$(proc_starttime "$1")" = "$2" ]
}
is_fuse_pid() { # PID DEADLINE SUP_PID [SUP_STARTTIME_ARGV] — argv: bash <FUSE> d p [st]
  # the 4th parameter is the SUPERVISOR start time carried as the fuse's argv5
  # (the launch contract) — NOT the fuse's own /proc start time, which is
  # captured separately for the record after discovery
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(proc_arg "$1" 2)" = "$FUSE" ] || return 1
  [ "$(proc_arg "$1" 3)" = "$2" ] || return 1
  [ "$(proc_arg "$1" 4)" = "$3" ] || return 1
  [ -z "${4:-}" ] || [ "$(proc_arg "$1" 5)" = "$4" ]
}
sup_validator()    { is_supervisor_pid "$@"; }
fuse_validator()   { local d p; d="${EXTRA_D:-}"; p="${EXTRA_P:-}"; is_fuse_pid "$1" "$d" "$p" "${EXTRA_S:-}"; }

# discover PATTERN VALIDATOR [extra identity fields via EXTRA_* env]
#   -> exactly one validated PID on stdout; rc 1 = not found in 10 s; rc 2 = ambiguous
# The transient double-fork intermediate (argv[2] == -c) never validates; a
# pre-existing genuine instance makes the result ambiguous — never a guess.
discover() {
  local pattern="$1" validator="$2" pid found n i
  for i in $(seq 1 20); do
    found=""
    for pid in $(pgrep -f "$pattern" 2>/dev/null); do
      if "$validator" "$pid"; then found="${found}${pid}
"; fi
    done
    n="$(printf '%s' "$found" | grep -c .)"
    [ "$n" = 1 ] && { printf '%s' "$found" | head -1; return 0; }
    [ "$n" -gt 1 ] && return 2
    sleep 0.5
  done
  return 1
}

write_record() { # write_record RESULT REASON — explicit jq refs (never object shorthand)
  jq -n --arg launchedAt "$(date -u +%FT%TZ)" \
        --argjson duration "$DURATION" \
        --argjson deadline "$DEADLINE" \
        --argjson supPid "${SUP_PID:-0}" \
        --arg supStarttime "${SUP_STARTTIME:-unknown}" \
        --argjson fusePid "${FUSE_PID:-0}" \
        --arg fuseStarttime "${FUSE_STARTTIME:-unknown}" \
        --arg result "$1" \
        --arg reason "${2:-}" \
        '{launchedAt: $launchedAt, durationSeconds: $duration, deadlineEpoch: $deadline,
          supervisorPid: $supPid, supervisorStarttime: $supStarttime,
          fusePid: $fusePid, fuseStarttime: $fuseStarttime, result: $result, reason: $reason}' \
    > "$RECORD"
}

fail_closed() { # fail_closed REASON — stop everything launched, preserve all evidence
  log "LAUNCH FAILURE: $1 — executing fail-closed"
  # (a) the stop-flag is STATE-DIR scoped: it stops every supervisor reading this
  #     state dir, including one we cannot individually identify
  SEKTOR7_STATE_DIR="$STATE_DIR" bash "$SUP_SCRIPT" stop >> "$LOG" 2>&1
  log "stop-flag set — waiting up to 60 s for supervisor exits"
  local i
  for i in $(seq 1 60); do pgrep -f "bash $SUP_SCRIPT run" >/dev/null 2>&1 || break; sleep 1; done
  # (b) the identity-verified kill fallback — only OUR recorded supervisor
  if [ -n "${SUP_PID:-}" ] && kill -0 "$SUP_PID" 2>/dev/null && is_supervisor_pid "$SUP_PID" "${SUP_STARTTIME:-}"; then
    kill -TERM "$SUP_PID" 2>/dev/null && log "TERM sent to $SUP_PID (identity verified)"
    for i in $(seq 1 30); do kill -0 "$SUP_PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$SUP_PID" 2>/dev/null && is_supervisor_pid "$SUP_PID" "${SUP_STARTTIME:-}"; then
      kill -KILL "$SUP_PID" 2>/dev/null && log "KILL sent to $SUP_PID (identity verified)"
    fi
  fi
  # (c) tear down the fuse if it was launched (identity-verified only)
  if [ -n "${FUSE_PID:-}" ] && kill -0 "$FUSE_PID" 2>/dev/null; then
    if is_fuse_pid "$FUSE_PID" "$DEADLINE" "${SUP_PID:-}" "${SUP_STARTTIME:-}"; then
      kill -TERM "$FUSE_PID" 2>/dev/null && log "fuse TERM (identity verified) — an unpaired fuse must not stay armed"
    else
      log "fuse present but NOT identity-verifiable — no signal sent; investigate manually"
    fi
  fi
  # (d) the stale stop-flag would sabotage a future launch — nothing is running
  #     that reads this state dir now; remove it (forensic state untouched)
  sleep 1
  pgrep -f "bash $SUP_SCRIPT run" >/dev/null 2>&1 || rm -f "$STATE_DIR/stop-flag" 2>/dev/null
  pgrep -f "bash $SUP_SCRIPT run" >/dev/null 2>&1 \
    && log "WARNING: supervisor-like processes remain after fail-closed (not ours / different state dir) — investigate"
  write_record "failed" "$1"
  log "fail-closed complete — state preserved; record: $RECORD"
  exit 1
}

log "paired launch beginning: duration=${DURATION}s state_dir=$STATE_DIR fuse=$FUSE"
DEADLINE=$(( $(date -u +%s) + DURATION ))
log "deadline_epoch=$DEADLINE ($(date -u -d "@$DEADLINE" +%FT%TZ 2>/dev/null || echo '?'))"

# --- (1) launch the supervisor — the proven double-fork orphan form -----------------
bash -c "setsid nohup bash '$SUP_SCRIPT' run >> '$PILOT_DIR/supervisor-launch.log' 2>&1 < /dev/null & disown"

# --- (2) discover + strictly identify the supervisor PID ----------------------------
SUP_PID="$(discover "bash $SUP_SCRIPT run" sup_validator)" \
  || fail_closed "supervisor discovery failed (not found in 10 s or ambiguous — a pre-existing instance?)"
SUP_STARTTIME="$(proc_starttime "$SUP_PID")"
[ -n "$SUP_STARTTIME" ] || fail_closed "supervisor start time unreadable for pid $SUP_PID"
log "supervisor identified: pid=$SUP_PID starttime=$SUP_STARTTIME (argv verified)"

# --- (3) verify the supervisor corresponds to the intended deployment ---------------
SUPLOG="$STATE_DIR/supervisor.log"
for i in $(seq 1 20); do
  grep -q 'supervisor starting: mode=live' "$SUPLOG" 2>/dev/null && break
  kill -0 "$SUP_PID" 2>/dev/null || fail_closed "supervisor exited during startup"
  sleep 0.5
done
grep -q 'supervisor starting: mode=live' "$SUPLOG" 2>/dev/null \
  || fail_closed "the supervisor loop-start line never appeared in the state log"
grep -q 'seats configuration validated' "$SUPLOG" 2>/dev/null \
  || fail_closed "the supervisor startup validation did not pass (no 'seats configuration validated')"
log "supervisor deployment verified: mode=live; the coordinator configuration validated"

# --- (4) launch the fuse — the same double-fork orphan form --------------------------
bash -c "setsid nohup bash '$FUSE' '$DEADLINE' '$SUP_PID' '$SUP_STARTTIME' >> '$PILOT_DIR/fuse-launch.log' 2>&1 < /dev/null & disown"

# --- (5) discover + strictly identify the fuse PID -----------------------------------
FUSE_PID="$(EXTRA_D="$DEADLINE" EXTRA_P="$SUP_PID" EXTRA_S="$SUP_STARTTIME" \
  discover "bash $FUSE $DEADLINE $SUP_PID" fuse_validator)" \
  || fail_closed "fuse discovery failed (not found in 10 s or ambiguous — the fuse launch may have failed)"
FUSE_STARTTIME="$(proc_starttime "$FUSE_PID")"
[ -n "$FUSE_STARTTIME" ] || fail_closed "fuse start time unreadable for pid $FUSE_PID"
log "fuse identified: pid=$FUSE_PID starttime=$FUSE_STARTTIME (argv verified: deadline $DEADLINE, supervisor $SUP_PID)"

# --- (6) both alive ------------------------------------------------------------------
kill -0 "$SUP_PID" 2>/dev/null || fail_closed "the supervisor died before the launch completed"
kill -0 "$FUSE_PID" 2>/dev/null || fail_closed "the fuse died before the launch completed"

# --- (7) the fuse recorded the intended deadline --------------------------------------
for i in $(seq 1 10); do
  grep -qF "deadline_epoch=$DEADLINE " "$PILOT_DIR/expiry-fuse.log" 2>/dev/null && break
  sleep 0.5
done
grep -qF "deadline_epoch=$DEADLINE " "$PILOT_DIR/expiry-fuse.log" 2>/dev/null \
  || fail_closed "the fuse did not record the intended deadline in its log (unverifiable arming)"
is_fuse_pid "$FUSE_PID" "$DEADLINE" "$SUP_PID" "$SUP_STARTTIME" \
  || fail_closed "the fuse identity no longer verifies (argv/deadline mismatch)"
log "fuse arming verified: deadline $DEADLINE recorded in the fuse log and carried in its argv"

# --- (8) success ----------------------------------------------------------------------
write_record "launched" ""
log "PAIRED LAUNCH VERIFIED: supervisor pid=$SUP_PID fuse pid=$FUSE_PID deadline=$DEADLINE — record: $RECORD"
echo "paired launch verified: supervisor=$SUP_PID fuse=$FUSE_PID deadline=$DEADLINE"
exit 0

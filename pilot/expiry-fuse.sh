#!/usr/bin/env bash
# SEKTOR7 pilot expiry fuse — the deadline-side half of the paired launch.
#
# Launched ONLY on the owner's activation GO, normally via pilot/paired-launch.sh
# (the fail-closed O1 launcher that verifies both processes and the recorded
# deadline). Authority: terminate the supervisor at the deadline and leave
# evidence. NOTHING ELSE: no POSTs to the daemon, no restarts, no cron changes,
# no writes to the accepted v11 sources, no state resets. It is a deadline fuse,
# not a watchdog — it observes nothing but the clock.
#
# usage: expiry-fuse.sh DEADLINE_EPOCH [SUPERVISOR_PID [SUPERVISOR_STARTTIME]]
#   DEADLINE_EPOCH       UTC epoch seconds of the Day-7 stop (set at GO time)
#   SUPERVISOR_PID       the PID recorded at the supervisor launch (the verified-
#                        kill fallback only; the stop-flag is the primary)
#   SUPERVISOR_STARTTIME /proc/<pid>/stat field 22 captured at launch — the
#                        process-start identity; with it, the signal path
#                        verifies cmdline AND start time (PID-reuse closing)
# env:   SEKTOR7_ORCH_DIR, SEKTOR7_STATE_DIR, SEKTOR7_PILOT_DIR,
#        SEKTOR7_FUSE_POLL (deadline poll, default 300 s — the stop executes
#        within one poll of the deadline), SEKTOR7_FUSE_TERM_WAIT (default 60 s
#        after the stop-flag before TERM), SEKTOR7_FUSE_KILL_WAIT (default 30 s
#        after TERM before KILL) — the waits are test-overridable.
#
# Stop escalation: (1) supervisor.sh stop — the stop-flag, clean exit within
# one cycle; (2) if still alive after TERM_WAIT: kill -TERM by the recorded PID,
# ONLY after the process identity verifies (exact script args in /proc/cmdline
# AND the recorded start time when provided); (3) if still alive after
# KILL_WAIT: kill -KILL, same verification. If the identity does not verify, NO
# signal is sent — the stop-flag stands and the ambiguity is recorded for a
# human decision. After a VERIFIED forced kill the (then-stale) stop-flag is
# removed so it cannot sabotage a future launch.
set -u
umask 077

ORCH_DIR="${SEKTOR7_ORCH_DIR:-$HOME/.qwen/sektor7-coordination/orchestrator}"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
PILOT_DIR="${SEKTOR7_PILOT_DIR:-$HOME/.qwen/sektor7-coordination/pilot}"
DEADLINE_EPOCH="${1:?usage: expiry-fuse.sh DEADLINE_EPOCH [SUPERVISOR_PID [SUPERVISOR_STARTTIME]]}"
SUP_PID="${2:-}"
SUP_STARTTIME="${3:-}"
LOG="$PILOT_DIR/expiry-fuse.log"
EVIDENCE="$PILOT_DIR/expiry-executed.json"
POLL="${SEKTOR7_FUSE_POLL:-300}"
TERM_WAIT="${SEKTOR7_FUSE_TERM_WAIT:-60}"
KILL_WAIT="${SEKTOR7_FUSE_KILL_WAIT:-30}"

mkdir -p "$PILOT_DIR" 2>/dev/null
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

log "fuse armed: deadline_epoch=$DEADLINE_EPOCH ($(date -u -d "@$DEADLINE_EPOCH" +%FT%TZ 2>/dev/null || echo '?')) supervisor_pid=${SUP_PID:-unset} supervisor_starttime=${SUP_STARTTIME:-unset} state_dir=$STATE_DIR"

sup_alive() {
  if [ -n "$SUP_PID" ] && kill -0 "$SUP_PID" 2>/dev/null; then return 0; fi
  pgrep -f "$ORCH_DIR/supervisor.sh run" >/dev/null 2>&1
}

proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

pid_is_supervisor() { # signal-path identity: exact argv AND (when recorded) start time
  [ -n "$SUP_PID" ] || return 1
  kill -0 "$SUP_PID" 2>/dev/null || return 1
  local args
  args="$(tr '\0' '\n' < "/proc/$SUP_PID/cmdline" 2>/dev/null)"
  [ "$(printf '%s\n' "$args" | sed -n 2p)" = "$ORCH_DIR/supervisor.sh" ] || return 1
  [ "$(printf '%s\n' "$args" | sed -n 3p)" = "run" ] || return 1
  [ -z "$SUP_STARTTIME" ] || [ "$(proc_starttime "$SUP_PID")" = "$SUP_STARTTIME" ]
}

# --- the deadline wait (a bounded poll; the fuse observes nothing else) ------------
while [ "$(date -u +%s)" -lt "$DEADLINE_EPOCH" ]; do
  sleep "$POLL"
done
log "DEADLINE REACHED — executing the hard stop"

if ! sup_alive; then
  # a dead supervisor cannot consume a stop-flag; a stale one would make any
  # future launch exit at its first cycle — remove it and record
  rm -f "$STATE_DIR/stop-flag"
  log "supervisor not running at deadline — stale stop-flag removed (if any); nothing to stop"
  jq -n --argjson deadline "$DEADLINE_EPOCH" \
        --arg executedAt "$(date -u +%FT%TZ)" \
        --arg method "already-stopped" \
        '{deadline: $deadline, executedAt: $executedAt, method: $method, supervisorRunningAtDeadline: false, exitVerified: true}' \
      > "$EVIDENCE"
  log "evidence written: $EVIDENCE (already-stopped)"
  exit 0
fi

# (1) the clean primary: the stop-flag (works regardless of PID)
bash "$ORCH_DIR/supervisor.sh" stop >> "$LOG" 2>&1
log "stop-flag set — waiting up to $TERM_WAIT s for the clean exit (one cycle at the 20 s interval)"
for _ in $(seq 1 "$TERM_WAIT"); do sup_alive || break; sleep 1; done

method="stop-flag"
forced=0
if sup_alive; then
  if pid_is_supervisor; then
    kill -TERM "$SUP_PID" 2>/dev/null && log "TERM sent to $SUP_PID (argv + start-time verified)"
    for _ in $(seq 1 "$KILL_WAIT"); do sup_alive || break; sleep 1; done
    method="stop-flag+TERM"
    forced=1
    if sup_alive && pid_is_supervisor; then
      kill -KILL "$SUP_PID" 2>/dev/null && log "KILL sent to $SUP_PID (argv + start-time verified)"
      method="stop-flag+TERM+KILL"
    fi
  else
    log "FUSE AMBIGUOUS: the supervisor still runs but the recorded PID fails the identity check (reuse?) — NO signal sent; the stop-flag stands; human decision required"
    method="stop-flag-only-identity-unverified"
  fi
fi

if sup_alive; then
  log "exit NOT verified (method=$method) — the stop-flag remains in place; human decision required"
  verified=false
else
  if [ "$forced" = 1 ]; then
    # the supervisor was killed mid-cycle: it never consumed the flag — the
    # flag is stale by construction; remove it so a future launch is not
    # sabotaged (forensic state — the event store, checkpoint, logs — untouched)
    rm -f "$STATE_DIR/stop-flag"
    log "stale stop-flag removed after the verified forced stop"
  fi
  log "supervisor terminated (method=$method)"
  verified=true
fi

jq -n --argjson deadline "$DEADLINE_EPOCH" \
      --arg executedAt "$(date -u +%FT%TZ)" \
      --arg method "$method" \
      --argjson verified "$verified" \
      '{deadline: $deadline, executedAt: $executedAt, method: $method, supervisorRunningAtDeadline: true, exitVerified: $verified}' \
    > "$EVIDENCE"
log "evidence written: $EVIDENCE (exitVerified=$verified)"
exit 0

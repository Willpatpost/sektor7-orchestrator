#!/usr/bin/env bash
# SEKTOR7 pilot expiry fuse — the independently enforced Day-7 hard stop.
#
# Launched ONLY on the owner's activation GO, as one activation unit with the
# supervisor (paired launch; see PILOT_ACTIVATION_PLAN_ADDENDUM.md §1).
# Authority: terminate the supervisor at the deadline and leave evidence.
# NOTHING ELSE: no POSTs to the daemon, no restarts, no cron changes, no
# writes to the accepted v11 sources, no state resets. It is a deadline fuse,
# not a watchdog — it observes nothing but the clock.
#
# usage: expiry-fuse.sh DEADLINE_EPOCH [SUPERVISOR_PID]
#   DEADLINE_EPOCH   UTC epoch seconds of the Day-7 hard stop (set at GO time)
#   SUPERVISOR_PID   the PID recorded at the supervisor launch (the verified-
#                    kill fallback only; the stop-flag is the primary)
# env:   SEKTOR7_ORCH_DIR, SEKTOR7_STATE_DIR, SEKTOR7_PILOT_DIR (all overridable
#        for testing; production defaults point at the live coordination tree)
#
# Stop escalation: (1) supervisor.sh stop — the stop-flag, clean exit within
# one cycle; (2) if still alive after 60 s: kill -TERM by the recorded PID,
# ONLY after /proc/<pid>/cmdline is verified to be supervisor.sh (PID-reuse
# protection over a 7-day window); (3) if still alive after 30 s: kill -KILL,
# same verification. If the PID does not verify, NO signal is sent — the stop-
# flag stands and the ambiguity is recorded for a human decision.
set -u
umask 077

ORCH_DIR="${SEKTOR7_ORCH_DIR:-$HOME/.qwen/sektor7-coordination/orchestrator}"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
PILOT_DIR="${SEKTOR7_PILOT_DIR:-$HOME/.qwen/sektor7-coordination/pilot}"
DEADLINE_EPOCH="${1:?usage: expiry-fuse.sh DEADLINE_EPOCH [SUPERVISOR_PID]}"
SUP_PID="${2:-}"
LOG="$PILOT_DIR/expiry-fuse.log"
EVIDENCE="$PILOT_DIR/expiry-executed.json"
# the deadline poll: production default 300 s (the stop executes within
# SEKTOR7_FUSE_POLL after the exact deadline); tests override to 1 s
POLL="${SEKTOR7_FUSE_POLL:-300}"

mkdir -p "$PILOT_DIR"
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

log "fuse armed: deadline_epoch=$DEADLINE_EPOCH ($(date -u -d "@$DEADLINE_EPOCH" +%FT%TZ 2>/dev/null || echo '?')) supervisor_pid=${SUP_PID:-unset} state_dir=$STATE_DIR"

sup_alive() {
  if [ -n "$SUP_PID" ] && kill -0 "$SUP_PID" 2>/dev/null; then return 0; fi
  pgrep -f "$ORCH_DIR/supervisor.sh run" >/dev/null 2>&1
}

pid_is_supervisor() { # PID-reuse protection: never signal an unverified PID
  [ -n "$SUP_PID" ] || return 1
  kill -0 "$SUP_PID" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$SUP_PID/cmdline" 2>/dev/null | grep -q "supervisor.sh"
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
log "stop-flag set — waiting up to 60 s for the clean exit (one cycle at the 20 s interval)"
for _ in $(seq 1 60); do sup_alive || break; sleep 1; done

method="stop-flag"
if sup_alive; then
  if pid_is_supervisor; then
    kill -TERM "$SUP_PID" 2>/dev/null && log "TERM sent to $SUP_PID (cmdline verified)"
    for _ in $(seq 1 30); do sup_alive || break; sleep 1; done
    method="stop-flag+TERM"
    if sup_alive && pid_is_supervisor; then
      kill -KILL "$SUP_PID" 2>/dev/null && log "KILL sent to $SUP_PID (cmdline verified)"
      method="stop-flag+TERM+KILL"
    fi
  else
    log "FUSE AMBIGUOUS: the supervisor still runs but the recorded PID does not verify (reuse?) — NO signal sent; the stop-flag stands; human decision required"
    method="stop-flag-only-pid-unverified"
  fi
fi

if sup_alive; then
  log "exit NOT verified (method=$method) — the stop-flag remains in place; human decision required"
  verified=false
else
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

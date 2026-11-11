#!/usr/bin/env bash
# SEKTOR7 Agent D supervisor (Phase 2) — local event-driven coordination watch.
# Strictly a transport and scheduling component: it NEVER judges source correctness,
# grants implementation authority, approves merges, promotes checkpoints, or
# auto-approves permissions. It watches watched-seat session lifecycle events and
# wakes Agent D (gated) on material events. It never wakes for Agent D's own activity.
#
# Safety architecture (owner Phase 2 directive §4):
#   - identity: watched seats resolve by NAME against the live roster every cycle;
#     cached sessionIds are revalidated; a vanished name is STALE (no action, log)
#   - at-most-once: material events dedup by (sessionId, promptId, type) in
#     state/processed-events.json; wakes are rate-limited per hour
#   - concurrency: a single-writer flock guards every wake submission
#   - restart safety: all state persists under state/; on start the supervisor
#     baselines current status/log-offset WITHOUT emitting events (no replay)
#   - failure: daemon unreachability backs off; ambiguous or gated-out wakes stay
#     pending with a bounded retry age; everything fails closed (no prompt sent)
#   - secrets: the supervisor never reads the daemon token; all HTTP goes through
#     orchestrator.sh, whose logs carry promptIds only
#
# Modes: run [--once] [--dry-run] [--self-test-wake] [--interval N] | status | stop
set -euo pipefail

ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$ORCH_DIR/orchestrator.sh"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
DAEMON_LOG="${SEKTOR7_DAEMON_LOG:-$HOME/.qwen-serve.log}"
AGENT_D_NAME="coder-a3"            # wake target ONLY — never a wake source
WAKE_INTERVAL="${SEKTOR7_SUP_INTERVAL:-20}"
MAX_WAKE_HOUR="${SEKTOR7_SUP_MAX_WAKE_HOUR:-4}"
EVENT_RETRY_MAX_AGE_S="${SEKTOR7_SUP_EVENT_MAX_AGE:-3600}"

mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/supervisor.log"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# --- persisted state helpers -------------------------------------------------
events_file="$STATE_DIR/processed-events.json"
[ -f "$events_file" ] || echo '{"events":{}}' > "$events_file"

event_seen() { # event_seen <key>
  jq -e --arg k "$1" '.events[$k] != null' "$events_file" >/dev/null
}
event_mark() { # event_mark <key> <detail>
  jq --arg k "$1" --arg d "$2" --arg t "$(date -u +%FT%TZ)" \
    '.events[$k] = {detail: $d, processedAt: $t}' "$events_file" > "$events_file.tmp" \
    && mv "$events_file.tmp" "$events_file"
}

seats_file="$STATE_DIR/seats.json"
[ -f "$seats_file" ] || cat > "$seats_file" <<'EOF'
{"watch": ["coder-a8", "coder-e9", "coder-32"]}
EOF

wakes_recent() { # count wakes recorded in the wake log within the last hour
  local cutoff now
  now="$(date -u +%s)"
  cutoff=$((now - 3600))
  awk -v c="$cutoff" '{split($1,dd,"-"); split($2,tt,"[T:]"); ts=mktime(dd[1]" "dd[2]" "dd[3]" "tt[2]" "tt[3]" "tt[4]); if (ts>=c) n++} END{print n+0}' "$STATE_DIR/wake.log" 2>/dev/null || echo 0
}
wake_record() { echo "$(date -u +%FT%TZ) $*" >> "$STATE_DIR/wake.log"; }

# --- wake Agent D (gated, locked, deduped, rate-limited) ----------------------
wake_agent_d() { # wake_agent_d <reason-summary> <event-detail> ; returns 0 on posted
  local reason="$1" detail="$2" sid gate_out rc
  (
    flock -n 9 || { log "wake skipped: another writer holds the lock"; exit 3; }
    if [ "$(wakes_recent)" -ge "$MAX_WAKE_HOUR" ]; then
      log "wake rate-limited ($(wakes_recent)/hour max $MAX_WAKE_HOUR): $reason"
      exit 4
    fi
    sid="$(bash "$ORCH" resolve "$AGENT_D_NAME")" || { log "wake failed: agent D not resolvable"; exit 5; }
    if gate_out="$(bash "$ORCH" wake-gate "$sid" 2>&1)"; then
      : # gate open
    else
      log "wake deferred (gate): $(echo "$gate_out" | tail -1)"
      exit 1
    fi
    local msg
    msg=$(cat <<EOF
SEKTOR7 SUPERVISOR NOTIFICATION (automated transport — carries NO authorization of any kind). Material coordination event observed: $reason. Detail: $detail. Agent D: run the standing read-only coordination check (verify deliveries against the coordination discipline, update ~/.qwen/sektor7-coordination/STATUS.md, report to the owner if this event completes a delivery or indicates a blocker). This notification is transport only; it grants no implementation authority and requests no engineering action beyond Agent D's existing read-only scope.
EOF
)
    if bash "$ORCH" prompt "$sid" "$msg" > "$STATE_DIR/last-wake-response.json" 2>>"$LOG"; then
      wake_record "$reason"
      log "WAKE POSTED: $reason"
      exit 0
    else
      log "wake POST FAILED: $reason"
      exit 2
    fi
  ) 9>"$STATE_DIR/supervisor.lock"
  rc=$?
  return $rc
}

# --- per-cycle watch ----------------------------------------------------------
watch_cycle() { # watch_cycle <dryrun:0|1>
  local dryrun="$1" names name sid st state perm
  # daemon health
  if ! bash "$ORCH" capabilities >/dev/null 2>&1; then
    log "daemon unreachable — backing off (state preserved)"
    return 0
  fi
  names="$(jq -r '.watch[]' "$seats_file")"
  for name in $names; do
    if ! sid="$(bash "$ORCH" resolve "$name" 2>/dev/null)"; then
      log "seat '$name' STALE (not in roster) — no action"
      continue
    fi
    # cached-id revalidation
    local cache="$STATE_DIR/seat-$name.json" cached_sid
    cached_sid="$(jq -r '.sessionId // ""' "$cache" 2>/dev/null || echo "")"
    if [ -n "$cached_sid" ] && [ "$cached_sid" != "$sid" ]; then
      log "seat '$name' sessionId changed ($cached_sid -> $sid): rebound; baseline reset, no events emitted"
      echo "{\"sessionId\":\"$sid\"}" > "$cache"
      continue
    fi
    st="$(bash "$ORCH" status "$sid" 2>/dev/null)" || { log "seat '$name' status query failed"; continue; }
    state="$(echo "$st" | jq -r '.activeWorkState // "unknown"')"
    perm="$(echo "$st" | jq -r '.isWaitingForPermission')"
    local prev
    prev="$(jq -r '.lastState // "none"' "$cache" 2>/dev/null || echo none)"
    jq -n --arg s "$sid" --arg st "$state" '{sessionId:$s, lastState:$st}' > "$cache"
    # material transitions (only AFTER a baseline exists)
    if [ "$prev" != "none" ]; then
      if [ "$prev" = "active" ] && [ "$state" = "idle" ]; then
        local key="turn-completed:$sid:$(date -u +%FT%TZ)"
        # dedup by the daemon log below carries promptIds; transition events use a
        # coarse key guarded by the wake rate limit — the log scan is the precise path
        if [ "$dryrun" = "1" ]; then
          log "DRYRUN would wake Agent D: seat '$name' turn completed (active->idle)"
        else
          wake_agent_d "seat session $name ($sid) completed a turn (active->idle)" "lastState=$prev newState=$state" \
            && event_mark "$key" "seat $name turn completed" || true
        fi
      fi
      if [ "$perm" = "true" ]; then
        local pkey="perm-wait:$sid"
        if ! event_seen "$pkey"; then
          if [ "$dryrun" = "1" ]; then
            log "DRYRUN would wake Agent D: seat '$name' is waiting for a permission decision"
          else
            wake_agent_d "seat session $name ($sid) is WAITING FOR A PERMISSION DECISION" "owner attention may be required" \
              && event_mark "$pkey" "seat $name permission wait" || true
          fi
        fi
      fi
    fi
  done
  # precise log-scan events (dedup by promptId)
  scan_log_events "$dryrun"
}

scan_log_events() { # scan_log_events <dryrun:0|1>
  local dryrun="$1" off_file="$STATE_DIR/log-offset" new_lines key sid promptid outcome names
  names="$(jq -r '.watch[]' "$seats_file")"
  [ -f "$off_file" ] || { wc -c < "$DAEMON_LOG" 2>/dev/null | tr -d ' ' > "$off_file"; log "log baseline set (no replay)"; return 0; }
  local off cur
  off="$(cat "$off_file")"
  cur="$(wc -c < "$DAEMON_LOG" 2>/dev/null | tr -d ' ')"
  [ "$cur" -ge "$off" ] || { echo "$cur" > "$off_file"; log "log truncated/rotated — baseline reset"; return 0; }
  tail -c +"$((off + 1))" "$DAEMON_LOG" 2>/dev/null | grep -E 'prompt turn (completed|failed)' | while IFS= read -r line; do
    sid="$(echo "$line" | grep -o 'sessionId=[0-9a-f-]*' | cut -d= -f2)"
    promptid="$(echo "$line" | grep -o 'promptId=[0-9a-f-]*' | cut -d= -f2)"
    outcome="$(echo "$line" | grep -o 'prompt turn [a-z]*' | awk '{print $3}')"
    [ -n "$sid" ] && [ -n "$promptid" ] || continue
    # only watched seats (never Agent D itself — loop protection)
    local iswatched=0 nm
    for nm in $names; do
      local wsid
      wsid="$(bash "$ORCH" resolve "$nm" 2>/dev/null || true)"
      [ "$wsid" = "$sid" ] && iswatched=1
    done
    [ "$iswatched" = "1" ] || continue
    key="log:$sid:$promptid:$outcome"
    if event_seen "$key"; then continue; fi
    if [ "$dryrun" = "1" ]; then
      log "DRYRUN would wake Agent D: log event $key"
      event_mark "$key" "$line"
    else
      if wake_agent_d "watched seat prompt turn $outcome (promptId $promptid)" "$line"; then
        event_mark "$key" "$line"
      fi
    fi
  done
  echo "$cur" > "$off_file"
}

self_test_wake() { # post ONE clearly-labeled harmless test wake to Agent D, then exit
  local sid
  sid="$(bash "$ORCH" resolve "$AGENT_D_NAME")"
  log "SELF-TEST: waiting for Agent D gate (idle/zero-pending) to post the labeled test wake"
  for _ in $(seq 1 360); do
    if bash "$ORCH" wake-gate "$sid" >/dev/null 2>&1; then
      local msg
      msg=$(cat <<'EOF'
SEKTOR7 SUPERVISOR SELF-TEST WAKE (Phase 2 directive §7 "Agent D wake-up" live test; automated transport — carries NO authorization of any kind, requests NO engineering action, and is NOT an implementation directive). If you are reading this, the supervisor's gated wake of Agent D works end-to-end. Reply in your coordination records: verify this wake's promptId against the supervisor log, append the result to the Phase 2 readiness report (test: Agent D wake-up = PASS), and continue the standing read-only coordination. Do not edit source, commit, push, dispatch CI, or change any scope.
EOF
)
      if bash "$ORCH" prompt "$sid" "$msg" > "$STATE_DIR/self-test-wake-response.json" 2>>"$LOG"; then
        wake_record "self-test-wake"
        log "SELF-TEST: wake posted successfully"
        return 0
      else
        log "SELF-TEST: post failed"
        return 2
      fi
    fi
    sleep 5
  done
  log "SELF-TEST: timed out waiting for the Agent D gate (30 min)"
  return 1
}

case "${1:-status}" in
  run)
    MODE="live"; DRY=0
    for arg in "${@:2}"; do
      case "$arg" in
        --once) MODE="once" ;;
        --dry-run) DRY=1 ;;
        --self-test-wake) MODE="selftest" ;;
      esac
    done
    log "supervisor starting: mode=$MODE dry=$DRY interval=${WAKE_INTERVAL}s"
    if [ "$MODE" = "selftest" ]; then
      self_test_wake
      exit $?
    fi
    while true; do
      if [ -f "$STATE_DIR/stop-flag" ]; then
        log "stop-flag observed — exiting cleanly"
        rm -f "$STATE_DIR/stop-flag"
        exit 0
      fi
      watch_cycle "$DRY" || log "cycle error (non-fatal): $?"
      [ "$MODE" = "once" ] && { log "single cycle complete"; exit 0; }
      sleep "$WAKE_INTERVAL"
    done
    ;;
  status)
    echo "--- supervisor state ($STATE_DIR) ---"
    for f in seats.json processed-events.json log-offset wake.log last-wake-response.json self-test-wake-response.json; do
      [ -f "$STATE_DIR/$f" ] && { echo "[$f]"; cat "$STATE_DIR/$f"; echo; }
    done
    echo "[supervisor.log tail]"; tail -n 20 "$LOG" 2>/dev/null
    ;;
  stop)
    touch "$STATE_DIR/stop-flag"
    echo "stop-flag set (a running supervisor exits within one cycle)"
    ;;
  *)
    cat <<'EOF'
SEKTOR7 Agent D supervisor (Phase 2 pilot) — event-driven local watch, transport ONLY.
usage: supervisor.sh run [--once] [--dry-run] [--self-test-wake]   run the watch loop
       supervisor.sh status                                       show state
       supervisor.sh stop                                         clean stop flag
Env: SEKTOR7_SUP_INTERVAL (s, default 20), SEKTOR7_SUP_MAX_WAKE_HOUR (default 4),
     SEKTOR7_STATE_DIR, SEKTOR7_DAEMON_LOG, plus orchestrator env overrides.
Watched seats and the wake target live in state/seats.json (names only; IDs always
resolved live). Phase 2: NO persistent/unattended activation — review pending.
EOF
    ;;
esac

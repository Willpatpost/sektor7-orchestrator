#!/usr/bin/env bash
# SEKTOR7 Agent D supervisor v4 (Phase 2 round-3 safety corrective, V5-F2/F3/F4).
# Strictly a transport and scheduling component: it NEVER judges source correctness,
# grants implementation authority, approves merges, promotes checkpoints, or
# auto-approves permissions.
#
# Round-3 corrective guarantees:
#   V5-F2  three outcomes preserved end-to-end with NO duplicate preflight gate:
#          the single authoritative gate+POST runs inside the orchestrator's
#          submission lock; a definite pre-POST refusal (exit 1) defers safely
#          (the event stays pending, no budget consumed); an attempted POST with
#          an unknown result (exit 2) becomes ambiguous (never blind-retried);
#          a verified UUID marks delivered atomically.
#   V5-F3  permission-wait EPISODES: distinct episodes are keyed by a persisted
#          per-session episode counter incremented on each false->true transition
#          (confirmed clearance resets the wait state); a continuous unchanged
#          wait never re-alerts; a new wait after clearance creates a new event
#          and notification; earlier delivered events remain as history; the
#          episode state persists across supervisor restarts.
#   V5-F4  byte-exact log scanning: the partial-line arithmetic uses byte counts
#          (wc -c), never bash character lengths — multibyte UTF-8 content cannot
#          corrupt the cursor; incomplete lines are withheld without advancing
#          past ANY of their bytes; the trailing-newline handling is the round-1
#          last-byte-probe form.
#   (Round-1/2 guarantees preserved: persist-before-advance; explicit states;
#    submitting/ambiguous crash-window protection; single instance; UTC rate
#    counting; bounded structured metadata only; R1 verified acknowledgments.)
#
# Modes: run [--once] [--dry-run] [--self-test-wake] | status | stop
set -euo pipefail
umask 077

ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$ORCH_DIR/orchestrator.sh"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
DAEMON_LOG="${SEKTOR7_DAEMON_LOG:-$HOME/.qwen-serve.log}"
AGENT_D_NAME="coder-a3"            # wake target ONLY — never a wake source
WAKE_INTERVAL="${SEKTOR7_SUP_INTERVAL:-20}"
MAX_WAKE_HOUR="${SEKTOR7_SUP_MAX_WAKE_HOUR:-4}"
EVENT_MAX_AGE_S="${SEKTOR7_SUP_EVENT_MAX_AGE:-7200}"

mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/supervisor.log"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# fault-tolerant startup init (an unwritable store must not kill the supervisor —
# the store operations themselves fail loudly and hold the cursor per E1)
EVENTS="$STATE_DIR/events.json"
[ -f "$EVENTS" ] || { printf '{"events":{}}' > "$EVENTS" 2>/dev/null || log "event store unwritable at startup (fault-tolerant; store operations will fail loudly): $EVENTS"; }
PERMSTATE="$STATE_DIR/perm-state.json"
[ -f "$PERMSTATE" ] || { printf '{"sessions":{}}' > "$PERMSTATE" 2>/dev/null || log "perm-state unwritable at startup (fault-tolerant): $PERMSTATE"; }

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# --- event state machine (E1: write failures propagate explicitly) ----------------
event_get() { jq -r --arg k "$1" '.events[$k] // empty' "$EVENTS"; }
event_exists() { jq -e --arg k "$1" '.events[$k] != null' "$EVENTS" >/dev/null; }
event_set() { # event_set KEY FIELDS_JSON -> 0 ok; 1 = write/serialization/rename failure
  local tmp="$EVENTS.tmp.$$.$RANDOM"
  if ! jq --arg k "$1" --argjson f "$2" '.events[$k] = $f' "$EVENTS" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: event-store serialization failed (invalid store JSON or bad fields)" >&2
    return 1
  fi
  if ! mv "$tmp" "$EVENTS" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: event-store atomic rename failed" >&2
    return 1
  fi
}
event_patch() { # event_patch KEY FILTER [extra jq options before the filter]
  local tmp="$EVENTS.tmp.$$.$RANDOM"
  if ! jq --arg k "$1" "${@:3}" "$2" "$EVENTS" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: event-store serialization failed (patch)" >&2
    return 1
  fi
  if ! mv "$tmp" "$EVENTS" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: event-store atomic rename failed (patch)" >&2
    return 1
  fi
}

# --- wake-rate limiting (UTC-correct) ----------------------------------------------
wakes_recent() {
  local cutoff line ts epoch n=0
  cutoff=$(( $(date -u +%s) - 3600 ))
  while IFS= read -r line; do
    ts="${line%% *}"
    epoch="$(date -u -d "$ts" +%s 2>/dev/null || echo 0)"
    [ "$epoch" -ge "$cutoff" ] && n=$((n + 1))
  done < "$STATE_DIR/wake.log" 2>/dev/null
  echo "$n"
}
wake_record() { echo "$(date -u +%FT%TZ) $*" >> "$STATE_DIR/wake.log"; }

# --- wake Agent D (V5-F2: no preflight gate; the notify outcome is authoritative) --
# exit 0 = delivered with a VERIFIED UUID (stdout); 1 = definite refusal (no POST —
# defer, no budget); 2 = ambiguous (POST attempted, unverified — never retried);
# 4 = rate-limited (no POST); 5 = agent D unresolvable.
wake_agent_d() { # wake_agent_d <metadata-json>
  local meta="$1" sid out wakepid nrc
  (
    flock -n 9 || { log "wake skipped: another writer holds the wake lock"; exit 3; }
    if [ "$(wakes_recent)" -ge "$MAX_WAKE_HOUR" ]; then
      log "wake rate-limited ($(wakes_recent)/hour max $MAX_WAKE_HOUR)"
      exit 4
    fi
    sid="$(bash "$ORCH" resolve "$AGENT_D_NAME")" || { log "wake failed: agent D not resolvable"; exit 5; }
    # V5-F2: NO duplicate preflight gate — the single authoritative gate and the
    # POST run together inside the notify command's submission lock.
    if out="$(bash "$ORCH" notify "$sid" "$meta" 2>>"$LOG")"; then
      wakepid="$(printf '%s\n' "$out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)"
      if [ -z "$wakepid" ]; then
        # R1: never count an unverified acknowledgment as delivery
        log "wake AMBIGUOUS: the orchestrator reported success without a valid promptId — reconcile against the daemon log"
        exit 2
      fi
      wake_record "wake"
      log "WAKE POSTED: $(echo "$meta" | jq -c '{kind, seat, promptId, outcome}') wake=$wakepid"
      printf '%s\n' "$wakepid"
      exit 0
    else
      nrc=$?
      if [ "$nrc" = "1" ]; then
        # V5-F2: a DEFINITE pre-POST refusal — safe deferral, the event stays pending
        log "wake DEFERRED (definite gate refusal, no POST attempted)"
        exit 1
      fi
      # exit 2 (or anything else after a submission attempt): ambiguous
      log "wake AMBIGUOUS (submission attempted, result unverified — no auto-retry; reconcile against the daemon log)"
      exit 2
    fi
  ) 9>"$STATE_DIR/supervisor.lock"
}

# --- log scanning (C1: generation continuity; E1: hold on persistence failure;
#     V5-F4: byte-exact; persist-before-advance) ------------------------------------
CONT="$STATE_DIR/log-continuity.json"
continuity_read() { jq -r "$1" "$CONT" 2>/dev/null || echo ""; }
prefix_digest_at() { # prefix_digest_at CURSOR -> the sha256 of the ENTIRE prefix [0, CURSOR)
  # The full prefix (not a trailing window) is hashed: an equal-size replacement
  # whose differences lie EARLIER in the file must still be detected — only a
  # whole-prefix digest catches every rewrite. sha256 over an appended-to log's
  # prefix is O(log size) per cycle and cheap in practice.
  local cursor="$1"
  if [ "$cursor" -le 0 ]; then echo "(empty)"; return; fi
  head -c "$cursor" "$DAEMON_LOG" 2>/dev/null | sha256sum | awk '{print $1}'
}
persist_log_gap() { # persist_log_gap PRIOR_CURSOR PRIOR_SIZE OLD_INO NEW_INO — the structured, visible, never-auto-resolved gap record
  local key from to oi ni
  from="$1"; to="$2"; oi="$3"; ni="$4"
  key="log-gap:$oi:$ni:$(date -u +%FT%TZ)"
  if event_exists "$key"; then return 0; fi
  if ! event_set "$key" "$(jq -n --arg from "$from" --arg to "$to" --arg oi "$oi" --arg ni "$ni" --arg ts "$(date -u +%FT%TZ)" \
    '{kind: "log-gap", seat: "D", sessionId: "coordinator", promptId: "00000000-0000-0000-0000-000000000000", outcome: "log-generation-change", observedAt: $ts, state: "unresolved", unobservedFrom: $from, unobservedTo: $to, oldInode: $oi, newInode: $ni, note: "a log generation change was detected; the interval [unobservedFrom, unobservedTo) of the previous generation was never observed. RECONCILIATION: compare each watched session turn-index (promptIds + timestamps) against the recorded events — a completion promptId present in a turn-index but absent from the event store within this window was unobserved; corroborate with GitHub branch/CI state. Never treat this interval as observed."}')"; then
    log "LOG-GAP PERSISTENCE FAILED: $key (the scan will hold)"
    return 1
  fi
  log "LOG-GAP RECORDED (unresolved, visible, never auto-resolved): $key unobserved=[$from,$to) oldInode=$oi newInode=$ni"
}

scan_log_events() { # scan_log_events <dryrun:0|1>
  local dryrun="$1" off_file="$STATE_DIR/log-offset" off cur region_len last_byte chunk last_part complete_region advance proc_rc
  local ino prior_cursor prior_size prior_digest cur_digest
  [ -f "$off_file" ] || {
    local base_size base_ino
    base_size="$(wc -c < "$DAEMON_LOG" 2>/dev/null | tr -d ' ')"
    base_ino="$(stat -c %i "$DAEMON_LOG" 2>/dev/null || echo 0)"
    echo "$base_size" > "$off_file"
    printf '{ "inode": "%s", "size": "%s", "cursor": "%s", "prefixDigest": "%s" }' \
      "$base_ino" "$base_size" "$base_size" "$(prefix_digest_at "$base_size")" > "$CONT"
    log "log baseline set (no replay; the initial continuity snapshot recorded)"
    return 0
  }
  off="$(cat "$off_file")"
  cur="$(wc -c < "$DAEMON_LOG" 2>/dev/null | tr -d ' ')"
  ino="$(stat -c %i "$DAEMON_LOG" 2>/dev/null || echo 0)"
  # C1: generation/continuity detection — the full-prefix digest at the
  # recorded cursor plus the inode. A digest mismatch means the content at the
  # cursor was rewritten (a NEW generation, whatever the size or inode): persist
  # the structured log-gap record for the never-observed interval of the previous
  # generation, then rescan the new generation from the start (event-ID dedup
  # applies). An inode change with a MATCHING digest is a content-continuous
  # copy-rotation — no gap, the cursor stands.
  if [ "$cur" -lt "$off" ]; then
    log "log shrank (rotation or truncation; old cursor $off > new size $cur) — a generation change (rescan from the start; event-ID dedup applies)"
    if [ -f "$CONT" ]; then
      persist_log_gap "$off" "$(continuity_read '.size // 0')" "$(continuity_read '.inode // 0')" "$ino" || return 1
    fi
    off=0
  elif [ -f "$CONT" ]; then
    prior_cursor="$(continuity_read '.cursor // -1')"
    prior_digest="$(continuity_read '.prefixDigest // ""')"
    if [ "$prior_cursor" = "$off" ] && [ -n "$prior_digest" ]; then
      cur_digest="$(prefix_digest_at "$off")"
      if [ "$cur_digest" != "$prior_digest" ]; then
        prior_size="$(continuity_read '.size // 0')"
        log "log generation CHANGE detected (prefix digest mismatch at cursor $off) — recording the log gap and rescanning from the start"
        persist_log_gap "$off" "$prior_size" "$(continuity_read '.inode // 0')" "$ino" || return 1
        off=0
      elif [ "$(continuity_read '.inode // 0')" != "$ino" ]; then
        log "log file replaced with identical content at the cursor (inode change, digest continuous) — no gap; the cursor stands"
      fi
    fi
  fi
  region_len=$((cur - off))
  if [ "$region_len" -le 0 ]; then return 0; fi
  last_byte="$(tail -c +"$cur" "$DAEMON_LOG" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  chunk="$(tail -c +"$((off + 1))" "$DAEMON_LOG" 2>/dev/null || true)"
  if [ "$last_byte" = "0a" ]; then
    complete_region="$chunk"
    advance="$cur"
  else
    last_part="${chunk##*$'\n'}"
    if [ "$last_part" = "$chunk" ]; then
      complete_region=""
      advance="$off"
    else
      complete_region="${chunk%"$last_part"}"
      # V5-F4: BYTE-exact arithmetic — bash ${#var} counts characters, which
      # differs from bytes under multibyte UTF-8; wc -c is authoritative.
      advance=$((cur - $(printf '%s' "$last_part" | wc -c)))
    fi
  fi
  proc_rc=0
  if [ -n "$complete_region" ]; then
    # C3: a region with NO matching completion lines is an ORDINARY successful scan
    # (the cursor advances); only a matched event's persistence failure holds it.
    # The filter is separated from the processing so grep's no-match exit cannot
    # masquerade as a failure under pipefail.
    matches="$(printf '%s\n' "$complete_region" | grep -E 'prompt turn (completed|failed)' || true)"
    if [ -n "$matches" ]; then
      printf '%s\n' "$matches" | while IFS= read -r line; do
        process_log_line "$line" "$dryrun"
      done || proc_rc=$?
    fi
  fi
  if [ "$proc_rc" != "0" ]; then
    # E1: a material event failed to persist — NEVER advance past it. The cursor
    # holds at $off and the region (including the failed event) is retried on the
    # next cycle once the underlying store failure is resolved.
    log "SCAN HELD: event persistence failed (rc=$proc_rc) — cursor UNCHANGED at $off; the region will be retried"
    return 1
  fi
  echo "$advance" > "$off_file"
  printf '{ "inode": "%s", "size": "%s", "cursor": "%s", "prefixDigest": "%s" }' \
    "$ino" "$cur" "$advance" "$(prefix_digest_at "$advance")" > "$CONT"
}

process_log_line() { # process_log_line LINE dryrun
  local line="$1" dryrun="$2" sid promptid outcome key nm names iswatched
  sid="$(printf '%s' "$line" | grep -o 'sessionId=[0-9a-f-]*' | cut -d= -f2 || true)"
  promptid="$(printf '%s' "$line" | grep -o 'promptId=[0-9a-f-]*' | cut -d= -f2 || true)"
  outcome="$(printf '%s' "$line" | grep -o 'prompt turn [a-z]*' | awk '{print $3}' || true)"
  [ -n "$sid" ] && [ -n "$promptid" ] || return 0
  names="$(jq -r '.watch[]' "$STATE_DIR/seats.json" 2>/dev/null)"
  iswatched=""
  for nm in $names; do
    local wsid
    wsid="$(bash "$ORCH" resolve "$nm" 2>/dev/null || true)"
    if [ "$wsid" = "$sid" ]; then iswatched="$nm"; break; fi
  done
  [ -n "$iswatched" ] || return 0
  key="log:$sid:$promptid:$outcome"
  if event_exists "$key"; then return 0; fi
  # E1: explicit persistence-failure propagation — no false "persisted" log, and the
  # caller (scan_log_events) holds the cursor so the event is retried safely.
  # C4: the event's seat is the CONFIGURED seatOf label for the source session
  # (falling back to the watch name when unconfigured) — the identity the notify
  # binding verifies.
  local seat_label
  seat_label="$(jq -r --arg n "$iswatched" '.seatOf[$n] // $n' "$STATE_DIR/seats.json" 2>/dev/null || echo "$iswatched")"
  if ! event_set "$key" "$(jq -n --arg seat "$seat_label" --arg sid "$sid" --arg pid "$promptid" --arg out "$outcome" --arg ts "$(date -u +%FT%TZ)" \
    '{kind: "worker-turn", seat: $seat, sessionId: $sid, promptId: $pid, outcome: $out, observedAt: $ts, state: "pending", attempts: 0, firstSeen: $ts}')"; then
    log "EVENT PERSISTENCE FAILED: $key (the cursor will hold; retried next cycle)"
    return 1
  fi
  log "EVENT PERSISTED (pending): $key"
}

# --- crash-window recovery + escalation --------------------------------------------
recover_and_escalate() {
  local key ev firstSeen ageS
  for key in $(jq -r '.events | to_entries[] | select(.value.state == "submitting") | .key' "$EVENTS" 2>/dev/null); do
    event_patch "$key" '.events[$k].state = "ambiguous" | .events[$k].ambiguousAt = (now | todate) | .events[$k].note = "crash window: submitting state found on restart — reconcile against the daemon log before any manual re-arm"'
    log "EVENT AMBIGUOUS (crash window — submitting found; NO auto-retry): $key"
  done
  for key in $(jq -r '.events | to_entries[] | select(.value.state == "ambiguous") | .key' "$EVENTS" 2>/dev/null); do
    ev="$(event_get "$key")"
    firstSeen="$(echo "$ev" | jq -r '.firstSeen // .ambiguousAt // ""')"
    if [ -n "$firstSeen" ]; then
      ageS=$(( $(date -u +%s) - $(date -u -d "$firstSeen" +%s 2>/dev/null || date -u +%s) ))
      if [ "$ageS" -ge "$EVENT_MAX_AGE_S" ]; then
        event_patch "$key" '.events[$k].state = "unresolved" | .events[$k].unresolvedAt = (now | todate)'
      fi
    fi
  done
  local n_unres n_amb
  n_unres="$(jq -r '[.events[] | select(.state == "unresolved")] | length' "$EVENTS" 2>/dev/null || echo 0)"
  n_amb="$(jq -r '[.events[] | select(.state == "ambiguous")] | length' "$EVENTS" 2>/dev/null || echo 0)"
  { [ "$n_unres" = "0" ] && [ "$n_amb" = "0" ]; } || log "ESCALATION: $n_unres unresolved, $n_amb ambiguous events require reconciliation (visible in status; never discarded)"
}

# --- deferred-event delivery (V5-F2 outcomes; R5 no-budget deferrals) ---------------
deliver_pending() { # deliver_pending <dryrun:0|1>
  local dryrun="$1" key ev meta pid rc
  for key in $(jq -r '.events | to_entries[] | select(.value.state == "pending") | .key' "$EVENTS" 2>/dev/null); do
    ev="$(event_get "$key")"
    [ "$(echo "$ev" | jq -r '.state')" = "pending" ] || continue
    if [ "$dryrun" = "1" ]; then
      log "DRYRUN would attempt delivery: $key"
      continue
    fi
    meta="$(echo "$ev" | jq -c '{kind, seat, sessionId, promptId, outcome}')"
    event_patch "$key" '.events[$k].state = "submitting" | .events[$k].submittingAt = (now | todate)'
    pid="$(wake_agent_d "$meta")" && rc=0 || rc=$?
    if [ "$rc" = "0" ] && [[ "$pid" =~ $UUID_RE ]]; then
      event_patch "$key" '.events[$k] = (.events[$k] + {state: "delivered", deliveredAt: (now | todate), wakePromptId: $w, attempts: (.events[$k].attempts + 1)})' --arg w "$pid"
      log "EVENT DELIVERED: $key wake=$pid"
    elif [ "$rc" = "1" ] || [ "$rc" = "4" ] || [ "$rc" = "5" ]; then
      event_patch "$key" '.events[$k].state = "pending" | .events[$k].lastDeferred = (now | todate)'
      log "EVENT DEFERRED (definite refusal or rate limit — no budget consumed; retry when D is idle): $key"
    else
      event_patch "$key" '.events[$k] = (.events[$k] + {state: "ambiguous", ambiguousAt: (now | todate), attempts: (.events[$k].attempts + 1)})'
      log "EVENT AMBIGUOUS (submission unverified — NO auto-retry; reconcile against the daemon log): $key"
    fi
  done
}

# --- permission-wait EPISODES (V5-F3 + C2: the event IS the durable record) ---------
perm_state_get() { jq -r --arg s "$1" '.sessions[$s].waiting // false' "$PERMSTATE" 2>/dev/null || echo false; }
perm_state_set() { # perm_state_set SID WAITING EPISODES
  local tmp="$PERMSTATE.tmp.$$.$RANDOM"
  if ! jq --arg s "$1" --argjson w "$2" --argjson n "$3" \
    '.sessions[$s] = {waiting: $w, episodes: $n}' "$PERMSTATE" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "ERROR: perm-state serialization failed" >&2; return 1
  fi
  if ! mv "$tmp" "$PERMSTATE" 2>/dev/null; then
    rm -f "$tmp"; echo "ERROR: perm-state atomic rename failed" >&2; return 1
  fi
}
perm_episode_next() { # perm_episode_next SID -> the next episode number, DERIVED FROM THE EVENT STORE
  jq -r --arg s "$1" '[.events[] | select((.kind == "permission-wait") and (.sessionId == $s))] | length + 1' "$EVENTS" 2>/dev/null || echo 1
}

check_permission_waits() { # check_permission_waits <dryrun:0|1>
  local dryrun="$1" names name sid st perm prior episodes key seat_label
  names="$(jq -r '.watch[]' "$STATE_DIR/seats.json" 2>/dev/null)"
  for name in $names; do
    sid="$(bash "$ORCH" resolve "$name" 2>/dev/null)" || continue
    st="$(bash "$ORCH" status "$sid" 2>/dev/null)" || continue
    perm="$(echo "$st" | jq -r '.isWaitingForPermission // false' 2>/dev/null || echo false)"
    prior="$(perm_state_get "$sid")"
    if [ "$perm" = "true" ] && [ "$prior" != "true" ]; then
      # C2: the EVENT is persisted FIRST (the durable record); the episode number is
      # DERIVED from the store, and the exists-check makes the transition idempotent
      # — if the perm-state write later fails, the next cycle recomputes the SAME
      # episode number and the exists-check prevents any duplicate. A permission
      # episode is never considered recorded until its event is durably persisted.
      episodes="$(perm_episode_next "$sid")"
      key="perm-wait:$sid:episode:$episodes"
      if event_exists "$key"; then
        : # the event already exists (a prior state-write failure) — no duplicate
      else
        seat_label="$(jq -r --arg n "$name" '.seatOf[$n] // $n' "$STATE_DIR/seats.json" 2>/dev/null || echo "$name")"
        if ! event_set "$key" "$(jq -n --arg seat "$seat_label" --arg sid "$sid" --arg pid "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 00000000-0000-0000-0000-000000000000)" --arg ts "$(date -u +%FT%TZ)" --argjson ep "$episodes" \
          '{kind: "permission-wait", seat: $seat, sessionId: $sid, promptId: $pid, outcome: "waiting", observedAt: $ts, state: "pending", attempts: 0, firstSeen: $ts, episode: $ep}')"; then
          log "PERM-EVENT PERSISTENCE FAILED: $key (the episode is NOT recorded; the state is not advanced — retried next cycle)"
          return 1
        fi
        log "EVENT PERSISTED (pending, episode $episodes): $key"
      fi
      # only NOW is the episode considered recorded (the state write is a cache;
      # its failure is self-healing via the store-derived episode number)
      perm_state_set "$sid" true "$episodes" || log "perm-state write failed (self-healing: the store-derived episode number prevents duplicates)"
    elif [ "$perm" = "true" ] && [ "$prior" = "true" ]; then
      : # a continuous, unchanged wait — no repeated alert (V5-F3)
    else
      # perm == false: confirmed clearance — reset the wait state (keep the counter)
      episodes="$(perm_episode_next "$sid")"
      episodes=$((episodes - 1))
      perm_state_set "$sid" false "$episodes" 2>/dev/null || true
    fi
  done
}

self_test_wake() { # post ONE fixed labeled harmless test wake to Agent D, then exit
  local sid out wakepid
  sid="$(bash "$ORCH" resolve "$AGENT_D_NAME")"
  log "SELF-TEST: waiting for Agent D gate (idle/zero-pending) to post the labeled test wake"
  for _ in $(seq 1 360); do
    if bash "$ORCH" wake-gate "$sid" >/dev/null 2>&1; then
      if out="$(bash "$ORCH" self-test-wake "$sid" 2>>"$LOG")"; then
        wakepid="$(printf '%s\n' "$out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)"
        if [ -z "$wakepid" ]; then
          log "SELF-TEST: AMBIGUOUS acknowledgment (no valid promptId) — not a pass"
          return 2
        fi
        wake_record "self-test-wake"
        log "SELF-TEST: wake posted successfully wake=$wakepid"
        return 0
      else
        log "SELF-TEST: post failed or refused"
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
    exec 8>"$STATE_DIR/supervisor-run.lock"
    if ! flock -n 8; then
      log "refusing to start: another supervisor instance holds the run lock"
      echo "ERROR: another supervisor instance is running (run lock held)" >&2
      exit 1
    fi
    log "supervisor starting: mode=$MODE dry=$DRY interval=${WAKE_INTERVAL}s"
    # C4: startup configuration validation — the coordinator binding must exist and
    # resolve; a misconfigured seats.json refuses to run (fail closed).
    coord_cfg="$(jq -r '.coordinator // ""' "$STATE_DIR/seats.json" 2>/dev/null || true)"
    if [ -z "$coord_cfg" ]; then
      log "refusing to run: no coordinator session configured (state/seats.json .coordinator) — the E3 destination binding is impossible"
      echo "ERROR: no coordinator session configured (state/seats.json .coordinator) — refusing to run" >&2
      exit 1
    fi
    if ! bash "$ORCH" resolve "$coord_cfg" >/dev/null 2>&1; then
      log "refusing to run: the configured coordinator session '$coord_cfg' does not resolve in the live roster"
      echo "ERROR: the configured coordinator session '$coord_cfg' does not resolve — refusing to run" >&2
      exit 1
    fi
    log "seats configuration validated (coordinator=$coord_cfg)"
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
      if bash "$ORCH" capabilities >/dev/null 2>&1; then
        recover_and_escalate || log "recovery error (non-fatal): $?"
        scan_log_events "$DRY" || log "EVENT-STORE/SCAN FAILURE (the cursor HOLDS; the region retries): $?"
        check_permission_waits "$DRY" || log "permission-watch error (non-fatal): $?"
        deliver_pending "$DRY" || log "delivery error (non-fatal): $?"
      else
        log "daemon unreachable — backing off (state preserved)"
      fi
      [ "$MODE" = "once" ] && { log "single cycle complete"; exit 0; }
      sleep "$WAKE_INTERVAL"
    done
    ;;
  status)
    echo "--- supervisor state ($STATE_DIR) ---"
    echo "[events]"; jq . "$EVENTS"
    echo "[perm-state]"; jq . "$PERMSTATE"
    for f in seats.json log-offset wake.log supervisor.log; do
      [ -f "$STATE_DIR/$f" ] && { echo "[$f]"; tail -n 10 "$STATE_DIR/$f" 2>/dev/null; echo; }
    done
    ;;
  stop)
    touch "$STATE_DIR/stop-flag"
    echo "stop-flag set (a running supervisor exits within one cycle)"
    ;;
  *)
    cat <<'EOF'
SEKTOR7 Agent D supervisor v4 (Phase 2 round-3 corrective) — event-driven local watch.
usage: supervisor.sh run [--once] [--dry-run] [--self-test-wake] | status | stop
V5-F2: no duplicate preflight gate; definite refusal (rc 1) defers without budget;
       attempted-POST ambiguity (rc 2) never blind-retries; verified UUID delivers.
V5-F3: permission-wait episodes keyed by a persisted per-session counter — a new
       wait after confirmed clearance creates a new event; a continuous wait
       never re-alerts; state persists across restarts.
V5-F4: byte-exact log scanning (wc -c arithmetic) — multibyte UTF-8 partial lines
       cannot corrupt the cursor; incomplete lines withhold all their bytes.
Env: SEKTOR7_SUP_INTERVAL (20s), SEKTOR7_SUP_MAX_WAKE_HOUR (4),
     SEKTOR7_SUP_EVENT_MAX_AGE (7200s), SEKTOR7_STATE_DIR, SEKTOR7_DAEMON_LOG.
Phase 2: NO persistent/unattended activation — review pending.
EOF
    ;;
esac

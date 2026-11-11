#!/usr/bin/env bash
# SEKTOR7 Agent D orchestrator v5 (Phase 2 round-3 safety corrective, V5-F1/V5-F2).
# Transport ONLY — never an engineering authority. Fails closed on any uncertainty.
#
# Round-3 corrective guarantees:
#   V5-F1  NO free-text operational prompts exist. The raw `prompt` command is
#          REMOVED. Operational notifications go through `notify`, which accepts
#          ONLY a strictly-validated structured metadata object (exact key set:
#          kind/seat/sessionId/promptId/outcome; enumerated values; UUID formats)
#          and CONSTRUCTS the fixed notification text internally from that
#          metadata — no caller-supplied text ever reaches the wire, so
#          prefix-plus-injected-instructions is structurally impossible. The
#          self-test wake is a separate fixed-text command. Owner-authorized
#          directives go only through `relay` (unchanged).
#   V5-F2  the three submission outcomes are preserved end-to-end: exit 0 =
#          verified success (a valid UUID on stdout); exit 1 = DEFINITE refusal
#          BEFORE any POST (gate refusal — safe to retry); exit 2 = AMBIGUOUS
#          (a POST was attempted with an unverified result — never blindly
#          retried). The single authoritative gate AND the POST run together
#          under the submission lock; there is no duplicate preflight gate.
#   (Round-1/2 guarantees preserved: F1 relay lock + intent; R2 strict schemas;
#    R3 gate+POST under one lock; R4 complete approval binding.)
#
# Env overrides for testing: SEKTOR7_DAEMON_URL, SEKTOR7_TOKEN_FILE, SEKTOR7_SESSIONS_JSON,
# SEKTOR7_STATE_DIR, SEKTOR7_QWEN_BIN, SEKTOR7_COORD_DIR.
set -euo pipefail
umask 077   # state files are 0600

ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="${SEKTOR7_DAEMON_URL:-http://127.0.0.1:4170}"
TOKEN_FILE="${SEKTOR7_TOKEN_FILE:-$HOME/.qwen-serve-token}"
SESSIONS_JSON="${SEKTOR7_SESSIONS_JSON:-}"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
COORD_DIR="${SEKTOR7_COORD_DIR:-$(cd "$ORCH_DIR/.." && pwd)}"
QWEN_BIN="${SEKTOR7_QWEN_BIN:-/home/coder/.nvm/versions/node/v24.21.0/bin/qwen}"
export PATH="/home/coder/.nvm/versions/node/v24.21.0/bin:/home/coder/.local/bin${PATH:+:$PATH}"
mkdir -p "$STATE_DIR"   # lock files and state must have their directory

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

die() { echo "ERROR: $*" >&2; exit 1; }

# --- HTTP layer (strict validation; token read per call, never logged) ----------
api() { # api METHOD PATH [JSON_BODY] -> sets REPLY (body) and HTTP_CODE
  local method="$1" path="$2" body="${3:-}" tok raw
  tok="$(cat "$TOKEN_FILE")"
  if [ -n "$body" ]; then
    raw="$(curl -s --max-time 15 -X "$method" \
      -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      -d "$body" -w $'\n%{http_code}' "$DAEMON$path" 2>/dev/null)" || raw=""
  else
    raw="$(curl -s --max-time 15 -X "$method" -H "Authorization: Bearer $tok" \
      -w $'\n%{http_code}' "$DAEMON$path" 2>/dev/null)" || raw=""
  fi
  HTTP_CODE="${raw##*$'\n'}"
  REPLY="${raw%$'\n'*}"
  [ -n "$REPLY" ] || REPLY=""
}

resolve() { # live roster (or mock) — IDs are never guessed
  local name="$1" sid
  if [ -n "$SESSIONS_JSON" ]; then
    sid="$(awk -F'|' -v n="$name" '$1==n{print $2}' "$SESSIONS_JSON" | head -1)"
  else
    sid="$("$QWEN_BIN" sessions ps --json 2>/dev/null | jq -r --arg n "$name" 'select(.name == $n) | .sessionId' | head -1)"
  fi
  [ -n "$sid" ] || die "session '$name' not found in the roster (stale or absent — re-resolve; never guess)"
  echo "$sid"
}

target() {
  local t="$1"
  if [[ "$t" =~ $UUID_RE ]]; then echo "$t"; else resolve "$t"; fi
}

name_of() {
  local sid="$1" name=""
  if [ -n "$SESSIONS_JSON" ]; then
    name="$(awk -F'|' -v s="$sid" '$2==s{print $1}' "$SESSIONS_JSON" | head -1)"
  else
    name="$("$QWEN_BIN" sessions ps --json 2>/dev/null | jq -r --arg s "$sid" 'select(.sessionId == $s) | .name' | head -1)"
  fi
  echo "$name"
}

seat_of() {
  local sid name seat
  sid="$(target "$1")"
  name="$(name_of "$sid")"
  [ -n "$name" ] || die "cannot resolve roster name for $sid (seat binding impossible — refuse)"
  seat="$(jq -r --arg n "$name" '.seatOf[$n] // ""' "$STATE_DIR/seats.json" 2>/dev/null || true)"
  [ -n "$seat" ] || die "no seat label recorded for session '$name' (state/seats.json seatOf) — authorization binding impossible, refuse"
  echo "$seat"
}

# --- strict wake gate (complete, typed, session-matched schemas) ----------------
gate_state() { # gate_state SID  (must be called while holding the submit lock)
  local sid="$1" st state pending
  api GET "/session/$sid/status"
  [ "$HTTP_CODE" = "200" ] || die "gate:refusal status query failed (HTTP $HTTP_CODE)"
  echo "$REPLY" | jq -e 'type == "object"' >/dev/null 2>&1 || die "gate:refusal status response is not a JSON object"
  st="$REPLY"
  echo "$st" | jq -e --arg s "$sid" '
      (.sessionId == $s)
      and ((.activeWorkState == "idle") or (.activeWorkState == "active"))
      and ((.isWaitingForPermission | type) == "boolean")
      and ((.isWaitingForUserQuestion | type) == "boolean")
      and ((.hasActivePrompt | type) == "boolean")
    ' >/dev/null 2>&1 || die "gate:refusal inconsistent session status (sessionId/activeWorkState/boolean fields) — fail closed"
  state="$(echo "$st" | jq -r '.activeWorkState')"
  api GET "/session/$sid/pending-prompts"
  [ "$HTTP_CODE" = "200" ] || die "gate:refusal pending-prompts query failed (HTTP $HTTP_CODE)"
  echo "$REPLY" | jq -e 'type == "object" and ((.pendingPrompts | type) == "array")' >/dev/null 2>&1 \
    || die "gate:refusal malformed pending-prompts response — fail closed"
  pending="$(echo "$REPLY" | jq -r '.pendingPrompts | length')"
  echo "gate: state=$state pending=$pending permWait=$(echo "$st" | jq -r '.isWaitingForPermission') questionWait=$(echo "$st" | jq -r '.isWaitingForUserQuestion') activePrompt=$(echo "$st" | jq -r '.hasActivePrompt')" >&2
  [ "$state" = "idle" ] || die "gate:refusal session is '$state' (never interrupt a running turn)"
  [ "$(echo "$st" | jq -r '.hasActivePrompt')" = "false" ] || die "gate:refusal active prompt present"
  [ "$pending" = "0" ] || die "gate:refusal $pending pending prompt(s) (never overlap)"
  [ "$(echo "$st" | jq -r '.isWaitingForPermission')" = "false" ] || die "gate:refusal session is waiting for a permission decision"
  [ "$(echo "$st" | jq -r '.isWaitingForUserQuestion')" = "false" ] || die "gate:refusal session is waiting for a user question"
}

# --- prompt submission core (strict; NO lock — caller holds the submit lock) -----
# Returns 2 for EVERY POST-attempt failure: a POST was attempted, so the outcome
# is AMBIGUOUS — never classifiable as a definite refusal.
post_prompt_core() { # post_prompt_core SID TEXT -> prints the validated UUID promptId
  local sid="$1" text="$2" pid
  api POST "/session/$sid/prompt" "$(jq -n --arg t "$text" '{prompt: [{type: "text", text: $t}]}')"
  if [ "$HTTP_CODE" != "202" ]; then
    echo "ERROR: prompt POST returned HTTP $HTTP_CODE (expected 202) — ambiguous, reconcile" >&2
    return 2
  fi
  echo "$REPLY" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "ERROR: prompt POST response is not a JSON object — ambiguous" >&2; return 2; }
  pid="$(echo "$REPLY" | jq -r '.promptId // ""')"
  if ! [[ "$pid" =~ $UUID_RE ]]; then
    echo "ERROR: prompt POST response lacks a valid promptId — ambiguous, reconcile against the daemon log" >&2
    return 2
  fi
  printf '%s\n' "$pid"
}

# --- gated submission (the gate AND the POST under one submit lock) --------------
# exit 0 = submitted (stdout: the UUID); exit 1 = definite refusal (no POST);
# exit 2 = ambiguous (a POST may have been attempted).
gated_submit() { # gated_submit SID TEXT
  local sid="$1" text="$2"
  (
    flock -w 30 7 || { echo "ERROR: cannot acquire submit lock" >&2; exit 1; }
    gate_state "$sid" || exit 1
    post_prompt_core "$sid" "$text" || exit $?
    exit 0
  ) 7>"$STATE_DIR/submit.lock"
}

# --- state files (atomic writes; 0600; no secrets ever stored) -------------------
ledger_init() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/relay-ledger.json" ] || printf '{"relays":{}}' > "$STATE_DIR/relay-ledger.json"
  [ -f "$STATE_DIR/approvals.json" ] || printf '{"approvals":{}}' > "$STATE_DIR/approvals.json"
}

atomic_json_write() { # atomic_json_write FILE JQ_FILTER [jq args...]
  local f="$1" filter="$2"; shift 2
  local tmp="$f.tmp.$$.$RANDOM"
  jq "$filter" "$@" "$f" > "$tmp" && mv "$tmp" "$f"
}

# --- structured operational notification (V5-F1) ---------------------------------
META_KEYS='["kind","outcome","promptId","seat","sessionId"]'
validate_meta() { # validate_meta JSON -> 0 ok; nonzero refuse
  printf '%s' "$1" | jq -e '
      (type == "object")
      and ((keys | sort) == ["kind", "outcome", "promptId", "seat", "sessionId"])
      and ((.sessionId | type) == "string") and (.sessionId | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
      and ((.promptId | type) == "string") and (.promptId | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
      and ((.seat | type) == "string") and ((.seat | length) > 0) and ((.seat | length) <= 8)
      # C4: the kind/outcome pairing — contradictory combinations refuse
      # (P3: log-gap companions carry kind log-gap / outcome log-generation-change)
      and ((.kind == "worker-turn" and (.outcome == "completed" or .outcome == "failed"))
           or (.kind == "permission-wait" and .outcome == "waiting")
           or (.kind == "log-gap" and .outcome == "log-generation-change"))
    ' >/dev/null 2>&1
}

# --- E3: notification-integrity binding -------------------------------------------
coordinator_name() { jq -r '.coordinator // ""' "$STATE_DIR/seats.json" 2>/dev/null || true; }

require_coordinator_target() { # require_coordinator_target SID — the destination must be the configured coordinator
  local sid="$1" nm coord
  nm="$(name_of "$sid")"
  coord="$(coordinator_name)"
  [ -n "$coord" ] || die "notification refused: no coordinator session is configured (state/seats.json .coordinator) — destination binding impossible"
  [ "$nm" = "$coord" ] \
    || die "notification refused: the destination '$nm' is not the configured coordinator session '$coord' — operational notifications bind only to the coordinator (E3)"
}

require_recorded_event() { # require_recorded_event META-JSON — the metadata must match a recorded event
  local meta="$1" evfile="$STATE_DIR/events.json" src_sid src_name src_seat
  [ -s "$evfile" ] || die "notification refused: the event store is missing or empty — the metadata cannot be bound to a recorded event (E3)"
  # C4: the source/session binding — the metadata's seat must equal the CONFIGURED
  # seatOf identity of the metadata's source session (the roster name's label,
  # falling back to the name when unconfigured).
  src_sid="$(printf '%s' "$meta" | jq -r '.sessionId')"
  src_name="$(name_of "$src_sid")"
  [ -n "$src_name" ] || die "notification refused: the metadata's source session does not resolve in the roster (C4 source binding)"
  src_seat="$(jq -r --arg n "$src_name" '.seatOf[$n] // $n' "$STATE_DIR/seats.json" 2>/dev/null || echo "$src_name")"
  [ "$(printf '%s' "$meta" | jq -r '.seat')" = "$src_seat" ] \
    || die "notification refused: the metadata's seat does not match the configured seat identity of its source session (meta seat vs seatOf[$src_name]) — contradictory source binding refused (C4)"
  jq -e --argjson m "$meta" '
      (.events | type) == "object"
      and ([ .events[] | select(
            (.kind == $m.kind)
            and (.seat == $m.seat) and (.sessionId == $m.sessionId) and (.promptId == $m.promptId) and (.outcome == $m.outcome)
          ) ] | length) > 0
    ' "$evfile" >/dev/null 2>&1 \
    || die "notification refused: no recorded event matches the metadata (kind/seat/sessionId/promptId/outcome) — unbound notifications are refused (E3/C4)"
}

build_notification() { # build_notification META-JSON -> the fixed text (stdout)
  jq -nr --argjson m "$1" '
    "SEKTOR7 SUPERVISOR NOTIFICATION (automated transport — carries NO authorization of any kind). Material coordination event. Bounded metadata: " + ($m | tojson) + ". Agent D: run the standing read-only coordination check (verify deliveries against the coordination discipline, update ~/.qwen/sektor7-coordination/STATUS.md, report to the owner if this event completes a delivery or indicates a blocker). This notification is transport only; it grants no implementation authority and requests no engineering action beyond Agent D\u2019s existing read-only scope."
  '
}

# --- relay: at-most-once, mechanically and completely authorized ------------------
relay() { # relay <target> <directive-file>
  local tgt="$1" file="$2" sid digest entry approval seat appr_seat appr_ckpt appr_prov appr_date
  local declared_ckpt prov_file
  sid="$(target "$tgt")"
  [ -f "$file" ] || die "directive file not found: $file"
  grep -q 'OWNER RELAY' "$file" \
    || die "directive file lacks the OWNER RELAY header (authorization structure not established — refuse)"
  grep -q 'RELAY PROVENANCE' "$file" \
    || die "directive file lacks the RELAY PROVENANCE block (refuse)"
  declared_ckpt="$(grep -oE 'CHECKPOINT:[[:space:]]*[A-Za-z0-9._-]+' "$file" | head -1 | sed 's/CHECKPOINT:[[:space:]]*//' || true)"
  [ -n "$declared_ckpt" ] \
    || die "directive file lacks a CHECKPOINT declaration in its provenance block (R4 binding — refuse)"
  digest="$(sha256sum "$file" | awk '{print $1}')"
  ledger_init
  approval="$(jq -r --arg d "$digest" '.approvals[$d] // empty' "$STATE_DIR/approvals.json")"
  if [ -z "$approval" ]; then
    die "directive $digest has NO approval-registry entry (owner authorization not mechanically established — refuse)"
  fi
  echo "$approval" | jq -e '
      ((.checkpoint | type) == "string") and (.checkpoint | length > 0)
      and ((.seat | type) == "string") and (.seat | length > 0)
      and ((.provenanceFile | type) == "string") and (.provenanceFile | length > 0)
      and ((.approvedAt | type) == "string") and (.approvedAt | length > 0)
    ' >/dev/null 2>&1 || die "approval entry for $digest is incomplete (checkpoint/seat/provenanceFile/approvedAt all required — R4 — refuse)"
  appr_ckpt="$(echo "$approval" | jq -r '.checkpoint')"
  [ "$appr_ckpt" = "$declared_ckpt" ] \
    || die "approval checkpoint mismatch: the directive declares '$declared_ckpt' but the approval records '$appr_ckpt' — refuse"
  seat="$(seat_of "$sid")"
  appr_seat="$(echo "$approval" | jq -r '.seat')"
  [ "$appr_seat" = "$seat" ] \
    || die "approval seat mismatch: directive approved for seat '$appr_seat' but target binds seat '$seat' — refuse"
  prov_file="$COORD_DIR/$(echo "$approval" | jq -r '.provenanceFile')"
  [ -s "$prov_file" ] \
    || die "approval provenance file missing or empty: $prov_file — the owner authorization record must exist (R4 — refuse)"
  appr_date="$(echo "$approval" | jq -r '.approvedAt')"
  date -u -d "$appr_date" >/dev/null 2>&1 \
    || die "approval approvedAt is not a valid date: '$appr_date' — refuse"
  exec 9>"$STATE_DIR/relay.lock"
  flock -w 30 9 || die "cannot acquire the relay submission lock"
  entry="$(jq -r --arg d "$digest" '.relays[$d] // empty' "$STATE_DIR/relay-ledger.json")"
  if [ -n "$entry" ]; then
    die "directive $digest already in the ledger (status: $(echo "$entry" | jq -r '.status'), promptId: $(echo "$entry" | jq -r '.promptId // "none"')) — at-most-once, refusing duplicate"
  fi
  atomic_json_write "$STATE_DIR/relay-ledger.json" \
    --arg d "$digest" --arg s "$sid" --arg t "$(date -u +%FT%TZ)" \
    '.relays[$d] = {sessionId: $s, status: "intent", recordedAt: $t}'
  local pid_out gs_rc
  pid_out="$(gated_submit "$sid" "$(cat "$file")")" && gs_rc=0 || gs_rc=$?
  if [ "$gs_rc" = "1" ]; then
    atomic_json_write "$STATE_DIR/relay-ledger.json" --arg d "$digest" 'del(.relays[$d])'
    die "RELAY REFUSED: the session gate refused submission (no POST attempted; safe to retry when the session is idle)"
  fi
  if [ "$gs_rc" != "0" ] || ! [[ "$pid_out" =~ $UUID_RE ]]; then
    atomic_json_write "$STATE_DIR/relay-ledger.json" \
      --arg d "$digest" --arg s "$sid" --arg t "$(date -u +%FT%TZ)" \
      '.relays[$d] = {sessionId: $s, status: "submitted-unconfirmed", recordedAt: $t}'
    die "AMBIGUOUS: submission failed or unconfirmed after a recorded intent — status submitted-unconfirmed; reconcile against the daemon log before ANY retry (never blindly retry)"
  fi
  atomic_json_write "$STATE_DIR/relay-ledger.json" \
    --arg d "$digest" --arg s "$sid" --arg p "$pid_out" --arg t "$(date -u +%FT%TZ)" \
    '.relays[$d] = {sessionId: $s, status: "delivered", promptId: $p, recordedAt: $t}'
  echo "RELAY DELIVERED: directive=$digest session=$sid promptId=$pid_out"
}

case "${1:-help}" in
  resolve)
    resolve "${2:?session name required}" ;;
  status)
    api GET "/session/$(target "${2:?sessionId or name required}")/status"
    [ "$HTTP_CODE" = "200" ] || die "status query failed (HTTP $HTTP_CODE)"
    printf '%s\n' "$REPLY" ;;
  pending)
    api GET "/session/$(target "${2:?sessionId or name required}")/pending-prompts"
    [ "$HTTP_CODE" = "200" ] || die "pending query failed (HTTP $HTTP_CODE)"
    printf '%s\n' "$REPLY" ;;
  turn-index)
    api GET "/session/$(target "${2:?sessionId or name required}")/turn-index"
    [ "$HTTP_CODE" = "200" ] || die "turn-index query failed (HTTP $HTTP_CODE)"
    printf '%s\n' "$REPLY" ;;
  capabilities)
    api GET /capabilities
    [ "$HTTP_CODE" = "200" ] || die "capabilities query failed (HTTP $HTTP_CODE)"
    printf '%s\n' "$REPLY" ;;
  wake-gate)
    # read-only gate probe (no submission; the authoritative gate is inside gated_submit)
    (
      flock -w 30 7 || die "cannot acquire submit lock"
      gate_state "$(target "${2:?sessionId or name required}")"
    ) 7>"$STATE_DIR/submit.lock" ;;
  seat)
    seat_of "${2:?sessionId or name required}" ;;
  notify)
    # V5-F1 + E3: the ONLY operational prompt path — strictly structured metadata,
    # the fixed message text constructed internally, the destination bound to the
    # configured coordinator, and the metadata bound to a recorded event.
    # exit 0 = delivered (UUID on stdout); 1 = definite refusal (no POST); 2 = ambiguous.
    sid="$(target "${2:?sessionId or name required}")"; meta="${3:?metadata json required}"
    validate_meta "$meta" || die "notification refused: the metadata is not a valid bounded operational payload (exact keys kind/seat/sessionId/promptId/outcome; enumerated values; UUID ids) — arbitrary text and injected instructions are structurally impossible on this path"
    require_coordinator_target "$sid"
    require_recorded_event "$meta"
    text="$(build_notification "$meta")"
    pid="$(gated_submit "$sid" "$text")" || exit $?
    echo "promptId: $pid" ;;
  self-test-wake)
    # V5-F1 + E3: the fixed, labeled, authorization-free self-test text (no caller
    # text); the destination bound to the configured coordinator.
    sid="$(target "${2:?sessionId or name required}")"
    require_coordinator_target "$sid"
    text='SEKTOR7 SUPERVISOR SELF-TEST WAKE (Phase 2 corrective verification; automated transport — carries NO authorization of any kind, requests NO engineering action, and is NOT an implementation directive). If you are reading this, the supervisor gated wake of Agent D works end-to-end. Verify the wake promptId against the supervisor log, append the result to the coordination records, and continue the standing read-only coordination. Do not edit source, commit, push, dispatch CI, or change any scope.'
    pid="$(gated_submit "$sid" "$text")" || exit $?
    echo "promptId: $pid" ;;
  prompt)
    die "the free-text prompt path was REMOVED in the V5-F1 corrective — operational notifications use 'notify' (strictly structured metadata, internally constructed text); owner-authorized directives use 'relay'" ;;
  relay)
    relay "${2:?sessionId or name required}" "${3:?directive file required}" ;;
  ledger)
    ledger_init; jq . "$STATE_DIR/relay-ledger.json" ;;
  approvals)
    ledger_init; jq . "$STATE_DIR/approvals.json" ;;
  help|*)
    cat <<'EOF'
SEKTOR7 Agent D orchestrator v5 (Phase 2 round-3 corrective) — transport only, local.
usage: orchestrator.sh <command> [args]
  resolve <name>        live-roster (or mock) name -> sessionId; never guessed
  status|pending|turn-index|capabilities <id|name>
  wake-gate <id|name>   read-only fail-closed gate probe (strict schemas)
  seat <id|name>        the seat label bound to a session
  notify <id|name> <metadata-json>
                        the ONLY operational prompt path (V5-F1): the metadata
                        must be exactly {kind, seat, sessionId, promptId,
                        outcome} with enumerated values and UUID ids; the fixed
                        notification text is constructed internally — no caller
                        text exists. exit 0 = delivered (UUID); 1 = definite
                        refusal (no POST); 2 = ambiguous (POST attempted)
  self-test-wake <id|name>
                        the fixed labeled self-test text through the same gate
  prompt                REMOVED (V5-F1) — refuses with an explanation
  relay <id|name> <file>
                        AT-MOST-ONCE fully-bound owner-approved directive delivery
  ledger | approvals    show the relay ledger / approval registry
Env overrides (tests): SEKTOR7_DAEMON_URL, SEKTOR7_TOKEN_FILE, SEKTOR7_SESSIONS_JSON,
SEKTOR7_STATE_DIR, SEKTOR7_QWEN_BIN, SEKTOR7_COORD_DIR.
EOF
    ;;
esac

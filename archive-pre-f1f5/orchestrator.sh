#!/usr/bin/env bash
# SEKTOR7 Agent D orchestrator v2 (Phase 2) — transport/activation + at-most-once relay.
# Transport ONLY — never an engineering authority. Fails closed on any uncertainty.
# Env overrides for testing: SEKTOR7_DAEMON_URL, SEKTOR7_TOKEN_FILE, SEKTOR7_SESSIONS_JSON,
# SEKTOR7_STATE_DIR, SEKTOR7_QWEN_BIN.
set -euo pipefail

ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="${SEKTOR7_DAEMON_URL:-http://127.0.0.1:4170}"
TOKEN_FILE="${SEKTOR7_TOKEN_FILE:-$HOME/.qwen-serve-token}"
SESSIONS_JSON="${SEKTOR7_SESSIONS_JSON:-}"
STATE_DIR="${SEKTOR7_STATE_DIR:-$ORCH_DIR/state}"
QWEN_BIN="${SEKTOR7_QWEN_BIN:-/home/coder/.nvm/versions/node/v24.21.0/bin/qwen}"
export PATH="/home/coder/.nvm/versions/node/v24.21.0/bin:/home/coder/.local/bin${PATH:+:$PATH}"

die() { echo "ERROR: $*" >&2; exit 1; }

api() { # api METHOD PATH [JSON_BODY] — token read per call, never logged/printed
  local method="$1" path="$2" body="${3:-}" tok out rc
  tok="$(cat "$TOKEN_FILE")"
  if [ -n "$body" ]; then
    out="$(curl -s --max-time 15 -X "$method" \
      -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      -d "$body" "$DAEMON$path" 2>/dev/null)" || rc=$?
  else
    out="$(curl -s --max-time 15 -X "$method" -H "Authorization: Bearer $tok" "$DAEMON$path" 2>/dev/null)" || rc=$?
  fi
  if [ "${rc:-0}" -ne 0 ]; then
    echo "ERROR: daemon transport failure (rc=$rc; is $DAEMON reachable?)" >&2
    exit 1
  fi
  printf '%s' "$out"
}

resolve() { # live roster (or SEKTOR7_SESSIONS_JSON mock) — IDs are never guessed
  local name="$1" sid
  if [ -n "$SESSIONS_JSON" ]; then
    sid="$(awk -F'|' -v n="$name" '$1==n{print $2}' "$SESSIONS_JSON" | head -1)"
  else
    sid="$("$QWEN_BIN" sessions ps --json 2>/dev/null | jq -r --arg n "$name" 'select(.name == $n) | .sessionId' | head -1)"
  fi
  [ -n "$sid" ] || die "session '$name' not found in the roster (stale or absent — re-resolve; never guess)"
  echo "$sid"
}

target() { # accept a sessionId or a roster name
  local t="$1"
  if [[ "$t" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "$t"
  else
    resolve "$t"
  fi
}

gate_state() { # fail-closed wake gate: idle, no active prompt, zero pending, no permission/question wait
  local sid="$1" st state pending perm quest active
  st="$(api GET "/session/$sid/status")" || die "status query failed"
  echo "$st" | jq -e '.sessionId' >/dev/null 2>&1 || die "status query returned no session: $st"
  state="$(echo "$st" | jq -r '.activeWorkState // "unknown"')"
  pending="$(api GET "/session/$sid/pending-prompts" | jq -r '(.pendingPrompts | length)')"
  perm="$(echo "$st" | jq -r '.isWaitingForPermission')"
  quest="$(echo "$st" | jq -r '.isWaitingForUserQuestion')"
  active="$(echo "$st" | jq -r '.hasActivePrompt')"
  echo "gate: state=$state pending=$pending permWait=$perm questionWait=$quest activePrompt=$active" >&2
  [ "$state" = "idle" ] || die "refusing: session is '$state' (never interrupt a running turn)"
  [ "$active" = "false" ] || die "refusing: active prompt present"
  [ "$pending" = "0" ] || die "refusing: $pending pending prompt(s) (never overlap)"
  [ "$perm" = "false" ] || die "refusing: session is waiting for a permission decision"
  [ "$quest" = "false" ] || die "refusing: session is waiting for a user question"
}

post_prompt() { # sid text -> daemon 202 json on stdout
  api POST "/session/$1/prompt" "$(jq -n --arg t "$2" '{prompt: [{type: "text", text: $t}]}')"
}

ledger_init() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/relay-ledger.json" ] || echo '{"relays":{}}' > "$STATE_DIR/relay-ledger.json"
}

ledger_write() { # apply a jq filter (with vars) to the relay ledger atomically
  jq "$@" "$STATE_DIR/relay-ledger.json" > "$STATE_DIR/relay-ledger.json.tmp" \
    && mv "$STATE_DIR/relay-ledger.json.tmp" "$STATE_DIR/relay-ledger.json"
}

relay() { # relay <target> <directive-file> — at-most-once delivery of an owner-approved directive
  local tgt="$1" file="$2" sid digest entry prompt_id
  sid="$(target "$tgt")"
  [ -f "$file" ] || die "directive file not found: $file"
  grep -q 'OWNER RELAY' "$file" \
    || die "directive file lacks the OWNER RELAY header (authorization structure not established — refuse)"
  grep -q 'RELAY PROVENANCE' "$file" \
    || die "directive file lacks the RELAY PROVENANCE block (refuse)"
  digest="$(sha256sum "$file" | awk '{print $1}')"
  ledger_init
  entry="$(jq -r --arg d "$digest" '.relays[$d] // empty' "$STATE_DIR/relay-ledger.json")"
  if [ -n "$entry" ]; then
    die "directive $digest already in the ledger (status: $(echo "$entry" | jq -r '.status'), promptId: $(echo "$entry" | jq -r '.promptId // "none"')) — at-most-once, refusing duplicate"
  fi
  gate_state "$sid"
  if ! prompt_id="$(post_prompt "$sid" "$(cat "$file")" | jq -r '.promptId // empty')"; then
    ledger_write --arg d "$digest" --arg s "$sid" --arg t "$(date -u +%FT%TZ)" \
      '.relays[$d] = {sessionId: $s, status: "submitted-unconfirmed", recordedAt: $t}'
    die "AMBIGUOUS: submission transport failed after the gate — recorded submitted-unconfirmed; reconcile before any retry"
  fi
  if [ -z "$prompt_id" ]; then
    ledger_write --arg d "$digest" --arg s "$sid" --arg t "$(date -u +%FT%TZ)" \
      '.relays[$d] = {sessionId: $s, status: "submitted-unconfirmed", recordedAt: $t}'
    echo "AMBIGUOUS: response carried no promptId — recorded submitted-unconfirmed; reconcile manually" >&2
    exit 2
  fi
  ledger_write --arg d "$digest" --arg s "$sid" --arg p "$prompt_id" --arg t "$(date -u +%FT%TZ)" \
    '.relays[$d] = {sessionId: $s, status: "delivered", promptId: $p, recordedAt: $t}'
  echo "RELAY DELIVERED: directive=$digest session=$sid promptId=$prompt_id"
}

case "${1:-help}" in
  resolve)
    resolve "${2:?session name required}" ;;
  status)
    api GET "/session/$(target "${2:?sessionId or name required}")/status" ;;
  pending)
    api GET "/session/$(target "${2:?sessionId or name required}")/pending-prompts" ;;
  turn-index)
    api GET "/session/$(target "${2:?sessionId or name required}")/turn-index" ;;
  capabilities)
    api GET /capabilities ;;
  wake-gate)
    gate_state "$(target "${2:?sessionId or name required}")" ;;
  prompt)
    sid="$(target "${2:?sessionId or name required}")"; text="${3:?message required}"
    gate_state "$sid"
    post_prompt "$sid" "$text" ;;
  relay)
    relay "${2:?sessionId or name required}" "${3:?directive file required}" ;;
  ledger)
    ledger_init; jq . "$STATE_DIR/relay-ledger.json" ;;
  help|*)
    cat <<'EOF'
SEKTOR7 Agent D orchestrator v2 (Phase 2 pilot) — daemon transport/activation, local only.
usage: orchestrator.sh <command> [args]
  resolve <name>              live-roster (or mock) name -> sessionId; never guessed
  status <id|name>            GET /session/:id/status
  pending <id|name>           GET /session/:id/pending-prompts
  turn-index <id|name>        GET /session/:id/turn-index
  capabilities                GET /capabilities
  wake-gate <id|name>         fail-closed idle/no-pending/no-permission-wait check
  prompt <id|name> <text>     gated raw prompt POST (returns 202 {promptId,...})
  relay <id|name> <file>      AT-MOST-ONCE relay of an owner-approved directive file
                             (requires OWNER RELAY + RELAY PROVENANCE headers; ledgered
                             by sha256; ambiguous delivery records submitted-unconfirmed)
  ledger                      show the relay ledger
Observation: ~/.qwen-serve.log records "prompt enqueued" / "prompt turn completed" /
"prompt turn failed" per promptId. Env overrides (tests): SEKTOR7_DAEMON_URL,
SEKTOR7_TOKEN_FILE, SEKTOR7_SESSIONS_JSON, SEKTOR7_STATE_DIR, SEKTOR7_QWEN_BIN.
EOF
    ;;
esac

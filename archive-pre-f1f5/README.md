# SEKTOR7 Agent D Orchestrator (Phase 2)

Local transport/activation + event-driven supervision for the owner-authorized
orchestration infrastructure (**Phase 2 directive, 2026-11-11** — implementation and
controlled testing ONLY; **unattended production activation NOT authorized** until
independent review). Everything is strictly loopback, bash/jq/curl/python3, with no
new dependencies.

**This infrastructure is transport and scheduling ONLY. It never judges source
correctness, grants implementation authority, approves merges, promotes checkpoints
to CLOSED-PASS, auto-approves permissions, or changes approval modes.**

## Components

- **`orchestrator.sh`** — daemon transport helper. Commands: `resolve` (live roster
  via `qwen sessions ps`, or a mock roster file for tests — IDs are never guessed),
  `status` / `pending` / `turn-index` / `capabilities` (read-only GETs),
  `wake-gate` (fail-closed: `activeWorkState=idle` AND `hasActivePrompt=false` AND
  zero pending prompts AND no permission/question wait), `prompt` (gated raw
  `POST /session/:id/prompt`), **`relay`** (at-most-once delivery of an
  owner-approved directive file), `ledger` (show the relay ledger).
- **`supervisor.sh`** — event-driven watch. Polls the daemon (default 20 s):
  watched-seat session status transitions (active→idle = turn completed;
  permission wait) and the daemon log's per-promptId `prompt turn completed/failed`
  lines. Material events wake **Agent D only** (`coder-a3` — never a wake source),
  gated + flock single-writer + deduped by `(sessionId, promptId, outcome)` +
  rate-limited (default 4 wakes/hour). Modes: `run [--once] [--dry-run]
  [--self-test-wake]`, `status`, `stop` (flag file). Baselines state on start —
  no replay of pre-existing history; all state persists under `state/` for
  restart-safe reconciliation; daemon unreachability backs off without acting.
- **`tests/mock-daemon.py`** — loopback mock of the daemon API with a
  per-request `scenario.json` (busy/pending/permission-wait/500/stale cases).
- **`tests/run-tests.sh`** — the non-destructive mock battery (24 checks, all
  PASS on 2026-11-11) + documentation hooks for the live tests.

## Safety rules enforced in code

1. **Identity:** names resolve against the live roster on every use; a vanished
   name is STALE (log, no action); cached sessionIds are revalidated and rebound
   with a baseline reset.
2. **Authorization provenance:** `relay` refuses any file lacking the `OWNER RELAY`
   + `RELAY PROVENANCE` headers; the at-most-once ledger keys directives by
   SHA-256. (The delivered F8 directive is registered: sha256 `062c76d0…` →
   promptId `07ef6f70-427e-4cc2-a0af-7529f2eef4b1`, status delivered.)
3. **At-most-once:** duplicate directive files refuse; ambiguous delivery
   (transport failure or missing promptId) records `submitted-unconfirmed` and
   refuses retries pending manual reconciliation.
4. **Concurrency:** never prompts an active/busy/pending/permission-waiting
   session; `flock` serializes wake submissions.
5. **Restart safety:** persisted state (`state/`), log-offset baselining, stale-ID
   rebind, backoff on daemon unavailability.
6. **Event filtering:** Agent D's own activity never triggers wakes; dedup by
   promptId; wake rate limit; self-test mode exits after exactly one labeled wake.
7. **Secrets:** the daemon bearer token is read per call and never printed,
   logged, or persisted by any component (verified by test T12).
8. **Failure behavior:** every uncertain condition fails closed — no prompt sent.

## Daemon API used (qwen 0.24.5)

`GET /capabilities` · `GET /session/:id/status` · `GET /session/:id/pending-prompts`
· `POST /session/:id/prompt` (body `{"prompt":[{"type":"text","text":"…"}]}` →
`202 {promptId,lastEventId,eventEpoch}`) · the daemon log's per-promptId lifecycle
lines (`prompt enqueued` / `prompt turn completed` / `prompt turn failed`).
Bearer auth from `~/.qwen-serve-token`; unregistered `x-qwen-client-id` headers are
rejected on some routes, so none is sent.

## Provenance rules for relayed prompts

Every coordinator prompt carries an explicit relay-provenance header: who relays it
(Agent D, `coder-a3`), the originating owner authority (dated directive, preserved
verbatim under `~/.qwen/sektor7-coordination/`), and the statement that the relay
adds no authorization. Recipients apply the permanent 2026-11-02
authorization-provenance rule and may byte-verify relayed directives against the
preserved copies (Agent B did exactly this for F8).

## Phase 2 status

Mock battery 24/24 PASS; live validations: idle-session activation (B wake test,
2026-11-11 17:42–17:45Z), worker completion + directive delivery (F8 relay
`07ef6f70…`, turn completed 18:02:21Z, delivery verified, CI `43073270525` GREEN ×3),
Agent D wake-up self-test (see the readiness report). **No persistent supervisor is
left running; the 30-minute cron pilot watch remains the only standing watch until
Phase 2 review.**

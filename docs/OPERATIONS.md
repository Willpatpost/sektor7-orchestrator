# SEKTOR7 Agent D Orchestrator (Phase 2 — round-4 corrective)

Local transport/activation + event-driven supervision for the owner-authorized
orchestration infrastructure. **Status: four independent review rounds corrected
(F1–F5, R1–R6, V5-F1–F4, E1–E3); unattended production activation NOT authorized —
independent review pending.** Loopback only, bash/jq/curl/python3, no new
dependencies. State files 0600 (`umask 077`); the daemon token is read per call and
never written or logged.

**This infrastructure is transport and scheduling ONLY. It never judges source
correctness, grants implementation authority, approves merges, promotes checkpoints
to CLOSED-PASS, auto-approves permissions, or changes approval modes.**

## Commands (orchestrator.sh)

- `resolve <name>` — the live roster; sessionIds are never guessed.
- `status` / `pending` / `turn-index` / `capabilities` — strict HTTP+schema validated.
- `wake-gate <id|name>` — read-only fail-closed probe (idle + no active prompt +
  zero pending + no permission/question wait; inconsistent/null state refuses).
- `seat <id|name>` — the seat label bound to a session.
- **`notify <id|name> <metadata-json>`** — the ONLY operational prompt path: the
  metadata must be exactly `{kind, seat, sessionId, promptId, outcome}` (enumerated
  values, UUID ids); the destination must be the **configured coordinator session**
  (`state/seats.json` `.coordinator` — E3); the metadata must match a **recorded
  event** in the event store (seat/session/promptId/outcome — E3); the fixed
  notification text is constructed internally — no caller text exists. Exit 0 =
  delivered (a UUID on stdout); 1 = definite pre-POST refusal; 2 = ambiguous.
- **`self-test-wake <id|name>`** — the fixed labeled self-test text, coordinator-bound.
- `prompt` — **REMOVED** (V5-F1); refuses with an explanation.
- **`relay <id|name> <file>`** — the owner-approved directive path: OWNER RELAY +
  RELAY PROVENANCE + a CHECKPOINT declaration, a complete approvals-registry entry
  (checkpoint/seat/provenanceFile/approvedAt — all validated; the provenance file
  must exist), seat matching, an interprocess lock, a durable pre-POST intent,
  at-most-once, gate-refusal rollback, and never a blind retry on ambiguity.

## The supervisor (supervisor.sh)

- **E1 — persistence failures hold the cursor:** every event-store write propagates
  serialization/rename failures explicitly (no false "persisted" log); the scanner
  NEVER advances past an unpersisted material event — the region retries once the
  store is repaired; startup init is fault-tolerant.
- **E2 — rotation-safe scanning:** a log shrink (replacement/truncation) rescans the
  new generation from the start — completions already present are NOT skipped; the
  event-ID dedup (sessionId/promptId/outcome) prevents re-firing; byte-exact
  partial-line handling (V5-F4) throughout.
- **E3-bound wakes:** the supervisor's notifications go through the same bound
  `notify` path (coordinator destination + recorded-event metadata).
- (Prior rounds preserved: pending/delivered/unresolved/ambiguous event states;
  submitting-crash-window protection; no-budget deferrals; permission-wait
  episodes; UTC rate counting; single instance; bounded structured metadata.)

## Tests

`tests/run-tests.sh`: **164/164 in both invocation styles** (`bash tests/run-tests.sh`
from this directory and by absolute path). The round-4 regressions: E1a/E1b (fault
injection via corrupted store JSON and a directory target — the cursor holds, no
false persistence, recovery exactly once), E2a/E2b (shorter and larger replacements
with new + already-seen completions — not skipped, not re-fired), E3a–d (non-
coordinator destination, unrecorded event, seat mismatch — all refuse with zero
POSTs; the bound path delivers). Requirements: bash, jq, curl, python3, GNU
coreutils.

## Operational notes

Production supervisor startup (post-authorization ONLY) must use the double-fork
orphan form — never a session-tracked background task of any session it may wake.
CI observation after cron retirement: the supervisor wakes the coordinator on the
CI-dispatching seat's turn completion; the coordinator verifies and starts the
`gh run watch` monitor. Residual limitation (documented in the corrective report):
a log replacement LONGER than the current cursor with misaligned content is
indistinguishable from an append — events solely in the skipped prefix of such a
replacement are not recoverable from the single watched path.

# SEKTOR7 — PHASE 2 ROUND-3 SAFETY CORRECTIVE REPORT (V5-F1–V5-F4)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~20:45Z) · **Authority:** the owner-relayed independent technical review "Agent D Phase 2 v5 — Targeted Safety Corrective" (VERDICT: HOLD; GO — V5-F1 through V5-F4 only; the R1–R6 corrections accepted within their tested scenarios).
**Status:** corrective COMPLETE under the authorized orchestrator-only scope. **Unattended production activation remains NOT authorized. STOP for independent review.**

---

## V5-F1 — Unrestricted appended text after an operational prefix — CORRECTED

**Confirmed:** the v5 template match (`"SEKTOR7 SUPERVISOR NOTIFICATION (…"*`) accepted arbitrary text after the prefix — an operational prompt could carry injected engineering instructions.

**Correction (orchestrator v6 — the free-text path no longer exists):**
- The `prompt` command is **REMOVED** — invoking it refuses with an explanation pointing to the two legitimate paths.
- Operational notifications go through **`notify <target> <metadata-json>`**, which accepts ONLY a strictly-validated structured object: **exact key set** `{kind, seat, sessionId, promptId, outcome}` (any extra key — e.g. an injected `instructions` field — refuses), enumerated `kind` (`worker-turn|permission-wait`) and `outcome` (`completed|failed|waiting`), UUID-format ids, a bounded seat string. **The fixed notification text is constructed internally** from the validated metadata — no caller-supplied text ever reaches the wire, so prefix-plus-injected-instructions is structurally impossible, not merely filtered.
- The self-test wake is a separate fixed-text command (`self-test-wake`). Owner-authorized directives go only through `relay` (unchanged, fully bound).

**Evidence:** V5F1a (a valid-prefix message with appended instructions through the old `prompt` path → refused: "REMOVED in the V5-F1 corrective"); C6c/V5F1b (metadata with an injected `instructions` field → refused **before any POST** — zero posts, no prompt recorded); V5F1c (a valid notify → the recorded wire text contains the fixed construction and the metadata, and contains no injected text).

## V5-F2 — Definite pre-POST refusal incorrectly becomes ambiguous — CORRECTED

**Confirmed:** the supervisor pre-gated, then `orchestrator prompt` gated again; a busy transition between the two gates produced a definite refusal that the supervisor classified as ambiguous — the event stopped retrying with zero notifications submitted.

**Correction (orchestrator v6 + supervisor v4):**
- **No duplicate preflight gate:** the supervisor's `wake_agent_d` no longer pre-gates; the single authoritative gate AND the POST run together inside the notify command's submission lock.
- **Three outcomes preserved end-to-end:** `notify` exits 0 (verified success — a valid UUID on stdout), **1 (definite refusal BEFORE any POST)**, or **2 (a POST was attempted with an unverified result)**; `wake_agent_d` propagates them: rc 1 → **safe deferral** (the event returns to `pending`, no budget consumed); rc 2 → **ambiguous** (never blind-retried); rc 0 + a UUID-validated acknowledgment → **delivered** (the state and wakePromptId in one atomic update). Rate-limit and unresolvable-target remain no-POST deferrals.
- The crash-window protections are unchanged (submitting → ambiguous on restart; never auto-resubmitted).

**Evidence (the deterministic race the review specified):** V5F2 — the mock's `pendingMode: "race"` makes the status query report idle and the pending query report busy (a prompt arrived between the two gate queries, inside the locked gate). Result: **zero POSTs**, the event **retained as pending**, **no budget consumed**, and **successful delivery on the next cycle** once idle. The prior misclassification path (a definite refusal becoming ambiguous) is structurally gone: T11/C3/R5's deferral semantics all still pass.

## V5-F3 — Repeated permission waits permanently suppressed — CORRECTED

**Confirmed:** permission-wait events keyed only by session ID — after the first delivered event, every later wait episode for that session was suppressed forever.

**Correction (supervisor v4):** **episode-based permission waits.** A persisted per-session state (`state/perm-state.json`: `{waiting: bool, episodes: N}`) tracks the wait:
- A **false→true transition** (a new episode) increments the counter and creates a **new event** keyed `perm-wait:<sid>:episode:<N>` — notified once.
- A **continuous unchanged wait** produces no new event (no repeated alerts).
- A **confirmed clearance** (the flag observed false) resets the wait state while keeping the counter — the next wait is a new episode.
- Earlier delivered events remain as **historical evidence**; the episode state **persists across supervisor restarts** (each `--once` cycle in the regression is a separate process).

**Evidence:** V5F3a (episode 1 → one event, delivered); V5F3b (a continuous wait → still exactly one); V5F3c (clearance observed); V5F3d (episode 2 → a **second** event, delivered, with episode 1 preserved as history) — all across separate supervisor invocations (restarts).

## V5-F4 — UTF-8 partial log lines corrupt byte offsets — CORRECTED

**Confirmed:** the partial-line arithmetic used bash's `${#var}` (character count), which differs from bytes under multibyte UTF-8 — the cursor could advance past unprocessed bytes.

**Correction (supervisor v4):** the partial-line length is computed with **`wc -c` (byte-exact)**; the fully-terminated branch advances to the exact file size; the round-1 last-byte probe (which never reads the region through command substitution for newline decisions) is preserved; incomplete lines withhold **all** their bytes.

**Evidence:** V5F4 — a worker-completion line whose trailing partial region contains multibyte UTF-8 (`— ✓ caf`, cut mid-`café`): the partial cycle creates **no event** and holds the offset at the exact pre-append byte position; after newline completion the event is persisted **exactly once** and the cursor equals the file's exact byte size (the character-count bug would have left the cursor short of the true byte length — asserted directly).

## Adjacent-path recheck (per the acceptance requirements)

- **Ambiguous submission classification:** R1a/R1b/R1c, C5b/C5c, T7a/T7b, and AMB all pass unchanged — the notify restructure preserved the 0/1/2 outcome contract end-to-end.
- **Structured-event validation:** every supervisor-driven notification now originates from the event store's own bounded fields and passes the same strict validation (R3/R3b/C3 prove the pipeline).
- **All 94 prior scenarios preserved** (adapted to the structured notify path — the gate/refusal/ambiguity semantics are unchanged) **plus 15 new round-3 checks: 127/127 PASS in BOTH invocation styles** (`bash tests/run-tests.sh` from the orchestrator directory and by absolute path; both outputs captured in the bundle).

## Residual risks (candid, unchanged in structure)

1. The client-side at-most-once window (rounds 1–2): flagged intents/submitting/unconfirmed/ambiguous states, all reconciled against the daemon log; the daemon offers no idempotency keys.
2. The approvals registry binds and traces; cryptographic owner-authorship proof remains the Phase-3 signing proposal (an owner decision).
3. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface (fail-safe on drift).
4. Poll-based watching (20 s); the SSE upgrade path remains documented.
5. Permission waits still require owner action (by design).

## Production-readiness assessment

**CONDITIONAL GO** — after independent acceptance of this round: all findings from the three review rounds (F1–F5, R1–R6, V5-F1–F4) are corrected with regressions that reject each reproduced failure; every tested failure mode is fail-closed; the architecture is unchanged and carries two live wake validations (`eb973a06…`, `d6b8784a…`). Conditions: acceptance of this corrective, the owner's cron-retirement cutover authorization, and an initial bounded activation with the 7-day expiry discipline and `supervisor.sh status` inspection. No engineering authority is delegated by this assessment.

## File inventory (all under `~/.qwen/sektor7-coordination/orchestrator/`)

`orchestrator.sh` (v6) · `supervisor.sh` (v4) · `tests/mock-daemon.py` (v4: the race mode + last-prompt recording) · `tests/run-tests.sh` (v4: 127 checks) · `state/` (ledger, approvals, seats, events, perm-state) · `archive-pre-f1f5/` (the original implementation, preserved). The v3/v4/v5 archives are preserved untouched; this corrective ships as the v6 archive beside them.

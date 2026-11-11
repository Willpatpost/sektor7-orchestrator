# SEKTOR7 — PHASE 2 ROUND-2 SAFETY CORRECTIVE REPORT (R1–R6)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~20:10Z) · **Authority:** the owner-relayed independent technical review "Agent D Phase 2 v4 — Safety Corrective Round 2" (VERDICT: HOLD; GO — narrow coordination safety corrective only; preserved verbatim in the coordination directory).
**Status:** corrective COMPLETE under the authorized orchestrator-only scope. **Unattended production activation remains NOT authorized. STOP for independent review.**

---

## R1 — CRITICAL: Invalid acknowledgment falsely reported as successful — CORRECTED

**Confirmed:** the v3 `prompt` command wrapped the submission in `echo "promptId: $(post_prompt …)"` — the command substitution's failure was swallowed by echo's exit 0, printing `promptId:` with an empty UUID; the supervisor could then mark an event `delivered` with an empty wakePromptId.

**Correction (orchestrator v4 + supervisor v3):**
- The `prompt` command captures first and fails loudly: `pid="$(gated_submit …)" || die "prompt submission failed or was refused"` — a failed validation propagates through every caller.
- `post_prompt_core` returns **2 for every POST-attempt failure** (HTTP ≠ 202, non-JSON body, missing/invalid UUID): a POST was attempted, so the outcome is *ambiguous*, never a definite refusal. Only gate refusals are definite (exit 1).
- The supervisor **refuses unverified acknowledgments**: it extracts and UUID-validates the wake promptId from the orchestrator's output; an empty/invalid acknowledgment logs `wake AMBIGUOUS` and exits 2 — the event is never marked delivered.
- The `delivered` transition and the `wakePromptId` are written in **one atomic jq update** (R1's atomicity requirement).

**Reproduction evidence (the tests reject each reproduced failure):** R1a (202-without-promptId through `prompt` → nonzero exit, no false `promptId:` line), R1b (empty body → refuse), R1c (the supervisor event goes `ambiguous`, **not** delivered, no wakePromptId, and stays ambiguous across further cycles — no retry).

## R2 — HIGH: Missing or null safety fields accepted — CORRECTED

**Confirmed:** the v3 gate defaulted missing/null flags to false and treated null `pendingPrompts` as length 0; the returned sessionId was never compared to the requested one.

**Correction:** the gate now enforces a complete, strictly typed, session-matched schema — `sessionId` must equal the requested session; `activeWorkState` must be `idle|active`; `isWaitingForPermission` / `isWaitingForUserQuestion` / `hasActivePrompt` must be real booleans (jq type checks, not `// false` defaults); `pendingPrompts` must be a real array. Any null, missing, wrong-typed, or mismatched value fails closed with a typed refusal.

**Evidence:** R2a (null booleans → refuse), R2b (string-typed flags → refuse), R2c (mismatched sessionId → refuse), R2d (null pendingPrompts → refuse). The four reproduced malformed cases are all rejected.

## R3 — HIGH: Concurrent raw prompts bypass the idle gate — CORRECTED

**Confirmed:** the v3 gate ran outside the submit lock; two concurrent operational prompts could both observe idle and both POST.

**Correction:** the gate AND the POST now run **together under the session submit lock** (`gated_submit`: `flock` → `gate_state` → `post_prompt_core`). Concurrent raw prompts serialize; the second invocation's gate observes the state reflected by the first's accepted POST and refuses. Relays use the same `gated_submit` (nested under the relay lock — consistent ordering, no cycles). The directive-level at-most-once protection is unchanged.

**Evidence:** R3 (two concurrent raw prompts against a post-reflecting mock → **exactly one POST**, one success, one refusal), R3b (a relay and a raw prompt racing → the relay's POST wins; the prompt's gate sees the reflected pending state and refuses; one POST total). The mock daemon gained a `trackPosts` mode that reflects accepted POSTs as pending state — the tests assert the POST count directly, not log entries.

## R4 — HIGH: Approval binding incomplete — CORRECTED

**Confirmed:** a registry entry of `{"seat":"B"}` sufficed; the checkpoint, provenance, and timestamp were never required or verified; the raw prompt accepted arbitrary text merely containing `NO authorization`.

**Correction:**
- **Every approval field is required and validated:** `checkpoint`, `seat`, `provenanceFile`, `approvedAt` — all non-empty strings; `approvedAt` must parse as a date.
- **Checkpoint binding:** the directive file must declare its checkpoint (`CHECKPOINT: <id>` in the provenance block) and it must equal the approval's recorded checkpoint (R4b/R4e).
- **Provenance binding:** the approval's `provenanceFile` (relative to the coordination directory) must **exist and be non-empty** — the owner authorization record must be real (R4c).
- **Recipient binding:** the target's seat must equal the approval's seat (unchanged, now among complete fields).
- **Raw prompts restricted to known templates:** the `prompt` command accepts ONLY the two operational message forms (the supervisor notification and the self-test wake) — free text mentioning "NO authorization" is refused (C6c).
- **Honest scope (unchanged and restated):** the registry binds and traces; it does **not** independently prove owner authorship. Owner-provenance verification (the preserved directive chain, the technical-lead review of every delivery, and recipient-side byte-verification) remains the authority.

**Evidence:** R4a (seat-only entry → refuse), R4b (checkpoint mismatch → refuse), R4c (missing provenance file → refuse), R4d (invalid date → refuse), R4e (directive without a CHECKPOINT declaration → refuse), C6c (free-text prompt → refuse).

## R5 — HIGH: Ordinary busy periods can exhaust event delivery — CORRECTED

**Confirmed:** the v2 supervisor incremented `attempts` on every failed delivery attempt including gate-busy and rate-limited deferrals; at the cap the event became `unresolved` and stopped retrying — an event could retire with zero submitted notifications.

**Correction (supervisor v3):**
- **Deferrals consume no budget:** gate refusals, rate-limiting, and unresolvable-target outcomes (no POST attempted) return the event to `pending` with a `lastDeferred` timestamp — **attempts stay 0** and the event remains eligible forever until Agent D is safely idle.
- **Only actual POST-attempt failures count**, and those immediately transition the event to `ambiguous` — never auto-retried (see the ambiguity section), so the permanent-budget failure mode no longer exists.
- **Escalation:** ambiguous events older than the age cap (2 h default) escalate to `unresolved`, and every cycle logs an `ESCALATION` summary with the counts of unresolved/ambiguous events (visible in `status`; never silently discarded).

**Evidence:** R5 (six consecutive busy cycles → still `pending`, `attempts == 0`; then idle → delivered), C7a (rate-limited → pending, attempts 0), plus C3b's `attempts-not-consumed` assertion.

## R6 — MEDIUM: Test-runner path bug — CORRECTED

**Confirmed:** the v2 battery changed into its script directory and then resolved the directory a second time — `bash tests/run-tests.sh` from the orchestrator directory failed to find the mock daemon.

**Correction:** the script directory is resolved **once** from the invocation context (`BASH_SOURCE`) before any `cd`, and the leading `cd` was removed. **Both invocation styles now pass 94/94** — verified by executing `bash tests/run-tests.sh` from the orchestrator directory AND by absolute path in this delivery.

## Additional safety regression — supervisor interruption in the delivery window — CORRECTED

**Requirement:** an interruption after the daemon accepts a notification but before the delivered transition must not auto-resubmit; the event stays observable and reconcilable.

**Correction (supervisor v3):** every wake submission is persisted as `submitting` **before** the POST; the delivered/ambiguous transition happens after the verified acknowledgment. On any cycle, a `submitting`-state event (the crash window) is transitioned to **`ambiguous`** with an explanatory note — **never automatically re-submitted** — and remains visible in `status` for reconciliation against the daemon log's per-promptId evidence.

**Evidence:** AMB (an event pre-seeded in `submitting` → becomes `ambiguous`, **zero POSTs across two cycles**, stays ambiguous; the post-count assertion proves no re-submission).

## A defect found in my own round-1 code during this corrective (documented)

The v3 relay's `declared_ckpt` extraction died **silently** under `set -e -o pipefail` when the directive carried no CHECKPOINT line (grep's no-match exit propagated through the pipeline inside the command substitution, killing the script before the intended typed refusal). The same latent pattern existed in the supervisor's log-line and wake-promptId extractions. All five sites now carry explicit `|| true` guards with the emptiness checks carrying the semantics. The regression R4e (previously a silent exit 1 with no output) now produces the intended typed refusal.

## Battery (deterministic; both invocation styles)

`tests/run-tests.sh` v3: **94/94 PASS** — the 12 original T scenarios, the 9+3 F1–F5 C scenarios, and the 18 round-2 checks (R1a–R1c, R2a–R2d, R3, R3b, R4a–R4e, R5, AMB×5, C2b gate-refusal rollback). Mock v3 adds the R2 malformed-status modes, null-pending, and the post-reflecting `trackPosts` mode for the R3 concurrency regressions; every delivery assertion checks POST counts and event-store states, **never** the presence of a log line or an attempted POST.

## Residual risks (candid)

1. The client-side at-most-once window (round 1, unchanged): a crash between the daemon accepting a POST and the ledger/event confirm surfaces as `intent`/`submitting`/`submitted-unconfirmed`/`ambiguous` — all flagged, none auto-retried, reconciled against the daemon log. The daemon offers no idempotency keys.
2. The approvals registry binds and traces but does not cryptographically prove owner authorship (the Phase-3 signing proposal stands as an owner decision).
3. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface (fail-safe on drift: no events, no false wakes).
4. Poll-based watching (20 s) — the SSE upgrade path remains documented.
5. Permission waits still require owner action (by design).

## Production-activation recommendation

**CONDITIONAL GO** (unchanged in structure, now on the round-2 corrected basis): after independent acceptance of this corrective — the two critical/high clusters from both review rounds are corrected and regression-proven, every failure mode tested is fail-closed, and the architecture remains as previously validated end-to-end (two live wake PASSes on record, `eb973a06…` and `d6b8784a…`). Conditions: acceptance of this round, the owner's cron-retirement cutover authorization, and an initial bounded activation with the 7-day expiry discipline. No engineering authority is delegated by this recommendation.

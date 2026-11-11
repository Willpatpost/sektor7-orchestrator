# SEKTOR7 — PHASE 2 ROUND-4 SAFETY CORRECTIVE REPORT (E1–E3)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~21:20Z) · **Authority:** the owner-relayed independent review "Agent D Phase 2 v6 — Event Reliability Corrective" (VERDICT: HOLD; GO — targeted event-reliability corrective; review target `Willpatpost/sektor7-orchestrator` @ `phase2-v6-review` / `9139915cffee3a5d5ce62b7a3e7a31dbf0fd56d1`).
**Status:** corrective COMPLETE. **Unattended production activation remains NOT authorized. STOP for independent review.** Delivered on the new branch `phase2-v7-event-reliability` (based on the exact reviewed v6 commit).

---

## E1 — Critical: Event persistence failures must stop cursor advancement — CORRECTED

**Confirmed:** persistence failures previously relied on emergent `set -e`/pipefail
propagation with no explicit failure contract — and the run loop labeled scan
failures "non-fatal" with no cursor-hold guarantee made explicit or testable.

**Correction (supervisor.sh):**
- `event_set`/`event_patch` now **propagate serialization and atomic-rename failures
  explicitly** (distinct typed messages; orphaned temp files cleaned; return 1).
- `process_log_line` checks the write's result: a failure logs `EVENT PERSISTENCE
  FAILED` and returns 1 — **no "persisted" log after a failed write**.
- `scan_log_events` captures the processing pipeline's exit: on ANY failure it logs
  `SCAN HELD … cursor UNCHANGED` and **returns 1 BEFORE writing the offset** — the
  region (including the failed event) is retried on the next cycle once the store is
  repaired. The run loop labels the failure loudly (`EVENT-STORE/SCAN FAILURE — the
  cursor HOLDS`).
- The startup store init is fault-tolerant (an unwritable store no longer kills the
  supervisor; the store operations fail loudly instead).

**Evidence (deterministic fault injection):** E1a — the store corrupted to invalid
JSON: the cursor **held** at the exact pre-failure byte offset, **no false
persistence log**, `SCAN HELD` recorded; after repair, the completion was recovered
**exactly once** and the cursor advanced. E1b — the atomic-rename failure injected
by replacing the store with a directory: the cursor held, the failure logged,
recovery exactly once after repair.

## E2 — High: Log rotation must not silently discard new-file events — CORRECTED

**Confirmed:** the `cur < off` branch reset the cursor to the replacement file's
current length — completions already present in the replacement were skipped
entirely.

**Correction (supervisor.sh):** a detected shrink (replacement or truncation) now
**resets the cursor to 0 and rescans the new generation in full**: completions
already present in the replacement are processed (not skipped), and the
event-ID dedup (sessionId/promptId/outcome keys — stable across generations)
prevents re-firing events already recorded. The rotation is logged with both the
old cursor and the new size. The restart, byte-exact (V5-F4), and
persist-before-advance (E1) guarantees are unchanged — the rescan goes through the
same complete-line and persistence-failure discipline.

**Evidence:** E2a — a SHORTER replacement already containing a new completion: the
new-generation event **was not skipped** (recorded), the prior generation's event
preserved, the rotation logged. E2b — a replacement containing BOTH an
already-seen completion and a new one (entered through the genuine shrink path
via a prior-generation cursor): the seen event **not re-fired** (exactly one), the
new event recorded, the cursor advanced to the file's exact byte size.

**Residual limitation (stated per the directive's "if coverage cannot be
established"):** a replacement file LONGER than the current cursor with misaligned
content is **indistinguishable from an append** — the scanner begins at the old
cursor inside the new file's content, and events solely in the skipped prefix are
not recoverable from the single watched path. This was reproduced during the
corrective (the region began mid-`sessionId=`, the extraction correctly emptied,
the line was not processed) and is documented rather than papered over: closing it
requires either generation tracking from the daemon (rotated-file naming) or a
content-identity checkpoint — both beyond this corrective's scope.

## E3 — Notification-integrity hardening — CORRECTED

**Confirmed:** `notify` validated the metadata shape only — no destination binding
and no recorded-event binding.

**Correction (orchestrator.sh):**
- **Destination binding:** `notify` and `self-test-wake` resolve the target's roster
  name and require it to equal the **configured coordinator session**
  (`state/seats.json` `.coordinator`) — operational notifications bind ONLY to the
  coordinator (E3a).
- **Recorded-event binding:** the metadata must match a **recorded event** in the
  shared event store — seat, sessionId, promptId, AND outcome together (E3b/E3c);
  a missing/empty store refuses fail-closed.
- The fixed-text, non-authorizing notification model is unchanged (V5-F1); the
  supervisor's wakes flow through the same bound path (its metadata originates
  from the event store by construction).

**Evidence:** E3a (a non-coordinator destination → refuse, **zero POSTs**), E3b
(an unrecorded promptId → refuse, zero POSTs), E3c (a seat mismatch → refuse, zero
POSTs), E3d (the fully-bound path → delivered, exactly one POST).

## Documentation correction

The live `orchestrator/README.md` still described the removed free-text `prompt`
path — rewritten for the current command set (notify/self-test-wake with the E3
bindings, the removed-path refusal, the E1/E2 guarantees, and the residual
limitation above). The repository README is updated to point at the round-4
corrective branch. The historical corrective reports are preserved as records.

## Battery

`tests/run-tests.sh` v5: **164/164 PASS in both invocation styles** — the 127
round-1/2/3 scenario checks (with every direct-notify test now seeded into the
event store per the E3 binding) plus 37 round-4 checks (E1a×8, E1b×5, E2a×5,
E2b×8, E3×8, and the strengthened prior assertions). Every delivery assertion
checks POST counts and persistent event states, never log lines.

## Residual risks (candid)

1. The E2 append-indistinguishable replacement window (above) — documented, with
   the two possible closures named.
2. The client-side at-most-once window (rounds 1–3, unchanged): flagged
   intents/submitting/unconfirmed/ambiguous states reconciled against the daemon
   log; the daemon offers no idempotency keys.
3. The approvals registry binds and traces; cryptographic owner-authorship proof
   remains the Phase-3 signing proposal (an owner decision).
4. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface
   (fail-safe on drift).
5. Poll-based watching (20 s); the SSE upgrade path remains documented.

## Production-readiness assessment

**CONDITIONAL GO** — after independent acceptance of this round: all findings from
the four review rounds are corrected with regressions that reject each reproduced
failure; every tested failure mode is fail-closed; the two live wake validations
(`eb973a06…`, `d6b8784a…`) stand. Conditions: acceptance of this corrective, the
owner's cron-retirement cutover authorization, and an initial bounded activation
with the 7-day expiry discipline. No engineering authority is delegated.

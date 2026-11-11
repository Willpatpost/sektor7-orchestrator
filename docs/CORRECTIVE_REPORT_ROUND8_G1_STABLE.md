# SEKTOR7 — PHASE 2 ROUND-8 SAFETY CORRECTIVE REPORT (G1 Stability Refinement)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~23:45Z) · **Authority:** the owner-relayed independent review "Agent D v10 — Stable Log-Gap Identity Refinement" (VERDICT: HOLD — one narrow defect; GO — G1 stability corrective only; the reviewed target `phase2-v10-gap-identity` @ `a7a20d66ded5f500416be1e4872d4b0f0e8732a2`; G2 accepted at the source level).
**Status:** corrective COMPLETE. **Unattended production activation remains NOT authorized. STOP for independent review.** Delivered on the new branch `phase2-v11-stable-gap-id` based on the exact reviewed v10 commit.

---

## The finding — CORRECTED

**Confirmed:** the identity `sha256(oldCheckpointIdentity | newInode | newSize)` included `newSize` — a replacement log that grows (an ordinary daemon append) between the gap commit and the restart produced a different identity, duplicating the unresolved gap and its companion.

**Correction (supervisor.sh — one hash-input change):** the gap identity is now anchored to the **stable old checkpoint ALONE**: `transitionId = sha256(oldCheckpointIdentity)`. The old checkpoint is durable recovery provenance — it cannot change while the transition is being redetected (it was not advanced). Consequences, each per the directive's requirements:

1. **Repeated detection from the same unadvanced checkpoint reuses the same incident** — even after the replacement grows, across any number of retries: the identity input is unchanged, the exists-check returns early, and the existing gap and companion records are never touched (no state reset of `delivered`/`submitting`/`ambiguous`/`unresolved`).
2. **A genuinely new transition after the checkpoint advances receives a distinct identity** — the advanced checkpoint has a different cursor/inode/size/digest, so the hash differs.
3. **Multiple unobserved replacements while the checkpoint cannot advance are conservatively ONE unresolved coverage incident** — the correct semantics for a stall (never claim complete observation); the gap record's interval and the embedded reconciliation procedure remain the recovery path.
4. The atomic gap-and-companion transaction, the event deduplication, and the restart-safe legacy migration are all unchanged (the legacy identity was already anchored to the stable legacy offset/continuity values).

## Mandatory regressions (the precise interrupted-recovery sequence from the directive, plus the additional cases)

- **V11 (the precise sequence):** the old checkpoint established; the replacement committed with its gap + companion (2 POSTs: the companion + the recovered completion); the crash simulated (the old checkpoint restored); **a normal daemon append grows the replacement** (newSize changes, newInode preserved); the restart → **exactly one unresolved gap, exactly one delivered companion, no duplicate POST for the gap** (the POST count grows only by the newly discovered completion's own notification — asserted), and **the newly appended completion remains discoverable** (recovered exactly once).
- **V11 (repeated retries with additional appends):** a second crash + growth + retry → still one gap, still no duplicate gap-POST, the second appended completion discovered.
- **V11 (a separate transition after advancement):** after the checkpoint advances, a third generation → **two** distinct gap records.
- **V11b (the legacy-migration retry with a growing log):** the first migration commits; the interrupted state simulated (the checkpoint lost, the legacy state returned — the gap + companion already committed); the log grows; the retry → **one** gap (the stable legacy identity), **both** completions recovered (the original and the grown), the legacy files removed, the checkpoint re-established.
- **G1b (the ambiguous companion, from round 7 — unchanged and passing):** never blindly resent, zero POSTs, the gap stays unresolved.

*Test-design note (documented for the record):* the original V11b draft tried to inject a checkpoint-write failure by placing a directory at the checkpoint path — debugging revealed `mv` into a directory *succeeds* (it moves the temp file inside), so the injection didn't fail the write at all. The delivered regression simulates the interrupted state directly (the checkpoint removed, the legacy state restored after a successful commit) — modeling the same crash window truthfully.

## Battery

`tests/run-tests.sh` v9: **292/292 PASS in both invocation styles** — the 271 round-1..7 checks unchanged (no weakening, no removals) plus 21 round-8 checks. The source change is confined to the gap-identity hash input in `supervisor.sh` (one line + the comment); no orchestrator change.

## Remaining risks (candid, unchanged in structure)

1. The C1 prefix-identity boundary and the linear-prefix-hash cost (with the named Merkle/chunked upgrade path).
2. The client-side at-most-once window.
3. The Phase-3 cryptographic signing proposal (an owner decision).
4. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface (fail-safe on drift).
5. One-incident-per-stall (requirement 5's conservative semantics): a stall spanning multiple distinct replacements records a single gap covering the union interval — the reconciliation procedure (turn-index comparison + GitHub corroboration) is the recovery path for the individual replacements within it.

## Production-readiness assessment

**CONDITIONAL GO** — unchanged in structure: all findings from the eight review rounds corrected with regressions that reject each reproduced failure; the identity is now stable across every interrupted-recovery shape the reviews have specified. Conditions: acceptance, the owner's cron-retirement cutover authorization, and an initial bounded activation with the 7-day expiry discipline.

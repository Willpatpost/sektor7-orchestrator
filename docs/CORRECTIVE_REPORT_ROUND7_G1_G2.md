# SEKTOR7 — PHASE 2 ROUND-7 SAFETY CORRECTIVE REPORT (G1–G2)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~23:10Z) · **Authority:** the owner-relayed independent review "Agent D v9 Crash-Consistency Review" (VERDICT: HOLD — two narrow correctives; GO — G1 and G2 only; the reviewed target `phase2-v9-crash-consistency` @ `2728ddc6d90bb87a9493f1fa056ffdd016ac83e3`, one-commit ancestry and the six-file scope verified; P1's atomic transaction, P2's unified checkpoint, and P3's companion path accepted at the source level).
**Status:** corrective COMPLETE. **Unattended production activation remains NOT authorized. STOP for independent review.** Delivered on the new branch `phase2-v10-gap-identity` based on the exact reviewed v9 commit.

---

## G1 — Stable identity for log gaps across interrupted recovery — CORRECTED

**Confirmed:** the gap key used the current timestamp — a crash between the gap persistence and the checkpoint update left the old checkpoint in place; the restart redetected the same transition with a new timestamp and duplicated the gap and companion.

**Correction (supervisor.sh):** the gap identity is now **deterministic and persistent** — `transitionId = sha256(oldCheckpointIdentity | newInode | newSize)` truncated to 16 hex chars, where the old-checkpoint identity is the compact `{cursor, inode, size, digest}` of the checkpoint that detected the transition (stable across a redetection because the checkpoint was not updated) and the new file's inode/size are properties of the replacement itself. Reprocessing the same transition after a crash recomputes the **same identity** → the exists-check returns early ("LOG-GAP already recorded for this transition — no duplicate") → **no duplicate gap, no duplicate companion, no reset of a delivered notification** (the early return never touches the existing records). Genuinely distinct transitions produce distinct tuples (a repeat of the same tuple would mean the same checkpoint and the same file — which would not be detected as a transition at all), and the regression proves two successive replacements yield **two** separate gap records. The atomic gap+companion persistence is unchanged (one jq write).

**Evidence (the deterministic crash regression the directive specified):** G1 — a full gap cycle (the gap + companion committed, both notification POSTs made: the companion + the recovered completion), then the pre-gap checkpoint **restored** (simulating the crash that lost the checkpoint update): the recovery cycle redetects the transition and yields **exactly one gap, exactly one delivered companion, and no duplicate POST**; a genuinely distinct third generation then produces the **second** gap record. G1b — a log-gap companion seeded in the `submitting` (crash-window) state: the recovery marks it **ambiguous**, **zero POSTs**, the gap stays unresolved — never blindly retried.

## G2 — Make legacy checkpoint migration restart-safe — CORRECTED

**Confirmed:** the migration deleted `log-offset`/`log-continuity.json` before establishing `log-checkpoint.json` — a crash or write failure after the deletion left the environment looking like a fresh install (a baseline at EOF, silently skipping the current log's completions).

**Correction (supervisor.sh):** the migration order is inverted — **the durable recovery position is established BEFORE the legacy state is removed**:
1. The gap is persisted (the deterministic G1 identity; a failed migration redetected after a crash reuses it — no duplicate).
2. **The new checkpoint is written at cursor 0** (the conservative recovery position — a rescan of everything). If this write fails, `return 1` — **the legacy files remain**, and the next cycle reruns the full recovery (never a fresh baseline).
3. Only then are the legacy files removed.
4. A crash after step 2 but before step 3 leaves the durable checkpoint + stale legacy files: the checkpoint is authoritative (the normal path reads it), and the stale legacy files are **cleaned up safely** at the top of the next scan ("stale legacy checkpoint files removed — the atomic checkpoint is authoritative") — no fresh baseline, no lost completions.

**Evidence:** G2 — the interrupted migration (the legacy files intact, no checkpoint): the recovery records **one** gap (the deterministic identity), recovers the current-log completion **once**, establishes the checkpoint, removes the legacy files; a post-migration cycle adds nothing (still one gap, still one completion). G2b — the crash-after-checkpoint window (a durable checkpoint + stale legacy files): the legacy files cleaned, the completion recovered **once**, **no spurious gap**.

## Acceptance requirements

- All existing regression checks preserved: the 245 round-1..6 checks pass unchanged.
- **Battery v8: 271/271 PASS in both invocation styles** (the 245 prior + 26 round-7 checks: G1×10, G1b×5, G2×8, G2b×4 — every delivery assertion checking POST counts and persistent event states).
- The changes are limited to the two crash-recovery issues and their tests (the supervisor's gap identity + migration order; no orchestrator change required).

## Remaining risks (candid, unchanged in structure)

1. The C1 prefix-identity boundary (round 5) and the linear-prefix-hash cost (round 6, documented with the upgrade path).
2. The client-side at-most-once window (rounds 1–6).
3. The Phase-3 cryptographic signing proposal (an owner decision).
4. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface (fail-safe on drift).

## Production-readiness assessment

**CONDITIONAL GO** — after independent acceptance of this round: all findings from the seven review rounds are corrected with regressions that reject each reproduced failure; the crash-consistency invariants are atomic and now deterministic across interrupted recoveries. Conditions: acceptance, the owner's cron-retirement cutover authorization, and an initial bounded activation with the 7-day expiry discipline. No engineering authority is delegated.

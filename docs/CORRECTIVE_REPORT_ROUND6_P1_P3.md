# SEKTOR7 — PHASE 2 ROUND-6 SAFETY CORRECTIVE REPORT (P1–P3)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~22:30Z) · **Authority:** the owner-relayed independent review "Agent D v8 — Crash Consistency and Permission-Episode Corrective" (VERDICT: HOLD; GO — two targeted correctives and associated gap-notification handling; the reviewed target `phase2-v8-finalization` @ `f9d33e2ccf1b5bdbc9f94d1e727b57f4a1ef711d`, one-commit ancestry and the seven-file scope verified; C3/C4 accepted at the reviewed source level; the core C1 replacement detection present).
**Status:** corrective COMPLETE. **Unattended production activation remains NOT authorized. STOP for independent review.** Delivered on the new branch `phase2-v9-crash-consistency` based on the exact reviewed v8 commit.

---

## P1 — Permission episode and event persistence must be atomic — CORRECTED

**Confirmed:** the episode number derived from the count of existing permission-wait events — a state-write failure after the event write genuinely produced a duplicate on the next cycle (the claimed self-healing was incorrect).

**Correction (supervisor.sh):** the permission-episode state (`permState`) now lives **inside the event-store document**, and the transition is **ONE atomic jq transaction** (temp+mv): the episode-event insertion and `permState[sid] = {waiting: true, episodes: N}` commit **together** — a failure before commit leaves BOTH unchanged (logged `PERM-EPISODE TRANSACTION FAILED … both the event and the state are UNCHANGED`); a successful commit preserves BOTH. The episode number comes from the **authoritative permState counter** — never from the count of existing events alone. The clearance is its own atomic transaction. A legacy partial state (the event exists, the state absent — reachable only from the pre-P1 code) is **repaired without a duplicate**: the exists-check suppresses the event re-insertion and the transaction writes only the state.

**Evidence:** P1 — the legacy crash window (the episode-1 event seeded, no permState): the repair cycle yields **exactly one event** with the state repaired to `{waiting: true, episodes: 1}`; clearance; episode 2 → **two distinct events** with the counter at 2 (the number from the state, not the count). P1b — the transaction write failure (a corrupted store): **the store unchanged**; after repair, **exactly one event AND the state committed** (both together). The prior distinct-episode/no-duplicate tests (V5F3a–d, C2) all pass.

## P2 — Make log cursor and continuity state crash-consistent — CORRECTED

**Confirmed:** `log-offset` and `log-continuity.json` were written separately — a crash between them left an inconsistent pair, and the recorded-cursors-disagree case silently bypassed continuity verification.

**Correction (supervisor.sh):** the cursor, inode, size, and prefix digest persist as **ONE atomic checkpoint** (`state/log-checkpoint.json`, temp+mv). A crash leaves either the complete prior checkpoint or the complete new one — a torn state is impossible. On startup, a **legacy split state** (log-offset/log-continuity from the pre-P2 code) is recovered **conservatively**: a structured continuity gap is recorded (the never-observed interval of the legacy generation), the legacy files are removed, and the scan restarts from 0 — **continuity validation is never silently bypassed**. The E1 hold now leaves the entire checkpoint unwritten (the cursor AND the continuity state stay exactly where they were). The C1 digest, byte-exact, dedup, and persistence guarantees are unchanged.

**Evidence:** P2 — the torn legacy state (offset written, continuity absent): the gap recorded, the completion in the new file recovered, the legacy files removed, the new checkpoint written. P2b — a replacement AFTER the interrupted state: the new completion recovered (nothing silently disappears). The C1s/C1e/C1l/C1a replacement regressions and the E1a/E1b fault injections all pass on the checkpoint.

## P3 — Surface log-gap events to Agent D — CORRECTED

**Confirmed:** the gap record was inserted as `unresolved`; the wake loop selects only `pending` — the coordinator was never notified.

**Correction (supervisor.sh + orchestrator.sh):** `persist_log_gap` now writes the gap record AND a **companion notification event** in the same atomic store transaction: the gap record (state `unresolved`) carries the interval, the inodes, and the reconciliation procedure; the companion (`kind: log-gap`, state `pending`, bound to the coordinator session as both source and seat — the seatOf fallback identity) is what the wake loop delivers through the standard `notify` path (the fixed non-authorizing text, the full E3/C4 binding: the destination must be the coordinator, the metadata must match the recorded companion, the source seat must match the configured identity). The orchestrator's `validate_meta` accepts the `log-gap`/`log-generation-change` kind/outcome pairing. **The gap record itself stays unresolved until manual reconciliation — notification does not resolve it.** Restart dedup: the companion's key includes the gap key; once delivered, it is never re-fired.

**Evidence:** P3 — a genuine generation change: the companion delivered (the POST count includes both the companion and the recovered completion), the gap record preserved `unresolved`, and a restart cycle re-posts nothing. P3b — the busy-session deferral: zero POSTs while the coordinator is busy with the companion `pending`; delivery once idle; the gap still unresolved.

## Additional acceptance requirements

- **The performance documentation is corrected:** hashing the entire growing log prefix is **linear in the prefix size** (not logarithmic — the round-5 report's "O(log size)" claim was wrong and is retracted here; the code comment now states it plainly). The cost is accepted deliberately: the C1 correctness requirement (detecting an equal-size replacement differing anywhere before the cursor) demands the whole-prefix digest. If prefix sizes grow beyond practicality, a Merkle/chunked digest is the named upgrade path — out of scope here.
- All previously accepted tests preserved: the 211 round-1..5 checks pass unchanged in meaning (the perm-state and log-offset assertions updated to the new atomic homes — the C2-state assertion now genuinely fails on an incorrect advance, per the directive).
- **Battery v7: 245/245 PASS in both invocation styles** (the 211 prior + 34 round-6 checks: P1×8, P1b×5, P2×6, P3×8, P3b×5, and the corrected prior assertions). Every delivery assertion checks POST counts and persistent event states.

## Residual risks (candid)

1. The C1 prefix-identity boundary (round 5, unchanged): a rewrite leaving `[0, cursor)` byte-identical is indistinguishable from an append; the gap record + reconciliation cover the unknowable cases.
2. The linear-prefix-hash cost (above) — documented, accepted, with the upgrade path named.
3. The client-side at-most-once window (rounds 1–5, unchanged).
4. The Phase-3 cryptographic signing proposal (an owner decision, out of scope).
5. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface (fail-safe on drift).

## Production-readiness assessment

**CONDITIONAL GO** — after independent acceptance of this round: all findings from the six review rounds are corrected with regressions that reject each reproduced failure; every tested failure mode is fail-closed; the crash-consistency invariants (P1/P2) are atomic by construction. Conditions: acceptance of this corrective, the owner's cron-retirement cutover authorization, and an initial bounded activation with the 7-day expiry discipline. No engineering authority is delegated.

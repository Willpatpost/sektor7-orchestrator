# SEKTOR7 — PHASE 2 ROUND-5 SAFETY CORRECTIVE REPORT (C1–C4)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~21:55Z) · **Authority:** the owner-relayed independent review "v7 Event Reliability — Finalization Corrective" (VERDICT: HOLD; GO — targeted event-reliability and integrity corrective only; the reviewed target `phase2-v7-event-reliability` @ `e7d131e2e8cebd76340228e1321d520f5173b1fb`, one-commit ancestry and the seven-file scope verified).
**Status:** corrective COMPLETE. **Unattended production activation remains NOT authorized. STOP for independent review.** Delivered on the new branch `phase2-v8-finalization` based on the exact reviewed v7 commit.

---

## C1 — Resolve incomplete log-generation coverage — CORRECTED

**Confirmed:** replacement detection was shrink-only (`cur < off`); a same-size or larger replacement could silently skip completions before the old cursor.

**Correction (supervisor.sh):** a **full-prefix continuity digest** — each cycle records `{inode, size, cursor, prefixDigest}` where the digest is the sha256 of the ENTIRE prefix `[0, cursor)`; the next cycle recomputes the digest of the same prefix and compares:
- **Any digest mismatch** (a rewrite anywhere before the cursor — regardless of size or inode) is a **generation change**: the scanner persists a **structured log-gap record** into the event store (`kind: log-gap`, the never-observed interval `[cursor, lastSize)` of the previous generation, the old/new inodes, `state: unresolved`, never auto-resolved, visible in `status`), then **rescans the new generation from byte 0** with the existing event-ID dedup. The gap record embeds the **reconciliation procedure**: compare each watched session's turn-index (promptIds + timestamps) against the recorded events — a completion promptId present in a turn-index but absent from the store within the window was unobserved — corroborated with GitHub branch/CI state. **An uncertain interval is never represented as observed.**
- An **inode change with a matching digest** is a content-continuous copy-rotation — no gap, the cursor stands.
- The initial baseline now records the continuity snapshot, so a replacement immediately after a baseline is detected too.
- The whole-prefix digest (not a trailing window) was chosen deliberately: during the corrective, a trailing 64-byte window was proven insufficient — an equal-size replacement differing only EARLIER in the line escaped it (the regression caught this before delivery). `head -c | sha256` over an appended-to log's prefix is O(log size) per cycle and cheap in practice.

**Evidence (no artificial cursors anywhere):** C1s — a genuine **shorter** replacement containing an unobserved completion: the gap recorded (unresolved), the unobserved completion recovered, the prior event preserved. C1e — a genuinely **equal-size** replacement (byte-count-equal lines, verified in the test) with a swapped-in unobserved completion: the gap recorded, the completion recovered. C1l — a genuinely **longer** replacement (asserted larger than the REAL cursor from the prior cycle) with rewritten content: the gap recorded, both unobserved completions recovered. C1a — the pure-append control: no spurious gap, the appended event recorded.

**Residual limitation (stated):** an in-place rewrite that leaves the entire prefix `[0, cursor)` byte-identical while changing only bytes beyond the cursor is indistinguishable from an append — but such a rewrite cannot hide a completion before the cursor (the prefix is the boundary of the already-observed), and completions after the cursor are scanned normally. The genuinely unknowable case (events in a removed prior generation never scanned by this process) is covered by the gap record's reconciliation procedure.

## C2 — Make permission-wait event persistence recoverable — CORRECTED

**Confirmed:** `perm_state_set` recorded `waiting=true` before `event_set` confirmed persistence — a failed store write left the episode marked recorded with no event, permanently suppressed.

**Correction (supervisor.sh):** the ordering is inverted and the episode number **derived from the event store** (`perm_episode_next` counts the sid's existing permission-wait events): the **event persists FIRST**; only on success does the state write run — and the state write is now a self-healing cache: if it fails, the next cycle recomputes the SAME store-derived episode number and the `event_exists` check prevents any duplicate. **The invariant holds: a permission episode is never considered recorded until its event is durably persisted.** A failed event write logs `PERM-EVENT PERSISTENCE FAILED`, does not advance the state, and returns for retry.

**Evidence:** C2 — the first observed wait with a corrupted store: **no event, the state not advanced**; after repair: **exactly one** event; clearance; episode 2 → **two distinct events** (the V5-F3 distinct-episode and no-duplicate behaviors preserved).

## C3 — Distinguish no-matching-lines from processing failure — CORRECTED

**Confirmed:** the scan pipeline used `grep` under `pipefail` — a complete region with no completion lines made grep exit 1 and the scanner treated the ordinary condition as a persistence failure (the cursor would never advance; this was a defect my E1 change introduced and the prior battery had not covered).

**Correction (supervisor.sh):** the filter is **separated from the processing** — the matches are extracted first (`grep … || true` into a variable); an empty match set is an ordinary successful scan that advances the cursor; only the processing of a MATCHED line can fail and hold it. Malformed input (a line matching the pattern but carrying no extractable ids) produces no event and no failure — it is a non-material line, advanced past.

**Evidence:** C3 — a filler-only region: **no SCAN HELD, the cursor advanced**; C3b — a matching line with no ids: no event, no hold, advance; the E1a/E1b fault-injection regressions (a matched event failing persistence holds the cursor) unchanged and passing.

## C4 — Finish notification identity and configuration binding — CORRECTED

**Confirmed:** the recorded-event comparison omitted `kind`; the source/session binding was not verified against the configured seat identity; the repository's `examples/seats.json` predated the coordinator configuration.

**Correction (orchestrator.sh + supervisor.sh + examples):**
- `validate_meta` enforces the **kind/outcome pairing** (worker-turn ↔ completed|failed; permission-wait ↔ waiting) — contradictory combinations refuse at the shape gate.
- `require_recorded_event` now includes **`kind`** in the recorded-event match AND verifies the **source binding**: the metadata's seat must equal the **configured `seatOf` identity** of the metadata's source session (resolved through the roster; the name itself when unconfigured).
- The supervisor's events (worker-turn and permission-wait) now record the **seatOf label** as the seat — the same identity the binding verifies.
- **Startup configuration validation:** the supervisor refuses to run when no coordinator is configured or the configured coordinator does not resolve in the live roster (fail closed), logging the validation on success.
- `examples/seats.json` updated with the complete configuration (watch, seatOf, coordinator) and the validation documented.

**Evidence:** C4a (a kind mismatch → refuse, zero POSTs), C4b (a contradictory kind/outcome → refuse at the shape gate, zero POSTs), C4c (a source-seat mismatch → refuse, zero POSTs), C4d (the valid configuration end-to-end → delivered, one POST), C4e (no coordinator configured → the supervisor refuses to run).

## Battery

`tests/run-tests.sh` v6: **211/211 PASS in both invocation styles** — the 164 round-1..4 scenario checks (with the E3c seat-mismatch regression now asserting the C4 source-binding message) plus 47 round-5 checks (C3×7, C1s×8, C1e×4+1, C1l×4, C1a×3, C2×7, C4×10). Every delivery assertion checks POST counts and persistent event states.

## Residual risks (candid)

1. The C1 prefix-identity boundary (above) — the gap record + the reconciliation procedure cover the unknowable cases explicitly.
2. The client-side at-most-once window (rounds 1–4, unchanged).
3. The approvals registry binds and traces; cryptographic owner-authorship proof remains the Phase-3 signing proposal (an owner decision, out of scope here).
4. The daemon-log line format remains a stable-but-internal qwen 0.24.5 interface (fail-safe on drift).
5. Poll-based watching (20 s); the SSE upgrade path remains documented.

## Production-readiness assessment

**CONDITIONAL GO** — after independent acceptance of this round: all findings from the five review rounds are corrected with regressions that reject each reproduced failure; every tested failure mode is fail-closed; the two live wake validations stand. Conditions: acceptance of this corrective, the owner's cron-retirement cutover authorization, and an initial bounded activation with the 7-day expiry discipline. No engineering authority is delegated.

# SEKTOR7 Orchestration — Agent D Wake-Up Self-Test Results

**(Phase 2 review requirement §4: the pending harmless Agent D wake-up validation,
its eight required data points, and the interference analysis.)**

## Status at bundle time (2026-11-11 ~18:55Z) — REVISED 19:20Z with the true root cause

The self-test (`supervisor.sh run --self-test-wake`) posts exactly ONE clearly-labeled,
authorization-free test prompt to the Agent D session through the same gated path used
for real coordination, then exits. Three launches have occurred:

- **Launch 1 (18:32:11Z, background task `bg_bc8fd98f`):** stopped cleanly at ~18:45Z
  (owner-directed cancellation). No prompt posted.
- **Launch 2 (18:49:19Z, background task `bg_664fefdf`):** timed out at ~19:19Z after
  its 30-minute bounded window. No prompt posted.
- **Launch 3 (19:21:28Z, DETACHED via the double-fork orphan — `bash -c 'setsid nohup … & disown'`,
  outside any session's background task registry): **PASS — the wake fired end-to-end.**
  Full evidence chain, all cross-verified:
  - Gate at post time: `gate: state=idle pending=0 permWait=false questionWait=false activePrompt=false` (19:21:59Z, captured in `state/supervisor.log`) — **Agent D was genuinely idle before activation**.
  - Exactly ONE prompt: **promptId `eb973a06-f220-4f4c-a131-a481b4bc3d29`** (202-accepted; identical in `state/self-test-wake-response.json`, the single `state/wake.log` entry, and the daemon log's `prompt enqueued` line for the Agent D session at 19:21:59.894Z).
  - The existing Agent D session processed the prompt (the wake arrived as the session's next user turn, in the SAME conversation — context preserved; no session replace/resume involved).
  - The supervisor exited cleanly after the single post (pid 2754009 gone; `SELF-TEST: wake posted successfully` logged).
  - No cron interference in the successful run (the wake fired ~30 s after the prior turn ended; the next cron fire was 19:43).
  - Duplicate suppression held: one wake, one log entry, no overlapping prompts.
- **Launch 4 (19:43:40Z, the CORRECTED v2 code, same double-fork detached form): **PASS —
  the F1–F5 corrective's live validation.** Evidence chain:
  - Spawned 19:43:40Z; gate opened on genuine idle (`state=idle pending=0 permWait=false questionWait=false activePrompt=false`); **wake posted 19:43:56Z** — 16 s after spawn, arriving as the Agent D session's next turn (this verification turn IS the wake; context preserved).
  - **promptId `d6b8784a-8081-4bb1-a528-e346e63e3bc9`** (authoritative in the daemon log's `prompt enqueued` line at 19:43:56.226Z; the single new `wake.log` entry `2026-11-11T19:43:56Z self-test-wake`; `SELF-TEST: wake posted successfully` in supervisor.log).
  - The wake traveled the CORRECTED paths end-to-end: the label-enforced non-authorizing `prompt` command (F3), the strict 202 + UUID validation (F4), the submit lock (F5), the single-instance run lock (F5), and the gated wake — one post, no duplicates, clean exit.
  - Minor gap noted honestly: the v2 self-test no longer writes `self-test-wake-response.json` (that file still holds launch 3's response); the daemon log is the delivery authority and carries launch 4's promptId. No correctness impact (no dedup depends on the file); noted for any future polish.
  - No cron interference (the wake won the idle window at 19:43:56 ahead of the 19:43 cron fire).

**ROOT CAUSE OF LAUNCHES 1-2 NOT FIRING (source-verified, correcting the earlier
cron-interference analysis — cron timing was real but secondary):** the daemon's
session-liveness model (qwen 0.24.5, `chunks/chunk-F4ERRMCO.js`) computes
`activeWorkState` via `entryHasLocalWork(entry) = entry.pendingPromptCount > 0 ||
entry.pendingAgentNotificationCount > 0 || !!entry.backgroundTurn`. **A session with a
running background task reports `active` even with no prompt and nothing pending.**
The self-test was launched as a background shell OF Agent D's own session — so while it
ran, Agent D's `activeWorkState` could never return to `idle`, and the wake gate
(`state=idle`) could never open. **A structural catch-22: the waker must not be a
tracked background task of the session it wakes.** (The cron's idle-moment firing and
the seconds-scale turn gaps documented earlier were genuine additional consumers of
idle windows, but the primary blocker was this self-hold.)

**The correction is the production form the readiness report §13 already specified:**
the supervisor runs DETACHED (`setsid nohup … &`, not registered to any session's task
list) — launch 3 uses exactly that form. This finding is a genuine Phase 2 review item:
in production, the supervisor must never be launched as a session-tracked background
task of any session it may need to wake (Agent D included).

## The eight required data points

1. **Was Agent D idle before activation?** — Enforced by construction: the self-test
   polls the orchestrator `wake-gate` every 5 s and posts ONLY when the daemon reports
   `activeWorkState=idle`, `hasActivePrompt=false`, zero pending prompts, no permission
   wait, and no user-question wait. A gate refusal means NO post (observed throughout
   launch 1 — the fail-closed proof). The eventual wake's promptId will timestamp a
   state in which the gate had just passed.
2. **The event that caused the supervisor to act** — the self-test's single synthetic
   event (`--self-test-wake` mode), deliberately substituting for a watched-seat
   lifecycle event so no real worker state is consumed. In production the triggering
   events are watched-seat `prompt turn completed/failed` (daemon log, promptId-deduped)
   and watched-seat permission waits — the same wake path.
3. **Exactly one prompt?** — Enforced by the mode's structure: the loop posts once and
   `exit`s; the at-most-once relay ledger and `state/wake.log` (one line per wake)
   provide the record. Mock battery T9b/T9c additionally prove duplicate-line
   suppression (one event wake despite a duplicated log line; rescan adds nothing).
4. **Did the existing Agent D session process the prompt?** — To be evidenced by the
   wake turn itself (the arriving prompt IS this test's success signal; Agent D will
   verify its promptId against `state/self-test-wake-response.json` + the daemon log's
   `prompt turn completed` line and record it here).
5. **Was conversation context preserved?** — Yes, by the daemon's design and by all
   prior evidence: prompts enqueue into the existing session conversation (no
   replace/resume-with-new-context). Demonstrated repeatedly on Agent B (wake test
   `7fdd3239…` → F8 relay `07ef6f70…` → the accepted F8 delivery executed with B's full
   B-R1a1 context) and on Agent D itself (every owner directive today, including the
   Phase 2 directive, arrived through this same POST path into this same conversation).
6. **Did concurrent cron activity interfere?** — **YES, materially — documented as a
   real finding.** The 30-minute cron pilot (`eeat3vcp`) fires only while the session is
   idle, and fires THE MOMENT idleness is detected; today's cadence (deferred cron
   fires, monitor-notification turns, and promptly-arriving owner directives) left only
   seconds-scale idle gaps, which the self-test's 5-second poll repeatedly missed.
   Diagnostic evidence at 18:44Z: `gate: state=active pending=1 …` (the in-flight
   prompt counts as pending; the pending entry at that moment was the review directive
   itself, `fdb8687a…`). Conclusion: cron/supervisor coexistence is safe (no overlap —
   the shared gate serializes) but adds wake latency; on Phase 2 acceptance the cron
   should be retired in favor of the supervisor (as planned in the Phase 2 directive
   §6), which wakes on events rather than on wall-clock idle detection.
7. **Did duplicate suppression work?** — Yes: no duplicate wake was ever posted
   (launch 1 posted nothing; the wake log and ledger remain single-entry-per-event by
   construction); the mock battery proves the dedup logic (T9b: one wake for a
   duplicated event; T9c: rescan no-op; T6b: duplicate directive refused).
8. **Did the supervisor terminate cleanly?** — Launch 1: yes — stopped via the
   owner-visible task cancellation (clean SIGTERM drain; no state corruption; state
   files consistent). Launch 2 self-terminates after one post (or the 30-minute
   bounded timeout) by design. The production `stop` command uses a flag file checked
   each cycle (clean exit within one interval).

## Safety notes

- The test prompt is labeled as carrying NO authorization and requests no engineering
  action; it cannot be mistaken for an owner directive (see
  `AUTHORIZATION_INTEGRITY.md` for why transport ≠ authorization).
- No persistent supervisor was installed or activated; the cron pilot remains the only
  standing watch, unchanged in frequency and lifetime.

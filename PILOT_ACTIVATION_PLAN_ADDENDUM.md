# SEKTOR7 — Pilot Plan Operational Addendum
## Resolving the three review points on the seven-day pilot plan

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-12 · **Basis:** the technical-lead pilot-plan review ("PILOT DESIGN CONDITIONALLY ACCEPTABLE — ACTIVATION: HOLD — NO GO YET"; the three-point addendum requirement; the recommended cutover choices).
**Constraints honored:** the accepted v11 runtime source is UNMODIFIED (verified byte-identical to `02fd483` after all work below); no supervisor activation, no cron retirement, no persistent watchdog launched, no engineering authority altered. The two new artifacts live in `~/.qwen/sektor7-coordination/pilot/` — coordination documents outside the accepted tree. No new review archive (per the directive); this addendum + the on-disk test record are the evidence.

---

## §1 Hard expiry — the independently enforced Day-7 shutdown

**The mechanism (chosen because nothing else exists here):** verified this turn — **no systemd** (PID 1 is the container entrypoint `coder`, not systemd; `systemctl` cannot operate) and **no atd** (`at` not installed). The qwen scheduled-task mechanism delivers prompts to sessions — it depends on the daemon and an Agent D turn, which is exactly the reminder-based enforcement the review rejected. The only independent mechanism available is a **detached deadline fuse**: a double-fork-orphan process whose sole authority is to terminate the supervisor at the deadline and leave evidence. It observes nothing but the clock — it is a fuse, not a watchdog. It cannot POST to the daemon, restart anything, touch the cron, or write the accepted sources.

**The artifact:** `~/.qwen/sektor7-coordination/pilot/expiry-fuse.sh` (full text on the review branch; `usage: expiry-fuse.sh DEADLINE_EPOCH [SUPERVISOR_PID [SUPERVISOR_STARTTIME]]` — the paired launcher passes all three).

**Exact activation-time procedure (part of the owner's activation GO — the fail-closed paired launcher `pilot/paired-launch.sh`, O1-corrected and 37/37 test-verified):**

```bash
# Day 0, after preflight — ONE command launches and verifies the pair:
bash ~/.qwen/sektor7-coordination/pilot/paired-launch.sh 604800
```

The launcher (source on the review branch; the full behavior proven in `pilot/paired-launch-test.sh`): launches the supervisor and the fuse as ONE unit via the proven double-fork orphan form; discovers each PID by pattern and then **strictly verifies identity — the exact argv from `/proc/<pid>/cmdline` (never a loose substring; the transient double-fork intermediate fails the check) plus the process start time from `/proc/<pid>/stat`**, captured and recorded in `pilot/launch-record.json`; asserts exactly one validated match (a pre-existing instance = an abort, never a guess); verifies the supervisor's loop-start and coordinator-configuration lines in the state log (the intended deployment); verifies the fuse is alive, carries the intended deadline in its argv, and recorded `fuse armed: deadline_epoch=<N>` in its log. **On ANY failure at any step: the stop-flag is set (state-dir scoped — it stops every supervisor reading this state dir, including one that cannot be individually identified), the identity-verified kill fallback applies only to OUR recorded PID, an unpaired fuse is torn down by its verified identity, the stale stop-flag is removed only when nothing remains running, ALL state and logs are preserved (nothing deleted — forensic evidence intact), the failure is recorded with its reason, and the launcher exits 1.** The deliberate fuse-launch-failure demonstration (test L2): a broken fuse path → the supervisor stopped cleanly, the failure record written, state preserved — 9/9 assertions.

**Termination escalation (in the fuse, all steps logged with UTC timestamps):**
1. **Primary — the stop-flag:** `supervisor.sh stop` (the accepted v11 interface, unchanged); a running supervisor exits cleanly within one cycle (≤ ~20 s + cycle). The fuse waits up to `SEKTOR7_FUSE_TERM_WAIT` (default 60 s).
2. **Fallback — `kill -TERM`** by the recorded PID, only after the process identity verifies: **the exact argv** (`bash <script> run` from `/proc/<PID>/cmdline`) **AND the recorded process start time** from `/proc/<PID>/stat` when provided by the launcher (**PID-reuse protection over the 7-day window** — an unverified PID is NEVER signaled); then up to `SEKTOR7_FUSE_KILL_WAIT` (default 30 s) more. **Test-verified (L3):** a long-interval supervisor that cannot consume the flag in time is stopped by the identity-verified TERM — `method: stop-flag+TERM`, `exitVerified: true`, the stale flag removed after the verified kill.
3. **Last resort — `kill -KILL`**, same verification. *Documented but untested* (would require a TERM-surviving process; the escalation logic above it is tested).
4. If the identity does not verify: **no signal** — the stop-flag stands, the ambiguity is recorded, and a human decision is required (never a blind kill). *Documented; the refusal path is exercised implicitly by the identity-check unit logic.*

**Timing bound:** the fuse polls the clock every `SEKTOR7_FUSE_POLL` (default 300 s) — the stop executes within 5 minutes after the exact Day-7 deadline. If the supervisor is already dead at the deadline, the fuse removes any stale stop-flag (so it cannot sabotage a future launch) and records `already-stopped`.

**Verification procedure and expected evidence:**
- `~/.qwen/sektor7-coordination/pilot/expiry-executed.json` — `{deadline, executedAt, method, supervisorRunningAtDeadline, exitVerified}`; expected at Day 7: `method: "stop-flag"`, `exitVerified: true`.
- `pilot/expiry-fuse.log` — `DEADLINE REACHED` → `stop-flag set` → `supervisor terminated (method=stop-flag)` lines.
- The supervisor's own `state/supervisor.log` — `stop-flag observed — exiting cleanly`.
- `pgrep -f 'orchestrator/supervisor.sh run'` returns nothing.
- Agent D's next turn records the outcome in STATUS.md; the owner can read the JSON directly. **None of this depends on the daemon, a session turn, or the cron.**

**End-to-end verification ALREADY PERFORMED (this turn, mock-wired, production untouched):** `pilot/fuse-test.sh` — **15/15 PASS** (`pilot/fuse-test-record.txt` holds the output + both evidence JSONs + the fuse and supervisor logs). Test A: the REAL v11 `supervisor.sh run` (mock daemon, test state dir) launched, ran its cycles, was stopped by the fuse at a short deadline via the stop-flag — the supervisor's log shows `stop-flag observed — exiting cleanly`, the evidence records `method: stop-flag, exitVerified: true`, no residual flag, state preserved, both processes exited. Test B: the already-stopped branch removed a stale flag and recorded `already-stopped`. Two defects were found and fixed during test development (both documented in the record): the fixed 300 s poll overshooting short test deadlines (now the `SEKTOR7_FUSE_POLL` override; production keeps 300 s), and `jq -n` object shorthand emitting nulls (fixed to explicit variable refs — run 2's nulls are preserved in the record for comparison).

**Shared-fate + pairing discipline:** a pod restart kills the supervisor and the fuse together (both are orphans under init — but the pod's process namespace dies wholesale). Any post-restart relaunch is a **paired relaunch** (supervisor + a fresh fuse with a new deadline), executed only per the owner's standing activation or an explicit instruction. The daily check asserts **both-or-neither**: a solo supervisor (dead fuse) is itself a finding → Agent D stops it (the §6 runbook) and reports.

---

## §2 Failure monitoring — detectors, triggers, recipients, executors (the honest map)

**Classification first (per the review's demand):** the v11 source contains autonomous **preventions** and autonomous **escalations**, but **no autonomous rollback**. The pilot has exactly **one independently enforced rollback: the Day-7 fuse (§1)**. Every T1–T10 rollback below is executed **by Agent D at its next turn** (or by the owner) — never claimed as autonomous. Nothing in the v11 source was changed to alter this.

**In-source autonomous preventions (always on; no detector needed):** the fail-closed wake gate (T3's prevention — refuses on busy/pending/permWait/questionWait); the E3 destination binding (T2's prevention — every notify is bound to the configured coordinator AND a recorded event, mismatches refuse pre-POST); the at-most-once event store with UUID-validated acknowledgments (T1's prevention — event-ID dedup, delivered never re-sent, ambiguous never retried); the 4/hour wake cap (T8's prevention); the run lock (single instance); the E1 cursor-hold (a persistence failure never advances the checkpoint — T4's containment).

**In-source autonomous escalations:** the log-gap companion (T9 — the supervisor wakes the coordinator about the gap itself); permission-episode events (a new wait after clearance wakes the coordinator); `recover_and_escalate` (ambiguous→unresolved aging, logged every cycle, never discarded).

**Detection cadence:** Agent D turns — supervisor wakes (seat events), the cron heartbeat while alive (≤30 min latency), or owner turns. Worst-case exposure between a breach and the executing turn is bounded by the in-source caps: ≤4 gated, coordinator-bound wakes/hour.

| # | Threshold | Actual detector | Trigger (exact observable) | Escalation recipient | Rollback executor | Independent? |
|---|---|---|---|---|---|---|
| T1 | Duplicate notification | Agent D at turns | `jq '[.events[] \| select(.state=="delivered")] \| length' state/events.json` cross-checked against the daemon log: each `wakePromptId` enqueued exactly once | owner report | Agent D (§6 runbook) | prevention in-source; detection manual |
| T2 | POST to a non-coordinator | Agent D at turns | every `wakePromptId` in the store + `state/wake.log` resolves to `coder-a3`'s sessionId | owner report | Agent D | prevention in-source; detection manual |
| T3 | Gate failure (wake during busy/wait) | Agent D (structurally: a wake prompt enqueued while an Agent D turn is active — visible in the daemon log timestamps); the gate's refusal lines in `supervisor.log` | any wake arriving mid-turn | owner report | Agent D | prevention in-source |
| T4 | Checkpoint regression / store corruption | Agent D at turns | `jq . state/log-checkpoint.json && jq . state/events.json` parse; cursor monotonic vs `supervisor.log` | owner report | Agent D | E1 containment in-source |
| T5 | Token leakage | Agent D at preflight + every turn | `TOK="$(cat ~/.qwen-serve-token)"; grep -rF -- "$TOK" ~/.qwen/sektor7-coordination/pilot/ orchestrator/state/ orchestrator/*.log 2>/dev/null` (the value is read into the variable and never printed) | owner report — IMMEDIATE | Agent D | none in-source (manual scan) |
| T6 | Crash loop | process-absence check at every Agent D turn + the cron heartbeat | `pgrep -f 'orchestrator/supervisor.sh run'` empty while the pilot is active | owner report | **none needed — no restart mechanism exists; a dead supervisor stays dead** (crash loops are structurally impossible; the risk is coverage loss) | n/a |
| T7 | Ambiguous/unresolved >24 h | in-source escalation + Agent D at turns | `ESCALATION: N unresolved…` in `supervisor.log` every cycle; `jq '.events \| to_entries[] \| select(.value.state=="unresolved"\|"ambiguous")'` | the store itself is the persistent alarm | Agent D (rollback if unreconciled) | escalation in-source |
| T8 | Rate pinned at cap | Agent D at turns | `wakes_recent` logic over `state/wake.log`; sustained 4/hour without seat activity in the daemon log | owner report | Agent D | cap in-source; detection manual |
| T9 | Log gap unreconciled >48 h | **in-source autonomous** (the gap companion IS a wake to the coordinator) | the gap record + companion in the store; `supervisor.log` gap lines | Agent D is woken directly | Agent D (reconcile via the documented turn-index + GitHub procedure; rollback at 48 h) | detection autonomous; rollback manual |
| T10 | Prefix-hash cost | Agent D at turns (advisory) | cycle duration from `supervisor.log` timestamps; `stat -c %s ~/.qwen-serve.log` | advisory note | n/a (documented linear cost; Merkle upgrade path named) | none |

**The plain statement the review required:** *the only autonomous rollback in this pilot is the Day-7 fuse. T1–T10 rollbacks are executed by Agent D at its next turn — with the cron heartbeat preserved, detection latency is ≤30 minutes; without it, detection is event-driven (a seat event, a gap companion, or an owner turn). Between a breach and that turn, exposure is bounded by the in-source caps (gated, coordinator-bound, ≤4/hour). If the daemon itself is down, no wake can be delivered at all — the fuse remains the terminal guarantee.*

---

## §3 Dry-run state — acknowledged, snapshotted, reconciled

**Acknowledged (source-verified this turn, lines cited):** `--dry-run` suppresses **only the delivery POSTs** — `deliver_pending` is the single DRY-branching function (`DRYRUN would attempt delivery`, no `submitting` transition, no POST). The checkpoint writes (`checkpoint_write` in both the fresh-baseline and advance paths), event persistence (`process_log_line` never consults `dryrun` — every matched completion becomes a `pending` event), permission-episode transactions, clearances, and `recover_and_escalate` patches **all proceed in dry-run**.

**Expected state transition on the CURRENT fresh production state (source-verified AND test-verified — `pilot/dryrun-restore-test.sh` 14/14):**
1. `state/log-checkpoint.json` **NEW** — the fresh-baseline path writes `{cursor: <daemon-log EOF>, inode, size, prefixDigest}` and logs `log baseline set (no replay; the initial continuity snapshot recorded)`; the function returns before any region scan — **no events from historical content**.
2. `state/supervisor.log` **NEW** — the startup/baseline/single-cycle lines.
3. `state/supervisor-run.lock` **NEW** — the run-lock file (empty; the flock releases at exit, the file remains).
4. `state/events.json` **MUTATED — the permState clearance cache**: `check_permission_waits` runs its clearance transaction for every watched session with `perm=false` on every cycle **regardless of dryrun** (the flag is not consulted on that path), so `.permState` gains `{waiting:false, episodes:0}` per watched session. This is the accepted P1 self-healing cache — benign and characterized exactly: **`.events` stays empty (no events created), seats/approvals byte-identical, no `wake.log`, no `submit.lock`.** (If a watched seat is in permWait at that moment, one episode event + transition would also persist — pre-checked live beforehand.)
5. **Zero POSTs** (nothing pending + the DRY branch).

**Protected snapshot BEFORE the first dry-run (reordered per the review — now preflight step 6, before any supervisor execution):**
```bash
cd ~/.qwen/sektor7-coordination
tar czf "pilot-baseline-state-$(date -u +%Y%m%dT%H%MZ).tar.gz" -C orchestrator state
chmod 600 pilot-baseline-state-*.tar.gz
sha256sum pilot-baseline-state-*.tar.gz   # recorded in STATUS.md
stat -c '%s %i' ~/.qwen-serve.log         # the pre-dry-run log size + inode, recorded
```
Stored outside the runtime path; nothing in `orchestrator/` is modified by the snapshot itself.

**Post-dry-run verification (the classified comparison — `pilot/dryrun-restore-test.sh` automates exactly this):**
- **Expected metadata delta — all four items above and NOTHING else.**
- **Unexpected (any one → the failure path):** any `.events` entry, any byte change to seats.json/approvals.json/relay-ledger.json, a `wake.log` or `submit.lock`, or any new file outside the expected set.
```bash
NEWFILES="$(comm -13 <(tar tzf pilot-baseline-state-<ts>.tar.gz | sed 's|^\./||' | grep -v '^$' | sort) <(ls -A orchestrator/state | sort))"
# expected: exactly log-checkpoint.json, supervisor.log, supervisor-run.lock
jq '.permState | length == 3 and ([to_entries[] | .value.waiting == false and .value.episodes == 0] | all)' orchestrator/state/events.json
jq '.events | length' orchestrator/state/events.json   # must be 0
```

**The restoration procedure (a failed preflight — tested; forensic evidence preserved, nothing deleted):**
```bash
# (1) move the post-failure state aside — the forensic record (logs, checkpoint, store)
mv orchestrator/state ~/.qwen/sektor7-coordination/state-failed-$(date -u +%Y%m%dT%H%M%SZ)
# (2) recreate the exact pre-dry-run state from the snapshot
mkdir -p orchestrator/state && tar xzf pilot-baseline-state-<ts>.tar.gz -C orchestrator/state
# (3) verify: the restored inventory + contents are EXACTLY the snapshot (no unrecognized new files)
tar czf /tmp/restored.tar.gz -C orchestrator state . && cmp /tmp/restored.tar.gz pilot-baseline-state-<ts>.tar.gz
```
Test-verified (R2): the restored state is byte-identical to the snapshot with no leftover files, and the forensic copy retains the checkpoint, logs, and store for explaining the failure.

**First production baseline reconciled with the last successful cron observation:** the fresh baseline's cursor is the daemon-log EOF at dry-run time; events in the interval **(last cron observation → baseline)** are never observed by the supervisor. The one-time reconciliation at activation:
```bash
# the last successful cron observation: 2026-11-12 ~00:20Z (recorded in STATUS.md:
#   B idle, tip 2385de5f unchanged, main 31113aed unchanged)
for SID in 88b93591-309e-4503-8ffe-9a7afd8314b1 a6cce63a-e53d-4715-b343-c7795ce330fe 7a664d89-e1f1-4391-9867-e973872f7447; do
  awk -v s="$SID" -v after="2026-11-12T00:20" '$0 ~ s && $0 ~ /prompt (enqueued|turn (completed|failed))/ && substr($0,1,16) >= after' ~/.qwen-serve.log
done
```
Every line found is checked against the coordination records (each must be an already-handled event — an Agent D turn, a relay, or a recorded observation); the finding — expected empty or fully accounted — is recorded in STATUS.md before the continuous launch. **The supervisor then observes only post-baseline content; nothing pre-baseline is silently skipped because the interval was explicitly reviewed.**

---

## Cutover choices (adopted per the review's recommendations)

1. **Cron preserved for the first 24 hours** — `eeat3vcp` continues untouched through Day 0→1 alongside the supervisor (both bounded; the overlap cost is redundant read-only checks).
2. **The cron retirement is a SEPARATE owner decision at the Day-1 checkpoint** — not bundled into the activation GO. Agent D will present the Day-1 stability evidence (the threshold log, the wake/delivery statistics, any ambiguous/unresolved records) and the owner decides: retire now via `cron_delete eeat3vcp`, or preserve to natural expiry (~2026-11-18). **Agent D's recommendation at Day 1: preserve to natural expiry** — the twice-hourly heartbeat bounds T1–T10 detection latency at ≤30 min for most of the window, and the expiry lands naturally inside the pilot.
3. **The independently enforced seven-day expiry** — the §1 fuse (the expiry-reminder scheduled-task idea from the original plan §6 is WITHDRAWN, superseded by the fuse).
4. **T1–T10 retained as proposed** (the §2 table above is the operational detail, not a change to the thresholds).

## The revised activation GO requested

On the owner's explicit GO, Agent D executes: preflight (source identity → battery 292/292 → **the protected state snapshot → the live-roster perm-state pre-check** → `--dry-run --once` → the post-dry-run diff check → the baseline-interval reconciliation → daemon health) → the paired launch (**supervisor + fuse as one unit**, both PIDs + the deadline recorded) → the supervised first window → the §2 monitoring discipline → the Day-1 cron decision presented separately → the Day-7 fuse stop + the pilot report. The GO states:
1. **Activate** the supervisor + expiry fuse per this addendum;
2. **Confirm** the Day-1 separate cron decision point;
3. Any threshold adjustments (otherwise T1–T10 as proposed).

Absent the GO: nothing launches, nothing changes. **Agent D STOPs here for the owner's activation decision.**

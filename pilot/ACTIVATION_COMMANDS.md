# SEKTOR7 — Exact Pilot Activation, Check, and Rollback Commands (O1–O4 corrected)

The exact command sequences referenced by `PILOT_ACTIVATION_PLAN_ADDENDUM.md` — corrected per the 2026-11-12 fuse review (O1 the fail-closed paired launch, O2 the dry-run state contract, O3 the quiet token scan, O4 the conditional-expiry characterization). All paths are absolute on the pilot pod; the daemon bearer token is referenced **by file path only** (its value is never printed by any command below). Nothing here is authorized until the owner's explicit activation GO.

## 1. Day-0 activation — the fail-closed paired launch (ONE command)

Executed only after every preflight check passes (addendum §2/§3: source identity, battery 292/292, the protected state snapshot, the live perm-state pre-check, `--dry-run --once`, the classified post-dry-run comparison, the baseline-interval reconciliation, daemon health).

```bash
bash ~/.qwen/sektor7-coordination/pilot/paired-launch.sh 604800
```

The launcher (O1, 37/37 test-verified) does the rest: the double-fork-orphan launches of BOTH processes; strict PID discovery and identity verification (exact argv from `/proc/<pid>/cmdline` + the start time from `/proc/<pid>/stat` — never a loose substring); the exactly-one-match assertion; the supervisor's loop-start + coordinator-validation lines checked; the fuse's deadline verified in its argv AND its `fuse armed` log line; `pilot/launch-record.json` written with both PIDs, both start times, and the deadline. **On any failure it stops every supervisor reading the state dir (the state-scoped stop-flag), tears down an unpaired fuse by verified identity, preserves all state and logs, records the failure reason, and exits 1** — a failed launch never leaves a supervisor running unattended (the deliberate-failure demonstration: paired-launch-test.sh L2).

## 2. The daily pairing + health check (every Agent D turn during the pilot)

```bash
# the pairing check — the TESTED unexpected-fuse-death detector (exit 1 = BROKEN):
bash ~/.qwen/sektor7-coordination/pilot/pairing-check.sh
#   exit 0 = both alive, or NEITHER (the normal post-expiry state)
#   exit 1 = BROKEN: a live supervisor WITHOUT its fuse -> execute §3 immediately
#   exit 2 = AMBIGUOUS: a fuse without a supervisor -> investigate
# the threshold checks (T1–T10 observables) per the addendum §2 table, e.g.:
jq '[.events[] | select(.state=="delivered")] | length' ~/.qwen/sektor7-coordination/orchestrator/state/events.json
tail -n 20 ~/.qwen/sektor7-coordination/orchestrator/state/supervisor.log
# T5 token-leak scan — the QUIET O3 procedure (status only; never the value or lines):
bash ~/.qwen/sektor7-coordination/pilot/token-scan.sh
#   exit 0 = clean · exit 1 = MATCH (T5 immediate-rollback class) · exit 2 = scan error
```

A BROKEN pairing → §3 below. On/after the Day-7 date: verify `~/.qwen/sektor7-coordination/pilot/expiry-executed.json` shows `exitVerified: true` and no supervisor remains; deliver the pilot report.

## 3. The rollback runbook (any immediate threshold T1–T6, a BROKEN pairing, or the owner's order)

```bash
# (1) the clean stop — state-dir scoped; a running supervisor exits within one cycle:
bash ~/.qwen/sektor7-coordination/orchestrator/supervisor.sh stop
# (2) only if unresponsive after 60 s — kill by the RECORDED exact PID (launch-record.json),
#     after verifying /proc/<pid>/cmdline is exactly `bash <script> run` AND the recorded
#     start time matches (never a pattern kill; an unverified PID is never signaled):
#       SUP_PID="$(jq -r .supervisorPid ~/.qwen/sektor7-coordination/pilot/launch-record.json)"
#       tr '\0' '\n' < /proc/$SUP_PID/cmdline | sed -n '2p;3p'   # must be the script path, then "run"
#       awk '{print $22}' /proc/$SUP_PID/stat                    # must equal the recorded starttime
#       kill -TERM $SUP_PID
# (3) verify no further POSTs and no process:
pgrep -f 'bash ~/.qwen/sektor7-coordination/orchestrator/supervisor.sh run' || echo "supervisor stopped"
tail -n 5 /home/coder/.qwen-serve.log
# (4) PRESERVE all state (the event store, checkpoint, logs — the forensic record; delete nothing).
# (5) disarm the fuse if it remains armed (an unpaired fuse must not stay armed):
#     kill -TERM by its recorded PID after the same identity verification (launch-record.json).
# (6) cron coverage: if eeat3vcp was already retired, restore per the addendum §4; else untouched.
# (7) record in STATUS.md with the triggering evidence; report to the owner immediately.
```

## 4. The Day-7 expiry verification (the fuse's own evidence)

```bash
cat ~/.qwen/sektor7-coordination/pilot/expiry-executed.json
#   expected: { "method": "stop-flag", "exitVerified": true, ... }
tail -n 10 ~/.qwen/sektor7-coordination/pilot/expiry-fuse.log
#   expected: DEADLINE REACHED → stop-flag set → supervisor terminated (method=stop-flag)
tail -n 3 ~/.qwen/sektor7-coordination/orchestrator/state/supervisor.log
#   expected: stop-flag observed — exiting cleanly
bash ~/.qwen/sektor7-coordination/pilot/pairing-check.sh   # expected: exit 0, NEITHER
```

## 5. The dry-run preflight verification + the restoration procedure (O2 corrected)

The snapshot precedes ANY supervisor execution; the comparison is classified (expected metadata vs unexpected mutations); the restoration preserves forensics. The exact contract and commands are in the addendum §3, and the whole procedure is automated and test-verified by `pilot/dryrun-restore-test.sh` (14/14): the expected delta is EXACTLY (1) `log-checkpoint.json` new, (2) `supervisor.log` new, (3) `supervisor-run.lock` new, (4) the `permState` clearance cache in `events.json` (`{waiting:false, episodes:0}` per watched session — `.events` stays empty); anything else is the failure path → move the state aside (forensics), restore the snapshot, verify the restore is exact, report — no activation.

## 6. The fuse-death recovery (O4 — the review's question; FUSE_REVIEW_NOTES.md §2)

**The expiry is CONDITIONAL on the fuse surviving to the deadline — not an unconditional hard seven-day expiry** (nothing on this pod can provide one; the characterization and the two owner options — A: a separately-authorized fail-closed lifetime dependency; B: the existing fuse with the risk explicitly accepted — are in FUSE_REVIEW_NOTES.md §2). Detected via the §2 pairing check (exit 1) or any turn on/after Day 7 with the supervisor still running and no evidence file: execute §3 (stop the supervisor, preserve state, record, report). If the owner explicitly wants the pilot to continue: a fresh fuse is armed against the still-running supervisor (a new explicit deadline — owner authority; never automatic).

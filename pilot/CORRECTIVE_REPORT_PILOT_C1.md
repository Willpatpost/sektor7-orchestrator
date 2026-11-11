# SEKTOR7 — Pilot Fuse Review Corrective Report (O1–O4)

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-12 (~02:00Z) · **Authority:** the owner-relayed independent review "PHASE 2 PILOT FUSE INDEPENDENT REVIEW" (VERDICT: CONDITIONAL HOLD — FINAL OPERATIONAL CORRECTIONS; the reviewed branch `pilot-fuse-review` @ `34c56ab07aa4da2663e20dfa85a36add1e2c654f`; the accepted v11 source CLOSED-PASS and unchanged; this directive authorizing O1–O3 corrections + O4 documentation/test improvements — NOT production activation, NOT a new expiry architecture).
**Status:** corrections COMPLETE, delivered on the new branch `pilot-fuse-review-c1` based on the exact reviewed commit. The accepted v11 implementation (`02fd483`) preserved exactly — every change lives in `pilot/` (operational scripts/procedures/tests) or the coordination documents.

---

## O1 — Fail-closed paired launch — CORRECTED

**New artifact: `pilot/paired-launch.sh`** (the single activation command). What it enforces, per the review's requirements:

- **The supervisor PID is nonempty and uniquely identified**: pattern discovery polls up to 10 s; every candidate must pass the strict identity check; exactly one validated match is required — zero or multiple (e.g., a pre-existing instance) is an abort, never a guess.
- **Process identity via the exact executable/script arguments AND process start identity, not a loose substring**: the check reads `/proc/<pid>/cmdline` as an argument vector and requires arg2 == the exact `supervisor.sh` path and arg3 == `run` (the transient double-fork intermediate — whose arg2 is `-c` — never validates); `/proc/<pid>/stat` field 22 (the start time) is captured and recorded, and every later verification (the fuse's signal path, the pairing check, the rollback runbook) compares both.
- **The fuse PID is captured explicitly** — the same strict discovery (argv: `bash <fuse> <deadline> <sup_pid> <sup_starttime>`) with its own start time recorded.
- **Both processes verified alive and corresponding to the intended deployment**: `kill -0` on both; the supervisor's loop-start line (`mode=live`) and the coordinator-configuration validation line are checked in the state log before proceeding.
- **The fuse has recorded the intended deadline**: verified twice — the deadline is the fuse's argv3 (visible in `ps`), and the fuse's first log line `fuse armed: deadline_epoch=<N>` is grepped for the exact value.
- **On any launch failure: stop the supervisor, preserve state, report** — `fail_closed` sets the state-dir-scoped stop-flag (stopping every supervisor reading the state dir, including one that cannot be individually identified), applies the identity-verified kill fallback only to OUR recorded PID, tears down an unpaired fuse by verified identity, removes the stale stop-flag only when nothing remains running, deletes NOTHING (all state and logs preserved as forensic evidence), writes `launch-record.json` with the failure reason, and exits 1.
- **The failure path demonstrated with a deliberate fuse-launch failure in a mock environment**: `paired-launch-test.sh` **L2 — 9/9** — a broken fuse path (`SEKTOR7_FUSE_PATH=/nonexistent/fuse.sh`) → the supervisor stopped cleanly (`stop-flag observed — exiting cleanly` in its log), the failure record written with the reason, state preserved, no residual flag, exit 1. (The demonstration ran four times in total across test development — every success-path wiring mistake accidentally re-exercised the fail-closed machinery; it never once left a supervisor running.)

**Test evidence: `pilot/paired-launch-test.sh` — 37/37 PASS** (`pilot/paired-launch-test-record.txt` holds the launch records, the expiry evidence, the paired-launch logs, and the pairing-check outputs): L1 the full success lifecycle (13 checks: both identities + start times, the deadline in argv+log, the clean expiry stop, the post-expiry NEITHER state); L2 the deliberate failure → fail-closed (9); L3 the TERM escalation (8); L4 the unexpected fuse death → detection (4); L5 the quiet token scan (4).

## O2 — Correct dry-run state verification — CORRECTED

**The corrected contract (source-verified AND test-verified — `pilot/dryrun-restore-test.sh` 14/14):** the expected dry-run delta on the fresh production state is EXACTLY:
1. `log-checkpoint.json` **NEW** (the fresh baseline; no replay);
2. `supervisor.log` **NEW** (the startup/baseline/cycle lines — the review's "legitimate supervisor log activity");
3. `supervisor-run.lock` **NEW** (the run-lock file — the review's "lock-file activity");
4. `events.json` **MUTATED — the permState clearance cache**: a finding the review's O2 surfaced — `check_permission_waits` runs its clearance transaction for every watched session with `perm=false` on every cycle **regardless of dryrun** (the flag is not consulted on that path), so `.permState` gains `{waiting:false, episodes:0}` per watched session. This is the accepted P1 self-healing cache — benign, now characterized and asserted exactly: `.events` stays empty, seats/approvals byte-identical, no `wake.log`, no `submit.lock`.

The comparison procedure distinguishes expected metadata changes from unexpected event-store mutations (any `.events` entry, any seats/approvals/ledger byte change, `wake.log`/`submit.lock`, or any file outside the four-item set → the failure path). **The restoration procedure is verified to actually restore:** the post-failure state is moved aside (forensic evidence preserved — nothing deleted), the pre-dry-run snapshot re-extracted, and the restored state is byte-identical to the snapshot with no unrecognized new files (R2: inventory + content identical; the forensic copy retains the checkpoint, logs, and store for explaining the failed preflight).

## O3 — Quiet token-leak scanning — CORRECTED

**New artifact: `pilot/token-scan.sh`**: reads the token value into a shell variable (never echoed), scans with `grep -rFq` (the `-q` prints nothing), and reports ONLY a status line — `clean` (exit 0) / `MATCH` (exit 1, locations suppressed) / `ERROR` (exit 2, e.g., an unreadable token file). **Tested with a dummy token planted in a test log (L5):** exit 1 with the `MATCH:` status, the dummy value absent from the output (asserted); a clean tree → exit 0 `clean:`; an unreadable token file → exit 2 `ERROR:`. The T5 command in the standing procedures now invokes this script instead of the raw grep (which could print matching lines).

## O4 — Expiry enforcement clarified + tests strengthened — CORRECTED (documentation + tests only)

- **The characterization corrected everywhere it appeared:** the fuse provides a **CONDITIONAL** hard expiry — conditional on the fuse surviving to the deadline. **It is not an unconditional hard seven-day expiry**, and nothing on this pod can provide one (every independent mechanism is itself a detachable process with the same failure mode).
- **The two explicit options presented for the owner's decision** (FUSE_REVIEW_NOTES.md §2 + the addendum): **Option A** — a fail-closed lifetime dependency or equivalent enforceable deadline mechanism with mock-based fault tests (e.g., a v11 source change giving the supervisor's own loop a deadline refusal) — **NOT implemented; requires a separate scoped implementation authorization**; **Option B** — retain the existing fuse and conduct the bounded best-effort pilot with the fuse-only-failure risk explicitly accepted (the turn-dependent detection, the shared-fate analysis, and the pilot's per-cycle bounds remain in force).
- **Mock-based tests added for the previously documented-but-untested procedures:** the **PID verification** (the strict argv + start-time checks — exercised in every paired-launch test), the **TERM/KILL escalation** (L3: a long-interval supervisor that cannot consume the stop-flag is stopped by the identity-verified TERM — `method: stop-flag+TERM`, `exitVerified: true`, the stale flag removed after the verified kill), and the **unexpected-fuse-death detection** (L4: the fuse killed by its recorded PID → `pairing-check.sh` — the new tested detector — exits 1 BROKEN; after the runbook cleanup → exit 0 NEITHER).
- **Tested behavior distinguished from documented-but-untested** (FUSE_REVIEW_NOTES.md §3): tested — the clean stop, the already-stopped branch, the paired-launch identity verification, the fail-closed path, the TERM escalation, the stale-flag removal, the fuse-death detection, the quiet token scan, the dry-run delta, the restoration; documented-but-untested — the KILL escalation after a survived TERM, the identity-refusal branch's no-signal outcome, the pod-restart shared fate, the full 7-day duration, the cron restore path.

## Defects found and fixed during this corrective (the honest record)

1. **`is_fuse_pid` start-time parameter bug:** the launcher's fuse identity check compared the FUSE's own `/proc` start time against the SUPERVISOR's recorded start time — two different processes, so the check could never pass (discovered as the L1/L3/L4 failures; L2's failure path kept working, which localized it). Fixed: the supervisor start time is carried as the fuse's argv5 (the launch contract) and checked there; the fuse's own start time is captured separately for the record.
2. **The dry-run contract's "events.json unchanged" claim was wrong** (the addendum §3 as originally delivered): the permState clearance cache writes on every cycle regardless of dryrun — found by the O2 test's failing assertion, confirmed in the forensic copy. Fixed: the four-item characterized contract, asserted by the test.

(Plus the test-harness wiring fix: the test initially did not pass `SEKTOR7_FUSE_PATH` to the per-case launcher invocations, so the launcher's default fuse path resolved inside the case pilot dir — which accidentally exercised the fail-closed path three more times and demonstrated its reliability.)

## Boundaries honored

The accepted v11 orchestration source (`02fd483`) preserved exactly — verified byte-identical after all work (all changes live in `pilot/` and the coordination documents; the orchestrator tree untouched). The cron unchanged. No activation, no merge, no permission change, no engine CI, no engineering checkpoint. No new expiry architecture implemented (Option A requires separate authorization).

## Test summary

- `fuse-test.sh`: **15/15** (the original battery, re-run green after the fuse corrections — the clean-stop path unaffected)
- `paired-launch-test.sh`: **37/37** (O1/O3/O4)
- `dryrun-restore-test.sh`: **14/14** (O2)
- All mock-wired against the accepted `tests/mock-daemon.py` with per-case state/pilot dirs; the production state dir and the live tree untouched throughout; token-value scans clean on all published artifacts.

# SEKTOR7 — Expiry-Fuse Review Notes (the narrow source-review submission)

**Scope:** `pilot/expiry-fuse.sh` + `pilot/fuse-test.sh` + the test record + the addendum + the exact commands — submitted for the technical lead's narrow source review per the 2026-11-12 review directive ("PLAN ACCEPTED IN PRINCIPLE — ACTIVATION STILL ON HOLD"). **This is review evidence, not activation.** The accepted v11 implementation (`02fd483`) is preserved exactly — the fuse and its test live outside the accepted tree and modify nothing in it.

## 1. What the fuse is (one paragraph)

A detached double-fork-orphan bash process whose sole authority is to terminate the supervisor at a deadline and leave evidence. It observes nothing but the clock (a `sleep $POLL` loop, default 300 s → the stop executes within one poll of the deadline). It cannot POST to the daemon, restart anything, touch the cron, or write the accepted sources. Its only writes: its own log and `expiry-executed.json` (both under `pilot/`), plus the stop-flag through the accepted `supervisor.sh stop` interface and, in the already-stopped branch, the removal of a stale stop-flag. Stop escalation: the stop-flag (clean, ≤ one cycle) → `kill -TERM` by the recorded PID **only after `/proc/<pid>/cmdline` verifies it is supervisor.sh** (PID-reuse protection over the 7-day window) → `kill -KILL`, same verification. An unverified PID is never signaled; the ambiguity is recorded instead.

## 2. The review's question: the fuse terminates unexpectedly while the supervisor remains active

**What happens, precisely:**

1. **The Day-7 hard stop is not executed by the fuse.** The supervisor continues past the deadline. The loss is the *terminal bound*, not any per-action safety property: every cycle remains gated, coordinator-bound, at-most-once, and rate-capped exactly as before — the supervisor cannot do anything after Day 7 that it could not do before Day 7; it merely keeps doing the bounded things indefinitely.
2. **The expiry evidence file (`expiry-executed.json`) is absent** — the durable signal that the stop did NOT run (the file is written only by an executed stop).

**Detection paths (all turn-dependent — stated honestly):**

- **The daily pairing check** (part of the standing daily verification, exact command in `pilot/ACTIVATION_COMMANDS.md`): `pgrep -f expiry-fuse.sh` empty while `pgrep -f 'orchestrator/supervisor.sh run'` returns the supervisor — the **both-or-neither invariant broken** — is itself a threshold-class finding; Agent D executes the rollback runbook (stop the supervisor, preserve state, record, report). Latency: **≤30 minutes while the cron heartbeat lives** (through its natural expiry ~2026-11-18 ≈ Day 6); event-driven after that (a seat-event wake, a gap companion, or an owner turn).
- **The deadline itself**: any Agent D turn on/after the Day-7 date observes the supervisor still running with no evidence file → immediate stop via the runbook.
- **The owner** can check `pilot/expiry-executed.json` (absent = not executed) and `pgrep` directly at any time.

**The independently enforced fallback: NONE EXISTS — stated plainly.** On this pod every independent mechanism is itself a detachable process; a second watchdog would carry the identical failure mode (and the review directives forbid persistent watchdogs). No in-process fallback exists in the supervisor (the v11 source is unmodifiable, and v11 has no self-expiry by design). What bounds the risk instead:

- **Shared fate covers the dominant real termination event:** a pod restart — by far the most likely "unexpected termination" — kills the supervisor and the fuse TOGETHER (both are orphans in the same process namespace; the pod dies wholesale). A fuse-only death requires a targeted kill, a fuse-specific crash, or an OOM event.
- **The fuse's own crash surface is minimal:** one bash loop (`sleep` + `date`), no external input parsed, no state writes before the deadline, no network, no children. Resident memory is a few MB against a 32 GiB cgroup (OOM is not a realistic solo-death cause). Its two non-nominal paths are tested: the already-stopped branch (15/15, test B) and the ambiguous-PID path (refuses to signal, records, exits).
- **The turn-dependent backstops with their bounds** (above): ≤30 min detection latency for ~6 of the 7 days (the cron heartbeat), event-driven only in the final ~day after the cron's natural expiry.
- **Optional Day-1 owner decision (offered, not default):** extend the heartbeat through Day 7 (a replacement scheduled task expiring at Day 7+) so the pairing check's latency stays ≤30 min for the entire window. This is a cron change and therefore an explicit owner decision at the Day-1 checkpoint, not part of this submission.

**Recovery action once detected (any path):** the rollback runbook (`pilot/ACTIVATION_COMMANDS.md` §3): stop-flag → verified kill if needed → verify no further POSTs → preserve all state → record + report. If the owner instead wants the pilot to CONTINUE past a detected fuse death: a fresh fuse is armed against the still-running supervisor (the run lock prevents doubles; the new deadline is explicit owner authority) — never an automatic relaunch.

**The inverse scenarios, for completeness:** supervisor dead + fuse alive → the fuse at deadline takes the tested already-stopped branch (removes a stale stop-flag so it cannot sabotage a future launch, records `already-stopped`, exits). Both dead (pod restart) → nothing runs; any relaunch is a paired relaunch per the owner's standing activation or an explicit instruction.

## 3. The test evidence summary

`pilot/fuse-test.sh` — 15/15 PASS, mock-wired (the REAL v11 `supervisor.sh` against the accepted `tests/mock-daemon.py`, test state dirs only; production state and sources untouched — byte-identity to `02fd483` re-verified after the run). Test A: a live supervisor stopped cleanly at a short deadline via the stop-flag (`method: "stop-flag"`, `exitVerified: true`, the supervisor's own `stop-flag observed — exiting cleanly` line, no residual flag, state preserved). Test B: the already-stopped branch removes a stale flag and records `already-stopped`. The full output, both evidence JSONs, and the fuse/supervisor logs are in `pilot/fuse-test-record.txt`. Two defects were found and fixed during test development and are documented there honestly: (a) the deadline poll was a fixed 300 s sleep whose first time-check postdated short test deadlines (now `SEKTOR7_FUSE_POLL`, default 300 s in production — the documented deadline bound); (b) the `jq -n` evidence writers used object shorthand, emitting nulls under null input (fixed to explicit variable refs; the null-bearing run-2 evidence is preserved in the record for comparison).

## 4. Sanitization statement

The committed artifacts contain no credentials or token values (the only token-like string is the battery's own labeled mock fixture, already public on the accepted branch), no runtime state (the test record's paths point at disposable `/tmp` workdirs), and no transcripts. The token-leak scan performed before the commit is the same command specified for T5 in the addendum: the value is read from the token file into a shell variable and matched against the staged tree; the value itself is never printed. Session identifiers appear in the addendum's reconciliation command as operational necessities (the loopback daemon is unreachable without the bearer token; the identifiers alone grant nothing).

## 5. What this submission is NOT

Not activation. Not a modification of the v11 runtime (the live tree remains byte-identical to `02fd483` — the fuse and its test are new files in `pilot/`, outside the accepted tree). Not a cron change. Not engineering authority. The pilot choices remain as the review recommended: seven-day bounded operation, cron Option 1 with the separate Day-1 retirement decision, T1–T10 unchanged, hard expiry enforced independently, no engineering authority delegation.

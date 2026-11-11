# SEKTOR7 — Exact Pilot Activation, Check, and Rollback Commands

The exact command sequences referenced by `PILOT_ACTIVATION_PLAN_ADDENDUM.md` — extracted here as the review requested. All paths are absolute on the pilot pod; the daemon bearer token is referenced **by file path only** (its value is never printed by any command below). Nothing here is authorized until the owner's explicit activation GO.

## 1. Day-0 activation (the paired launch — supervisor + fuse as ONE unit)

Executed only after every preflight check passes (addendum §2/§3: source identity, battery 292/292, the protected state snapshot, the live perm-state pre-check, `--dry-run --once`, the post-dry-run diff check, the baseline-interval reconciliation, daemon health).

```bash
# (a) launch the supervisor — the proven double-fork orphan form:
bash -c "setsid nohup bash ~/.qwen/sektor7-coordination/orchestrator/supervisor.sh run \
  >> ~/.qwen/sektor7-coordination/pilot/supervisor-launch.log 2>&1 < /dev/null & disown"
sleep 1

# (b) record the supervisor PID — abort unless exactly ONE match:
SUP_PID="$(pgrep -f 'orchestrator/supervisor.sh run')"
[ "$(printf '%s\n' "$SUP_PID" | wc -l)" = 1 ] || { echo "ABORT: supervisor PID not unique"; exit 1; }

# (c) launch the fuse — deadline = activation + exactly 7 days (604800 s):
DEADLINE=$(( $(date -u +%s) + 604800 ))
bash -c "setsid nohup bash ~/.qwen/sektor7-coordination/pilot/expiry-fuse.sh \
  $DEADLINE $SUP_PID >> ~/.qwen/sektor7-coordination/pilot/fuse-launch.log 2>&1 < /dev/null & disown"

# (d) record both PIDs + the deadline + the Day-7 date in STATUS.md immediately.
```

## 2. The daily pairing + health check (every Agent D turn during the pilot)

```bash
# both-or-neither: a solo supervisor (dead fuse) or solo fuse (dead supervisor) is a finding
pgrep -f 'orchestrator/supervisor.sh run'   # expected: the supervisor PID, or empty after Day 7
pgrep -f 'expiry-fuse.sh'                   # expected: the fuse PID, or empty after Day 7
# the threshold checks (T1–T10 observables) per the addendum §2 table, e.g.:
jq '[.events[] | select(.state=="delivered")] | length' ~/.qwen/sektor7-coordination/orchestrator/state/events.json
tail -n 20 ~/.qwen/sektor7-coordination/orchestrator/state/supervisor.log
# T5 token-leak scan (the value is read into the variable and never printed):
TOK="$(cat ~/.qwen-serve-token)"
grep -rF -- "$TOK" ~/.qwen/sektor7-coordination/pilot/ \
  ~/.qwen/sektor7-coordination/orchestrator/state/ 2>/dev/null || echo "clean"
```

A broken pairing → §3 below. On/after the Day-7 date: verify `~/.qwen/sektor7-coordination/pilot/expiry-executed.json` shows `exitVerified: true` and no supervisor remains; deliver the pilot report.

## 3. The rollback runbook (any immediate threshold T1–T6, a broken pairing, or the owner's order)

```bash
# (1) the clean stop — a running supervisor exits within one cycle (≤ ~20 s + cycle):
bash ~/.qwen/sektor7-coordination/orchestrator/supervisor.sh stop
# (2) only if unresponsive after 60 s — kill by the RECORDED exact PID, after verifying
#     /proc/<pid>/cmdline contains supervisor.sh (never a pattern kill):
#       tr '\0' ' ' < /proc/<SUP_PID>/cmdline | grep -q supervisor.sh && kill -TERM <SUP_PID>
# (3) verify no further POSTs and no process:
pgrep -f 'orchestrator/supervisor.sh run' || echo "supervisor stopped"
tail -n 5 /home/coder/.qwen-serve.log
# (4) PRESERVE all state (the event store, checkpoint, logs — the forensic record; delete nothing).
# (5) disarm the fuse if it remains armed (a stopped pilot needs no expiry):
pgrep -f 'expiry-fuse.sh' && kill -TERM "$(pgrep -f 'expiry-fuse.sh')"   # recorded exact PID preferred
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
pgrep -f 'orchestrator/supervisor.sh run' || echo "no supervisor — hard stop verified"
```

## 5. The fuse-death recovery (the review's question — FUSE_REVIEW_NOTES.md §2)

Detected via the §2 pairing check or any turn on/after Day 7 with the supervisor still running and no evidence file: execute §3 (stop the supervisor, preserve state, record, report). If the owner explicitly wants the pilot to continue: arm a fresh fuse against the still-running supervisor (§1c with a new explicit deadline) — never an automatic relaunch. **There is no independently enforced fallback for a dead fuse — the turn-dependent backstops and their latency bounds are documented in FUSE_REVIEW_NOTES.md §2.**

# sektor7-orchestrator

The Agent D coordination infrastructure for the SEKTOR7 project — the local,
loopback-only transport/scheduling tooling that relays owner-approved directives
to engineering-agent sessions and watches their lifecycle events. **It is
transport and scheduling only: it never judges source correctness, grants
implementation authority, approves merges, promotes checkpoints, or
auto-approves permissions.** This repository exists for independent technical
review of that infrastructure; the SEKTOR7 game-engine repository is separate
and untouched by anything here.

## What is under review

The **`phase2-v6-review`** branch carries the Phase 2 v6 corrective delivery —
the current implementation after three independent review rounds:

- Round 1 (F1–F5): relay serialization + durable intent, the persisted event
  store, mechanical authorization binding, strict HTTP validation,
  rate/concurrency corrections — `docs/CORRECTIVE_REPORT_F1_F5.md`.
- Round 2 (R1–R6): no false acknowledgments, strict session schemas, gate+POST
  under one submission lock, complete approval binding, no-budget deferrals,
  test-runner path fixes — `docs/CORRECTIVE_REPORT_ROUND2_R1_R6.md`.
- Round 3 (V5-F1–F4): the free-text prompt path removed (strictly structured
  `notify` with internally-constructed text), no duplicate preflight gates with
  end-to-end refusal/ambiguity/success outcomes, permission-wait episodes,
  byte-exact UTF-8 log scanning — `docs/CORRECTIVE_REPORT_ROUND3_V5F1_F4.md`.

`archive-pre-f1f5/` preserves the original implementation byte-for-byte for
comparison. `docs/test-outputs/` contains the captured battery runs from this
exact tree (both invocation styles). `examples/` carries sanitized state samples
(the approval registry and relay ledger; no runtime state, no credentials).

## Running the tests

```bash
bash tests/run-tests.sh                 # from this directory
/home/abs/path/sektor7-orchestrator/tests/run-tests.sh   # by absolute path
```

Both styles must pass. The battery is deterministic and non-destructive: it
starts a loopback mock daemon (`tests/mock-daemon.py`) on a probed-free port,
drives every scenario through per-request `scenario.json` control, and asserts
HTTP POST counts and persistent event states — never log lines. Current result:
**127/127 checks, both invocation styles.**

Requirements: bash, jq, curl, python3, GNU date/coreutils. No other dependencies.

## Operational notes

- All state lives under `state/` (gitignored; created at runtime, mode 0600).
- The daemon bearer token is read per call from `~/.qwen-serve-token` and is
  never written, logged, or committed (verified by scan on every delivery).
- Production supervisor startup must use the double-fork orphan form — never a
  session-tracked background task of any session it may wake (see
  `docs/WAKE_TEST_RESULTS.md` for the source-verified analysis).
- Unattended production activation is NOT authorized — pending the independent
  review this repository exists for.

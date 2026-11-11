# SEKTOR7 — PHASE 2 F1–F5 SAFETY CORRECTIVE REPORT

**From:** Agent D — Qwen Code serve session `coder-a3` (sessionId `394a5b6b-d0cc-4673-8fed-d2c8423798ba`)
**Date:** 2026-11-11 (~19:50Z) · **Authority:** the owner-relayed independent-review directive "Agent D Phase 2 Safety Corrective" (verbatim: `OWNER_DIRECTIVE_2026-11-11_PHASE2_SAFETY_CORRECTIVE.md`) + the owner's execution confirmation.
**Status:** corrective COMPLETE under the authorized orchestrator-only scope. **Unattended production activation remains NOT authorized. STOP for independent review.**

---

## F1 — Duplicate directive submission — CORRECTED

**The defect (confirmed):** `relay` performed its ledger lookup before the POST and the ledger write after, with no serialization — concurrent invocations could both POST, and the fixed-name ledger temp file could collide.

**The correction (orchestrator.sh v3, `relay`):**
1. **Interprocess submission lock:** the entire check → intent → POST → confirm sequence runs under `flock -w 30` on `state/relay.lock` (fd 9), held for the operation's duration.
2. **Durable submission-intent BEFORE the POST:** the ledger entry is written with `status: "intent"` (plus target sessionId and timestamp) *before* any network call, using an atomic write (unique temp name `$$.$RANDOM` + `mv`). A crash at any later point leaves the intent on disk, which blocks re-submission.
3. **At-most-once across processes and restarts:** any existing ledger entry for the directive sha256 — `intent`, `delivered`, or `submitted-unconfirmed` — refuses a new attempt. Concurrent invocations serialize on the lock; the second sees the first's intent and refuses (regression C1: exactly one HTTP POST, one ledger entry).
4. **Ambiguous outcomes stay unresolved:** a POST transport failure or a response without a valid promptId records `submitted-unconfirmed` and dies — never a blind retry (regressions T7a/T7b, C2).
5. **Directive identity and target binding validated:** the file must carry the `OWNER RELAY` + `RELAY PROVENANCE` headers AND (F3) a matching approvals-registry entry; the target's seat must equal the approval's seat.
6. **Daemon idempotency limitation (stated plainly):** the qwen 0.24.5 `POST /session/:id/prompt` API accepts no client-supplied idempotency key, so at-most-once is enforced **client-side** by the lock + intent ledger. The residual window is a crash between the daemon accepting the POST and the ledger confirm — it surfaces as `submitted-unconfirmed` and **requires manual reconciliation against the daemon log's per-promptId `prompt enqueued` lines** (the delivery authority). The window cannot produce a silent duplicate through this tool; it can only produce a correctly-flagged ambiguity.

**Evidence:** C1 (two concurrent relays → one POST, one ledger entry), C2 (a pre-seeded `intent`/`submitted-unconfirmed` entry blocks re-submission), T6a/T6b (delivered + duplicate refused), T7a/T7b (500 → unconfirmed → retry refused).

## F2 — Lost worker-completion events — CORRECTED

**The defect (confirmed, and my own test had codified it as acceptable):** the log offset advanced even when the wake was deferred; deferred events were never retried.

**The correction (supervisor.sh v2):**
1. **Persist-before-advance:** every material log line is persisted to the event store (`state/events.json`) as `state: "pending"` with bounded structured fields **before** the offset advances. The offset now moves only after the region's events are on disk.
2. **Explicit event states:** `pending → delivered` (on a verified wake POST, recording the wake promptId) or `pending → unresolved` (only after the attempt cap — 12 — or the age cap — 2 h — both configurable). **Unresolved events are never deleted**: they remain visible in `supervisor.sh status` and are logged loudly. Nothing is silently discarded.
3. **Deferred retry:** every cycle re-attempts pending events while Agent D passes the wake gate; the gate refusal path increments `attempts` and leaves the event pending (regression C3: deferred while D busy → delivered on the next cycle once D is idle; C4: the delivered state survives further restarts with exactly one delivery).
4. **Restart/truncation/partial-line handling:** the event store persists across supervisor restarts and log truncation (truncation resets the offset baseline; events survive it). Partial trailing lines are withheld — the scan probes the region's **last byte** and only processes through the final newline, advancing the offset to the exact complete-line boundary (regressions C9a–c).
5. **A second real defect found and fixed during the corrective (documented for the record):** the original scan read the new log region through command substitution, which **strips trailing newlines** — a fully-complete region was misclassified as partial (events lost, offset frozen), and a mixed region lost its later complete lines. The corrected scan uses exact byte accounting (region length, last-byte probe, last-newline idiom). The original test T9 had masked this; the corrected battery now covers it (T9/C9).

**Evidence:** T11b (deferred event persisted, offset advanced, nothing lost), C3a–c (the exact lost-event scenario from the review: deferred → retried → delivered once, wake promptId recorded), C4 (restart survival, single delivery), C9 (partial lines withheld, completed later, exactly once).

## F3 — Authorization integrity — CORRECTED

**The correction (mechanical binding, replacing header-only checks):**
1. **Approvals registry (`state/approvals.json`, mode 0600):** every relayable directive must have an entry keyed by its **sha256** binding: the checkpoint, the **recipient seat**, the **source provenance** (the dated owner directive that authorized it), and the approval timestamp. Entries are created **only** by Agent D from an explicit owner authorization — the registry records *where the authorization came from*, it does not create it. The delivered F8 directive is registered retroactively with its true provenance (the cycle-2 owner directive §2).
2. **Seat binding:** `relay` resolves the target's seat from `state/seats.json` (`seatOf`, established via the identity protocol) and **refuses on mismatch** with the approval's seat (regression C6b).
3. **Raw `prompt` restricted:** the command now **mechanically refuses any message lacking the literal label `NO authorization`** — only explicitly non-authorizing operational messages (supervisor notifications, self-tests) may use it; directives must go through `relay` (regression C6c). There is no other authorizing path.
4. **What the registry is NOT (honest limitation):** it is a **binding and traceability mechanism, not proof of owner authorship**. Agent D's own preserved copies and generated digests are provenance records, not independent proof — the independent layers remain (a) the owner/technical-lead review of every delivery, and (b) recipient-side verification against preserved owner copies (Agent B demonstrably byte-verified the F8 relay). A cryptographic signing scheme (owner-held key, per-directive signatures verified in each seat) would close this and is recommended as a Phase 3 owner decision — not invented unilaterally. All permission gates are untouched; nothing auto-approves.

**Evidence:** C6a (no registry entry → refuse), C6b (seat mismatch → refuse), C6c (unlabeled raw prompt → refuse), T5 (no headers → refuse).

## F4 — HTTP response validation — CORRECTED

Every HTTP call now captures and checks the status code; every response is schema-validated:
- Prompt POST must return **exactly 202** with a **UUID promptId** — 4xx/5xx, malformed bodies, missing/null promptIds all refuse (and, in `relay`, record `submitted-unconfirmed`).
- Status/pending responses must be well-formed JSON objects; `activeWorkState` must be `idle|active` (anything else, including null, refuses: "inconsistent session state"); the pending count must be numeric.
- A 4xx/5xx or malformed response is **never** counted as delivery or wake success.

**Evidence:** C5a (HTTP 500 → refused + unconfirmed), C5b (missing promptId → unconfirmed), C5c (malformed body → unconfirmed), C5d (null `activeWorkState` → refuse), T8a (daemon down → fail closed).

## F5 — Rate limiting and concurrency — CORRECTED

1. **Wake-counter timestamp parsing:** rewritten to `date -u -d` per entry — UTC-consistent regardless of the host timezone (regressions C7a/b: four recent wakes rate-limit the next attempt — the event stays pending, not lost; expired entries no longer count).
2. **One supervisor instance:** `run` takes an exclusive `flock` on `state/supervisor-run.lock`; a second instance exits immediately with an explicit error (regression C8).
3. **Consistent submission locking:** all prompt submissions (relay and the supervisor's wake path) serialize through the orchestrator's `submit.lock`; lock ordering is relay.lock → submit.lock (no cycles).
4. **One signal per completion:** worker completions are detected **only** through the daemon log's per-promptId lifecycle lines (the authoritative, dedupable signal); the previous status-transition wake path was removed entirely, eliminating the duplicate-signal class. The permission-wait event remains, keyed once per session.
5. **Cron preserved unchanged** (frequency, lifetime) pending the owner's separately authorized cutover.

**Evidence:** C7a/b, C8, plus the single-delivery assertions in C3c/C4.

## §6 — Test battery (deterministic)

`tests/run-tests.sh` v2: **57/57 PASS** (2026-11-11, captured in `state-samples/TEST_OUTPUT.txt`). The original T1–T12 scenarios are preserved and passing; the new corrective regressions: C1 concurrent duplicate relay, C2 crash/intent reconciliation, C3 deferred-event delivery, C4 restart survival, C5 HTTP failure modes, C6 provenance refusals, C7 rate counting/expiry, C8 multiple instances, C9 truncation/partial lines. Deterministic execution: the mock port is probed for freeness before use, the mock daemon's readiness is polled before the first assertion, and every scenario is file-driven (`scenario.json` read per request). No existing test was weakened — two original assertions (T11's "deferred" outcome, T9's dedup count) were *strengthened* to assert the event-store states they previously only implied.

**Live evidence (real daemon):** the prior wake-up validation **PASS** stands (promptId `eb973a06-f220-4f4c-a131-a481b4bc3d29`, 19:21:59Z — the full eight-point chain in `WAKE_TEST_RESULTS.md`); a corrected-code self-test was launched at delivery (double-fork detached) with its result to be appended at the next Agent D turn; real-daemon sanity checks after the rewrite pass (resolve / seat binding / status / wake-gate).

## §7 — Additional requirements

- **Bounded structured metadata:** supervisor notifications carry only `{kind, seat, sessionId, promptId, outcome}` — never raw log text (enforced in `wake_agent_d`'s message construction).
- **State protection:** `umask 077` in both scripts — every created state file is 0600; the daemon token is read per call and never written, logged, or included in any bundle (token-value scans on every archive build).
- **CI observation after cron retirement:** the supervisor detects a watched seat's **turn completion** (the CI-dispatching turn) and wakes Agent D; Agent D then verifies the delivery and starts the established `gh run watch` monitor for the run's duration. GitHub-side CI completion is not directly observable by the supervisor (no polling by design); the monitor covers the wait, and the owner can wake Agent D at any time. The cron retirement itself requires separate owner authorization.

## §9 — Remaining risks and limitations (honest)

1. The client-side at-most-once window (F1 §6 above) — flagged ambiguities, manual reconciliation, daemon log authoritative.
2. The approvals registry binds and traces but cannot cryptographically prove owner authorship (F3 §4; Phase 3 signing proposal).
3. The daemon-log line format remains a stable-but-internal interface of qwen 0.24.5 (version-pinned; drift degrades to no events — fail-safe).
4. Poll-based watching (20 s default) — SSE upgrade path documented.
5. Permission waits still require owner action (by design).

## §9 — Production-activation recommendation

**CONDITIONAL GO** — after this review: the two critical defects are corrected and regression-proven; the failure modes tested are fail-closed; the architecture is unchanged and already proven end-to-end on the real chain. Recommended conditions: independent acceptance of this corrective, the corrected-code live self-test result, retirement of the cron in favor of the supervisor at the owner's cutover authorization, and an initial bounded activation (the 7-day-expiry discipline with `supervisor.sh status` inspection after 24 h). No engineering authority of any kind is delegated by this recommendation.

## File inventory (all under `~/.qwen/sektor7-coordination/orchestrator/`)

`orchestrator.sh` (v3) · `supervisor.sh` (v2) · `tests/mock-daemon.py` (v2) · `tests/run-tests.sh` (v2, 57 checks) · `state/{relay-ledger,approvals,seats,events}.json` · `archive-pre-f1f5/` (the complete original implementation, preserved byte-for-byte for comparison) · README. The v3 review archive is preserved untouched; this corrective ships as the v4 archive beside it.

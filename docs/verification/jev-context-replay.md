# Jev context-retention replay verification

Audience: maintainer verification.

Date: 2026-09-21.
Scope: active maintainer evidence for `bin/fm-jev-context-replay.py`.

This record supports `bin/fm-jev-context-replay.py`, the offline-only replay evaluator for sanitized Jev context-retention fixtures.
The script header owns the CLI contract, input schema, and output files.

Current safety contract:

- Transcript inputs are sanitized fixture transcripts only.
- Jev-shaped advice is local-only: no proposal source, a cached proposal file, or a caller-supplied fake transport.
- The evaluator writes a diffable `ledger.jsonl` and `report.md` under the caller's `--out-dir`.
- It never reads live agent context, never calls TypeSafe directly, and never mutates Pi, Claude, Codex compaction, sessions, prompts, watchers, daemons, memory stores, or live context.
- Jev-shaped proposals are advisory.
- Deterministic rules keep captain instructions, accepted requirements, approvals, blockers, unresolved decisions, security boundaries, source receipts, unknown segments, and every segment needed by a downstream fixture question.
- Kept text remains verbatim.
- Truncation is non-generative and preserves `original_segment_id`, `original_sha256`, and original length.
- Missing, unknown-action, absent-confidence, or low-confidence per-segment proposals fall back to keep.
- Malformed proposal response envelopes are rejected before a ledger is written.

The representative fixture set lives at `tests/fixtures/jev-context-replay/transcripts.json`.
It contains 30 sanitized transcripts with held-out downstream questions covering contradictory updates, scope supersession, ask-user decisions, command-output noise, long evidence payloads, security boundaries, source receipts, absent-key behavior, unknown rows, and low-confidence proposals.

Evidence command:

```console
$ bin/fm-test-run.sh tests/fm-jev-context-replay.test.sh
FM_TEST_BEGIN 2026-09-21T19:33:11Z tests/fm-jev-context-replay.test.sh family=unclassified expected_gate_skip=none
ok - fm-jev-context-replay public interface preserves protected context offline
FM_TEST_END 2026-09-21T19:33:12Z tests/fm-jev-context-replay.test.sh exit=0 duration_ms=1093 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1210
FM_TEST_SUMMARY_FAMILY family=unclassified count=1 duration_ms=1093 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-jev-context-replay.test.sh duration_ms=1093
```

The test drives the public CLI with a fake TypeSafe transport, proves no network command is invoked when `TYPESAFE_API_KEY` is absent, checks protected-category rescue, provenance, verbatim retention, low-confidence keep behavior, missing-required-evidence failure, and reproducible ledgers.

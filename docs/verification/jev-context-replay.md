# Jev context-retention replay verification

Audience: maintainer verification.

This record supports `bin/fm-jev-context-replay.py`, the offline-only replay evaluator for sanitized Jev context-retention fixtures.
The script header owns the CLI contract, input schema, and output files.

Current safety contract:

- Inputs are sanitized fixture transcripts only.
- The evaluator writes a diffable `ledger.jsonl` and `report.md` under the caller's `--out-dir`.
- It never reads live agent context, never calls TypeSafe directly, and never mutates Pi, Claude, Codex compaction, sessions, prompts, watchers, daemons, memory stores, or live context.
- Jev-shaped proposals are advisory.
- Deterministic rules keep captain instructions, accepted requirements, approvals, blockers, unresolved decisions, security boundaries, source receipts, unknown segments, and every segment needed by a downstream fixture question.
- Kept text remains verbatim.
- Truncation is non-generative and preserves `original_segment_id`, `original_sha256`, and original length.
- Low-confidence, malformed, or missing proposals fall back to keep.

The representative fixture set lives at `tests/fixtures/jev-context-replay/transcripts.json`.
It contains 30 sanitized transcripts with held-out downstream questions covering contradictory updates, scope supersession, ask-user decisions, command-output noise, long evidence payloads, security boundaries, source receipts, absent-key behavior, unknown rows, and low-confidence proposals.

Verification command:

```console
$ bin/fm-test-run.sh tests/fm-jev-context-replay.test.sh
```

The test drives the public CLI with a fake TypeSafe transport, proves no network command is invoked when `TYPESAFE_API_KEY` is absent, checks protected-category rescue, provenance, verbatim retention, low-confidence keep behavior, missing-required-evidence failure, and reproducible ledgers.

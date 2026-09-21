# Jev Evidence Screening Verification

Audience: maintainer verification.

This record supports the active guarantee that `bin/fm-jev-evidence-screen.sh` is report-only, preflights outputs before transport, appends advisory receipts, sanitizes transport inputs and receipt metadata, and preserves deterministic-review precedence.
Current behavior and authority boundaries are documented in [`../jev-evidence-screening.md`](../jev-evidence-screening.md).
The executable public-interface regression is [`../../tests/fm-jev-evidence-screen.test.sh`](../../tests/fm-jev-evidence-screen.test.sh).
The labeled fixture corpus is under [`../../tests/fixtures/jev-evidence-screen/`](../../tests/fixtures/jev-evidence-screen/).

Refresh command:

```bash
bin/fm-test-run.sh tests/fm-jev-evidence-screen.test.sh
```

Expected output shape:

```text
ok - no-key path is report-only, needs_review, and no-network
ok - fixture corpus produces append-only ledger and required metrics
ok - screen requires separate ledger and summary outputs
ok - output aliases are rejected before receipts
ok - output preflight rejects bad targets before transport
ok - transport request omits packet extras
ok - summary metrics score only expected spans and complete token totals
ok - invalid usage values are filtered from receipts and metrics
ok - empty changed-file summaries route to needs_review
ok - empty fixture directory is rejected before receipts
ok - mode-specific inputs are rejected before receipts
ok - authority boundary exposes no approval or merge control
ok - json stdout surface is not part of the public contract
ok - malformed packet metadata is sanitized in receipts
ok - evidence span choices are validated as a bounded set
ok - low-confidence and malformed responses route to needs_review
ok - confidence floor is fixed inside the advisory pilot
ok - malformed confidence and fabricated span route to needs_review
ok - model id is the local requested model, not transport echo
ok - deterministic-failure precedence cannot be suppressed by Jev
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 ...
```

The test drives the public CLI with a fake TypeSafe command.
It proves the missing-key path does not invoke the transport, a second run appends rather than replaces ledger rows, the required summary is separate from the ledger, output aliases and unwritable targets fail before transport, request payloads omit changed-file and receipt extras, and usage/model metadata is sanitized before receipts.
It also proves low-confidence and malformed responses route to `needs_review`, malformed packet metadata and evidence-span choices stay bounded, unsupported-claim recall and the other required metrics are emitted, and a stale-head deterministic finding keeps `needs_review` even when the fake Jev answer reports support.

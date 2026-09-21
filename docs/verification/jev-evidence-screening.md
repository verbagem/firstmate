# Jev Evidence Screening Verification

Audience: maintainer verification.

This record supports the active guarantee that `bin/fm-jev-evidence-screen.sh` is report-only, appends advisory receipts, and preserves deterministic-review precedence.
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
ok - authority boundary exposes no approval or merge control
ok - low-confidence and malformed responses route to needs_review
ok - deterministic-failure precedence cannot be suppressed by Jev
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 ...
```

The test drives the public CLI with a fake TypeSafe command.
It proves the missing-key path does not invoke the transport, a second run appends rather than replaces ledger rows, low-confidence and malformed responses route to `needs_review`, unsupported-claim recall and the other required metrics are emitted, and a stale-head deterministic finding keeps `needs_review` even when the fake Jev answer reports support.

Observed on 2026-09-21 from this branch:

```text
FM_TEST_BEGIN 2026-09-21T19:04:20Z tests/fm-jev-evidence-screen.test.sh family=unclassified expected_gate_skip=none
ok - no-key path is report-only, needs_review, and no-network
ok - fixture corpus produces append-only ledger and required metrics
ok - authority boundary exposes no approval or merge control
ok - low-confidence and malformed responses route to needs_review
ok - deterministic-failure precedence cannot be suppressed by Jev
FM_TEST_END 2026-09-21T19:04:22Z tests/fm-jev-evidence-screen.test.sh exit=0 duration_ms=1637 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1775
FM_TEST_SUMMARY_FAMILY family=unclassified count=1 duration_ms=1637 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-jev-evidence-screen.test.sh duration_ms=1637
```

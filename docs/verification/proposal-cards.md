# Proposal-card verification

Audience: maintainer verification.

This record supports the active guarantee that the proposal-card owner validates deterministic decision-time classes and can render a read-only stalled-work recommendation without mutating the frozen scenario it describes.
The contract owner is [`bin/fm-proposal-card.sh`](../../bin/fm-proposal-card.sh).
The public-interface regression is [`tests/fm-proposal-card.test.sh`](../../tests/fm-proposal-card.test.sh).

## Read-only stalled-work recommendation

The frozen scenario is an upstream-reconciliation task parked after a restart invalidated its saved worker conversation.
Safe relaunch refused because the surviving endpoint opened outside the recorded isolated copy.
The branch and all work remain preserved.
Two prior relaunches timed out before completing validation.

The fixture card is [`tests/fixtures/proposal-card/stalled-upstream-reconciliation.json`](../../tests/fixtures/proposal-card/stalled-upstream-reconciliation.json).
The expected rendering is [`tests/fixtures/proposal-card/stalled-upstream-reconciliation.expected.out`](../../tests/fixtures/proposal-card/stalled-upstream-reconciliation.expected.out).
The test builds a disposable scenario tree containing task state, metadata, and a branch preservation receipt, makes that tree read-only, records a SHA-256 digest over every file, validates and renders the card through the public CLI, then records the digest again.
The test fails if validation accepts an invalid decision-time class, if rendering differs from the expected proposal card, if a rejection reason is required, if a supplied rejection reason is not preserved verbatim, or if any file in the frozen scenario changes.

Refresh command:

```bash
bin/fm-test-run.sh tests/fm-proposal-card.test.sh
```

Expected output shape:

```text
ok - stalled-work proposal card renders expected output with zero scenario mutation
ok - invalid decision-time classes are rejected at the executable boundary
ok - rejection path preserves optional why-not words without requiring a reason
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 ...
```

Observed on 2026-09-17 from this branch:

```text
FM_TEST_BEGIN 2026-09-17T18:19:18Z tests/fm-proposal-card.test.sh family=pure-contract-unit expected_gate_skip=none
ok - stalled-work proposal card renders expected output with zero scenario mutation
ok - invalid decision-time classes are rejected at the executable boundary
ok - rejection path preserves optional why-not words without requiring a reason
FM_TEST_END 2026-09-17T18:19:18Z tests/fm-proposal-card.test.sh exit=0 duration_ms=226 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=300
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=226 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-proposal-card.test.sh duration_ms=226
```

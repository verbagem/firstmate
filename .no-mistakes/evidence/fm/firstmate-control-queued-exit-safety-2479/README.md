# Firstmate queued-input lifecycle safety — test evidence

Intent: `exit`/`relaunch` must never concatenate a lifecycle command onto a
worker's already-queued composer text (turning control into chat), never enter
the conversational inbox, and never be reported as executed without a verified
outcome. Legitimate queued worker input must be preserved.

## What was exercised

- `tests/fm-control.test.sh` — behavior-level (stubbed session provider). New
  cases drive `exit`/`relaunch` against a busy worker with queued composer
  text, an idle worker with pending input, an unverifiable ("unknown") composer
  before interrupt, input restored *during* interrupt handling, and the
  post-interrupt redraw-settle path. Each asserts observable effects: no keys
  sent, no lifecycle text typed, nothing submitted as chat, queued bytes and the
  durable inbox message preserved byte-for-byte, worker left alive.
- `tests/fm-control-herdr-smoke.test.sh` — the same busy queued-input
  preservation against the **real `herdr` binary** end-to-end.
- `tests/fm-control-relaunch.test.sh`, `tests/fm-task-inbox.test.sh`,
  `tests/fm-secondmate-reconcile.test.sh` — all pass (relaunch transaction,
  inbox lock-race retry, reconcile).

## Regression proof (fails on old behavior, passes with fix)

Swapping in the base-commit (`ff68407`) `bin/fm-control.sh` and running the new
tests reproduces the defect — the old code has no composer guard and does not
refuse:

    not ok - exit refusal should identify the preserved queued instruction
             (missing: 'composer holds a queued instruction')

With the fix in place every guard test passes, including the real-herdr case.

## Operator-visible behavior (CLI transcript)

`operator-refusal-messages.txt` captures the exact stderr an operator sees. The
lifecycle command is refused as a refusal — not turned into chat, not submitted,
not journaled as a failed stop — and the queued instruction is left intact:

- busy worker, queued text: `task t1's composer holds a queued instruction; refusing lifecycle control until the worker consumes it`
- idle worker, pending text: `task t1's composer reads 'pending' with no interrupt sent; refusing to type a lifecycle command into unverified input`
- unreadable composer before interrupt: `task t1's composer reads 'unknown' before interrupt handling; refusing to risk clearing unverified input`

No rendered UI surface exists for this change — it is a terminal control-plane
(`fm-control.sh`); the CLI refusal transcript is the end-user artifact.

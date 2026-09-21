# Jev Evidence Screening

Audience: operator current behavior.

`bin/fm-jev-evidence-screen.sh` is an advisory-only pilot for evaluating evidence packets about claimed task completion.
It adapts two narrow patterns from the Jev repository audit: Canny's append-only completion ledger shape and deterministic-before-model sequencing, plus `jev-review`'s evidence-span triage.
It does not add a reviewer daemon, dashboard, approval system, delivery mode, or state machine.

The current fixture packet includes a claimed outcome, acceptance criteria, changed-file summaries, test or check receipts, evidence excerpts, and a known truth label.
The supported truth labels are `proven`, `unsupported`, `contradicted`, `ambiguous`, and `out-of-scope`.
The label is used for corpus metrics, not for approving work.

Deterministic checks run before any Jev advisory step.
They identify missing changed-file summaries, stale head evidence, failed or missing executable receipts, and out-of-scope changed files.
When a deterministic check needs review, the final recommendation remains `needs_review` even if Jev reports support.

The Jev step is narrow and optional.
It asks for direct support, contradiction, missing evidence category, risk category, and the evidence excerpt span that matters.
The default is report-only and no live TypeSafe transport is enabled unless a caller passes an explicit `--typesafe-command`.
Tests use a fake TypeSafe transport.
Missing keys, absent transport, transport errors, malformed responses, and below-floor confidence all route to `needs_review`.

The output is an append-only JSONL ledger plus a required summary.
The summary reports unsupported-claim recall, false-escalation rate, evidence-span quality, deterministic disagreement count, latency and cost totals, and abstention rate.
These metrics are for deciding whether a future integration is worth more study.

## Authority Boundary

The screening result is never completion proof.
It may suggest normal review or human/no-mistakes review priority, but it cannot pass or fail CI, approve a merge, certify completion, suppress a deterministic failure, answer an ask-user finding, or replace no-mistakes review.
The ledger repeats those false authority fields as `false` in every recommendation.

Proposal-card decision vocabulary remains owned by [`../bin/fm-proposal-card.sh`](../bin/fm-proposal-card.sh).
no-mistakes delivery and review authority remain owned by the no-mistakes path described in [`../CONTRIBUTING.md`](../CONTRIBUTING.md) and the installed no-mistakes skill.
TypeSafe live API assumptions remain owned by the typed dispatch resolver evidence in [`verification/dispatch-resolve.md`](verification/dispatch-resolve.md).

## Future Evaluation

Do not adopt this pilot into dispatch, CI, merge, completion, or ask-user handling from one green fixture run.
A future integration would need a larger labeled corpus, fresh live TypeSafe evidence, fixed confidence thresholds pinned to a concrete model version, and an error budget approved for advisory false positives and false negatives.
It would also need a non-interference regression proving that deterministic failures and no-mistakes findings still surface unchanged.

The first acceptance bar is metric quality, not authority.
Unsupported-claim recall should improve without an unacceptable false-escalation rate.
Evidence-span quality should show that the advisory answer points reviewers at the right receipt or excerpt.
Abstention should stay high when evidence is missing, malformed, low-confidence, or out of scope.
Only after that evidence exists should Firstmate consider a pointer from an existing owner, and that pointer must still preserve the advisory boundary above.

# Jev Evidence Screening

Audience: operator current behavior.

`bin/fm-jev-evidence-screen.sh` is an advisory-only stage for evaluating evidence packets about claimed task completion and suggesting review depth or relevant tests.
It adapts two narrow patterns from the Jev repository audit: Canny's append-only completion ledger shape and deterministic-before-model sequencing, plus `jev-review`'s evidence-span triage.
It does not add a reviewer daemon, dashboard, approval system, delivery mode, or state machine.

The current fixture packet includes a claimed outcome, acceptance criteria, changed-file summaries, test or check receipts, evidence excerpts, and a known truth label.
The supported truth labels are `proven`, `unsupported`, `contradicted`, `ambiguous`, and `out-of-scope`.
The label is used for corpus metrics, not for approving work.
Packets may also name bounded test candidates, identify required tests, mark an open captain decision, and carry numeric comparison observations for qualified low-risk review.
The executable owner validates the exact packet schema, mode-specific inputs, and `--help` usage.

Deterministic checks run before any Jev advisory step.
They identify malformed packets, missing changed-file summaries, stale head evidence, failed or missing executable receipts, out-of-scope changed files, and open captain decisions.
When a deterministic check needs review, the final recommendation remains `needs_review` even if Jev reports support.
The recommendation keeps deep review and every packet-declared required test in that case.

The Jev step is narrow and optional.
It asks for direct support, contradiction, missing evidence category, risk category, the evidence excerpt span that matters, review depth, and one relevant test candidate.
Review depth is limited to focused, standard, deep, or routing to an existing stronger reviewer.
The selected test is added to every packet-declared required test, so Jev cannot waive a required test.
The default is report-only and no live TypeSafe transport is enabled unless a caller passes an explicit `--typesafe-command`.
Tests use a fake TypeSafe transport.
Missing keys, absent transport, transport errors, malformed responses, and below-floor confidence all route to `needs_review`.
The transport request includes only packet id, claim, acceptance criteria, changed-file path and summary, receipt name/status/kind, bounded test candidates, the open-decision boolean, and evidence excerpt id/text.

The output is an append-only JSONL ledger plus a required summary.
The ledger and summary paths must be distinct non-symlink file paths; same-file aliases, hardlinks, directories, unwritable targets, and case-only future aliases are rejected before any transport call.
The ledger stores bounded reference ids, hashes of packet and claim content, sanitized numeric observations and usage metrics, and the local requested model id.
It does not store raw claims, evidence excerpts, arbitrary transport model text, or unbounded private prompt material.
The summary reports unsupported-claim recall, false-safe classifications, false-escalation rate, evidence-span quality, deterministic-failure preservation, required-test preservation, latency and cost totals, abstention rate, and a normalized reproducibility digest.
It measures strong-model review time and repeated test-selection turns only for proven, deterministic-clean packets that received focused review.
The summary sets `savings_claim_qualified` only when initial acceptance passes, both measured reductions are at least 20 percent, and no stop condition is present.

## Authority Boundary

The screening result is never completion proof.
It may prioritize depth inside the existing no-mistakes review path, suggest relevant tests, or recommend the existing stronger-reviewer lane.
It cannot pass or fail CI, approve a merge, certify completion, suppress a deterministic failure, waive a required test, answer a captain decision, or replace no-mistakes review.
The ledger repeats those false authority fields as `false` in every recommendation.

Proposal-card decision vocabulary remains owned by [`../bin/fm-proposal-card.sh`](../bin/fm-proposal-card.sh).
no-mistakes delivery and review authority remain owned by the no-mistakes path described in [`../CONTRIBUTING.md`](../CONTRIBUTING.md) and the installed no-mistakes skill.
TypeSafe live API assumptions remain owned by the typed dispatch resolver evidence in [`verification/dispatch-resolve.md`](verification/dispatch-resolve.md).

## Acceptance And Stop Conditions

The checked-in safe corpus contains 112 packets, including 104 parameterized triage cases and the eight accepted evidence-screen cases.
Initial acceptance requires at least 100 packets, unsupported-claim recall of at least 95 percent, zero false safe or focused-review classifications for unsupported or contradicted claims, deterministic-failure preservation, required-test preservation, and a stable normalized output digest.
The public regression covers supported, unsupported, contradicted, incomplete, malformed, absent-key, low-confidence, open-decision, and deterministic-failure cases.
Evaluation stops on a hidden or downgraded deterministic failure, a false safe classification, a required-test waiver, a captain-decision bypass, private prompt leakage, or any authority expansion.
The stage remains advisory even after those acceptance measures pass.

# Proposal Card

- Triggering source/evidence: A Firstmate upstream-reconciliation task is parked after a computer restart invalidated its saved worker conversation. Safe relaunch refused because the surviving endpoint opened outside the recorded isolated copy. The branch and all work remain preserved. Two prior relaunches timed out before completing validation.
- Proposed action: Open a five-minute captain review to authorize one supervised recovery attempt against the preserved isolated branch, with no cleanup, discard, merge, branch mutation, worker instruction, interrupt, or relaunch performed by this read-only recommendation.
- Why now: The preserved branch keeps the work recoverable, but repeated timeout evidence means another unattended relaunch could waste time or touch the wrong local copy.
- Expected impact: The captain can approve or decline a narrow recovery lane without losing the preserved work or creating a competing control plane.
- Decision time: five-minute review
- Risk/blast radius: Risk is limited to choosing the wrong recovery lane for one preserved Firstmate task; the blast radius grows only if someone cleans up, discards, merges, or drives the worker before authorization.
- Permission boundary: This card is read-only evidence. It does not send instructions, interrupt or relaunch a worker, alter task state, modify a branch, clean up files, spend money, contact anyone, publish externally, touch credentials, discard work, or merge anything.
- Proof/receipt: The receipt is the rendered proposal card plus an unchanged before/after digest of the frozen scenario fixture from tests/fm-proposal-card.test.sh.
- Rollback or stop condition: Stop if the isolated branch is no longer preserved, endpoint identity still points outside the recorded isolated copy, validation times out again, or the captain rejects the recovery.
- Recommended lane: Captain's Call through the existing captain-hold/Bearings path if the recommendation needs a durable decision; otherwise leave it as report evidence.
- Cadence: one-off

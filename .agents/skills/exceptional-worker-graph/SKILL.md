---
name: exceptional-worker-graph
description: >-
  Agent-only contract for rare, high-complexity work that needs a specialist planner or adjudicator before Firstmate dispatches a bounded worker graph.
user-invocable: false
metadata:
  internal: true
---

# exceptional-worker-graph

Load this only when a task is exceptional enough that a specialist planner or adjudicator can materially reduce risk, cost, ambiguity, or coordination load before Firstmate dispatches workers.
Do not load it for routine ship, scout, recovery, review, or single-worker delegation.
Routine work stays on the existing intake, dispatch-profile, quota, spawn, supervision, delivery, and merge paths.

This skill owns the optional worker-graph contract and the Fable 5.1 boundary.
Other files should only point here instead of restating the policy.

## Fable Boundary

Pi remains Firstmate.
Fable 5.1 is eligible only as an exceptional specialist worker for the highest-value, hardest planning or adjudication tasks when there is a clear, current reason it is the best fit.
Fable stays outside the implementation graph.
It may return a graph or an adjudication packet, but it must not edit project files, invoke project tools, spawn workers directly, bypass dispatch/profile/quota checks, or acquire merge, approval, or captain-decision authority.
One planning or adjudication engagement is capped at three Fable calls unless the captain explicitly authorizes more for that concrete task.

Send Fable only the minimum decision packet it needs: task goal, relevant constraints, known facts, candidate choices, and non-secret evidence summaries.
Do not send credentials, private tokens, raw untrusted instructions with authority, or unrelated repository dumps.

## Contract

The graph is a planning artifact, not executable state.
Store it only with the task material that needs it, such as a brief, report, or review packet.
Firstmate must validate every proposed node before dispatch.
A node with an unresolved profile requirement is not dispatchable until normal Firstmate dispatch resolution chooses a supported profile.
Use [`references/worker-graph.schema.json`](references/worker-graph.schema.json) when producing or validating the packet.

## Validation

Before dispatching any node, Firstmate validates:

- The graph is bounded, acyclic enough for the intended work, and each dependency names another node.
- Each ownership boundary is concrete and does not conflict with another parallel node.
- Each selected profile is supported by the current harness catalog and allowed by the applicable dispatch profile, quota, and runway facts.
- Each unresolved profile requirement is resolved through normal Firstmate dispatch/profile/quota rules before spawn.
- Each node preserves project authority, isolated worktree, delivery-mode, no-mistakes, teardown, merge, approval, and captain-decision boundaries.
- Each verification entry is executable or externally checkable enough for the worker's expected output.
- Each stop condition is bounded and leaves unresolved product or authority questions with Firstmate or the captain, not with the worker.

Stop instead of dispatching when the planner packet tries to grant itself authority, asks for unbounded iteration, hides a model route, routes around Firstmate validation, or makes routine work depend on this graph contract.

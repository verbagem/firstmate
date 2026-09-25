# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the typesafe.ai model, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

## Live rule match against real briefs

Run 2026-09-16 with the key injected for the one command through the vault (`av inject +TYPESAFE_API_KEY -- ...`), model `jev-latest`, confidence floor 0.6, timeout 5 s, one `quota-axi --json` snapshot for the whole run.
Rules: the captain's five-rule file with a captain-authored none option, one `approval: captain` rule, two rule floors on `model:fable`, and declared `provider` on the Pi profiles.
Briefs: 15 real briefs from this home's recent work plus 10 synthetic ones written to hit each rule.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 20 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 1 / 6 / 0 |
| Clear results with a wrong profile | 0 |
| API latency (min / median / max) | 152 / 214 / 348 ms |
| Wall time per call including jq (min / median / max) | 198 / 261 / 396 ms |
| Input tokens per brief (min / median / max) | 1,279 / 3,114 / 4,538 |
| Output tokens | 150 to 152 |
| API errors | 0 |

Of the five disagreements, one was a wrong hand label (the brief quoted the bug-fix rule's wording verbatim), three were real briefs the model read as the approval-gated design rule at 0.66 to 0.86 confidence and escalated by design, each of which the captain had in fact dispatched at the strongest-reasoning class, and one was a synthetic tweak that came back ambiguous at 0.41 confidence and was handed back to firstmate.
A lean request that asks only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs, which is why the shipped tool asks one question and keeps every gate in code.
That table records the 2026-09-16 run with the captain-authored none option.
A second live run on 2026-09-17 used the same 25 briefs, held one quota snapshot constant through a fake `quota-axi`, and exercised a copy of this branch with the shipped neutral `No listed rule applies to this task.` option and option-free interface.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 18 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 17 / 2 / 6 / 0 |
| Clear results with a profile other than the hand label | 1 |
| API latency (min / median / max) | 137 / 220 / 1,795 ms |
| Input tokens per brief (min / median / max) | 754 / 2,589 / 4,013 |
| Output tokens | 60 to 62 |
| API errors | 0 |

The maximum latency was one outlier; the next slowest request was 309 ms.
The differing clear result was a synthetic small tweak that matched the simple-bug-fix rule at 0.90 and selected `cursor-grok-4.6-medium` instead of the hand-labeled `cursor-grok-4.6-high`: the tweak exemption removed from the none-option text belongs in that rule's own `when` text.
Two default-labeled briefs became ambiguous.

## Live launch realization

Verified 2026-09-24 with Cursor Agent `v2026.09.23-86fc751`, TypeSafe model `jev-1.13.0`, and the installed `gpt-5.6-sol-medium` catalog entry.
The probe used an isolated throwaway project and home, a no-write scout brief, the real TypeSafe API, the real quota snapshot, and the public spawn interface without explicit harness, model, or effort flags.

```console
$ TYPESAFE_API_KEY=<injected> FM_HOME=<isolated-home> bin/fm-spawn.sh live-cursor-e2e <isolated-project> --scout
spawned live-cursor-e2e harness=cursor kind=scout ...
$ jq -c '{task,resolver,selected,launched,quota_facts,divergence_reason}' <isolated-home>/state/dispatch-receipts.jsonl
{"task":"live-cursor-e2e","resolver":{"status":"clear","model":"jev-1.13.0","tokens":{"input_tokens":417,"output_tokens":35},"confidence":0.83},"selected":{"harness":"cursor","model":"gpt-5.6-sol-medium","effort":"default"},"launched":{"harness":"cursor","model":"gpt-5.6-sol-medium","effort":"default"},"quota_facts":[{"harness":"cursor","model":"gpt-5.6-sol-medium","effort":null,"provider":"cursor","eligible":true,"scope":"all_models","remaining_percent":97,"spend_priority":3.0107,"runway":"through_reset","bounds":[{"scope":"all_models","status":"known","pct":97,"runway":"through_reset","spendPriority":3.0107}],"reason":"ok"}],"divergence_reason":"none"}
```

The real worker rendered `GPT-5.6 Sol ... Medium`, replied `READY`, and returned to its idle follow-up prompt.
The selected and launched profiles matched, the receipt carried the current provider facts, and there was no unexplained divergence.
The probe made no project changes and was stopped and cleaned through the guarded lifecycle commands after evidence capture.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It also proves the opt-in JSON surface reports that path as `off` without adding a dependency on either command.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the fixed endpoint and model, carries only the project, brief, and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It proves the JSON composition surface preserves only parsed selection and quota evidence and contains neither the brief nor key.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, explicit-provider multi-provider harness routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key and validates resolver-only malformed shapes when the home `.env` activates typed resolution.
`tests/fm-spawn-dispatch-profile.test.sh` proves every typed launch intake emits one private selected-versus-launched receipt across absent-key, clear, ambiguous, escalation, error, ineligible-candidate, and launch-refusal paths.
It proves a clear medium-reasoning Cursor selection reaches the Cursor worker command without repeated profile flags, matching selected and launched fields are recorded with Jev model/token/confidence and current quota facts, an unexplained clear divergence is refused, and an ineligible candidate cannot be launched through the supported override flag.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
$ bash tests/fm-spawn-dispatch-profile.test.sh | tail -1
# all fm-spawn-dispatch-profile tests passed
```

The live API table and live launch proof both need a key and are not part of the suite; refresh the table with an injected-key resolver run, and refresh launch realization with an isolated `fm-spawn.sh --scout` probe.

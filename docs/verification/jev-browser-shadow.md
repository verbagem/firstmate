# Jev browser action shadow pilot verification

Audience: maintainer verification.

This record supports the bounded pilot in [`../../bin/fm-jev-browser-shadow.sh`](../../bin/fm-jev-browser-shadow.sh).
The script header owns the exact command-line contract, fixture input shape, transport injection, and receipt fields.
This page records the current verification evidence for the pilot's safety boundary.

Live TypeSafe behavior is not claimed here.
The evidence below is offline fixture evidence using an injectable fake TypeSafe transport, because the pilot must be fixture-only and must not depend on network credentials for CI.

## QA handback

Absolute verification paths for this worktree are listed as literals because the documentation checker forbids absolute local Markdown links:

- Script: `/Users/temp/.treehouse/firstmate-29202e/2/firstmate/bin/fm-jev-browser-shadow.sh` ([relative link](../../bin/fm-jev-browser-shadow.sh))
- Focused test: `/Users/temp/.treehouse/firstmate-29202e/2/firstmate/tests/fm-jev-browser-shadow.test.sh` ([relative link](../../tests/fm-jev-browser-shadow.test.sh))
- Fixture tasks: `/Users/temp/.treehouse/firstmate-29202e/2/firstmate/tests/fixtures/jev-browser-shadow/tasks.json` ([relative link](../../tests/fixtures/jev-browser-shadow/tasks.json))
- Fake TypeSafe transport: `/Users/temp/.treehouse/firstmate-29202e/2/firstmate/tests/fixtures/jev-browser-shadow/fake-typesafe.sh` ([relative link](../../tests/fixtures/jev-browser-shadow/fake-typesafe.sh))
- Offline summary: `/Users/temp/.treehouse/firstmate-29202e/2/firstmate/docs/verification/jev-browser-shadow-offline-summary.json` ([relative link](jev-browser-shadow-offline-summary.json))
- Offline receipts: `/Users/temp/.treehouse/firstmate-29202e/2/firstmate/docs/verification/jev-browser-shadow-offline-receipts.jsonl` ([relative link](jev-browser-shadow-offline-receipts.jsonl))

## Acceptance map

| Requirement | Evidence |
| --- | --- |
| Bounded Jev browser-action shadow pilot without adopting `browser-use/jev-ultrafast` or replacing `chrome-devtools-axi` | The script is a standalone fixture consumer; it does not start a browser or call `chrome-devtools-axi`, and the boundary section below states existing browser lifecycle owners remain outside the helper. |
| Deterministic local/read-only fixtures only, with forbidden state-changing browser actions rejected | The 24 fixture tasks include local HTML and a read-only public navigation fixture; validation rejects submit, purchase, booking, message, login, delete, upload, download, and external-state-change risks. |
| Validated element/action table with stable ids, compatibility constraints, state hash, task goal, and bounded history | The request state contains goal, page identity, state hash, bounded recent action history, and sanitized action rows with stable ids, operation compatibility, enabled state, and risk tags. |
| Narrow TypeSafe Choice for operation and target with freshness validation before recording | The request asks `operation` and `target` Choice questions, then code validates confidence, hash freshness, target existence, compatibility, forbidden tags, and optional allowlist before receipt output. |
| Shadow-only default, optional local-fixture execution flag gated by deterministic allowlist | Default receipts use `valid-shadow`; `--execute-local-fixture` only changes the receipt outcome for local fixtures with `local_fixture_allowlist` and still does not drive a browser. |
| Injectable fake TypeSafe transport and safe missing-key/provider failure behavior | `--transport-command` injects the fake transport; absent key, provider failure, malformed response, and low confidence produce non-clear receipts and no action. |
| Row-level JSONL receipts and aggregate metrics | The saved receipts have 24 rows with state hash, question version, model, probabilities/confidence, selected action, validation result, expected action, and outcome; the summary reports success, top-choice accuracy, wrong-action rate, stale rejection, calibration, latency/cost, and human override count. |
| Focused public-interface tests | `tests/fm-jev-browser-shadow.test.sh` covers fake API, no-key/no-network, provider failure, malformed response, low confidence, action compatibility, safety allowlist, and required receipt fields. |

## Boundary

Verified 2026-09-21.
The pilot consumes deterministic fixture observations that already contain a stable element/action table.
It does not start a browser, drive `chrome-devtools-axi`, submit forms, buy, book, message, log in, delete, upload, download, or mutate external state.
Default mode is shadow-only: it records a recommendation after validation and never executes it.
`--execute-local-fixture` only changes the receipt outcome when the page is explicitly local and the selected action carries a matching `local_fixture_allowlist`; the helper still does not drive a browser.

The TypeSafe request asks two Choice questions over the same observed state: one operation and one stable target id.
The state includes task goal, page URL and title, the state hash, bounded recent action history, and a sanitized action table.
It excludes full page HTML, secrets, cookies, credentials, private fleet state, and expected answers.

After the response, code validates confidence, page freshness, target existence, operation compatibility, forbidden-action tags, and optional local-fixture allowlist status before recording a receipt.
Missing key, provider failure, malformed response, and low confidence all produce non-clear receipts and no action.

## Fixture coverage

`tests/fixtures/jev-browser-shadow/tasks.json` currently contains 24 local or read-only fixture tasks.
They cover local navigation, clicking, typing into local fields, stale page rejection, stale action rejection, no-compatible-action, prompt-injection text, ambiguous options, read-only public navigation, operation compatibility, and forbidden submit, purchase, booking, message, login, download, upload, delete, and external-state-change actions.

## Offline behavior

`tests/fm-jev-browser-shadow.test.sh` drives the public command with an injectable fake TypeSafe transport.
It verifies the 24-task fixture report, row-level JSONL receipts, missing-key/no-network behavior, provider failure, malformed response, low confidence, action compatibility, and the optional local-fixture safety allowlist.
The saved offline summary is [`jev-browser-shadow-offline-summary.json`](jev-browser-shadow-offline-summary.json), and the saved row-level receipts are [`jev-browser-shadow-offline-receipts.jsonl`](jev-browser-shadow-offline-receipts.jsonl).

```console
$ bash tests/fm-jev-browser-shadow.test.sh
ok - fake TypeSafe transport over twenty-four fixture tasks records metrics and receipts
ok - no-key/no-network path produces safe non-clear receipts
ok - provider failure records no action
ok - malformed response records no action
ok - low confidence records no action
ok - action compatibility is enforced after model choice
ok - safety allowlist gates the optional local-fixture execution mode
# all fm-jev-browser-shadow tests passed
```

The fixture report exposes success rate, top-choice accuracy, wrong-action rate, stale-action rejection count, confidence calibration, latency and cost fields, and human override count.
Live TypeSafe runs are intentionally outside the automated suite; inject a key for one operator-run command only when refreshing live model evidence.

# Jev Context-Retention Replay

Status: `pass`
Fixture transcripts: `30`
Proposal source: `fake-transport:/Users/temp/.no-mistakes/evidence/01M3B41HWQGFCCX0P0TB09A0PX/jev-context-replay/fake-typesafe.py`
Proposal model: `jev-evidence-fake`
Latency ms: `428`
Input tokens: `1000`
Output tokens: `60`
Estimated TypeSafe cost USD: `4.2e-05`
False drop rate denominator: protected segment rows; zero protected rows reports `0`.

| Strategy | Answerable | Unanswerable | Missing constraints | Missing evidence | Retention ratio | False drop rate | False drops |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 30 | 0 | 0 | 0 | 0.804753 | 0 | 0 |
| jev | 30 | 0 | 0 | 0 | 0.771674 | 0 | 0 |

Failures:
- none

Ledger: `ledger.jsonl`

Boundary: this report is generated from sanitized fixtures only and is not an automatic compactor.

# Local Inference Verification

Date: 2026-09-02.
Scope: active maintainer evidence for `bin/fm-local-inference.sh`.

## Guarantees

The local-inference surface is inert without an explicit invocation and local catalog.
Catalog validation rejects unknown fields and non-loopback endpoints.
Ranking accounts for memory reserve, requested context, required capability flags, and unknown available memory.
Probe performs bounded OpenAI-compatible `/models` discovery against loopback endpoints and reports timeout or HTTP failures without credentials.
No Magnitude source file, dependency, or Apache-2.0 licensed implementation body was copied into Firstmate for this feature.
The implementation is a new Firstmate CLI and test fixture that independently implements the catalog, hardware, ranking, and loopback-probe patterns.

Harness and runtime backend axes are not applicable in this release.
No supported worker harness or runtime backend reads this catalog, and no dispatch integration exists.

## Evidence

Command:

```sh
bin/fm-local-inference.sh catalog --catalog docs/examples/local-inference-catalog.json
```

Output:

```text
catalog=valid providers=1 models=1
provider=example-loopback endpoint=local-openai-v1 type=openai-compatible models=1
```

Command:

```sh
bin/fm-local-inference.sh rank --catalog docs/examples/local-inference-catalog.json --context-tokens 32768 --reserve-mib 2048 --require-capability chat
```

Output:

```text
ranking models=1 reserve_mib=2048 requested_context_tokens=32768 available_memory_mib=88
rank=1 model=example/qwen3-8b-q4 provider=example-loopback admission=rejected memory_mib=6144 context=32768 reasons=insufficient-memory-headroom
```

Command:

```sh
rg -n "from '.*magnitude|from \".*magnitude|@magnitudedev|magnitude/" bin/fm-local-inference.mjs tests/fm-local-inference.test.sh docs/local-inference.md docs/examples/local-inference-catalog.json || true
```

Output:

```text
```

Command:

```sh
node --check bin/fm-local-inference.mjs
```

Output:

```text
```

Command:

```sh
bash -n bin/fm-local-inference.sh tests/fm-local-inference.test.sh
```

Output:

```text
```

Command:

```sh
bin/fm-test-run.sh tests/fm-local-inference.test.sh
```

Output:

```text
FM_TEST_BEGIN 2026-09-02T21:05:37Z tests/fm-local-inference.test.sh family=pure-contract-unit expected_gate_skip=none
ok - default status is inert when no opt-in catalog exists
ok - catalog validation is strict and JSON output is deterministic
ok - ranking accounts for reserve, requested context, and unknown hardware
ok - probe is bounded to loopback model discovery and reports failure classes
FM_TEST_END 2026-09-02T21:05:38Z tests/fm-local-inference.test.sh exit=0 duration_ms=1706 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1801
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=1706 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-local-inference.test.sh duration_ms=1706
```

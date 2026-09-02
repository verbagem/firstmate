# Local Inference Inspection

Firstmate can inspect an opt-in local-inference catalog with `bin/fm-local-inference.sh`.
This feature is inert by default: no startup path reads the catalog, no dispatcher consumes it, and no background service is installed.

The current owner is inspection only.
It validates a machine-readable catalog, reports a bounded hardware inventory, ranks configured models against memory and context constraints, and probes explicitly configured loopback OpenAI-compatible `/models` endpoints.
It never starts, kills, unloads, evicts, downloads, routes to, or configures a local model provider.
The implementation independently reuses the local-inference patterns from the Magnitude audit; no Magnitude source code is copied.

## Setup

Use a local catalog file and pass it explicitly:

```sh
bin/fm-local-inference.sh catalog --catalog docs/examples/local-inference-catalog.json
bin/fm-local-inference.sh rank --catalog docs/examples/local-inference-catalog.json --context-tokens 32768 --reserve-mib 2048 --require-capability chat
```

Copy that schema shape into a local, gitignored `config/local-inference-catalog.json` when configuring a real provider.
Then probe the configured provider:

```sh
bin/fm-local-inference.sh probe --catalog config/local-inference-catalog.json --provider llama-cpp --timeout-ms 3000
```

If no command is supplied, the tool prints only whether the default local path `config/local-inference-catalog.json` exists and validates.
That default is a convenience for manual inspection, not a dispatch integration.

## Catalog Schema

The catalog is strict JSON with `version: 1`.
Unknown fields are rejected with their exact path.
Provider URLs must be loopback HTTP(S) URLs with no embedded credentials, query string, or fragment.

```json
{
  "version": 1,
  "providers": [
    {
      "id": "llama-cpp",
      "endpoint_id": "loopback-main",
      "type": "openai-compatible",
      "base_url": "http://127.0.0.1:10100/v1",
      "models": [
        {
          "id": "local/qwen3-8b-q4",
          "upstream_id": "qwen3-8b-q4",
          "quantization": "Q4_K_M",
          "context_tokens": 32768,
          "estimated_memory_mib": 6144,
          "capabilities": {
            "chat": true,
            "tools": false,
            "json_mode": true
          },
          "license": "apache-2.0",
          "speed_evidence": {
            "tokens_per_second": 35,
            "source": "local benchmark"
          },
          "intelligence_evidence": {
            "score": 7.2,
            "source": "maintainer benchmark"
          }
        }
      ]
    }
  ]
}
```

Supported provider type is `openai-compatible`.
Supported capability flags are `chat`, `tools`, `vision`, `embeddings`, `reasoning`, and `json_mode`.
Every model must declare stable Firstmate model identity, upstream endpoint model identity, provider and endpoint identity through its provider, quantization, context capacity, estimated memory, capabilities, and license.
Speed and intelligence evidence are optional and used only as deterministic ranking tie-breakers.

## Hardware And Ranking

`bin/fm-local-inference.sh hardware` prints portable local inventory with platform, architecture, CPU model, total memory, available memory, and source.
Linux prefers `/proc/meminfo` and uses `MemAvailable` when present.
Other supported hosts use Node's operating-system inventory and report unknowns when a value cannot be read.

Ranking is deterministic and read-only:

```sh
bin/fm-local-inference.sh rank --catalog config/local-inference-catalog.json --context-tokens 32768 --reserve-mib 2048 --json
```

A model is rejected when the requested context exceeds its declared context capacity, when a required capability is false or absent, or when its estimated memory exceeds available memory after the reserve is subtracted.
When available memory is unknown, memory admission is `unknown` with `available-memory-unknown` rather than guessed.
Ranking order is admitted, then unknown, then rejected; within each group it sorts by optional intelligence evidence, optional speed evidence, smaller memory estimate, provider id, and model id.

## Probe Boundary

`probe` sends one unauthenticated GET request to the configured provider's OpenAI-compatible `/models` URL.
It accepts only loopback provider URLs, sends no Authorization header, no `x-api-key`, no cookies, and no caller-provided headers.
It reports sanitized classes: `ok`, `http-error`, `timeout`, `network-error`, or `unsupported-provider`.

The probe does not prove a model can answer a generation request.
It proves only that the configured loopback provider exposes a bounded `/models` discovery surface at that moment.

## Compatibility

macOS and Linux are supported for bounded hardware inventory and loopback probes.
When platform-specific memory sources are unavailable, the tool reports unknown values instead of substituting guesses.
Windows is not a supported Firstmate platform in the current README platform contract, so no Windows-specific collection path is implemented.

Harness and worker-tool implications are explicitly inapplicable in this release.
Claude, Codex, OpenCode, Pi, `pi-signed`, Grok, Kimi, Cursor, Muse, tmux, Herdr, Zellij, Orca, cmux, watcher supervision, secondmates, and no-mistakes do not read this catalog or route from it.
Future dispatch integration must use this output as evidence and still preserve Firstmate as the sole owner of worker identity, sessions, messages, interrupts, policy, orchestration, and lifecycle.

## Limitations

The tool does not install Magnitude, Ollama, llama.cpp, model weights, startup services, or harness configuration.
It does not forward credentials or use cloud APIs.
Memory estimates are trusted catalog inputs, not measured resident set size.
Admission answers only whether the declared estimate fits current reported memory after reserve, not whether the provider will load or serve the model successfully.

Current behavior is verified in [`docs/verification/local-inference.md`](verification/local-inference.md).

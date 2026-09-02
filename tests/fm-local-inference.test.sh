#!/usr/bin/env bash
# Behavior tests for fm-local-inference.sh, the inert local-inference inspection
# surface.
#
# The suite drives only the public CLI. It proves strict catalog validation,
# deterministic JSON output, memory/context admission, explicit unknown hardware,
# and loopback-only OpenAI-compatible model discovery without credentials or
# lifecycle authority.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-inference)
SCRIPT="$ROOT/bin/fm-local-inference.sh"

write_catalog() { # <path> <base-url>
  local out=$1 base_url=$2
  cat > "$out" <<JSON
{
  "version": 1,
  "providers": [
    {
      "id": "llama-cpp",
      "endpoint_id": "loopback-main",
      "type": "openai-compatible",
      "base_url": "$base_url",
      "models": [
        {
          "id": "local/small",
          "upstream_id": "small-q4",
          "quantization": "Q4_K_M",
          "context_tokens": 32768,
          "estimated_memory_mib": 4096,
          "capabilities": {
            "chat": true,
            "json_mode": true,
            "tools": false
          },
          "license": "apache-2.0",
          "speed_evidence": {
            "tokens_per_second": 42,
            "source": "fixture"
          },
          "intelligence_evidence": {
            "score": 7.5,
            "source": "fixture"
          }
        },
        {
          "id": "local/large",
          "upstream_id": "large-q5",
          "quantization": "Q5_K_M",
          "context_tokens": 65536,
          "estimated_memory_mib": 7000,
          "capabilities": {
            "chat": true,
            "json_mode": true,
            "tools": true
          },
          "license": "llama-community",
          "intelligence_evidence": {
            "score": 9.1,
            "source": "fixture"
          }
        },
        {
          "id": "local/tiny-context",
          "upstream_id": "tiny-q4",
          "quantization": "Q4_0",
          "context_tokens": 4096,
          "estimated_memory_mib": 1024,
          "capabilities": {
            "chat": true
          },
          "license": "mit"
        }
      ]
    }
  ]
}
JSON
}

write_hardware() { # <path> <available-or-null>
  local out=$1 available=$2
  cat > "$out" <<JSON
{
  "schema": "fm-local-inference-hardware.v1",
  "platform": "fixture-os",
  "arch": "fixture-arch",
  "memory": {
    "total_mib": 16384,
    "available_mib": $available,
    "source": "fixture"
  },
  "cpu": {
    "logical_cores": 8,
    "model": "fixture"
  }
}
JSON
}

json_get() { # <json> <expr>
  # shellcheck disable=SC2016 # JavaScript reads process.argv[1]; shell expansion is not wanted here.
  node -e 'const fs=require("fs"); const obj=JSON.parse(fs.readFileSync(0,"utf8")); const fn=new Function("obj", `return ${process.argv[1]}`); const value=fn(obj); if (Array.isArray(value)) console.log(value.join(",")); else console.log(value);' "$2" <<<"$1"
}

test_status_is_inert_without_catalog() {
  local home out
  home="$TMP_ROOT/status-home"
  mkdir -p "$home/config"
  out=$(FM_HOME="$home" "$SCRIPT")
  assert_contains "$out" 'local-inference=disabled' "default status should be disabled without a catalog"
  [ ! -e "$home/config/local-inference-catalog.json" ] \
    || fail "status created a local-inference catalog"
  pass "default status is inert when no opt-in catalog exists"
}

test_catalog_validation_and_deterministic_json() {
  local catalog out1 out2 bad rc=0 err
  catalog="$TMP_ROOT/catalog.json"
  write_catalog "$catalog" 'http://127.0.0.1:10100/v1'

  out1=$("$SCRIPT" catalog --catalog "$catalog" --json)
  out2=$("$SCRIPT" catalog --catalog "$catalog" --json)
  [ "$out1" = "$out2" ] || fail "catalog JSON output changed between identical runs"
  [ "$(json_get "$out1" 'obj.schema')" = 'fm-local-inference-catalog.v1' ] \
    || fail "catalog JSON did not name its schema"
  assert_contains "$("$SCRIPT" catalog --catalog "$catalog")" 'catalog=valid providers=1 models=3' \
    "compact catalog output missing expected summary"

  bad="$TMP_ROOT/catalog-unknown-field.json"
  cp "$catalog" "$bad"
  node -e 'const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8")); x.providers[0].models[0].surprise=true; fs.writeFileSync(p, JSON.stringify(x, null, 2));' "$bad"
  set +e
  err=$("$SCRIPT" catalog --catalog "$bad" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "catalog with an unknown field should fail"
  assert_contains "$err" 'catalog.providers[0].models[0].surprise: unsupported field' \
    "unknown catalog field was not reported precisely"

  bad="$TMP_ROOT/catalog-nonloopback.json"
  write_catalog "$bad" 'http://example.com/v1'
  set +e
  err=$("$SCRIPT" catalog --catalog "$bad" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "non-loopback endpoint should fail validation"
  assert_contains "$err" 'base_url: non-loopback-host' \
    "non-loopback validation failure did not name the boundary"
  pass "catalog validation is strict and JSON output is deterministic"
}

test_ranking_accounts_for_memory_context_and_unknowns() {
  local catalog hardware unknown out first reasons admission
  catalog="$TMP_ROOT/rank-catalog.json"
  hardware="$TMP_ROOT/hardware.json"
  unknown="$TMP_ROOT/hardware-unknown.json"
  write_catalog "$catalog" 'http://127.0.0.1:10100/v1'
  write_hardware "$hardware" 8192
  write_hardware "$unknown" null

  out=$("$SCRIPT" rank --catalog "$catalog" --hardware "$hardware" --context-tokens 32768 --reserve-mib 2048 --require-capability chat --json)
  first=$(json_get "$out" 'obj.results[0].model_id')
  [ "$first" = 'local/small' ] || fail "expected local/small to rank first, got $first"
  admission=$(json_get "$out" 'obj.results.find((row) => row.model_id === "local/large").admission')
  [ "$admission" = rejected ] || fail "large model should reject on memory headroom"
  reasons=$(json_get "$out" 'obj.results.find((row) => row.model_id === "local/large").reasons')
  assert_contains "$reasons" 'insufficient-memory-headroom' "large rejection missed memory reason"
  reasons=$(json_get "$out" 'obj.results.find((row) => row.model_id === "local/tiny-context").reasons')
  assert_contains "$reasons" 'requested-context-exceeds-capacity' "tiny-context rejection missed context reason"

  out=$("$SCRIPT" rank --catalog "$catalog" --hardware "$unknown" --context-tokens 4096 --reserve-mib 2048 --json)
  admission=$(json_get "$out" 'obj.results.find((row) => row.model_id === "local/small").admission')
  [ "$admission" = unknown ] || fail "unknown available memory should produce unknown admission"
  reasons=$(json_get "$out" 'obj.results.find((row) => row.model_id === "local/small").reasons')
  assert_contains "$reasons" 'available-memory-unknown' "unknown memory did not produce an explicit reason"
  pass "ranking accounts for reserve, requested context, and unknown hardware"
}

start_models_server() { # <mode>
  local mode=$1 dir port_file pid_file
  dir="$TMP_ROOT/server-$mode"
  mkdir -p "$dir"
  port_file="$dir/port"
  pid_file="$dir/pid"
  node - "$mode" "$port_file" > "$dir/server.out" 2> "$dir/server.err" <<'NODE' &
const http = require('http');
const mode = process.argv[2];
const portFile = process.argv[3];
const fs = require('fs');
const server = http.createServer((req, res) => {
  if (req.url !== '/v1/models') {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  if (req.headers.authorization || req.headers['x-api-key'] || req.headers.cookie) {
    res.writeHead(400);
    res.end('unexpected credential header');
    return;
  }
  if (mode === 'slow') {
    setTimeout(() => {
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(JSON.stringify({data: [{id: 'slow'}]}));
    }, 500);
    return;
  }
  if (mode === 'fail') {
    res.writeHead(503);
    res.end('unavailable');
    return;
  }
  res.writeHead(200, {'content-type': 'application/json'});
  res.end(JSON.stringify({data: [{id: 'beta'}, {id: 'alpha'}]}));
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
NODE
  printf '%s\n' "$!" > "$pid_file"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$port_file" ] && break
    sleep 0.1
  done
  [ -s "$port_file" ] || fail "test server did not publish a port"
  printf '%s|%s\n' "$(<"$port_file")" "$(<"$pid_file")"
}

test_probe_loopback_models_timeout_and_failure() {
  local ok_rec slow_rec fail_rec ok_port slow_port fail_port ok_pid slow_pid fail_pid
  local catalog out models status http_status
  ok_rec=$(start_models_server ok)
  slow_rec=$(start_models_server slow)
  fail_rec=$(start_models_server fail)
  ok_port=${ok_rec%%|*}
  ok_pid=${ok_rec#*|}
  slow_port=${slow_rec%%|*}
  slow_pid=${slow_rec#*|}
  fail_port=${fail_rec%%|*}
  fail_pid=${fail_rec#*|}
  FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT/server-ok" "$TMP_ROOT/server-slow" "$TMP_ROOT/server-fail")
  trap 'kill "$ok_pid" "$slow_pid" "$fail_pid" 2>/dev/null || true; fm_test_cleanup; exit 130' INT
  trap 'kill "$ok_pid" "$slow_pid" "$fail_pid" 2>/dev/null || true; fm_test_cleanup; exit 143' TERM
  trap 'kill "$ok_pid" "$slow_pid" "$fail_pid" 2>/dev/null || true; fm_test_cleanup' EXIT

  catalog="$TMP_ROOT/probe-catalog.json"
  cat > "$catalog" <<JSON
{
  "version": 1,
  "providers": [
    {
      "id": "ok",
      "endpoint_id": "ok-endpoint",
      "type": "openai-compatible",
      "base_url": "http://127.0.0.1:$ok_port/v1",
      "models": [
        {
          "id": "catalog/alpha",
          "upstream_id": "alpha",
          "quantization": "Q4",
          "context_tokens": 8192,
          "estimated_memory_mib": 2048,
          "capabilities": {
            "chat": true
          },
          "license": "fixture"
        }
      ]
    },
    {
      "id": "slow",
      "endpoint_id": "slow-endpoint",
      "type": "openai-compatible",
      "base_url": "http://localhost:$slow_port/v1",
      "models": [
        {
          "id": "catalog/slow",
          "upstream_id": "slow",
          "quantization": "Q4",
          "context_tokens": 8192,
          "estimated_memory_mib": 2048,
          "capabilities": {
            "chat": true
          },
          "license": "fixture"
        }
      ]
    },
    {
      "id": "fail",
      "endpoint_id": "fail-endpoint",
      "type": "openai-compatible",
      "base_url": "http://127.0.0.1:$fail_port/v1",
      "models": [
        {
          "id": "catalog/fail",
          "upstream_id": "fail",
          "quantization": "Q4",
          "context_tokens": 8192,
          "estimated_memory_mib": 2048,
          "capabilities": {
            "chat": true
          },
          "license": "fixture"
        }
      ]
    }
  ]
}
JSON

  out=$("$SCRIPT" probe --catalog "$catalog" --provider ok --json)
  status=$(json_get "$out" 'obj.status')
  [ "$status" = ok ] || fail "healthy probe returned $status"
  models=$(json_get "$out" 'obj.models_discovered')
  [ "$models" = 'alpha,beta' ] || fail "probe did not sort discovered model ids: $models"

  out=$("$SCRIPT" probe --catalog "$catalog" --provider slow --timeout-ms 50 --json)
  status=$(json_get "$out" 'obj.status')
  [ "$status" = timeout ] || fail "slow probe returned $status instead of timeout"

  out=$("$SCRIPT" probe --catalog "$catalog" --provider fail --json)
  status=$(json_get "$out" 'obj.status')
  http_status=$(json_get "$out" 'obj.http_status')
  [ "$status" = 'http-error' ] || fail "failing probe returned $status instead of http-error"
  [ "$http_status" = 503 ] || fail "failing probe did not expose sanitized HTTP status"
  assert_contains "$("$SCRIPT" probe --catalog "$catalog" --provider ok)" 'provider=ok endpoint=ok-endpoint status=ok http_status=200 discovered=2' \
    "compact probe output missed expected status"
  kill "$ok_pid" "$slow_pid" "$fail_pid" 2>/dev/null || true
  trap fm_test_cleanup EXIT
  trap 'fm_test_cleanup; exit 130' INT
  trap 'fm_test_cleanup; exit 143' TERM
  pass "probe is bounded to loopback model discovery and reports failure classes"
}

test_status_is_inert_without_catalog
test_catalog_validation_and_deterministic_json
test_ranking_accounts_for_memory_context_and_unknowns
test_probe_loopback_models_timeout_and_failure

#!/usr/bin/env bash
# fm-local-inference.sh - inspect opt-in local-inference catalog, hardware, ranking, and loopback probes.
#
# This is an introspection surface only.
# It never starts, stops, downloads, unloads, evicts, routes, writes harness config, or launches workers.
#
# Usage:
#   fm-local-inference.sh [status] [--catalog <path>] [--json]
#   fm-local-inference.sh catalog --catalog <path> [--json]
#   fm-local-inference.sh hardware [--json]
#   fm-local-inference.sh rank --catalog <path> [--hardware <path>] [--context-tokens <n>] [--reserve-mib <n>] [--require-capability <name>] [--json]
#   fm-local-inference.sh probe --catalog <path> --provider <id> [--timeout-ms <n>] [--json]
#
# Catalog schema owner: this header plus the JSON validator in fm-local-inference.mjs.
# The default catalog path for status is config/local-inference-catalog.json under
# the effective FM_HOME, but no command reads it unless this script is invoked.
# Provider endpoints are restricted to loopback URLs with no embedded credentials.
# Probe sends no Authorization, x-api-key, cookies, or caller-provided headers.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  printf 'fm-local-inference: node is required for strict JSON validation.\n' >&2
  exit 127
fi

exec node "$SCRIPT_DIR/fm-local-inference.mjs" "$@"

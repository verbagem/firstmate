#!/usr/bin/env bash
# fm-jev-evidence-screen.sh - advisory-only Jev evidence/completion screening pilot.
#
# This tool evaluates synthetic or captured evidence packets and appends report-only
# receipts.
# It never passes or fails CI, approves a merge, certifies completion, suppresses a
# deterministic failure, answers an ask-user finding, starts a daemon, or writes to
# Firstmate runtime state.
#
# Usage:
#   fm-jev-evidence-screen.sh screen --packet <packet.json> --ledger <ledger.jsonl> --summary <summary.json> [--typesafe-command <path>]
#   fm-jev-evidence-screen.sh evaluate --fixtures <dir> --ledger <ledger.jsonl> --summary <summary.json> [--typesafe-command <path>]
#
# Packet schema owner: bin/fm-jev-evidence-screen.mjs.
# Documentation: docs/jev-evidence-screening.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  printf 'fm-jev-evidence-screen: node is required for strict JSON validation.\n' >&2
  exit 127
fi

exec node "$SCRIPT_DIR/fm-jev-evidence-screen.mjs" "$@"

#!/usr/bin/env bash
# Syntax checks for retained Linear bridge helper scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_linear_node_scripts_parse() {
  local script
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found"
    return 0
  fi
  for script in \
    bin/fm-linear-poll.mjs \
    bin/fm-linear-team-reshape.mjs \
    bin/fm-linear-team-scaffold.mjs; do
    node --check "$ROOT/$script" >/dev/null \
      || fail "$script failed node --check"
  done
  pass "linear scripts parse as Node modules"
}

test_linear_node_scripts_parse

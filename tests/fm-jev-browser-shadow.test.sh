#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-browser-shadow.sh.
#
# Drives the public fixture interface with fake TypeSafe transports. No test
# touches the network or drives a browser.
set -u

WORKTREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$WORKTREE_ROOT/scratchpad-jev-browser-shadow-test"
export TMPDIR="$WORKTREE_ROOT/scratchpad-jev-browser-shadow-test"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-browser-shadow.sh"
TASKS="$ROOT/tests/fixtures/jev-browser-shadow/tasks.json"
TMP_ROOT=$(fm_test_tmproot fm-jev-browser-shadow)
RECEIPTS="$TMP_ROOT/receipts.jsonl"
SUMMARY="$TMP_ROOT/summary.json"
FAKE="$ROOT/tests/fixtures/jev-browser-shadow/fake-typesafe.sh"

assert_equals() {
  local expected=$1 actual=$2 msg=$3
  [ "$actual" = "$expected" ] || fail "$msg"$'\n'"expected: $expected"$'\n'"actual: $actual"
}

out=$("$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --transport-command "$FAKE" --summary-json)
printf '%s\n' "$out" > "$SUMMARY"
assert_equals 24 "$(jq -r '.task_count' "$SUMMARY")" "fixture suite has twenty-four tasks and all were processed"
assert_equals 12 "$(jq -r '.clear_recommendations' "$SUMMARY")" "only safe fresh compatible selections become clear shadow recommendations"
assert_equals 2 "$(jq -r '.stale_action_rejection_count' "$SUMMARY")" "stale page/action recommendations are rejected"
assert_equals 1 "$(jq -r '.no_compatible_action_count' "$SUMMARY")" "none/no-compatible case is reported"
assert_equals 9 "$(jq -r '.forbidden_action_rejection_count' "$SUMMARY")" "forbidden submit/purchase/booking/message/login/download/upload/delete/external-change actions are rejected"
assert_equals 0 "$(jq -r '.wrong_action_rate' "$SUMMARY")" "wrong-action rate is zero for deterministic fake"
assert_equals 0 "$(jq -r '.human_override_count' "$SUMMARY")" "human override count is reported"
assert_equals 24 "$(wc -l < "$RECEIPTS" | tr -d ' ')" "one row-level receipt is emitted per task"
jq -e 'all(.;
  (.state_hash | type == "string") and
  (.question_version == "jev-browser-action-shadow.v1") and
  has("probabilities") and
  has("confidence") and
  has("selected_action") and
  has("validation_result") and
  has("expected_action") and
  has("outcome") and
  has("latency_ms") and
  has("cost_usd") and
  has("human_override")
)' "$RECEIPTS" >/dev/null || fail "receipts must carry the required row-level fields"
pass "fake TypeSafe transport over twenty-four fixture tasks records metrics and receipts"

rm -f "$RECEIPTS"
out=$(env -u TYPESAFE_API_KEY "$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --summary-json)
assert_equals 24 "$(jq -r '.no_key_count' <<<"$out")" "missing key and no fake transport is safe non-clear for every task"
assert_equals 0 "$(jq -r '.clear_recommendations' <<<"$out")" "missing key never records a clear action"
pass "no-key/no-network path produces safe non-clear receipts"

rm -f "$RECEIPTS"
out=$(FAKE_MODE=fail "$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --transport-command "$FAKE" --summary-json)
assert_equals 24 "$(jq -r '.provider_failure_count' <<<"$out")" "provider failure is safe non-clear"
pass "provider failure records no action"

rm -f "$RECEIPTS"
out=$(FAKE_MODE=malformed "$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --transport-command "$FAKE" --summary-json)
assert_equals 24 "$(jq -r '.malformed_response_count' <<<"$out")" "malformed responses are counted"
pass "malformed response records no action"

rm -f "$RECEIPTS"
out=$(FAKE_CONFIDENCE=0.2 "$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --transport-command "$FAKE" --summary-json)
assert_equals 24 "$(jq -r '.low_confidence_count' <<<"$out")" "low confidence responses are counted"
assert_equals 0 "$(jq -r '.clear_recommendations' <<<"$out")" "low confidence never records a clear action"
pass "low confidence records no action"

rm -f "$RECEIPTS"
out=$(FAKE_MODE=incompatible "$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --transport-command "$FAKE" --summary-json)
assert_contains "$(cat "$RECEIPTS")" '"validation_result":"incompatible-action"' "operation compatibility rejects click on type-only input"
pass "action compatibility is enforced after model choice"

rm -f "$RECEIPTS"
out=$("$TOOL" --tasks "$TASKS" --receipts "$RECEIPTS" --transport-command "$FAKE" --execute-local-fixture --summary-json)
assert_contains "$(cat "$RECEIPTS")" '"validation_result":"valid-fixture-execution"' "local fixture allowlist can permit optional fixture execution"
assert_contains "$(cat "$RECEIPTS")" '"validation_result":"safety-allowlist-rejected"' "read-only public fixture is not executable under the local fixture flag"
assert_contains "$(cat "$RECEIPTS")" '"validation_result":"forbidden-action"' "forbidden actions remain rejected even with execution flag"
pass "safety allowlist gates the optional local-fixture execution mode"

echo "# all fm-jev-browser-shadow tests passed"

#!/usr/bin/env bash
# Public-interface tests for the proposal-card contract owner.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CARD="$ROOT/bin/fm-proposal-card.sh"
FIXTURE_DIR="$ROOT/tests/fixtures/proposal-card"
TMP_ROOT=$(fm_test_tmproot fm-proposal-card)
READONLY_FIXTURES=()

cleanup_proposal_card_test() {
  local dir
  for dir in "${READONLY_FIXTURES[@]:-}"; do
    [ -e "$dir" ] && chmod -R u+w "$dir" 2>/dev/null || true
  done
  fm_test_cleanup
}

trap cleanup_proposal_card_test EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

digest_tree() {  # <dir>
  local dir=$1
  (cd "$dir" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
  done)
}

test_stalled_work_card_renders_without_mutating_scenario() {
  local scenario before after
  scenario="$TMP_ROOT/stalled-scenario"
  mkdir -p "$scenario/state" "$scenario/projects/firstmate" "$scenario/data"
  cp "$FIXTURE_DIR/stalled-upstream-reconciliation.json" "$scenario/proposal-card.json"
  printf 'working: parked after restart invalidated saved worker conversation\n' > "$scenario/state/upstream-reconcile.status"
  printf 'window=firstmate:fm-upstream-reconcile\nworktree=%s/projects/firstmate\n' "$scenario" > "$scenario/state/upstream-reconcile.meta"
  printf 'branch=fm/firstmate-upstream-sync-followup-3417\npreserved=true\n' > "$scenario/projects/firstmate/branch.receipt"
  READONLY_FIXTURES+=("$scenario")
  chmod -R a-w "$scenario"
  before=$(digest_tree "$scenario")
  "$CARD" validate "$scenario/proposal-card.json" > "$TMP_ROOT/validate.out" \
    || fail "valid stalled-work proposal card was rejected"
  "$CARD" render "$scenario/proposal-card.json" > "$TMP_ROOT/actual.md" \
    || fail "stalled-work proposal card did not render"
  after=$(digest_tree "$scenario")
  [ "$before" = "$after" ] || fail "read-only stalled-work recommendation mutated the frozen scenario"
  diff -u "$FIXTURE_DIR/stalled-upstream-reconciliation.expected.out" "$TMP_ROOT/actual.md" \
    || fail "rendered proposal card did not match expected stalled-work output"
  assert_grep "valid proposal card" "$TMP_ROOT/validate.out" "validation receipt missing"
  pass "stalled-work proposal card renders expected output with zero scenario mutation"
}

test_invalid_decision_time_class_is_rejected() {
  local card
  card="$TMP_ROOT/invalid-class.json"
  jq '.decision_time_class = "quickish"' "$FIXTURE_DIR/stalled-upstream-reconciliation.json" > "$card"
  if "$CARD" validate "$card" > "$TMP_ROOT/invalid.out" 2> "$TMP_ROOT/invalid.err"; then
    fail "invalid decision_time_class passed validation"
  fi
  assert_grep "invalid proposal card" "$TMP_ROOT/invalid.err" "invalid decision class rejection was not explicit"
  pass "invalid decision-time classes are rejected at the executable boundary"
}

test_rejection_reason_is_optional_and_verbatim() {
  local card why rejected
  card="$FIXTURE_DIR/stalled-upstream-reconciliation.json"
  "$CARD" reject "$card" --source "unit test" > "$TMP_ROOT/rejected-empty.json" \
    || fail "rejection without why-not reason failed"
  jq -e '.rejection.status == "rejected" and .rejection.reason_supplied == false and .rejection.why_not == ""' \
    "$TMP_ROOT/rejected-empty.json" >/dev/null \
    || fail "empty rejection did not preserve the optional-reason contract"

  why="$TMP_ROOT/why-not.txt"
  rejected="$TMP_ROOT/rejected-with-why.json"
  printf 'Not worth risking the preserved branch today.\nUse the report as evidence only.\n' > "$why"
  "$CARD" reject "$card" --why-not-file "$why" --source "unit test" > "$rejected" \
    || fail "rejection with why-not reason failed"
  jq --rawfile why "$why" -e '.rejection.reason_supplied == true and .rejection.why_not == $why' \
    "$rejected" >/dev/null \
    || fail "why-not reason was not preserved verbatim"
  "$CARD" validate "$rejected" >/dev/null \
    || fail "rejected card failed validation"
  pass "rejection path preserves optional why-not words without requiring a reason"
}

test_stalled_work_card_renders_without_mutating_scenario
test_invalid_decision_time_class_is_rejected
test_rejection_reason_is_optional_and_verbatim

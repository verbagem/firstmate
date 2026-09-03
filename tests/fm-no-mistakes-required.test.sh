#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

BODY_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../bin/fm-no-mistakes-attestation-body.sh"

# fake_gh <fakebin> <stale-polls> <stale-body> <bound-body>: `gh api` answers
# <stale-body> for the first <stale-polls> calls and <bound-body> afterwards,
# mirroring the pipeline rewriting the PR body a few seconds after its push.
fake_gh() {
  local fakebin=$1 stale_polls=$2
  printf '%s' "$3" > "$fakebin/stale-body"
  printf '%s' "$4" > "$fakebin/bound-body"
  : > "$fakebin/calls"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 9
echo "\$2" >> "$fakebin/calls"
if [ "\$(wc -l < "$fakebin/calls")" -le $stale_polls ]; then
  cat "$fakebin/stale-body"
else
  cat "$fakebin/bound-body"
fi
SH
  chmod +x "$fakebin/gh"
}

test_live_body_waits_for_head_bound_attestation() {
  local fakebin stale bound output rc
  fakebin=$(fm_fakebin "$TMP_ROOT/wait")
  stale="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  bound="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  fake_gh "$fakebin" 2 "$stale" "$bound"
  rc=0
  output=$(PATH="$fakebin:$PATH" "$BODY_SCRIPT" acme/widgets 3006 "$NEW_SHA" 30 0 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "live-body script failed once the attestation bound the head"
  [ "$output" = "$bound" ] || fail "live-body script did not print the head-bound body"
  expect_code 3 "$(wc -l < "$fakebin/calls" | tr -d ' ')" "live-body script did not stop polling once the body bound the head"
  assert_contains "$(cat "$fakebin/calls")" "repos/acme/widgets/pulls/3006" \
    "live-body script did not read the PR from the forge"
  rc=0
  output=$(run_verifier "$output" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected the live body the script handed it"
  pass "live-body script polls past the stale push-time body and hands the shared action a passing body"
}

test_live_body_times_out_with_last_body() {
  local fakebin stale output rc
  fakebin=$(fm_fakebin "$TMP_ROOT/timeout")
  stale="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  fake_gh "$fakebin" 99 "$stale" "$stale"
  rc=0
  output=$(PATH="$fakebin:$PATH" "$BODY_SCRIPT" acme/widgets 3006 "$NEW_SHA" 0 0 2>"$fakebin/stderr") || rc=$?
  expect_code 0 "$rc" "live-body script should hand a never-bound body to the shared action, not fail itself"
  [ "$output" = "$stale" ] || fail "live-body script did not print the last body it saw on timeout"
  assert_contains "$(cat "$fakebin/stderr")" "still binds $OLD_SHA after 0s, not $NEW_SHA" \
    "timeout diagnostic did not name the stale head the body still binds"
  assert_contains "$(cat "$fakebin/stderr")" "republish the body against the current head" \
    "timeout diagnostic did not tell the operator how to rebind the attestation"
  rc=0
  output=$(run_verifier "$output" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted a body that never bound the current head"
  pass "live-body script times out on a never-bound body and the shared action still fails it"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_live_body_waits_for_head_bound_attestation
test_live_body_times_out_with_last_body

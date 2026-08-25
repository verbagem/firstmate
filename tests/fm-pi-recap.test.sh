#!/usr/bin/env bash
# Tests for bin/fm-pi-recap.sh, the pure render step behind the Pi task-recap
# widget (.pi/extensions/fm-task-recap.ts). Every case exercises the real
# script's stdout against synthetic state/data fixtures - no source-byte
# assertions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECAP="$ROOT/bin/fm-pi-recap.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-recap)

make_fixture() {  # <name> -> "<state-dir>|<data-dir>"
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data"
  printf '%s|%s' "$dir/state" "$dir/data"
}

write_backlog_entry() {  # <data-dir> <id> <title>
  printf -- '- [ ] %s - %s (repo: demo) (kind: ship) (since 2026-08-01)\n' "$2" "$3" >> "$1/backlog.md"
}

render() {  # <id> <state-dir> <data-dir>
  "$RECAP" render "$1" "$2" "$3"
}

test_renders_title_and_starting_up_before_any_status() {
  local rec state data id=recap-fresh-1
  rec=$(make_fixture fresh); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Fix the login bug"
  local out; out=$(render "$id" "$state" "$data")
  [ "$out" = $'Fix the login bug\nStarting up' ] || fail "expected title + Starting up before any status line, got:"$'\n'"$out"
  pass "a freshly spawned task with no status yet shows its title and a Starting up phase"
}

test_renders_latest_working_note_as_phase() {
  local rec state data id=recap-phase-1
  rec=$(make_fixture phase); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Fix the login bug"
  printf 'working: reproduced the bug\n' > "$state/$id.status"
  local out; out=$(render "$id" "$state" "$data")
  [ "$out" = $'Fix the login bug\nIn progress: reproduced the bug' ] || fail "expected translated phase+note, got:"$'\n'"$out"
  pass "the latest working: line becomes the plain-language phase and its note"
}

test_terminal_verbs_translate_to_plain_language() {
  local rec state data id=recap-terminal-1
  rec=$(make_fixture terminal); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'done: PR checks green\n' > "$state/$id.status"
  local out; out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Done: PR checks green' "done: should translate to plain 'Done:'"
  printf 'failed: no-mistakes gate rejected the diff\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Failed: no-mistakes gate rejected the diff' "failed: should translate to plain 'Failed:'"
  pass "terminal verbs (done/failed) translate to plain captain-facing wording"
}

test_open_decision_not_duplicated_when_it_is_the_latest_line() {
  local rec state data id=recap-dedup-blocker
  rec=$(make_fixture dedup-blocker); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Pick a retry strategy"
  printf 'needs-decision: retry with backoff or fail fast?\n' > "$state/$id.status"
  local out; out=$(render "$id" "$state" "$data")
  local count; count=$(printf '%s\n' "$out" | grep -c 'retry with backoff or fail fast')
  [ "$count" = 1 ] || fail "the open decision must appear exactly once when it is also the latest status line, appeared $count times:"$'\n'"$out"
  assert_contains "$out" 'Needs a decision: retry with backoff or fail fast?' "phase line should carry the decision text"
  pass "an open decision that is also the latest status line is shown once, not duplicated as a separate blocker line"
}

test_open_decision_shown_separately_under_a_later_working_line() {
  local rec state data id=recap-stale-decision
  rec=$(make_fixture stale-decision); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Pick a retry strategy"
  {
    printf 'needs-decision: retry with backoff or fail fast?\n'
    printf 'working: kept investigating while waiting on the decision\n'
  } > "$state/$id.status"
  local out; out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'In progress: kept investigating while waiting on the decision' "phase should reflect the latest line"
  assert_contains "$out" 'Needs a decision: retry with backoff or fail fast?' "the still-open decision from an earlier line must still surface"
  pass "a decision left open under a later unrelated status line gets its own dedicated line"
}

test_resolved_decision_disappears() {
  local rec state data id=recap-resolved
  rec=$(make_fixture resolved); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Pick a retry strategy"
  {
    printf 'needs-decision: retry with backoff or fail fast?\n'
    printf 'resolved: went with backoff\n'
    printf 'working: implementing backoff retry\n'
  } > "$state/$id.status"
  local out; out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" 'Needs a decision' "a resolved decision must not still show as open"
  assert_contains "$out" 'In progress: implementing backoff retry' "phase should reflect the latest line"
  pass "a resolved decision no longer appears once closed"
}

test_pr_line_only_when_meta_has_pr() {
  local rec state data id=recap-pr-1
  rec=$(make_fixture pr-present); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: fixing lint\n' > "$state/$id.status"
  local out; out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" 'PR:' "no PR line before state/<id>.meta has pr="
  printf 'pr=https://github.com/verbagem/firstmate/pull/99\n' > "$state/$id.meta"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'PR: https://github.com/verbagem/firstmate/pull/99' "PR line should appear once meta has pr="
  pass "the PR line appears only once state/<id>.meta records pr= and shows the full URL"
}

test_truncates_a_long_note_deterministically() {
  local rec state data id=recap-trunc-1 words out line
  rec=$(make_fixture truncate); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  words=$(printf 'word %.0s' $(seq 1 40))
  printf 'working: %s\n' "$words" > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  line=$(printf '%s\n' "$out" | sed -n 2p)
  case "$line" in
    *…) : ;;
    *) fail "a long note should truncate with a trailing ellipsis, got: $line" ;;
  esac
  [ "${#line}" -le 130 ] || fail "truncated line unexpectedly long (${#line} chars): $line"
  # Same long input renders the identical truncated line every time.
  local out2; out2=$(render "$id" "$state" "$data")
  [ "$out" = "$out2" ] || fail "rendering must be deterministic for identical input"
  pass "a long status note truncates deterministically with an ellipsis, and rendering is repeatable"
}

test_redacts_paths_and_secret_shaped_tokens() {
  local rec state data id=recap-privacy-1 out
  rec=$(make_fixture privacy); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: found it in /Users/temp/secret/project/file.ts using token=abcdefghij0123456789xyz\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" '/Users/temp' "an absolute local path must never reach the recap"
  assert_not_contains "$out" 'abcdefghij0123456789xyz' "a secret-shaped token must never reach the recap"
  assert_contains "$out" '[path]' "a redacted path leaves a visible placeholder"
  assert_contains "$out" '[redacted]' "a redacted secret leaves a visible placeholder"
  pass "absolute local paths and secret-shaped tokens are redacted before the recap is rendered"
}

test_never_prints_the_task_id() {
  local rec state data id=recap-no-raw-id-9999 out
  rec=$(make_fixture no-id); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: fixing lint\n' > "$state/$id.status"
  printf 'pr=https://github.com/verbagem/firstmate/pull/1\n' > "$state/$id.meta"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" "$id" "the raw task id must never appear in the captain-facing recap"
  pass "the raw task id never appears anywhere in the rendered recap"
}

test_absent_backlog_entry_falls_back_safely() {
  local rec state data out
  rec=$(make_fixture no-backlog); IFS='|' read -r state data <<<"$rec"
  out=$(render "some-unregistered-task" "$state" "$data")
  expect_code 0 $? "render must exit 0 even with no backlog entry"
  [ "$out" = $'This task\nStarting up' ] || fail "expected a generic fallback title, got:"$'\n'"$out"
  pass "a task with no backlog entry (or no backlog.md at all) still renders a safe generic fallback"
}

test_absent_state_and_data_dirs_do_not_error() {
  local out status
  out=$("$RECAP" render some-task "$TMP_ROOT/does-not-exist-state" "$TMP_ROOT/does-not-exist-data" 2>&1)
  status=$?
  expect_code 0 "$status" "render must not fail just because the directories do not exist yet"
  [ "$out" = $'This task\nStarting up' ] || fail "expected the safe fallback render, got:"$'\n'"$out"
  pass "missing state/data directories degrade to the safe fallback render instead of erroring"
}

test_usage_error_on_missing_arguments() {
  local out status
  out=$("$RECAP" render only-one-arg 2>&1); status=$?
  expect_code 2 "$status" "render with missing arguments must be a usage error"
  out=$("$RECAP" 2>&1); status=$?
  expect_code 2 "$status" "no subcommand must be a usage error"
  pass "missing arguments and an unknown subcommand are refused as usage errors (exit 2)"
}

test_renders_title_and_starting_up_before_any_status
test_renders_latest_working_note_as_phase
test_terminal_verbs_translate_to_plain_language
test_open_decision_not_duplicated_when_it_is_the_latest_line
test_open_decision_shown_separately_under_a_later_working_line
test_resolved_decision_disappears
test_pr_line_only_when_meta_has_pr
test_truncates_a_long_note_deterministically
test_redacts_paths_and_secret_shaped_tokens
test_never_prints_the_task_id
test_absent_backlog_entry_falls_back_safely
test_absent_state_and_data_dirs_do_not_error
test_usage_error_on_missing_arguments

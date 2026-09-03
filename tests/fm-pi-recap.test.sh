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

test_no_catchall_redaction_of_long_words_or_mid_word_keywords() {
  local rec state data id=recap-privacy-2 out
  rec=$(make_fixture privacy-catchall); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Fix turnkey checkout flow for command-center-ops-firstmate"
  printf 'working: monkey patched the abcdefghijklmnopqrstuvwxyz0123 helper, no key involved\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Fix turnkey checkout flow for command-center-ops-firstmate' "an ordinary long repo name and a mid-word 'key' must survive intact"
  assert_contains "$out" 'In progress: monkey patched the abcdefghijklmnopqrstuvwxyz0123 helper, no key involved' "a bare long alnum run is not a secret"
  assert_not_contains "$out" '[redacted]' "nothing keyword-prefixed was present, so nothing may be redacted"
  printf 'working: rotated ghp_abcdefghijklmnop and password=hunter2hunter2 then sk-abcdef0123456789\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" 'ghp_abcdefghijklmnop' "a ghp_ token must be redacted"
  assert_not_contains "$out" 'hunter2hunter2' "a password= assignment must be redacted"
  assert_not_contains "$out" 'sk-abcdef0123456789' "an sk- token must be redacted"
  pass "redaction is keyword-prefixed only: plain long words and mid-word keywords pass through, real secret shapes still do not"
}

test_pr_url_on_the_allowlist_is_emitted_verbatim() {
  local rec state data id=recap-pr-2 out
  rec=$(make_fixture pr-verbatim); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'pr=https://github.com/verbagem/command-center-ops-firstmate/pull/12\n' > "$state/$id.meta"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'PR: https://github.com/verbagem/command-center-ops-firstmate/pull/12' "a canonical GitHub PR URL must reach the captain byte-for-byte"
  printf 'pr=https://gitlab.example.com/group/sub/project/-/merge_requests/7\n' > "$state/$id.meta"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'PR: https://gitlab.example.com/group/sub/project/-/merge_requests/7' "a canonical GitLab MR URL must reach the captain byte-for-byte"
  printf 'pr=https://github.com/verbagem/firstmate/pull/12?token=abcdefghijklmnop\n' > "$state/$id.meta"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" 'abcdefghijklmnop' "an off-allowlist pr= value goes through the sanitizer"
  pass "a pr= value that parses under fm_pr_url_parse is emitted verbatim; anything else is sanitized"
}

test_open_count_survives_when_latest_line_is_the_blocker() {
  local rec state data id=recap-open-count out
  rec=$(make_fixture open-count); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  {
    printf 'blocked: waiting on API access\n'
    printf 'needs-decision: [key=alt] pick a retry policy\n'
    printf 'blocked: [key=third] disk full\n'
  } > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Blocked: disk full (+2 more)' "the phase line must carry the count of the other still-open decisions"
  [ "$(printf '%s\n' "$out" | grep -c 'disk full')" = 1 ] || fail "the latest blocker text must still appear only once:"$'\n'"$out"
  printf 'blocked: only one thing\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Blocked: only one thing' "a lone blocker renders plainly"
  assert_not_contains "$out" 'more)' "a lone blocker carries no (+N more) suffix"
  pass "the (+N more) open-decision count is kept even when the latest line's own text is deduplicated"
}

test_open_decision_still_shown_when_latest_blocker_is_rejected_by_the_fold() {
  local rec state data id=recap-open-rejected out
  rec=$(make_fixture open-rejected); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  {
    printf 'needs-decision: [key=a] choose A\n'
    printf 'blocked: [key=bad!slug] disk full\n'
  } > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Blocked: [key=bad!slug] disk full' "the latest blocker still renders as the phase"
  assert_contains "$out" 'Needs a decision: choose A' "an earlier still-open decision must not be hidden because the fold rejected the latest line's key"
  assert_not_contains "$out" 'more)' "no phantom (+N more) when the latest line is not itself in the open set"
  {
    printf 'needs-decision: [key=a] choose A\n'
    printf 'blocked: [key=pending-reply-x] waiting on captain\n'
  } > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Needs a decision: choose A' "a reserved-namespace latest key must not hide the earlier open decision either"
  pass "an open decision stays visible when the latest blocked line was not accepted into the folded open set"
}

test_relative_paths_and_url_segments_are_not_redacted() {
  local rec state data id=recap-relpath out
  rec=$(make_fixture relpath); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: updated app/home/page.tsx and api/private/routes.ts, see https://example.com/tmp/x; log at /var/log/app.log\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'app/home/page.tsx' "a relative path containing /home must not be redacted"
  assert_contains "$out" 'api/private/routes.ts' "a relative path containing /private must not be redacted"
  assert_contains "$out" 'https://example.com/tmp/x' "a URL path segment containing /tmp must not be redacted"
  assert_not_contains "$out" '/var/log' "a real absolute path is still redacted"
  assert_contains "$out" 'log at [path]' "the absolute path leaves its placeholder"
  pass "path redaction only fires on absolute paths, leaving relative paths and URL segments intact"
}

test_decision_key_tokens_are_not_treated_as_secrets() {
  local rec state data id=recap-keytoken out
  rec=$(make_fixture keytoken); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: resolved the [key=retry-policy] question, rotated key=abcdefghijk afterwards\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" '[key=retry-policy]' "a bracketed decision key is structural syntax, not a credential"
  assert_not_contains "$out" 'abcdefghijk' "a bare key= assignment is still redacted"
  printf 'needs-decision [key=api-shape]: [key=other-thing] pick one\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Needs a decision: [key=other-thing] pick one' "a note-head decision key passes through unredacted"
  pass "the [key=<slug>] decision-key grammar is exempt from secret redaction while key= assignments are not"
}

test_prefixed_secret_assignments_are_redacted() {
  local rec state data id=recap-prefixed-secret out
  rec=$(make_fixture prefixed-secret); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: set API_KEY=abcdefghijkl and DB_PASSWORD=hunter2hunter2 and AUTH_TOKEN=zyxwvutsrqpo; the PRIMARY KEY constraint held\n' > "$state/$id.status"
  out=$(FM_PI_RECAP_LINE_MAX=300 render "$id" "$state" "$data")
  assert_not_contains "$out" 'abcdefghijkl' "an API_KEY= assignment must be redacted"
  assert_not_contains "$out" 'hunter2hunter2' "a DB_PASSWORD= assignment must be redacted"
  assert_not_contains "$out" 'zyxwvutsrqpo' "an AUTH_TOKEN= assignment must be redacted"
  assert_contains "$out" 'the PRIMARY KEY constraint held' "an uppercase word followed by a bare keyword in prose stays intact"
  pass "identifier-prefixed secret assignments are redacted while uppercase prose is untouched"
}

test_file_urls_are_redacted_as_paths() {
  local rec state data id=recap-file-url out
  rec=$(make_fixture file-url); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: see file:///Users/temp/secret/notes.md and https://example.com/tmp/x\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" '/Users/temp' "a file:// URL carries a machine path and must be redacted"
  assert_contains "$out" 'see [path] and https://example.com/tmp/x' "an http URL path segment still passes through"
  pass "file:// URLs are redacted like absolute paths while http URLs are left alone"
}

test_bearer_prose_is_not_redacted() {
  local rec state data id=recap-bearer-prose out
  rec=$(make_fixture bearer-prose); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: switched to bearer authentication for the client, header bearer eyJhbGci0iJIUzI1 and bearer=abcdefghijkl\n' > "$state/$id.status"
  out=$(FM_PI_RECAP_LINE_MAX=300 render "$id" "$state" "$data")
  assert_contains "$out" 'switched to bearer authentication for the client' "ordinary bearer prose must survive"
  assert_not_contains "$out" 'eyJhbGci0iJIUzI1' "a digit-bearing bearer credential after a space is redacted"
  assert_not_contains "$out" 'abcdefghijkl' "a bearer= assignment is redacted"
  pass "the bearer pattern redacts real credentials but leaves 'bearer authentication' prose alone"
}

test_short_bearer_tokens_and_colon_space_prose_are_not_redacted() {
  local rec state data id=recap-short-bearer out
  rec=$(make_fixture short-bearer); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: rotated bearer v2 keys and changed bearer 3 endpoints; the key: understanding retries; secret: rotation scheduled; password: hunter2hunter2; token: abcd1efg\n' > "$state/$id.status"
  out=$(FM_PI_RECAP_LINE_MAX=300 render "$id" "$state" "$data")
  assert_contains "$out" 'rotated bearer v2 keys and changed bearer 3 endpoints' "short version/count tokens after bearer are prose"
  assert_contains "$out" 'the key: understanding retries' "a colon-space keyword followed by a plain word is prose"
  assert_contains "$out" 'secret: rotation scheduled' "secret: followed by a plain word is prose"
  assert_not_contains "$out" 'hunter2hunter2' "a colon-space password with a digit is still redacted"
  assert_not_contains "$out" 'abcd1efg' "an 8-char digit-bearing colon-space token is still redacted"
  pass "the digit-plus-length gate keeps bearer and colon-space prose intact while redacting real credential shapes"
}

test_credential_prefixes_are_word_anchored_and_length_gated() {
  local rec state data id=recap-prefix-table out row prefix real embedded
  rec=$(make_fixture prefix-table); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Fix disk-space"
  local table='sk-|sk-abcdefghijklmnop1234|disk-space
ghp_|ghp_abcdefghijklmnop1234|graphghp_x
gho_|gho_abcdefghijklmnop1234|echogho_y
github_pat_|github_pat_abcdefghijklmnop1234|mygithub_pat_z
xoxb-|xoxb-abcdefghijklmnop1234|boxoxb-tool
AKIA|AKIAABCDEFGHIJKLMNOP|MAKIAWAKA-thing'
  while IFS='|' read -r prefix real embedded; do
    printf 'working: rotated %s while touching %s\n' "$real" "$embedded" > "$state/$id.status"
    out=$(FM_PI_RECAP_LINE_MAX=300 render "$id" "$state" "$data")
    assert_not_contains "$out" "$real" "a real $prefix credential must be redacted"
    assert_contains "$out" "touching $embedded" "$prefix embedded mid-word in '$embedded' must pass through"
  done <<<"$table"
  assert_contains "$out" 'Fix disk-space' "the title with an embedded sk- survives intact"
  pass "every credential prefix redacts a real token and leaves the prefix embedded mid-word alone"
}

test_reserved_key_latest_line_does_not_hide_earlier_open_decision() {
  local rec state data id=recap-reserved-key out
  rec=$(make_fixture reserved-key); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  {
    printf 'needs-decision: [key=pending-reply-x] pending-reply-x: first\n'
    printf 'blocked: [key=pending-reply-x] waiting on captain\n'
  } > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Blocked: waiting on captain' "the latest blocker still renders as the phase"
  assert_contains "$out" 'Needs a decision: pending-reply-x: first' "the earlier accepted decision sharing the key must keep its dedicated line"
  pass "a latest line the fold rejected does not suppress an earlier open decision that shares its key"
}

test_secret_keywords_redact_regardless_of_case() {
  local rec state data id=recap-privacy-case out
  rec=$(make_fixture privacy-case); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: sent Authorization: Bearer abcdefghijklmnop with TOKEN=abcdefghijkl and Password: hunter2hunter2\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" 'abcdefghijklmnop' "a capitalized Bearer credential must be redacted"
  assert_not_contains "$out" 'abcdefghijkl' "an upper-case TOKEN= assignment must be redacted"
  assert_not_contains "$out" 'hunter2hunter2' "a capitalized Password: assignment must be redacted"
  pass "keyword-prefixed secrets are redacted in their common capitalizations"
}

test_unrecognized_verb_renders_as_update_not_starting_up() {
  local rec state data id=recap-unknown-verb out
  rec=$(make_fixture unknown-verb); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'reviewing: checking the diff against the spec\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_contains "$out" 'Update: checking the diff against the spec' "an unrecognized leading verb shows the actual note as an Update"
  assert_not_contains "$out" 'Starting up' "a task that has reported progress is never shown as not yet begun"
  pass "an unrecognized status verb renders as 'Update: <note>', with 'Starting up' reserved for the absent-status case"
}

test_strips_osc_sequences_and_redacts_other_path_roots() {
  local rec state data id=recap-osc out
  rec=$(make_fixture osc); IFS='|' read -r state data <<<"$rec"
  write_backlog_entry "$data" "$id" "Ship the thing"
  printf 'working: wrote /opt/data/x and /var/tmp/y \033]0;pwned title\007then \033[31mred\033[0m and /etc/hosts\n' > "$state/$id.status"
  out=$(render "$id" "$state" "$data")
  assert_not_contains "$out" $'\033' "no escape byte may reach the widget"
  assert_not_contains "$out" 'pwned title' "an OSC payload must be stripped, not rendered"
  assert_not_contains "$out" '/opt/data' "an /opt path must be redacted"
  assert_not_contains "$out" '/var/tmp' "a /var path must be redacted"
  assert_not_contains "$out" '/etc/hosts' "an /etc path must be redacted"
  assert_contains "$out" 'In progress: wrote [path] and [path] then red and [path]' "the surrounding text survives the strip and redaction"
  pass "OSC and CSI escapes are stripped and absolute paths under common roots beyond /Users and /home are redacted"
}

test_title_matches_fleet_snapshot_title_of() {
  local rec state data id=recap-title-1 out expected
  rec=$(make_fixture title-of); IFS='|' read -r state data <<<"$rec"
  {
    printf '## Queued\n\n'
    printf -- '- [ ] %s - Fix login <https://github.com/verbagem/firstmate/pull/3> blocked-by: t0 - waits on auth (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id"
  } > "$data/backlog.md"
  out=$(render "$id" "$state" "$data")
  expected=$(FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-fleet-snapshot.sh" 2>/dev/null \
    | jq -r --arg id "$id" '.backlog.records[] | select(.id == $id) | .title' 2>/dev/null)
  [ -n "$expected" ] && [ "$expected" != null ] || fail "fm-fleet-snapshot.sh produced no title record for $id, so the parity check cannot run"
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "$expected" ] || fail "recap title must match the fleet snapshot's title_of ('$expected'), got:"$'\n'"$out"
  assert_not_contains "$out" 'blocked-by' "the blocked-by clause is not part of the title"
  assert_not_contains "$out" 'github.com' "a wrapped URL is not part of the title"
  pass "the recap title is produced by the same wrapped-URL/blocked-by/clean_title pipeline as the fleet snapshot"
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
test_no_catchall_redaction_of_long_words_or_mid_word_keywords
test_pr_url_on_the_allowlist_is_emitted_verbatim
test_open_count_survives_when_latest_line_is_the_blocker
test_open_decision_still_shown_when_latest_blocker_is_rejected_by_the_fold
test_relative_paths_and_url_segments_are_not_redacted
test_decision_key_tokens_are_not_treated_as_secrets
test_prefixed_secret_assignments_are_redacted
test_file_urls_are_redacted_as_paths
test_bearer_prose_is_not_redacted
test_short_bearer_tokens_and_colon_space_prose_are_not_redacted
test_credential_prefixes_are_word_anchored_and_length_gated
test_reserved_key_latest_line_does_not_hide_earlier_open_decision
test_secret_keywords_redact_regardless_of_case
test_unrecognized_verb_renders_as_update_not_starting_up
test_strips_osc_sequences_and_redacts_other_path_roots
test_title_matches_fleet_snapshot_title_of
test_never_prints_the_task_id
test_absent_backlog_entry_falls_back_safely
test_absent_state_and_data_dirs_do_not_error
test_usage_error_on_missing_arguments

#!/usr/bin/env bash
# Behavior tests for evals/run_eval.sh's public grading interface.
#
# The suite uses fake claude and codex binaries so auth/session-limit handling,
# prompt parity, and Codex's non-interactive envelope are covered without
# touching real credentials or starting real agent work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/evals/run_eval.sh"
TMP_ROOT=$(fm_test_tmproot run-eval)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TARGET="$TMP_ROOT/deliverable.md"
SECRET='SECRET_TOKEN_MUST_NOT_LEAK'

printf 'Completed the requested repair with validation evidence.\n' > "$TARGET"

assert_equals() {  # <expected> <actual> <label>
  local expected=$1 actual=$2 label=$3
  [ "$expected" = "$actual" ] || fail "$label"$'\n'"expected: $expected"$'\n'"actual: $actual"
}

assert_contains() {  # <needle> <haystack> <label>
  local needle=$1 haystack=$2 label=$3
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label"$'\n'"missing: $needle"$'\n'"--- text ---"$'\n'"$haystack" ;;
  esac
}

assert_not_contains() {  # <needle> <haystack> <label>
  local needle=$1 haystack=$2 label=$3
  case "$haystack" in
    *"$needle"*) fail "$label"$'\n'"unexpected: $needle"$'\n'"--- text ---"$'\n'"$haystack" ;;
  esac
}

make_fakebin() {  # <case-dir> [without-claude]
  local dir=$1 omit_claude=${2:-0} fakebin
  fakebin=$(fm_fakebin "$dir")
  if [ "$omit_claude" -eq 0 ]; then
    cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_FAKE_CLAUDE_ARGV:?}"
if [ "${1:-}" = "-p" ]; then
  printf '%s' "${2:-}" > "${FM_FAKE_CLAUDE_PROMPT:?}"
fi
case "${FM_FAKE_CLAUDE_MODE:-success}" in
  success)
    printf '%s\n' "${FM_FAKE_CLAUDE_STDOUT:-VERDICT: DONE}"
    ;;
  fail-verdict)
    printf 'VERDICT: FAIL\n'
    ;;
  session-limit)
    printf 'Claude AI usage limit reached|1758492000 %s\n' "${FM_FAKE_SECRET:?}" >&2
    exit 1
    ;;
  subscription-limit)
    printf 'Subscription plan limit reached; try again after reset. %s\n' "${FM_FAKE_SECRET:?}" >&2
    exit 1
    ;;
  auth-refresh)
    printf 'OAuth token expired; refresh credentials before retrying. %s\n' "${FM_FAKE_SECRET:?}" >&2
    exit 1
    ;;
  eligible-session)
    printf 'Claude session is no longer eligible; please log in again. %s\n' "${FM_FAKE_SECRET:?}" >&2
    exit 1
    ;;
  generic-failure)
    printf 'grader crashed for an ordinary reason\n' >&2
    exit 2
    ;;
  interrupt)
    printf 'Interrupted\n' >&2
    exit 130
    ;;
esac
SH
    chmod +x "$fakebin/claude"
  fi

  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_FAKE_CODEX_ARGV:?}"
pwd > "${FM_FAKE_CODEX_CWD:?}"
last_message=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message)
      last_message=$2
      shift 2
      ;;
    *) shift ;;
  esac
done
cat > "${FM_FAKE_CODEX_PROMPT:?}"
printf 'codex transcript noise must stay out of grader stdout\n'
printf 'codex stderr noise must stay separated\n' >&2
case "${FM_FAKE_CODEX_MODE:-success}" in
  success)
    [ -n "$last_message" ] || exit 3
    printf '%s\n' "${FM_FAKE_CODEX_FINAL:-VERDICT: DONE VIA CODEX}" > "$last_message"
    ;;
  no-final)
    ;;
  failure)
    exit 9
    ;;
esac
SH
  chmod +x "$fakebin/codex"
  printf '%s\n' "$fakebin"
}

RUN_RC=0
RUN_STDOUT=
RUN_STDERR=
RUN_DIR=
run_eval_case() {  # <case-name> [without-claude|with-claude] [env...]
  local case_name=$1 claude_mode=${2:-with-claude} fakebin rc=0
  shift 2 || true
  RUN_DIR="$TMP_ROOT/$case_name"
  mkdir -p "$RUN_DIR"
  if [ "$claude_mode" = "without-claude" ]; then
    fakebin=$(make_fakebin "$RUN_DIR" 1)
  else
    fakebin=$(make_fakebin "$RUN_DIR" 0)
  fi
  : > "$RUN_DIR/claude.argv"
  : > "$RUN_DIR/claude.prompt"
  : > "$RUN_DIR/codex.argv"
  : > "$RUN_DIR/codex.prompt"
  : > "$RUN_DIR/codex.cwd"
  env \
    PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_CLAUDE_ARGV="$RUN_DIR/claude.argv" \
    FM_FAKE_CLAUDE_PROMPT="$RUN_DIR/claude.prompt" \
    FM_FAKE_CODEX_ARGV="$RUN_DIR/codex.argv" \
    FM_FAKE_CODEX_PROMPT="$RUN_DIR/codex.prompt" \
    FM_FAKE_CODEX_CWD="$RUN_DIR/codex.cwd" \
    FM_FAKE_SECRET="$SECRET" \
    "$@" \
    "$SCRIPT" completeness "$TARGET" > "$RUN_DIR/stdout" 2> "$RUN_DIR/stderr" || rc=$?
  RUN_RC=$rc
  RUN_STDOUT=$(cat "$RUN_DIR/stdout")
  RUN_STDERR=$(cat "$RUN_DIR/stderr")
}

run_eval_case claude-success with-claude FM_FAKE_CLAUDE_MODE=success
assert_equals 0 "$RUN_RC" "auto Claude success exits zero"
assert_equals "VERDICT: DONE" "$RUN_STDOUT" "auto returns Claude grader stdout"
assert_equals "" "$(cat "$RUN_DIR/codex.argv")" "auto does not call Codex after Claude success"

run_eval_case fail-verdict with-claude FM_FAKE_CLAUDE_MODE=fail-verdict
assert_equals 0 "$RUN_RC" "a FAIL verdict is still a successful grader command"
assert_equals "VERDICT: FAIL" "$RUN_STDOUT" "FAIL verdict text is not reinterpreted"
assert_equals "" "$(cat "$RUN_DIR/codex.argv")" "FAIL verdict does not trigger fallback"

run_eval_case observed-session-limit with-claude FM_FAKE_CLAUDE_MODE=session-limit
assert_equals 0 "$RUN_RC" "observed Claude usage limit falls back"
assert_equals "VERDICT: DONE VIA CODEX" "$RUN_STDOUT" "fallback returns Codex final response"
assert_contains "reason=session-limit selected_grader=codex" "$RUN_STDERR" "fallback note names the reason class"
assert_not_contains "$SECRET" "$RUN_STDERR" "fallback note does not leak auth payloads"

run_eval_case subscription-limit with-claude FM_FAKE_CLAUDE_MODE=subscription-limit
assert_equals 0 "$RUN_RC" "Claude subscription limit falls back"
assert_equals "VERDICT: DONE VIA CODEX" "$RUN_STDOUT" "subscription fallback returns Codex final response"
assert_contains "reason=session-limit selected_grader=codex" "$RUN_STDERR" "subscription fallback is classified as a usage/session limit"
assert_not_contains "$SECRET" "$RUN_STDERR" "subscription fallback hides raw provider payloads"

run_eval_case auth-refresh with-claude FM_FAKE_CLAUDE_MODE=auth-refresh
assert_equals 0 "$RUN_RC" "Claude auth refresh failure falls back"
assert_contains "reason=auth-refresh selected_grader=codex" "$RUN_STDERR" "auth fallback is classified"
assert_not_contains "$SECRET" "$RUN_STDERR" "auth fallback hides raw credential text"

run_eval_case eligible-session with-claude FM_FAKE_CLAUDE_MODE=eligible-session
assert_equals 0 "$RUN_RC" "Claude ineligible session failure falls back"
assert_contains "reason=auth-refresh selected_grader=codex" "$RUN_STDERR" "ineligible session fallback is classified as auth refresh"
assert_not_contains "$SECRET" "$RUN_STDERR" "ineligible session fallback hides raw provider payloads"

run_eval_case missing-claude without-claude
assert_equals 0 "$RUN_RC" "missing Claude CLI falls back in auto mode"
assert_contains "reason=claude-unavailable selected_grader=codex" "$RUN_STDERR" "missing CLI fallback is classified"

run_eval_case generic-refusal with-claude FM_FAKE_CLAUDE_MODE=generic-failure
assert_equals 2 "$RUN_RC" "generic Claude failure is not fallback-eligible"
assert_contains "ordinary reason" "$RUN_STDERR" "generic failure preserves the grader error"
assert_equals "" "$(cat "$RUN_DIR/codex.argv")" "generic failure does not call Codex"

run_eval_case interrupt-refusal with-claude FM_FAKE_CLAUDE_MODE=interrupt
assert_equals 130 "$RUN_RC" "interrupt is not fallback-eligible"
assert_equals "" "$(cat "$RUN_DIR/codex.argv")" "interrupt does not call Codex"

run_eval_case explicit-claude with-claude FM_EVAL_GRADER=claude FM_FAKE_CLAUDE_MODE=session-limit
assert_equals 1 "$RUN_RC" "explicit Claude does not silently switch providers"
assert_contains "Claude AI usage limit reached" "$RUN_STDERR" "explicit Claude returns Claude's failure"
assert_equals "" "$(cat "$RUN_DIR/codex.argv")" "explicit Claude does not call Codex"

run_eval_case explicit-codex with-claude FM_EVAL_GRADER=codex FM_FAKE_CLAUDE_MODE=session-limit
assert_equals 0 "$RUN_RC" "explicit Codex succeeds directly"
assert_equals "" "$(cat "$RUN_DIR/claude.argv")" "explicit Codex does not call Claude"
codex_argv=$(cat "$RUN_DIR/codex.argv")
assert_contains "exec" "$codex_argv" "Codex uses non-interactive exec"
assert_contains "--disable" "$codex_argv" "Codex disables hooks"
assert_contains "hooks" "$codex_argv" "Codex disables hooks by feature name"
assert_contains 'approval_policy="never"' "$codex_argv" "Codex forces non-interactive approval policy"
assert_contains "--sandbox" "$codex_argv" "Codex argv includes sandbox flag"
assert_contains "read-only" "$codex_argv" "Codex sandbox is read-only"
assert_contains "--skip-git-repo-check" "$codex_argv" "Codex does not require a git repo"
assert_contains "--ephemeral" "$codex_argv" "Codex does not persist agent work"
assert_contains "--ignore-rules" "$codex_argv" "Codex ignores ambient project exec policy"
assert_contains "--output-last-message" "$codex_argv" "Codex final output is extracted"
assert_contains "-C" "$codex_argv" "Codex receives an explicit caller root"
assert_contains "$ROOT" "$codex_argv" "Codex caller root is the invoking directory"
assert_not_contains "workspace-write" "$codex_argv" "Codex never requests a write-capable sandbox"
assert_not_contains "danger-full-access" "$codex_argv" "Codex never requests an unrestricted sandbox"
assert_not_contains "dangerously-bypass" "$codex_argv" "Codex never bypasses approvals or sandboxing"
assert_not_contains "--worktree" "$codex_argv" "Codex does not create a managed worktree"
assert_not_contains "--add-dir" "$codex_argv" "Codex does not add writable directories"
assert_equals "$ROOT" "$(cat "$RUN_DIR/codex.cwd")" "Codex runs from the caller's cwd"

run_eval_case removed-timeout-knob with-claude FM_EVAL_GRADER=codex FM_EVAL_CODEX_TIMEOUT_SECONDS=0
assert_equals 0 "$RUN_RC" "removed timeout knob does not reject Codex grading"

caller_project="$TMP_ROOT/caller-project"
mkdir -p "$caller_project/reports"
printf 'evidence exists\n' > "$caller_project/reports/out.md"
printf 'Completed work; evidence: reports/out.md\n' > "$caller_project/deliverable.md"
caller_project_cwd=$(cd "$caller_project" && pwd)
case_dir="$TMP_ROOT/caller-cwd-fallback"
fakebin=$(make_fakebin "$case_dir" 0)
: > "$case_dir/claude.argv"
: > "$case_dir/claude.prompt"
: > "$case_dir/codex.argv"
: > "$case_dir/codex.prompt"
: > "$case_dir/codex.cwd"
(
  cd "$caller_project" || exit 1
  env \
    PATH="$fakebin:$BASE_PATH" \
    FM_FAKE_CLAUDE_ARGV="$case_dir/claude.argv" \
    FM_FAKE_CLAUDE_PROMPT="$case_dir/claude.prompt" \
    FM_FAKE_CODEX_ARGV="$case_dir/codex.argv" \
    FM_FAKE_CODEX_PROMPT="$case_dir/codex.prompt" \
    FM_FAKE_CODEX_CWD="$case_dir/codex.cwd" \
    FM_FAKE_SECRET="$SECRET" \
    FM_FAKE_CLAUDE_MODE=session-limit \
    "$SCRIPT" completeness deliverable.md > "$case_dir/stdout" 2> "$case_dir/stderr"
) && rc=0 || rc=$?
assert_equals 0 "$rc" "auto fallback from caller cwd succeeds"
assert_contains "$caller_project_cwd" "$(cat "$case_dir/codex.argv")" "auto fallback passes caller cwd to Codex"
assert_equals "$caller_project_cwd" "$(cat "$case_dir/codex.cwd")" "auto fallback also runs Codex from the caller cwd"
assert_contains "reports/out.md" "$(cat "$case_dir/codex.prompt")" "auto fallback preserves relative evidence path in prompt"

run_eval_case prompt-claude with-claude FM_EVAL_GRADER=claude FM_FAKE_CLAUDE_MODE=success
claude_prompt=$(cat "$RUN_DIR/claude.prompt")
run_eval_case prompt-codex with-claude FM_EVAL_GRADER=codex
codex_prompt=$(cat "$RUN_DIR/codex.prompt")
assert_equals "$claude_prompt" "$codex_prompt" "Claude and Codex receive the exact same grading prompt"

run_eval_case codex-output with-claude FM_EVAL_GRADER=codex FM_FAKE_CODEX_FINAL='FINAL ONLY'
assert_equals 0 "$RUN_RC" "Codex final-message extraction succeeds"
assert_equals "FINAL ONLY" "$RUN_STDOUT" "Codex transcript noise is excluded from stdout"
assert_equals "" "$RUN_STDERR" "Codex success keeps transport stderr out of grader stderr"

case_dir="$TMP_ROOT/validation-before-launch"
fakebin=$(make_fakebin "$case_dir" 0)
env \
  PATH="$fakebin:$BASE_PATH" \
  FM_FAKE_CLAUDE_ARGV="$case_dir/claude.argv" \
  FM_FAKE_CLAUDE_PROMPT="$case_dir/claude.prompt" \
  FM_FAKE_CODEX_ARGV="$case_dir/codex.argv" \
  FM_FAKE_CODEX_PROMPT="$case_dir/codex.prompt" \
  FM_FAKE_CODEX_CWD="$case_dir/codex.cwd" \
  FM_FAKE_SECRET="$SECRET" \
  "$SCRIPT" no-such-eval "$TARGET" > "$case_dir/stdout" 2> "$case_dir/stderr" && rc=0 || rc=$?
assert_equals 1 "$rc" "missing eval fails before provider launch"
assert_equals "" "$(cat "$case_dir/claude.argv" 2>/dev/null)" "missing eval does not call Claude"
assert_equals "" "$(cat "$case_dir/codex.argv" 2>/dev/null)" "missing eval does not call Codex"

case_dir="$TMP_ROOT/missing-target-before-launch"
fakebin=$(make_fakebin "$case_dir" 0)
env \
  PATH="$fakebin:$BASE_PATH" \
  FM_FAKE_CLAUDE_ARGV="$case_dir/claude.argv" \
  FM_FAKE_CLAUDE_PROMPT="$case_dir/claude.prompt" \
  FM_FAKE_CODEX_ARGV="$case_dir/codex.argv" \
  FM_FAKE_CODEX_PROMPT="$case_dir/codex.prompt" \
  FM_FAKE_CODEX_CWD="$case_dir/codex.cwd" \
  FM_FAKE_SECRET="$SECRET" \
  "$SCRIPT" completeness "$TMP_ROOT/no-such-target.md" > "$case_dir/stdout" 2> "$case_dir/stderr" && rc=0 || rc=$?
assert_equals 1 "$rc" "missing target fails before provider launch"
assert_equals "" "$(cat "$case_dir/claude.argv" 2>/dev/null)" "missing target does not call Claude"
assert_equals "" "$(cat "$case_dir/codex.argv" 2>/dev/null)" "missing target does not call Codex"

case_dir="$TMP_ROOT/invalid-grader"
fakebin=$(make_fakebin "$case_dir" 0)
env \
  PATH="$fakebin:$BASE_PATH" \
  FM_FAKE_CLAUDE_ARGV="$case_dir/claude.argv" \
  FM_FAKE_CLAUDE_PROMPT="$case_dir/claude.prompt" \
  FM_FAKE_CODEX_ARGV="$case_dir/codex.argv" \
  FM_FAKE_CODEX_PROMPT="$case_dir/codex.prompt" \
  FM_FAKE_CODEX_CWD="$case_dir/codex.cwd" \
  FM_FAKE_SECRET="$SECRET" \
  FM_EVAL_GRADER=bogus \
  "$SCRIPT" completeness "$TARGET" > "$case_dir/stdout" 2> "$case_dir/stderr" && rc=0 || rc=$?
assert_equals 2 "$rc" "invalid FM_EVAL_GRADER is rejected"
assert_contains "invalid FM_EVAL_GRADER=bogus" "$(cat "$case_dir/stderr")" "invalid grader error is explicit"
assert_equals "" "$(cat "$case_dir/claude.argv" 2>/dev/null)" "invalid grader does not call Claude"
assert_equals "" "$(cat "$case_dir/codex.argv" 2>/dev/null)" "invalid grader does not call Codex"

pass "run_eval.sh selects graders safely and preserves the eval prompt contract"

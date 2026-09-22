#!/usr/bin/env bash
# Run any eval against any deliverable, headless.
# Usage: ./run_eval.sh <eval-name> <file-to-grade>
#   e.g. ./run_eval.sh tov draft_post.md
# The eval file IS the grading spec.
# Select the grader with FM_EVAL_GRADER=auto|claude|codex.
#   auto   default; try Claude first, then Codex only for known auth, session/subscription-limit,
#          credential-refresh, or unavailable-CLI transport blocks.
#          Ordinary grader errors, interrupts, target/spec errors, and FAIL verdicts do not switch.
#   claude use `claude -p` directly and never switch providers.
#   codex  use `codex exec` directly with a read-only sandbox, ephemeral session, no repo requirement,
#          disabled hooks, and final-message extraction.
#          It runs from the caller's current directory so read-only inspection can resolve relative evidence paths.
# Codex runs are hard-bounded by an internal 600-second deadline.

set -euo pipefail
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$EVAL_DIR/.." && pwd)"
CALLER_CWD=$PWD
CODEX_TIMEOUT_SECONDS=600

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ "$#" -eq 2 ] || { usage >&2; exit 2; }

EVAL_NAME=$1
TARGET=$2
GRADER=${FM_EVAL_GRADER:-auto}

case "$GRADER" in
  auto|claude|codex) ;;
  *)
    printf 'run_eval.sh: invalid FM_EVAL_GRADER=%s; expected auto, claude, or codex.\n' "$GRADER" >&2
    exit 2
    ;;
esac

EVAL_FILE="$EVAL_DIR/${EVAL_NAME%.md}-eval.md"
[ -f "$EVAL_FILE" ] || EVAL_FILE="$EVAL_DIR/$EVAL_NAME.md"

[ -f "$EVAL_FILE" ] || { echo "no such eval: $EVAL_NAME (looked for $EVAL_FILE)"; exit 1; }
[ -f "$TARGET" ] || { echo "no such file: $TARGET"; exit 1; }

PROMPT=$(printf '%s' "You are an eval grader. Grade the DELIVERABLE strictly against the EVAL SPEC below. Follow the spec's output contract exactly. Be harsh; a borderline case fails.
You may use read-only inspection to resolve declared paths and verify evidence, but do not edit files, persist work, use the network beyond this model call, or run project tools beyond read-only verification commands.

=== EVAL SPEC ===
$(cat "$EVAL_FILE")

=== DELIVERABLE ===
$(cat "$TARGET")")

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-eval.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

emit_result() {  # <stdout-file> <stderr-file> <rc>
  local stdout_file=$1 stderr_file=$2 rc=$3
  [ ! -s "$stdout_file" ] || cat "$stdout_file"
  [ ! -s "$stderr_file" ] || cat "$stderr_file" >&2
  return "$rc"
}

run_claude_grader() {  # <stdout-file> <stderr-file>
  local stdout_file=$1 stderr_file=$2 rc
  : > "$stdout_file"
  : > "$stderr_file"
  if ! command -v claude >/dev/null 2>&1; then
    printf 'run_eval.sh: claude grader unavailable: claude not found on PATH.\n' > "$stderr_file"
    return 127
  fi
  set +e
  claude -p "$PROMPT" > "$stdout_file" 2> "$stderr_file"
  rc=$?
  set -e
  return "$rc"
}

run_codex_grader() {  # <stdout-file> <stderr-file>
  local stdout_file=$1 stderr_file=$2 last_message transcript raw_stderr prompt_file rc
  : > "$stdout_file"
  : > "$stderr_file"
  if ! command -v codex >/dev/null 2>&1; then
    printf 'run_eval.sh: codex grader unavailable: codex not found on PATH.\n' > "$stderr_file"
    return 127
  fi
  last_message="$TMP_ROOT/codex-last-message.txt"
  transcript="$TMP_ROOT/codex-transcript.txt"
  raw_stderr="$TMP_ROOT/codex-stderr.txt"
  prompt_file="$TMP_ROOT/codex-prompt.txt"
  printf '%s' "$PROMPT" > "$prompt_file"
  set +e
  fm_run_timed "$CODEX_TIMEOUT_SECONDS" \
    bash -c "prompt_file=\$1; shift; exec \"\$@\" < \"\$prompt_file\"" _ "$prompt_file" \
      codex exec \
      --disable hooks \
      -c 'approval_policy="never"' \
      --sandbox read-only \
      --skip-git-repo-check \
      --ephemeral \
      --ignore-rules \
      -C "$CALLER_CWD" \
      --output-last-message "$last_message" \
      - \
      > "$transcript" 2> "$raw_stderr"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      printf 'run_eval.sh: codex grader timed out after %ss.\n' "$CODEX_TIMEOUT_SECONDS" > "$stderr_file"
    else
      printf 'run_eval.sh: codex grader failed before producing a final response (exit %s).\n' "$rc" > "$stderr_file"
    fi
    return "$rc"
  fi
  if [ ! -f "$last_message" ]; then
    printf 'run_eval.sh: codex grader produced no final response.\n' > "$stderr_file"
    return 1
  fi
  cat "$last_message" > "$stdout_file"
}

claude_fallback_reason() {  # <rc> <stderr-file>
  local rc=$1 stderr_file=$2
  case "$rc" in
    130|143) return 1 ;;
  esac
  if [ "$rc" -eq 127 ] && grep -Eiq 'claude (grader unavailable|not found)|command not found|no such file|cannot execute' "$stderr_file"; then
    printf 'claude-unavailable\n'
    return 0
  fi
  if grep -Eiq 'Claude AI usage limit reached|usage limit|session limit|subscription[^[:cntrl:]]*limit|limit reached[^[:cntrl:]]*(reset|resets|try again)' "$stderr_file"; then
    printf 'session-limit\n'
    return 0
  fi
  if grep -Eiq '(OAuth|auth|authentication|credential|credentials)[^[:cntrl:]]*(expired|refresh|invalid|required|login|log in|reauth)|session[^[:cntrl:]]*(not eligible|no longer eligible|ineligible)|please[^[:cntrl:]]*(login|log in|reauth)' "$stderr_file"; then
    printf 'auth-refresh\n'
    return 0
  fi
  return 1
}

CLAUDE_STDOUT="$TMP_ROOT/claude.stdout"
CLAUDE_STDERR="$TMP_ROOT/claude.stderr"
CODEX_STDOUT="$TMP_ROOT/codex.stdout"
CODEX_STDERR="$TMP_ROOT/codex.stderr"

case "$GRADER" in
  claude)
    if run_claude_grader "$CLAUDE_STDOUT" "$CLAUDE_STDERR"; then rc=0; else rc=$?; fi
    emit_result "$CLAUDE_STDOUT" "$CLAUDE_STDERR" "$rc"
    ;;
  codex)
    if run_codex_grader "$CODEX_STDOUT" "$CODEX_STDERR"; then rc=0; else rc=$?; fi
    emit_result "$CODEX_STDOUT" "$CODEX_STDERR" "$rc"
    ;;
  auto)
    if run_claude_grader "$CLAUDE_STDOUT" "$CLAUDE_STDERR"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
      emit_result "$CLAUDE_STDOUT" "$CLAUDE_STDERR" 0
      exit $?
    fi
    if reason=$(claude_fallback_reason "$rc" "$CLAUDE_STDERR"); then
      printf 'run_eval.sh: auto fallback reason=%s selected_grader=codex.\n' "$reason" >&2
      if run_codex_grader "$CODEX_STDOUT" "$CODEX_STDERR"; then rc=0; else rc=$?; fi
      emit_result "$CODEX_STDOUT" "$CODEX_STDERR" "$rc"
      exit $?
    fi
    emit_result "$CLAUDE_STDOUT" "$CLAUDE_STDERR" "$rc"
    ;;
esac

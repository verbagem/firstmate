#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched.
# herdr's `pane report-agent` is the same registry the adapter reads, so registering and not registering an agent on a plain shell pane exercises exactly the classification the control plane gates on.
# A shell `read` prompt also provides a real pending composer for the busy-input regression without needing model credentials.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Reproduce the incident against the real backend: a busy worker has genuine
# unsubmitted input in its composer when exit or relaunch arrives.
# The lifecycle call must refuse before sending Escape or appending a command.
# The fixture shell expands $line after the command reaches the pane.
# shellcheck disable=SC2016
READ_CMD='printf "❯ "; IFS= read -r line; printf "SUBMITTED:%s\n" "$line"; sleep 30'
fm_backend_herdr_send_literal "$SESSION:$PANE_ID" "$READ_CMD" \
  || fail "could not type the pending-composer fixture"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" Enter \
  || fail "could not start the pending-composer fixture"
sleep 0.3
fm_backend_herdr_send_literal "$SESSION:$PANE_ID" "queued follow-up" \
  || fail "could not type queued worker input"
sleep 0.2
STATE=$(fm_backend_composer_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = pending ] || fail "real herdr queued input should classify pending, got '$STATE'"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" hsmoke)
printf 'busy_gen=%s\n' "$GEN" >> "$HOME_DIR/state/hsmoke.meta"
mkdir -p "$HOME_DIR/state/hsmoke.inbox/handled"
printf 'schema=fm-task-inbox.v1\n--\nlegitimate queued worker instruction' > "$HOME_DIR/state/hsmoke.inbox/001.msg"
INBOX_BEFORE=$(cat "$HOME_DIR/state/hsmoke.inbox/001.msg")
BRIEF_BEFORE=$(cat "$HOME_DIR/data/hsmoke/brief.md")

for VERB in exit relaunch; do
  if [ "$VERB" = relaunch ]; then
    if OUT=$(run_control hsmoke relaunch --note "continue safely" 2>&1); then
      fail "relaunch should refuse real queued composer input: $OUT"
    fi
  elif OUT=$(run_control hsmoke exit 2>&1); then
    fail "exit should refuse real queued composer input: $OUT"
  fi
  case "$OUT" in
    *"composer holds a queued instruction"*) : ;;
    *) fail "$VERB refusal should identify the preserved queued input, got: $OUT" ;;
  esac
  STATE=$(fm_backend_composer_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = pending ] || fail "$VERB changed the real queued composer, which now reads '$STATE'"
  PANE=$(fm_backend_herdr_capture_ansi "$SESSION:$PANE_ID" 20 2>/dev/null || true)
  case "$PANE" in
    *"queued follow-up"*) : ;;
    *) fail "$VERB removed the legitimate queued composer input" ;;
  esac
  case "$PANE" in
    *"/exit"*|*"/quit"*|*"SUBMITTED:queued follow-up"*) fail "$VERB let lifecycle text concatenate with or submit queued input" ;;
  esac
  [ "$(cat "$HOME_DIR/state/hsmoke.inbox/001.msg")" = "$INBOX_BEFORE" ] \
    || fail "$VERB changed the durable queued worker instruction"
  [ "$(cat "$HOME_DIR/data/hsmoke/brief.md")" = "$BRIEF_BEFORE" ] \
    || fail "$VERB did not restore the original instructions after refusing relaunch"
done
pass "real herdr: busy queued input survives exit and relaunch without lifecycle text entering chat"

fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-c >/dev/null 2>&1 || true
sleep 0.5
"$ROOT/bin/fm-busy-event.sh" retire "$HOME_DIR/state" hsmoke --current-gen >/dev/null 2>&1 || true

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
# Re-open the empty fixture so the lifecycle command has a positively empty
# composer instead of inheriting the earlier pending row from scrollback.
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-u >/dev/null 2>&1 || true
sleep 0.5
fm_backend_herdr_send_literal "$SESSION:$PANE_ID" "$READ_CMD" \
  || fail "could not type the empty-composer fixture"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" Enter \
  || fail "could not start the empty-composer fixture"
sleep 0.3
STATE=$(fm_backend_composer_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = empty ] || fail "real herdr empty fixture should classify empty, got '$STATE': $(fm_backend_herdr_capture "$SESSION:$PANE_ID" 20 2>/dev/null || true)"
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true

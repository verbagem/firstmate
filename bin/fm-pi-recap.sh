#!/usr/bin/env bash
# fm-pi-recap.sh - render a captain-facing recap for one ship/scout task,
# consumed by the tracked .pi/extensions/fm-task-recap.ts Pi widget.
#
# Pure, side-effect-free read: derives every line from the SAME authoritative
# owners the fleet-state digest and supervision protocol already use
# (bin/fm-classify-lib.sh's last_status_line/status_line_verb/status_line_note
# and status_open_decisions, state/<id>.meta's pr= field, and the task's
# data/backlog.md title line). Never a parallel source of truth. Safe to call
# on every turn boundary; the caller (fm-task-recap.ts) is responsible for
# skipping the widget update when the rendered text is unchanged.
#
# Usage:
#   fm-pi-recap.sh render <task-id> <state-dir> <data-dir>
#
# Prints zero or more lines to stdout: the task title (from data/backlog.md),
# the current phase (translated from the latest status-log verb, with its
# note), an open blocker/decision line (only when status_open_decisions
# reports one still open), and a PR line (only when state/<id>.meta has a
# pr= value). Missing inputs (absent status file, absent meta, absent backlog
# entry) degrade to fewer lines rather than an error; exit status is always 0
# on a well-formed call so a transient read races the caller can retry rather
# than treating as fatal, and 2 on a genuine usage error.
#
# Every free-text field (title, status note, decision note) is passed through
# fm_pi_recap_sanitize: it strips ANSI escapes, redacts absolute local
# filesystem paths and secret-shaped tokens, collapses whitespace, and
# truncates deterministically. Best-effort defense in depth, not a full DLP
# system - the status log is written by a trusted crewmate under firstmate's
# own status-line convention, not untrusted input.
set -u

usage() {
  cat >&2 <<'EOF'
usage: fm-pi-recap.sh render <task-id> <state-dir> <data-dir>
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

FM_PI_RECAP_LINE_MAX=${FM_PI_RECAP_LINE_MAX:-100}

# fm_pi_recap_sanitize: best-effort captain-facing scrub of one free-text
# field. ANSI strip -> whitespace collapse -> path/secret redaction ->
# deterministic truncation, in that order so redaction sees normalized text.
fm_pi_recap_sanitize() {
  local text=$1
  # Strip ANSI CSI/OSC escape sequences.
  text=$(printf '%s' "$text" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')
  # Collapse all whitespace (including embedded newlines) to single spaces.
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ' | sed -E 's/ +/ /g')
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  # Redact absolute local filesystem paths (never show the captain a machine
  # path) and secret-shaped tokens (common credential prefixes, a
  # token=/key=/secret= assignment, or a bare 24+ char alnum/underscore/dash
  # run that reads as a token/key). Deliberately portable POSIX ERE: no \b
  # word-boundary and no case-insensitive s///I flag, neither of which BSD
  # sed (the default /usr/bin/sed on macOS) supports - both silently no-op
  # instead of erroring, which let secrets through uncaught until this was
  # tested against the real platform sed rather than assumed GNU-compatible.
  # Case coverage is lowercase-only for the keyword prefixes as a result;
  # this stays best-effort defense in depth, not a full DLP system.
  text=$(printf '%s' "$text" | sed -E \
    -e 's#(/Users|/home)(/[A-Za-z0-9._-]+)+#[path]#g' \
    -e 's/(sk-|ghp_|gho_|github_pat_|xox[a-z]-|AKIA)[A-Za-z0-9_-]+/[redacted]/g' \
    -e 's/(token|key|secret|password|bearer)[=: ]+[A-Za-z0-9_.-]{8,}/[redacted]/g' \
    -e 's/[A-Za-z0-9_-]{24,}/[redacted]/g')
  if [ "${#text}" -gt "$FM_PI_RECAP_LINE_MAX" ]; then
    text="${text:0:$((FM_PI_RECAP_LINE_MAX - 1))}…"
  fi
  printf '%s' "$text"
}

# fm_pi_recap_title: the task's plain-language title from data/backlog.md's
# "- [ ] <id> - <title> (repo: ...)" line (docs/configuration.md's tasks-axi
# markdown backend format, the same file the manual backend hand-edits). The
# task id itself never reaches the recap - only this title does.
fm_pi_recap_title() {  # <task-id> <data-dir>
  local id=$1 data=$2 backlog="$2/backlog.md" line prefix title
  [ -f "$backlog" ] || return 0
  prefix="- [ ] $id - "
  line=$(grep -F -- "$prefix" "$backlog" 2>/dev/null | head -1)
  if [ -z "$line" ]; then
    prefix="- [x] $id - "
    line=$(grep -F -- "$prefix" "$backlog" 2>/dev/null | head -1)
  fi
  [ -n "$line" ] || return 0
  title=${line#"$prefix"}
  title=${title%% (repo:*}
  [ -n "$title" ] || return 0
  fm_pi_recap_sanitize "$title"
}

# fm_pi_recap_phase_label: plain-language translation of a status verb,
# matching the captain-facing wording AGENTS.md section 9 requires (never the
# internal verb itself).
fm_pi_recap_phase_label() {  # <verb>
  case "$1" in
    working) printf 'In progress' ;;
    needs-decision) printf 'Needs a decision' ;;
    blocked) printf 'Blocked' ;;
    paused) printf 'Paused' ;;
    done) printf 'Done' ;;
    failed) printf 'Failed' ;;
    resolved|captain-held) printf 'In progress' ;;
    *) printf 'Starting up' ;;
  esac
}

# fm_pi_recap_pr: the PR URL from state/<id>.meta's pr= line, or nothing.
fm_pi_recap_pr() {  # <meta-file>
  local meta=$1 pr
  [ -f "$meta" ] || return 0
  pr=$(grep -m1 '^pr=' "$meta" 2>/dev/null)
  pr=${pr#pr=}
  [ -n "$pr" ] || return 0
  fm_pi_recap_sanitize "$pr"
}

fm_pi_recap_render() {  # <task-id> <state-dir> <data-dir>
  local id=$1 state=$2 data=$3
  local status_file="$state/$id.status" meta_file="$state/$id.meta"
  local title last verb note phase open_decisions open_last open_verb open_note open_count pr

  title=$(fm_pi_recap_title "$id" "$data")
  [ -n "$title" ] || title='This task'
  printf '%s\n' "$title"

  last=$(last_status_line "$status_file")
  if [ -n "$last" ]; then
    verb=$(status_line_verb "$last")
    note=$(fm_pi_recap_sanitize "$(status_line_note "$last")")
    phase=$(fm_pi_recap_phase_label "$verb")
    if [ -n "$note" ]; then
      printf '%s: %s\n' "$phase" "$note"
    else
      printf '%s\n' "$phase"
    fi
  else
    printf '%s\n' "$(fm_pi_recap_phase_label '')"
  fi

  # Skip the dedicated line when the latest status line IS the open blocker/
  # decision - the phase line above already shows it, and repeating it would
  # be exactly the unchanged/duplicate noise the recap must not add. Only a
  # decision left open under a LATER, unrelated status line earns its own
  # line here.
  case "${verb:-}" in
    blocked|needs-decision) ;;
    *)
      open_decisions=$(status_open_decisions "$status_file")
      if [ -n "$open_decisions" ]; then
        open_count=$(printf '%s\n' "$open_decisions" | grep -c .)
        open_last=$(printf '%s\n' "$open_decisions" | tail -1)
        open_verb=${open_last#*$'\t'}; open_verb=${open_verb%%$'\t'*}
        open_note=${open_last##*$'\t'}
        open_note=$(fm_pi_recap_sanitize "$open_note")
        case "$open_verb" in
          needs-decision) printf 'Needs a decision: %s' "$open_note" ;;
          *) printf 'Blocked: %s' "$open_note" ;;
        esac
        if [ "$open_count" -gt 1 ]; then
          printf ' (+%d more)\n' "$((open_count - 1))"
        else
          printf '\n'
        fi
      fi
      ;;
  esac

  pr=$(fm_pi_recap_pr "$meta_file")
  [ -z "$pr" ] || printf 'PR: %s\n' "$pr"
}

CMD=${1:-}
case "$CMD" in
  render) shift ;;
  *) usage ;;
esac

ID=${1:-}
STATE=${2:-}
DATA=${3:-}
[ -n "$ID" ] && [ -n "$STATE" ] && [ -n "$DATA" ] || usage

fm_pi_recap_render "$ID" "$STATE" "$DATA"

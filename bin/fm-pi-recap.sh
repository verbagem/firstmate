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
# fm_pi_recap_sanitize: it strips ANSI CSI/OSC escapes, redacts absolute local
# filesystem paths and keyword-prefixed secret-shaped tokens, collapses
# whitespace, and truncates deterministically. The pr= URL is exempt only when
# it parses under bin/fm-pr-lib.sh's fm_pr_url_parse allowlist. Best-effort defense in depth, not a full DLP
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_PI_RECAP_LINE_MAX=${FM_PI_RECAP_LINE_MAX:-100}

# fm_pi_recap_sanitize: best-effort captain-facing scrub of one free-text
# field. ANSI strip -> whitespace collapse -> path/secret redaction ->
# deterministic truncation, in that order so redaction sees normalized text.
fm_pi_recap_sanitize() {
  local text=$1
  # Strip ANSI OSC (ESC ] ... BEL | ESC \) and CSI (ESC [ ... final) sequences.
  text=$(printf '%s' "$text" | sed -E \
    -e $'s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g' \
    -e $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g')
  # Collapse all whitespace (including embedded newlines) to single spaces.
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ' | sed -E 's/ +/ /g')
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  # Redact absolute local filesystem paths under the common roots (never show
  # the captain a machine path) and keyword-prefixed secret-shaped tokens:
  # well-known credential prefixes, a token=/key=/secret=/password=/bearer
  # assignment anchored at a word start (or carrying an UPPER_CASE_ identifier
  # prefix such as API_KEY=), and a bearer credential that is assigned, sits
  # under an Authorization: header, or is an 8+ char token containing a digit;
  # the same digit gate applies to the prose-shaped "key: word" colon-space
  # form, so "bearer authentication" and "the key: understanding" are left
  # alone while "password: hunter2hunter2" is still redacted. Only absolute paths and file://
  # URLs are redacted (a relative app/home/x or an http URL path segment is
  # left alone), and the
  # project's own bracketed [key=<slug>] decision-key grammar from
  # bin/fm-classify-lib.sh is structural syntax, never a credential.
  # Portable POSIX ERE: no \b and no
  # s///I flag, neither of which BSD sed (macOS /usr/bin/sed) supports - both
  # silently no-op instead of erroring. Best-effort defense in depth, not DLP.
  local c='[A-Za-z0-9_.-]' digit_tok
  digit_tok="(${c}{7,}[0-9]${c}*|[0-9]${c}{7,}|${c}[0-9]${c}{6,}|${c}{2}[0-9]${c}{5,}|${c}{3}[0-9]${c}{4,}|${c}{4}[0-9]${c}{3,}|${c}{5}[0-9]${c}{2,}|${c}{6}[0-9]${c}+)"
  text=$(printf '%s' "$text" | sed -E \
    -e 's#file://(/[A-Za-z0-9._-]+)+#[path]#g' \
    -e 's#(^|[^A-Za-z0-9._/-])(/Users|/home|/root|/opt|/var|/etc|/tmp|/srv|/private|/mnt)(/[A-Za-z0-9._-]+)+#\1[path]#g' \
    -e 's/(sk-|ghp_|gho_|github_pat_|xox[a-z]-|AKIA)[A-Za-z0-9_-]+/[redacted]/g' \
    -e 's/(^|[^A-Za-z0-9_[])[A-Z0-9_]+_(TOKEN|KEY|SECRET|PASSWORD)=[A-Za-z0-9_.-]{8,}/\1[redacted]/g' \
    -e 's/(^|[^A-Za-z0-9_[])([Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])(= ?|:)[A-Za-z0-9_.-]{8,}/\1[redacted]/g' \
    -e "s/(^|[^A-Za-z0-9_[])([Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]): +$digit_tok/\\1[redacted]/g" \
    -e 's/(^|[^A-Za-z0-9_])[Bb][Ee][Aa][Rr][Ee][Rr][=:] ?[A-Za-z0-9_.-]{8,}/\1[redacted]/g' \
    -e 's/(^|[^A-Za-z0-9_])[Aa]uthorization: *[Bb][Ee][Aa][Rr][Ee][Rr] +[A-Za-z0-9_.-]{8,}/\1[redacted]/g' \
    -e "s/(^|[^A-Za-z0-9_])[Bb][Ee][Aa][Rr][Ee][Rr] +$digit_tok/\\1[redacted]/g")
  if [ "${#text}" -gt "$FM_PI_RECAP_LINE_MAX" ]; then
    text="${text:0:$((FM_PI_RECAP_LINE_MAX - 1))}…"
  fi
  printf '%s' "$text"
}

# fm_pi_recap_title: the task's plain-language title from data/backlog.md's
# "- [ ] <id> - <title> (repo: ...)" line (docs/configuration.md's tasks-axi
# markdown backend format, the same file the manual backend hand-edits). The
# task id itself never reaches the recap - only this title does.
#
# fm_pi_recap_title_of is a shell port of bin/fm-fleet-snapshot.sh's jq
# title_of (wrapped-URL strip, blocked-by clause strip, then clean_title =
# strip_trailing_metadata + strip_title_artifacts + whitespace collapse) so
# the recap shows the captain the same title the fleet snapshot does. Keep
# the two in step when either changes.
fm_pi_recap_title_of() {  # <rest-after-"<id> - ">
  printf '%s' "$1" | sed -E \
    -e 's#<?https?://[^[:space:])"<>]+>?##g' \
    -e 's/[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$//' \
    -e 's/[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+//g' \
    -e ':meta' \
    -e 's/[[:space:]]*\([[:space:]]*((repo|kind|priority|hold|hold-kind):[[:space:]]*[^)]*|(since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\)[[:space:]]*$//' \
    -e 'tmeta' \
    -e 's#[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\.md$##' \
    -e 's#[[:space:]]+data/[^[:space:])]+/report\.md$##' \
    -e 's/[[:space:]]+-[[:space:]]+local main$//' \
    -e 's/[[:space:]]+local main$//' \
    -e 's/[[:space:]]+-[[:space:]]*$//' \
    -e 's/[[:space:]]+/ /g' \
    -e 's/^ //' -e 's/ $//'
}

fm_pi_recap_title() {  # <task-id> <data-dir>
  local id=$1 backlog="$2/backlog.md" line rest='' title
  [ -f "$backlog" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[-*][[:space:]]+\[[\ xX]\][[:space:]]+"$id"[[:space:]]+-[[:space:]]+(.*)$ ]]; then
      rest=${BASH_REMATCH[1]}
      break
    fi
  done < "$backlog"
  [ -n "$rest" ] || return 0
  title=$(fm_pi_recap_title_of "$rest")
  [ -n "$title" ] || return 0
  fm_pi_recap_sanitize "$title"
}

# fm_pi_recap_phase_label: plain-language translation of a status verb,
# matching the captain-facing wording AGENTS.md section 9 requires (never the
# internal verb itself). 'Starting up' is reserved for the true absent-status
# case (empty verb); any other unrecognized verb is an 'Update' so a task
# that has been reporting progress is never shown as not yet begun.
fm_pi_recap_phase_label() {  # <verb>
  case "$1" in
    '') printf 'Starting up' ;;
    working) printf 'In progress' ;;
    needs-decision) printf 'Needs a decision' ;;
    blocked) printf 'Blocked' ;;
    paused) printf 'Paused' ;;
    done) printf 'Done' ;;
    failed) printf 'Failed' ;;
    resolved|captain-held) printf 'In progress' ;;
    *) printf 'Update' ;;
  esac
}

# fm_pi_recap_pr: the PR URL from state/<id>.meta's pr= line, or nothing. A
# value that parses under bin/fm-pr-lib.sh's fm_pr_url_parse allowlist (the
# canonical GitHub pull / GitLab merge-request URL shapes, no query or
# fragment) is emitted verbatim - it is the one field the captain needs exact;
# anything else goes through the general sanitizer.
fm_pi_recap_pr() {  # <meta-file>
  local meta=$1 pr
  [ -f "$meta" ] || return 0
  pr=$(grep -m1 '^pr=' "$meta" 2>/dev/null)
  pr=${pr#pr=}
  [ -n "$pr" ] || return 0
  if fm_pr_url_parse "$pr"; then
    printf '%s' "$pr"
  else
    fm_pi_recap_sanitize "$pr"
  fi
}

fm_pi_recap_render() {  # <task-id> <state-dir> <data-dir>
  local id=$1 state=$2 data=$3
  local status_file="$state/$id.status" meta_file="$state/$id.meta"
  local title last verb='' note phase open_decisions open_last open_verb open_note open_count=0 more='' pr
  local last_key latest_in_open=0

  title=$(fm_pi_recap_title "$id" "$data")
  [ -n "$title" ] || title='This task'
  printf '%s\n' "$title"

  # The open blocker/decision set is always folded so the "(+N more)" count
  # survives even when the latest line's own text is suppressed below. The
  # latest line only stands in for its own open record when the fold actually
  # accepted it (valid key slug); otherwise it is shown on its own merits and
  # the folded set still gets its dedicated line.
  open_decisions=$(status_open_decisions "$status_file")
  [ -z "$open_decisions" ] || open_count=$(printf '%s\n' "$open_decisions" | grep -c .)

  last=$(last_status_line "$status_file")
  if [ -n "$last" ]; then
    verb=$(status_line_verb "$last")
    note=$(fm_pi_recap_sanitize "$(status_line_note "$last")")
    phase=$(fm_pi_recap_phase_label "$verb")
    case "$verb" in
      blocked|needs-decision)
        if last_key=$(_fm_decision_key "$last"); then
          case $'\n'"$open_decisions" in
            *$'\n'"$last_key"$'\t'*) latest_in_open=1 ;;
          esac
        fi
        [ "$latest_in_open" = 1 ] && [ "$open_count" -gt 1 ] && more=" (+$((open_count - 1)) more)"
        ;;
    esac
    if [ -n "$note" ]; then
      printf '%s: %s%s\n' "$phase" "$note" "$more"
    else
      printf '%s%s\n' "$phase" "$more"
    fi
  else
    printf '%s\n' "$(fm_pi_recap_phase_label '')"
  fi

  # Skip the dedicated line when the latest status line IS the open blocker/
  # decision - the phase line above already shows it (with the count of any
  # others still open), and repeating it would be exactly the unchanged/
  # duplicate noise the recap must not add. Only a decision left open under a
  # LATER, unrelated status line earns its own line here.
  case "$latest_in_open" in
    1) ;;
    *)
      if [ "$open_count" -gt 0 ]; then
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

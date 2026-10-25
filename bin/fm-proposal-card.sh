#!/usr/bin/env bash
# fm-proposal-card.sh - proposal-card validator, renderer, and rejection helper.
#
# This script is the single full owner of the proposal-card contract for
# agent-initiated recommendations.
# Other Firstmate surfaces may point here, but must not restate the full field
# list, decision-time vocabulary, cadence vocabulary, or rejection mechanics.
#
# A proposal card is a read-only recommendation packet.
# It does not create a captain-held task, answer one, steer a worker, restart a
# worker, clean up state, spend money, contact anyone, publish externally, touch
# credentials, discard work, merge a PR, or authorize destructive, irreversible,
# security-sensitive, external-send, credential, discard, or merge actions.
# Those actions still require their normal Firstmate owner and authority path.
# Full-autopilot outreach, autonomous spending, external publishing or contact,
# and speculative marketplace-replacement work are outside this contract.
#
# Required JSON fields, each a non-empty string except as noted:
#   triggering_source_evidence  The source and evidence that caused the agent to recommend action.
#   proposed_action             The exact action being recommended.
#   why_now                     Why this recommendation deserves attention now.
#   expected_impact             The expected outcome if accepted.
#   decision_time_class         One of the machine values below.
#   risk_blast_radius           The risk and blast radius if the action is wrong or incomplete.
#   permission_boundary         What the card does not authorize and what authority is still required.
#   proof_receipt               The proof or receipt that will show the action happened safely.
#   rollback_stop_condition     When to stop, roll back, or decline to proceed.
#   recommended_lane            The existing Firstmate lane that should carry any approved follow-up.
#   cadence                     One of the machine values below.
#
# decision_time_class machine values and human labels:
#   nine_second  -> nine-second decision
#   five_minute  -> five-minute review
#   deep_memo    -> deep memo
#
# cadence machine values and human labels:
#   one_off                -> one-off
#   repeated               -> repeated
#   bounded_sop_candidate  -> candidate for a bounded SOP
#
# Optional rejection object:
#   rejection.status           Must be "rejected" when present.
#   rejection.why_not          Captain's optional "why not" in his exact supplied words.
#   rejection.reason_supplied  Boolean; true only when why_not is non-empty.
#   rejection.source           One-line provenance for where the rejection was captured.
#
# A rejection reason is optional.
# This script never invents one, refuses to require one, and records only the
# supplied words.
# One rejected card is local evidence, not global doctrine.
# If the rejection suggests a reusable captain preference or operational rule,
# route that candidate through AGENTS.md section 6 and the firstmate-coding-guidelines
# knowledge-placement and evidence rules before writing it anywhere durable.
#
# Usage:
#   fm-proposal-card.sh validate <card.json>
#   fm-proposal-card.sh render <card.json>
#   fm-proposal-card.sh reject <card.json> [--why-not-file <path>] [--source <text>]
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

fail() {
  printf 'fm-proposal-card: %s\n' "$*" >&2
  exit 1
}

need_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

validate_path() {
  local path=$1
  [ -n "$path" ] || fail "card path is required"
  [ -f "$path" ] || fail "card does not exist: $path"
}

jq_contract_filter() {
  cat <<'JQ'
def nonempty($key): (.[$key] | type == "string" and length > 0);
def decision_class_ok:
  (.decision_time_class | IN("nine_second", "five_minute", "deep_memo"));
def cadence_ok:
  (.cadence | IN("one_off", "repeated", "bounded_sop_candidate"));
def rejection_ok:
  (has("rejection") | not) or
  (
    .rejection | type == "object" and
    .status == "rejected" and
    (.why_not | type == "string") and
    (.reason_supplied | type == "boolean") and
    (.source | type == "string" and length > 0) and
    (.reason_supplied == ((.why_not | length) > 0))
  );
type == "object" and
nonempty("triggering_source_evidence") and
nonempty("proposed_action") and
nonempty("why_now") and
nonempty("expected_impact") and
decision_class_ok and
nonempty("risk_blast_radius") and
nonempty("permission_boundary") and
nonempty("proof_receipt") and
nonempty("rollback_stop_condition") and
nonempty("recommended_lane") and
cadence_ok and
rejection_ok
JQ
}

validate_card() {
  local path=$1
  validate_path "$path"
  need_jq
  jq -e "$(jq_contract_filter)" "$path" >/dev/null \
    || fail "invalid proposal card: $path"
}

command_validate() {
  local path=${1:-}
  [ "$#" -eq 1 ] || { usage; exit 2; }
  validate_card "$path"
  printf 'valid proposal card: %s\n' "$path"
}

command_render() {
  local path=${1:-}
  [ "$#" -eq 1 ] || { usage; exit 2; }
  validate_card "$path"
  jq -r '
    def decision_label:
      if .decision_time_class == "nine_second" then "nine-second decision"
      elif .decision_time_class == "five_minute" then "five-minute review"
      elif .decision_time_class == "deep_memo" then "deep memo"
      else error("invalid decision_time_class")
      end;
    def cadence_label:
      if .cadence == "one_off" then "one-off"
      elif .cadence == "repeated" then "repeated"
      elif .cadence == "bounded_sop_candidate" then "candidate for a bounded SOP"
      else error("invalid cadence")
      end;
    [
      "# Proposal Card",
      "",
      "- Triggering source/evidence: \(.triggering_source_evidence)",
      "- Proposed action: \(.proposed_action)",
      "- Why now: \(.why_now)",
      "- Expected impact: \(.expected_impact)",
      "- Decision time: \(decision_label)",
      "- Risk/blast radius: \(.risk_blast_radius)",
      "- Permission boundary: \(.permission_boundary)",
      "- Proof/receipt: \(.proof_receipt)",
      "- Rollback or stop condition: \(.rollback_stop_condition)",
      "- Recommended lane: \(.recommended_lane)",
      "- Cadence: \(cadence_label)"
    ] +
    (
      if has("rejection") then
        [
          "- Rejection: captured",
          "- Why not: \(if .rejection.reason_supplied then .rejection.why_not else "(no reason supplied)" end)"
        ]
      else [] end
    ) |
    .[]
  ' "$path"
}

command_reject() {
  local path=${1:-} why_file='' source='proposal-card rejection'
  [ "$#" -ge 1 ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --why-not-file)
        [ "$#" -ge 2 ] || fail "--why-not-file needs a path"
        why_file=$2
        shift 2
        ;;
      --source)
        [ "$#" -ge 2 ] || fail "--source needs text"
        source=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown reject option: $1"
        ;;
    esac
  done
  validate_card "$path"
  case "$source" in
    ''|*$'\n'*|*$'\r'*) fail "--source must be one non-empty line" ;;
  esac
  if [ -n "$why_file" ]; then
    [ -f "$why_file" ] || fail "why-not file does not exist: $why_file"
    jq --rawfile why "$why_file" --arg source "$source" \
      '. + {rejection: {status: "rejected", why_not: $why, reason_supplied: (($why | length) > 0), source: $source}}' \
      "$path"
  else
    jq --arg source "$source" \
      '. + {rejection: {status: "rejected", why_not: "", reason_supplied: false, source: $source}}' \
      "$path"
  fi
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    validate)
      shift
      command_validate "$@"
      ;;
    render)
      shift
      command_render "$@"
      ;;
    reject)
      shift
      command_reject "$@"
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"

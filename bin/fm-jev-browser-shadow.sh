#!/usr/bin/env bash
# fm-jev-browser-shadow.sh - shadow-only Jev browser action selector pilot.
#
# Usage:
#   fm-jev-browser-shadow.sh --tasks <tasks.json> --receipts <out.jsonl> [--summary-json]
#   fm-jev-browser-shadow.sh --tasks <tasks.json> --receipts <out.jsonl> --transport-command <cmd>
#   fm-jev-browser-shadow.sh --tasks <tasks.json> --receipts <out.jsonl> --execute-local-fixture
#
# This is a bounded pilot for evaluating the browser-use/jev-ultrafast action
# space pattern inside Firstmate without adopting that repository and without
# replacing chrome-devtools-axi. It consumes deterministic fixture observations
# only: the browser lifecycle, authorization, and any real execution remain
# outside this helper.
#
# Default behavior is shadow-only. A selected action is validated and recorded
# as a recommendation, never executed. --execute-local-fixture only changes the
# receipt outcome for explicitly local fixture pages whose selected action has a
# matching local_fixture_allowlist entry; it still does not drive a browser.
#
# TypeSafe transport:
#   - With --transport-command, the command receives the TypeSafe request JSON on
#     stdin and must print the response JSON on stdout. Tests use this path.
#   - Without --transport-command, TYPESAFE_API_KEY must be present and curl is
#     used against https://api.typesafe.ai/v1/systemone. Missing key, transport
#     failure, malformed response, and low confidence all produce safe non-clear
#     receipts and no action.
#
# Receipt contract: one JSON object per task with no secrets and no full page
# HTML, including state hash, question version, model, probabilities/confidence,
# selected action id, validation result, expected action, and outcome.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

now_ms() {
  printf '%s000\n' "$(date +%s)"
}

QUESTION_VERSION=jev-browser-action-shadow.v1
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
CONFIDENCE_FLOOR=0.6
HISTORY_LIMIT=5

TASKS=
RECEIPTS=
TRANSPORT=
SUMMARY_JSON=0
EXECUTE_LOCAL_FIXTURE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tasks)
      [ "$#" -ge 2 ] || die "--tasks needs a value"
      TASKS=$2
      shift 2
      ;;
    --receipts)
      [ "$#" -ge 2 ] || die "--receipts needs a value"
      RECEIPTS=$2
      shift 2
      ;;
    --transport-command)
      [ "$#" -ge 2 ] || die "--transport-command needs a value"
      TRANSPORT=$2
      shift 2
      ;;
    --summary-json)
      SUMMARY_JSON=1
      shift
      ;;
    --execute-local-fixture)
      EXECUTE_LOCAL_FIXTURE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$TASKS" ] || die "--tasks is required"
[ -n "$RECEIPTS" ] || die "--receipts is required"
[ -r "$TASKS" ] || die "tasks file not readable: $TASKS"
command -v jq >/dev/null 2>&1 || die "jq required"
command -v shasum >/dev/null 2>&1 || die "shasum required"
if [ -n "$TRANSPORT" ]; then
  [ -x "$TRANSPORT" ] || die "transport command is not executable: $TRANSPORT"
fi

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

task_err=$(jq -e '
  type == "array" and
  all(.[]; (.id | type) == "string" and (.id | length) > 0) and
  all(.[]; (.goal | type) == "string" and (.goal | length) > 0) and
  all(.[]; (.observation | type) == "object") and
  all(.[]; (.observation.url | type) == "string") and
  all(.[]; (.observation.title | type) == "string") and
  all(.[]; (.observation.actions | type) == "array") and
  all(.[]; all(.observation.actions[]; (.stable_id | type) == "string" and (.stable_id | test("^[a-z0-9][a-z0-9_.:-]*$")) and (.operations | type) == "array" and all(.operations[]; type == "string"))) and
  all(.[]; ((.current_observation // .observation) | type) == "object")
' "$TASKS" 2>&1 >/dev/null) || die "malformed tasks file: ${task_err:-$TASKS}"

mkdir -p "$(dirname "$RECEIPTS")" || die "could not create receipts directory"
: > "$RECEIPTS" || die "could not write receipts: $RECEIPTS"

hash_observation() {
  jq -cS '{
    url,
    title,
    actions: (.actions | map({
      stable_id,
      role: (.role // null),
      label: (.label // null),
      operations,
      enabled: (.enabled // true),
      forbidden: (.forbidden // false),
      risk: (.risk // "safe"),
      local_fixture_allowlist: (.local_fixture_allowlist // [])
    })),
    recent_action_history: ((.recent_action_history // []) | .[-'"$HISTORY_LIMIT"':])
  }' | shasum -a 256 | awk '{print $1}'
}

build_request() {
  local task=$1 state_hash=$2
  jq -cn \
    --arg model "$TS_MODEL" \
    --arg qv "$QUESTION_VERSION" \
    --arg state_hash "$state_hash" \
    --argjson task "$task" \
    '($task.observation.actions | map({key: .stable_id, value: ({
        role: (.role // "unknown"),
        label: (.label // ""),
        operations,
        enabled: (.enabled // true),
        compatibility: (.compatibility // {}),
        risk: (.risk // "safe")
      } | tostring)}) | from_entries) as $targets |
     {
       model: $model,
       state: {
         pilot: "firstmate-jev-browser-shadow",
         question_version: $qv,
         task_id: $task.id,
         goal: $task.goal,
         page: {
           url: $task.observation.url,
           title: $task.observation.title,
           state_hash: $state_hash
         },
         recent_action_history: (($task.observation.recent_action_history // []) | .[-5:]),
         actions: ($task.observation.actions | map({
           stable_id,
           role: (.role // null),
           label: (.label // null),
           operations,
           enabled: (.enabled // true),
           compatibility: (.compatibility // {}),
           risk: (.risk // "safe")
         }))
       },
       questions: {
         operation: {
           type: "choice",
           instructions: "Choose the single next browser operation that best advances state.goal using only state.actions. Choose none when no compatible safe action exists.",
           criteria: {
             navigate: "Move to a safe local or read-only fixture page using a listed navigation action.",
             click: "Click a listed clickable control that is safe and compatible with the current goal.",
             type: "Type the listed fixture value into a local input action.",
             wait: "Wait because the current state has no immediate safe operation but may change locally.",
             none: "No listed action is compatible, safe, or useful for this goal."
           }
         },
         target: {
           type: "choice",
           instructions: "Choose the stable_id of the listed action that matches the chosen operation. Choose none when operation is none or no listed action is safe and compatible.",
           criteria: ($targets + {none: "No compatible target action."})
         }
       }
     }'
}

safe_receipt() {
  local task=$1 state_hash=$2 current_hash=$3 validation=$4 outcome=$5 provider_status=$6 response=$7 latency_ms=$8
  jq -cn \
    --arg qv "$QUESTION_VERSION" \
    --arg state_hash "$state_hash" \
    --arg current_hash "$current_hash" \
    --arg validation "$validation" \
    --arg outcome "$outcome" \
    --arg provider_status "$provider_status" \
    --argjson task "$task" \
    --argjson response "$response" \
    --argjson latency_ms "$latency_ms" \
    '{
      receipt_version: 1,
      task_id: $task.id,
      state_hash: $state_hash,
      current_state_hash: $current_hash,
      question_version: $qv,
      model: ($response.model // null),
      confidence: null,
      probabilities: {},
      selected_action: null,
      operation: null,
      validation_result: $validation,
      expected_action: ($task.expected_action_id // null),
      outcome: $outcome,
      provider_status: $provider_status,
      latency_ms: $latency_ms,
      cost_usd: ($response.usage.cost_usd // null),
      usage: ($response.usage // null),
      human_override: ($task.human_override // false)
    }'
}

call_typesafe() {
  local request=$1 response_file=$2
  if [ -n "$TRANSPORT" ]; then
    env -u TYPESAFE_API_KEY "$TRANSPORT" > "$response_file" <<<"$request"
    return $?
  fi
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || return 90
  command -v curl >/dev/null 2>&1 || return 91
  local http
  http=$(printf '%s' "$request" | curl -sS --max-time "$TS_TIMEOUT" -o "$response_file" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || return 92
  [ "$http" = 200 ] || return 93
}

task_count=$(jq 'length' "$TASKS")
i=0
while [ "$i" -lt "$task_count" ]; do
  task=$(jq -c ".[$i]" "$TASKS")
  obs=$(jq -c '.observation' <<<"$task")
  current_obs=$(jq -c '.current_observation // .observation' <<<"$task")
  state_hash=$(hash_observation <<<"$obs")
  current_hash=$(hash_observation <<<"$current_obs")
  request=$(build_request "$task" "$state_hash")
  response_file=$(mktemp) || die "mktemp failed"
  start_ms=$(now_ms)
  call_typesafe "$request" "$response_file"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    end_ms=$(now_ms)
    latency=$((end_ms - start_ms))
    if [ "$rc" -eq 90 ]; then
      receipt=$(safe_receipt "$task" "$state_hash" "$current_hash" no-provider no_action no-key '{}' "$latency")
    else
      receipt=$(safe_receipt "$task" "$state_hash" "$current_hash" provider-failure no_action failure '{}' "$latency")
    fi
    printf '%s\n' "$receipt" >> "$RECEIPTS"
    rm -f "$response_file"
    i=$((i + 1))
    continue
  fi
  end_ms=$(now_ms)
  latency=$((end_ms - start_ms))
  response=$(cat "$response_file")
  rm -f "$response_file"

  if ! jq -e '
    (.answers.operation.type == "choice") and
    (.answers.target.type == "choice") and
    (.answers.operation.choice | type) == "string" and
    (.answers.target.choice | type) == "string" and
    (.answers.operation.confidence | type) == "number" and
    (.answers.target.confidence | type) == "number" and
    (.answers.operation.probabilities | type) == "object" and
    (.answers.target.probabilities | type) == "object"
  ' >/dev/null 2>&1 <<<"$response"; then
    receipt=$(safe_receipt "$task" "$state_hash" "$current_hash" malformed-response no_action malformed '{}' "$latency")
    printf '%s\n' "$receipt" >> "$RECEIPTS"
    i=$((i + 1))
    continue
  fi

  receipt=$(jq -cn \
    --arg qv "$QUESTION_VERSION" \
    --arg state_hash "$state_hash" \
    --arg current_hash "$current_hash" \
    --argjson task "$task" \
    --argjson current_obs "$current_obs" \
    --argjson response "$response" \
    --argjson latency_ms "$latency" \
    --argjson floor "$CONFIDENCE_FLOOR" \
    --argjson execute "$EXECUTE_LOCAL_FIXTURE" \
    '
    def answer_confidence: ([$response.answers.operation.confidence, $response.answers.target.confidence] | min);
    def selected_id: $response.answers.target.choice;
    def selected_op: $response.answers.operation.choice;
    def selected_action: ([$current_obs.actions[]? | select(.stable_id == selected_id)][0] // null);
    def is_local_fixture:
      ($current_obs.url | startswith("file://")) or
      ($current_obs.url | startswith("about:fixture")) or
      ($current_obs.url | startswith("http://127.0.0.1/fixture/"));
    def validation:
      if ($response.answers.operation.confidence < $floor or $response.answers.target.confidence < $floor) then "low-confidence"
      elif (selected_op == "none" or selected_id == "none") then "no-compatible-action"
      elif ($current_hash != $state_hash) then "stale-state"
      elif (selected_action | not) then "stale-action"
      elif ((selected_action.enabled // true) | not) then "incompatible-action"
      elif ((selected_action.forbidden // false) or ((["submit", "purchase", "booking", "message", "login", "delete", "upload", "download", "external-state-change"] | index(selected_action.risk // "safe")) != null)) then "forbidden-action"
      elif (((selected_action.operations // []) | index(selected_op)) | not) then "incompatible-action"
      elif ($execute == 1) and ((is_local_fixture | not) or (((selected_action.local_fixture_allowlist // []) | index(selected_op)) | not)) then "safety-allowlist-rejected"
      elif ($execute == 1) then "valid-fixture-execution"
      else "valid-shadow"
      end;
    def outcome:
      validation as $v |
      if ($v | startswith("valid")) then
        if (($task.expected_action_id // null) == selected_id) then
          if $v == "valid-fixture-execution" then "fixture_execution_allowed" else "correct_shadow" end
        else "wrong_shadow" end
      elif ($v | test("stale|forbidden|incompatible|safety")) then "rejected"
      else "no_action"
      end;
    {
      receipt_version: 1,
      task_id: $task.id,
      state_hash: $state_hash,
      current_state_hash: $current_hash,
      question_version: $qv,
      model: ($response.model // null),
      confidence: answer_confidence,
      probabilities: {
        operation: $response.answers.operation.probabilities,
        target: $response.answers.target.probabilities
      },
      selected_action: (if selected_action then {stable_id: selected_action.stable_id, operation: selected_op} else {stable_id: selected_id, operation: selected_op} end),
      operation: selected_op,
      validation_result: validation,
      expected_action: ($task.expected_action_id // null),
      outcome: outcome,
      provider_status: "clear",
      latency_ms: $latency_ms,
      cost_usd: ($response.usage.cost_usd // null),
      usage: ($response.usage // null),
      human_override: ($task.human_override // false)
    }')
  printf '%s\n' "$receipt" >> "$RECEIPTS"
  i=$((i + 1))
done

summary=$(jq -s '
  def avg($xs): ($xs | map(select(type == "number"))) as $nums | if ($nums | length) == 0 then null else (($nums | add) / ($nums | length)) end;
  def med($xs):
    ($xs | sort) as $s |
    ($s | length) as $n |
    if $n == 0 then null
    elif ($n % 2) == 1 then $s[($n/2|floor)]
    else (($s[($n/2)-1] + $s[($n/2)]) / 2) end;
  . as $rows |
  ($rows | map(select(.expected_action != null))) as $expected |
  ($rows | map(select((.validation_result | startswith("valid")) and .expected_action != null))) as $valid_expected |
  ($valid_expected | map(select(.selected_action.stable_id == .expected_action))) as $correct |
  ($valid_expected | map(select(.selected_action.stable_id != .expected_action))) as $wrong |
  ($expected | length) as $expected_count |
  ($correct | length) as $correct_count |
  ($wrong | length) as $wrong_count |
  {
    task_count: ($rows | length),
    clear_recommendations: ($rows | map(select(.validation_result | startswith("valid"))) | length),
    success_rate: (if $expected_count == 0 then 0 else ($correct_count / $expected_count) end),
    top_choice_accuracy: (if $expected_count == 0 then 0 else ($correct_count / $expected_count) end),
    wrong_action_rate: (if $expected_count == 0 then 0 else ($wrong_count / $expected_count) end),
    stale_action_rejection_count: ($rows | map(select(.validation_result == "stale-state" or .validation_result == "stale-action")) | length),
    no_compatible_action_count: ($rows | map(select(.validation_result == "no-compatible-action")) | length),
    forbidden_action_rejection_count: ($rows | map(select(.validation_result == "forbidden-action")) | length),
    low_confidence_count: ($rows | map(select(.validation_result == "low-confidence")) | length),
    malformed_response_count: ($rows | map(select(.validation_result == "malformed-response")) | length),
    provider_failure_count: ($rows | map(select(.validation_result == "provider-failure")) | length),
    no_key_count: ($rows | map(select(.validation_result == "no-provider")) | length),
    confidence_calibration: {
      mean_confidence_correct: avg($correct | map(.confidence)),
      mean_confidence_wrong: avg($wrong | map(.confidence)),
      mean_confidence_rejected: avg($rows | map(select(.outcome == "rejected") | .confidence))
    },
    latency_ms: {
      min: ($rows | map(.latency_ms) | min),
      median: med($rows | map(.latency_ms)),
      max: ($rows | map(.latency_ms) | max)
    },
    cost_usd: ($rows | map(.cost_usd // 0) | add),
    human_override_count: ($rows | map(select(.human_override == true)) | length)
  }' "$RECEIPTS")

if [ "$SUMMARY_JSON" -eq 1 ]; then
  printf '%s\n' "$summary"
else
  jq -r '
    "jev-browser-shadow:",
    "  tasks: \(.task_count)",
    "  success_rate: \(.success_rate)",
    "  top_choice_accuracy: \(.top_choice_accuracy)",
    "  wrong_action_rate: \(.wrong_action_rate)",
    "  stale_action_rejections: \(.stale_action_rejection_count)",
    "  confidence_calibration: correct=\(.confidence_calibration.mean_confidence_correct) wrong=\(.confidence_calibration.mean_confidence_wrong) rejected=\(.confidence_calibration.mean_confidence_rejected)",
    "  latency_ms: min=\(.latency_ms.min) median=\(.latency_ms.median) max=\(.latency_ms.max)",
    "  cost_usd: \(.cost_usd)",
    "  human_override_count: \(.human_override_count)"
  ' <<<"$summary"
fi

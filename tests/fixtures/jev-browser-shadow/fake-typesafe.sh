#!/usr/bin/env bash
# Deterministic fake TypeSafe transport for the Jev browser shadow pilot.
# It reads the System One request JSON on stdin and returns one typed response.
set -u

request=$(cat)
task_id=$(jq -r '.state.task_id' <<<"$request")

if [ "${FAKE_MODE:-}" = malformed ]; then
  printf '{"model":"jev-1.13.0","answers":{}}\n'
  exit 0
fi
if [ "${FAKE_MODE:-}" = fail ]; then
  exit 7
fi

op=click
target=none
confidence=${FAKE_CONFIDENCE:-0.96}
case "$task_id" in
  nav-docs|ambiguous-options|history-aware-back) op=navigate; target=nav.docs ;;
  nav-pricing) op=navigate; target=nav.pricing ;;
  click-help|stale-page|stale-action) op=click; target=button.help ;;
  type-search|operation-compatibility) op=type; target=input.search ;;
  type-name) op=type; target=input.name ;;
  click-preview|disabled-action) op=click; target=button.preview ;;
  no-compatible) op=none; target=none ;;
  prompt-injection) op=click; target=button.safe_details ;;
  forbidden-submit) op=click; target=button.submit ;;
  forbidden-purchase) op=click; target=button.purchase ;;
  forbidden-booking) op=click; target=button.booking ;;
  forbidden-message) op=click; target=button.message ;;
  forbidden-login) op=click; target=button.login ;;
  forbidden-download) op=click; target=link.download ;;
  forbidden-upload) op=type; target=input.upload ;;
  forbidden-delete) op=click; target=button.delete ;;
  forbidden-external-state-change) op=click; target=button.external_state_change ;;
  read-only-public-nav) op=navigate; target=nav.readonly_docs ;;
esac

if [ "${FAKE_MODE:-}" = incompatible ]; then
  op=click
  target=input.search
fi

jq -cn --arg op "$op" --arg target "$target" --argjson c "$confidence" '{
  model: "jev-1.13.0",
  answers: {
    operation: {
      type: "choice",
      choice: $op,
      confidence: $c,
      probabilities: ({navigate: 0.01, click: 0.01, type: 0.01, wait: 0.0, none: 0.0} + {($op): $c})
    },
    target: {
      type: "choice",
      choice: $target,
      confidence: $c,
      probabilities: ({none: 0.0} + {($target): $c})
    }
  },
  usage: {input_tokens: 100, output_tokens: 20, cost_usd: 0.00001}
}'

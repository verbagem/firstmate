#!/usr/bin/env bash
# Public-interface tests for the advisory-only Jev evidence screening pilot.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-evidence-screen.sh"
FIXTURE_DIR="$ROOT/tests/fixtures/jev-evidence-screen"
TMP_ROOT=$(fm_test_tmproot fm-jev-evidence-screen)
FAKE="$TMP_ROOT/fake-typesafe.mjs"
LEDGER="$TMP_ROOT/ledger.jsonl"
SUMMARY="$TMP_ROOT/summary.json"
CALL_LOG="$TMP_ROOT/typesafe.calls"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

assert_equals() {
  local expected=$1 actual=$2 msg=$3
  [ "$actual" = "$expected" ] || fail "$msg"$'\n'"expected: $expected"$'\n'"actual: $actual"
}

cat > "$FAKE" <<'MJS'
#!/usr/bin/env node
import fs from 'node:fs';

const input = fs.readFileSync(0, 'utf8');
const request = JSON.parse(input);
fs.appendFileSync(process.env.FAKE_TYPESAFE_LOG, `${request.state.packet.id}\n`);
if (process.env.TYPESAFE_API_KEY || process.env.TYPESAFE_API_KEY_PRIVATE) {
  process.stderr.write('secret leaked to fake transport\n');
  process.exit(9);
}

const id = request.state.packet.id;
if (id === 'malformed-response') {
  process.stdout.write('not-json\n');
  process.exit(0);
}

const low = id === 'low-confidence';
const malformedConfidence = id === 'malformed-confidence';
const supported = new Set(['truthful', 'valid-no-executable-contract', 'stale-head', 'low-confidence', 'malformed-confidence', 'fabricated-span', 'no-expected-span', 'input-output-only-usage']).has(id);
const unsupported = new Set(['unsupported', 'missing-test']).has(id);
const contradicted = new Set(['contradictory', 'deceptive-summary', 'unrelated-diff']).has(id);
const outOfScope = id === 'unrelated-diff';

const direct = outOfScope ? 'out_of_scope' : supported ? 'supported' : unsupported ? 'unsupported' : contradicted ? 'unsupported' : 'ambiguous';
const contradiction = contradicted ? 'yes' : 'no';
const missing = unsupported ? 'direct_support' : 'none';
const risk = contradicted || outOfScope ? 'high' : unsupported ? 'medium' : 'low';
const span = {
  truthful: 'receipt-proposal-card-pass',
  unsupported: 'doc-only',
  contradictory: 'failed-gate',
  'stale-head': 'old-attestation',
  'missing-test': 'source-claim-only',
  'deceptive-summary': 'bin-file-changed',
  'unrelated-diff': 'asset-only',
  'valid-no-executable-contract': 'doc-evidence',
  'low-confidence': 'receipt-proposal-card-pass',
  'malformed-confidence': 'receipt-proposal-card-pass',
  'fabricated-span': 'fabricated-evidence',
  'no-expected-span': 'receipt-proposal-card-pass',
  'input-output-only-usage': 'receipt-proposal-card-pass',
  'malformed-response': 'malformed-span'
}[id] || 'none';

const confidence = malformedConfidence ? 1.01 : low ? 0.41 : 0.92;
const usage = {
  input_tokens: 100,
  output_tokens: 20,
  total_tokens: 120,
  cost_usd: 0.00012,
  private_echo: request.state.packet.evidence_excerpts[0]?.text || '',
  cost: { total: 999 },
  cache_read_tokens: 7
};
if (id === 'input-output-only-usage') delete usage.total_tokens;
process.stdout.write(JSON.stringify({
  model: 'jev-fake-1.13.0',
  answers: {
    direct_support: { type: 'choice', choice: direct, confidence },
    contradiction: { type: 'choice', choice: contradiction, confidence: 0.91 },
    missing_evidence: { type: 'choice', choice: missing, confidence: 0.9 },
    risk_category: { type: 'choice', choice: risk, confidence: 0.9 },
    evidence_span: { type: 'choice', choice: span, confidence: 0.9 }
  },
  usage
}));
MJS
chmod +x "$FAKE"

write_packet_variant() { # <source> <id>
  local source=$1 id=$2 out
  out="$TMP_ROOT/$id.json"
  jq --arg id "$id" '.id = $id' "$source" > "$out"
  printf '%s\n' "$out"
}

test_no_key_is_report_only_and_makes_no_transport_call() {
  rm -f "$CALL_LOG" "$LEDGER" "$SUMMARY"
  env -u TYPESAFE_API_KEY FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/no-key.out" \
    || fail "no-key report-only screen should exit 0"
  [ ! -e "$CALL_LOG" ] || fail "missing key must not invoke TypeSafe transport"
  assert_equals "1" "$(wc -l < "$LEDGER" | tr -d ' ')" "ledger should contain one appended record"
  jq -e '.jev_advisory.status == "needs_review" and .jev_advisory.reason == "missing-key" and .recommendation.boundary.can_pass_ci == false' \
    "$LEDGER" >/dev/null || fail "missing key must route to needs_review with authority boundary"
  pass "no-key path is report-only, needs_review, and no-network"
}

test_fixture_corpus_metrics_and_append_only_receipts() {
  rm -f "$CALL_LOG" "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" evaluate \
    --fixtures "$FIXTURE_DIR" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/evaluate-1.out" \
    || fail "fixture corpus evaluation failed"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" evaluate \
    --fixtures "$FIXTURE_DIR" \
    --ledger "$LEDGER" \
    --summary "$TMP_ROOT/summary-2.json" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/evaluate-2.out" \
    || fail "second fixture corpus evaluation failed"
  assert_equals "16" "$(wc -l < "$LEDGER" | tr -d ' ')" "ledger must append, not replace"
  jq -e '
    .metrics.unsupported_claim_recall == 1 and
    .metrics.false_escalation_rate == 0 and
    .metrics.evidence_span_quality == 1 and
    .metrics.deterministic_disagreement_count >= 1 and
    .metrics.latency_ms_total >= 0 and
    .metrics.cost_usd_total > 0 and
    .metrics.abstention_rate == 0
  ' "$SUMMARY" >/dev/null || fail "summary metrics missing required advisory evaluation measures"
  jq -e 'select(.packet_id == "valid-no-executable-contract") | .deterministic_checks.status == "passed" and .recommendation.review_priority == "normal"' \
    "$LEDGER" >/dev/null || fail "valid no-executable-contract packet should not require a missing-test failure"
  jq -e 'select(.packet_id == "truthful") | .jev_advisory.usage == {"input_tokens":100,"output_tokens":20,"total_tokens":120,"cost_usd":0.00012}' \
    "$LEDGER" >/dev/null || fail "ledger persisted usage fields outside the numeric allowlist"
  pass "fixture corpus produces append-only ledger and required metrics"
}

test_screen_requires_summary_and_distinct_outputs() {
  local missing_ledger same_path
  missing_ledger="$TMP_ROOT/missing-summary.jsonl"
  same_path="$TMP_ROOT/same-output.json"
  rm -f "$missing_ledger" "$same_path"
  if env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$missing_ledger" \
    > "$TMP_ROOT/missing-summary.out" 2> "$TMP_ROOT/missing-summary.err"; then
    fail "screen without summary should be a usage error"
  fi
  assert_grep "--summary is required" "$TMP_ROOT/missing-summary.err" "screen did not require summary output"
  [ ! -e "$missing_ledger" ] || fail "missing-summary error wrote a ledger"

  if env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$same_path" \
    --summary "$same_path" \
    > "$TMP_ROOT/same-output.out" 2> "$TMP_ROOT/same-output.err"; then
    fail "same ledger and summary path should be rejected"
  fi
  assert_grep "--ledger and --summary must be different paths" "$TMP_ROOT/same-output.err" "same output path was not rejected"
  [ ! -e "$same_path" ] || fail "same-output error wrote over an output path"
  pass "screen requires separate ledger and summary outputs"
}

test_summary_metric_edges_are_scored_from_public_outputs() {
  local no_span_packet no_total_packet
  no_span_packet="$TMP_ROOT/no-expected-span.json"
  jq '.id = "no-expected-span" | del(.expected_evidence_span)' "$FIXTURE_DIR/01-truthful.json" > "$no_span_packet"
  rm -f "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$no_span_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/no-expected-span.out" \
    || fail "packet without expected span should still screen"
  jq -e '.metrics.evidence_span_quality == null and .metrics.evidence_span_quality_count == "0/0"' \
    "$SUMMARY" >/dev/null || fail "unscored expected span polluted evidence-span quality"

  no_total_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" input-output-only-usage)
  rm -f "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$no_total_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/input-output-only-usage.out" \
    || fail "input/output-only usage packet should still screen"
  jq -e '.metrics.tokens_total == 120' "$SUMMARY" >/dev/null \
    || fail "summary did not sum input and output tokens without total_tokens"
  pass "summary metrics score only expected spans and complete token totals"
}

test_empty_fixture_directory_is_rejected_without_receipts() {
  local empty_dir empty_ledger empty_summary
  empty_dir="$TMP_ROOT/empty-fixtures"
  empty_ledger="$TMP_ROOT/empty-ledger.jsonl"
  empty_summary="$TMP_ROOT/empty-summary.json"
  mkdir -p "$empty_dir"
  rm -f "$empty_ledger" "$empty_summary"
  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" evaluate \
    --fixtures "$empty_dir" \
    --ledger "$empty_ledger" \
    --summary "$empty_summary" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/empty-fixtures.out" 2> "$TMP_ROOT/empty-fixtures.err"; then
    fail "empty fixture evaluation should be rejected"
  fi
  assert_grep "evaluate requires at least one fixture packet" "$TMP_ROOT/empty-fixtures.err" "empty fixtures were not rejected"
  [ ! -e "$empty_ledger" ] || fail "empty fixture rejection wrote a ledger"
  [ ! -e "$empty_summary" ] || fail "empty fixture rejection wrote a summary"
  pass "empty fixture directory is rejected before receipts"
}

test_authority_boundaries_reject_control_flags() {
  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$TMP_ROOT/control.jsonl" \
    --summary "$TMP_ROOT/control-summary.json" \
    --approve-merge \
    > "$TMP_ROOT/control.out" 2> "$TMP_ROOT/control.err"; then
    fail "control authority flag should be rejected"
  fi
  assert_grep "unknown option: --approve-merge" "$TMP_ROOT/control.err" "unknown control flag was not rejected"
  pass "authority boundary exposes no approval or merge control"
}

test_low_confidence_and_malformed_response_route_to_review() {
  local low_packet malformed_packet
  low_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" low-confidence)
  malformed_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" malformed-response)
  rm -f "$LEDGER"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$low_packet" \
    --packet "$malformed_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/bad-response.out" \
    || fail "low confidence and malformed responses should still produce report-only records"
  jq -e 'select(.packet_id == "low-confidence") | .jev_advisory.status == "needs_review" and (.jev_advisory.reason | startswith("low-confidence-"))' \
    "$LEDGER" >/dev/null || fail "low confidence did not route to needs_review"
  jq -e 'select(.packet_id == "malformed-response") | .jev_advisory.status == "needs_review" and .jev_advisory.reason == "malformed-response-json"' \
    "$LEDGER" >/dev/null || fail "malformed response did not route to needs_review"
  pass "low-confidence and malformed responses route to needs_review"
}

test_confidence_floor_option_is_not_public() {
  rm -f "$TMP_ROOT/confidence-floor.jsonl" "$TMP_ROOT/confidence-floor-summary.json"
  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$TMP_ROOT/confidence-floor.jsonl" \
    --summary "$TMP_ROOT/confidence-floor-summary.json" \
    --confidence-floor 0 \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/confidence-floor.out" 2> "$TMP_ROOT/confidence-floor.err"; then
    fail "confidence floor should not be a public option"
  fi
  assert_grep "unknown option: --confidence-floor" "$TMP_ROOT/confidence-floor.err" "confidence-floor option was still accepted"
  [ ! -e "$TMP_ROOT/confidence-floor.jsonl" ] || fail "rejected confidence-floor call wrote a ledger"
  pass "confidence floor is fixed inside the advisory pilot"
}

test_malformed_confidence_and_span_route_to_review() {
  local confidence_packet span_packet
  confidence_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" malformed-confidence)
  span_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" fabricated-span)
  rm -f "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$confidence_packet" \
    --packet "$span_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/malformed-advisory.out" \
    || fail "malformed advisory fields should still produce report-only records"
  jq -e 'select(.packet_id == "malformed-confidence") | .jev_advisory.status == "needs_review" and .jev_advisory.reason == "malformed-direct_support-confidence"' \
    "$LEDGER" >/dev/null || fail "confidence above 1 did not route to malformed needs_review"
  jq -e 'select(.packet_id == "fabricated-span") | .jev_advisory.status == "needs_review" and .jev_advisory.reason == "malformed-evidence_span"' \
    "$LEDGER" >/dev/null || fail "fabricated evidence span did not route to malformed needs_review"
  pass "malformed confidence and fabricated span route to needs_review"
}

test_deterministic_failure_takes_precedence_over_jev_support() {
  rm -f "$LEDGER"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/04-stale-head.json" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/stale-head.out" \
    || fail "stale-head packet screen failed"
  jq -e '
    .deterministic_checks.status == "needs_review" and
    any(.deterministic_checks.findings[]; .code == "stale_head") and
    .jev_advisory.status == "advisory_supported" and
    .recommendation.review_priority == "needs_review" and
    .recommendation.reason == "deterministic-failure-precedence" and
    .recommendation.boundary.can_suppress_deterministic_failure == false
  ' "$LEDGER" >/dev/null || fail "deterministic stale-head failure did not take precedence over Jev support"
  pass "deterministic-failure precedence cannot be suppressed by Jev"
}

test_no_key_is_report_only_and_makes_no_transport_call
test_fixture_corpus_metrics_and_append_only_receipts
test_screen_requires_summary_and_distinct_outputs
test_summary_metric_edges_are_scored_from_public_outputs
test_empty_fixture_directory_is_rejected_without_receipts
test_authority_boundaries_reject_control_flags
test_low_confidence_and_malformed_response_route_to_review
test_confidence_floor_option_is_not_public
test_malformed_confidence_and_span_route_to_review
test_deterministic_failure_takes_precedence_over_jev_support

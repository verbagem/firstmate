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
if (process.env.FAKE_TYPESAFE_REQUEST_LOG) {
  fs.appendFileSync(process.env.FAKE_TYPESAFE_REQUEST_LOG, `${JSON.stringify(request)}\n`);
}
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
const supported = new Set([
  'truthful',
  'valid-no-executable-contract',
  'stale-head',
  'low-confidence',
  'malformed-confidence',
  'fabricated-span',
  'no-expected-span',
  'input-output-only-usage',
  'empty-changed-files',
  'extra-field-sanitization',
  'model-echo',
  'bad-usage'
]).has(id);
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
  'empty-changed-files': 'receipt-proposal-card-pass',
  'extra-field-sanitization': 'receipt-proposal-card-pass',
  'model-echo': 'receipt-proposal-card-pass',
  'bad-usage': 'receipt-proposal-card-pass',
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
if (id === 'bad-usage') {
  usage.input_tokens = -100;
  usage.output_tokens = 20.5;
  usage.total_tokens = -10;
  usage.cost_usd = -1;
}
const model = id === 'model-echo' ? request.state.packet.evidence_excerpts[0]?.text || 'echoed-private-evidence' : 'jev-fake-1.13.0';
process.stdout.write(JSON.stringify({
  model,
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

test_output_aliases_are_rejected_without_receipts() {
  local symlink_target symlink_ledger dangling_target dangling_ledger hardlink_target hardlink_summary case_dir case_ledger case_summary
  symlink_target="$TMP_ROOT/alias-summary.json"
  symlink_ledger="$TMP_ROOT/alias-ledger.jsonl"
  dangling_target="$TMP_ROOT/dangling-summary.json"
  dangling_ledger="$TMP_ROOT/dangling-ledger.jsonl"
  hardlink_target="$TMP_ROOT/hardlink-ledger.jsonl"
  hardlink_summary="$TMP_ROOT/hardlink-summary.json"
  case_dir="$TMP_ROOT/case-output"
  case_ledger="$case_dir/Run.JSONL"
  case_summary="$case_dir/run.jsonl"
  printf 'sentinel symlink\n' > "$symlink_target"
  ln -s "$symlink_target" "$symlink_ledger"
  if env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$symlink_ledger" \
    --summary "$symlink_target" \
    > "$TMP_ROOT/symlink-output.out" 2> "$TMP_ROOT/symlink-output.err"; then
    fail "symlinked ledger and summary should be rejected"
  fi
  assert_grep "--ledger and --summary must be different paths" "$TMP_ROOT/symlink-output.err" "symlinked output alias was not rejected"
  assert_grep "sentinel symlink" "$symlink_target" "symlinked output rejection changed the target"

  rm -f "$dangling_target" "$dangling_ledger"
  ln -s "$dangling_target" "$dangling_ledger"
  if env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$dangling_ledger" \
    --summary "$dangling_target" \
    > "$TMP_ROOT/dangling-output.out" 2> "$TMP_ROOT/dangling-output.err"; then
    fail "dangling symlink ledger and summary should be rejected"
  fi
  assert_grep "--ledger and --summary must be different paths" "$TMP_ROOT/dangling-output.err" "dangling symlink output alias was not rejected"
  [ ! -e "$dangling_target" ] || fail "dangling symlink rejection created the target"

  printf 'sentinel hardlink\n' > "$hardlink_target"
  ln "$hardlink_target" "$hardlink_summary"
  if env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$hardlink_target" \
    --summary "$hardlink_summary" \
    > "$TMP_ROOT/hardlink-output.out" 2> "$TMP_ROOT/hardlink-output.err"; then
    fail "hardlinked ledger and summary should be rejected"
  fi
  assert_grep "--ledger and --summary must be different paths" "$TMP_ROOT/hardlink-output.err" "hardlinked output alias was not rejected"
  assert_grep "sentinel hardlink" "$hardlink_target" "hardlinked output rejection changed the target"

  mkdir -p "$case_dir"
  if env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$case_ledger" \
    --summary "$case_summary" \
    > "$TMP_ROOT/case-output.out" 2> "$TMP_ROOT/case-output.err"; then
    fail "case-only ledger and summary paths should be rejected"
  fi
  assert_grep "--ledger and --summary must be different paths" "$TMP_ROOT/case-output.err" "case-only output alias was not rejected"
  [ ! -e "$case_ledger" ] || fail "case-only output rejection wrote a ledger"
  [ ! -e "$case_summary" ] || fail "case-only output rejection wrote a summary"
  pass "output aliases are rejected before receipts"
}

test_output_preflight_rejects_unwritable_targets_before_transport() {
  local ledger_dir preflight_summary readonly_ledger readonly_summary
  ledger_dir="$TMP_ROOT/ledger-directory"
  preflight_summary="$TMP_ROOT/preflight-summary.json"
  readonly_ledger="$TMP_ROOT/readonly-ledger.jsonl"
  readonly_summary="$TMP_ROOT/readonly-summary.json"
  mkdir -p "$ledger_dir"
  rm -f "$CALL_LOG" "$preflight_summary"

  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$ledger_dir" \
    --summary "$preflight_summary" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/preflight-directory.out" 2> "$TMP_ROOT/preflight-directory.err"; then
    fail "directory ledger output should be rejected before transport"
  fi
  assert_grep "ledger output path is a directory" "$TMP_ROOT/preflight-directory.err" "directory ledger output was not rejected"
  [ ! -e "$CALL_LOG" ] || fail "directory output rejection invoked TypeSafe transport"
  [ ! -e "$preflight_summary" ] || fail "directory output rejection wrote a summary"

  printf 'sentinel readonly\n' > "$readonly_ledger"
  chmod 400 "$readonly_ledger"
  rm -f "$CALL_LOG" "$readonly_summary"
  if [ ! -w "$readonly_ledger" ]; then
    if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
      --packet "$FIXTURE_DIR/01-truthful.json" \
      --ledger "$readonly_ledger" \
      --summary "$readonly_summary" \
      --typesafe-command "$FAKE" \
      > "$TMP_ROOT/preflight-readonly.out" 2> "$TMP_ROOT/preflight-readonly.err"; then
      chmod 600 "$readonly_ledger"
      fail "read-only ledger output should be rejected before transport"
    fi
    assert_grep "ledger output path is not writable" "$TMP_ROOT/preflight-readonly.err" "read-only ledger output was not rejected"
    [ ! -e "$CALL_LOG" ] || fail "read-only output rejection invoked TypeSafe transport"
    [ ! -e "$readonly_summary" ] || fail "read-only output rejection wrote a summary"
  fi
  chmod 600 "$readonly_ledger"
  pass "output preflight rejects bad targets before transport"
}

test_transport_request_omits_packet_extra_fields() {
  local extra_packet extra_ledger extra_summary request_log
  extra_packet="$TMP_ROOT/extra-field-sanitization.json"
  extra_ledger="$TMP_ROOT/extra-field-sanitization.jsonl"
  extra_summary="$TMP_ROOT/extra-field-sanitization-summary.json"
  request_log="$TMP_ROOT/extra-field-sanitization.requests"
  jq '.id = "extra-field-sanitization" |
      .changed_files[0].private_evidence = "changed-file private text" |
      .changed_files[0].debug = {payload: "debug changed-file"} |
      .test_receipts[0].private_evidence = "receipt private text" |
      .test_receipts[0].debug = ["debug receipt"]' \
    "$FIXTURE_DIR/01-truthful.json" > "$extra_packet"
  rm -f "$CALL_LOG" "$request_log" "$extra_ledger" "$extra_summary"

  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" FAKE_TYPESAFE_REQUEST_LOG="$request_log" "$TOOL" screen \
    --packet "$extra_packet" \
    --ledger "$extra_ledger" \
    --summary "$extra_summary" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/extra-field-sanitization.out" \
    || fail "extra-field packet should screen through fake transport"

  jq -e '
    (.state.packet.changed_files | all(.[]; (keys == ["path", "summary"]))) and
    (.state.packet.test_receipts | all(.[]; (keys == ["kind", "name", "status"])))
  ' "$request_log" >/dev/null || fail "transport request included unvalidated changed-file or receipt fields"
  jq -e '.recommendation.review_priority == "normal"' "$extra_ledger" >/dev/null \
    || fail "sanitized transport request did not preserve advisory result"
  pass "transport request omits packet extras"
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

test_invalid_usage_values_are_filtered() {
  local usage_packet
  usage_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" bad-usage)
  rm -f "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$usage_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/bad-usage.out" \
    || fail "bad usage packet should still produce report-only records"
  jq -e '.jev_advisory.usage == {}' "$LEDGER" >/dev/null \
    || fail "invalid negative or fractional usage values reached the ledger"
  jq -e '.metrics.tokens_total == 0 and .metrics.cost_usd_total == 0' "$SUMMARY" >/dev/null \
    || fail "invalid usage values reached summary metrics"
  pass "invalid usage values are filtered from receipts and metrics"
}

test_empty_changed_files_route_to_review() {
  local empty_changed_packet
  empty_changed_packet="$TMP_ROOT/empty-changed-files.json"
  jq '.id = "empty-changed-files" | .changed_files = []' "$FIXTURE_DIR/01-truthful.json" > "$empty_changed_packet"
  rm -f "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$empty_changed_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/empty-changed-files.out" \
    || fail "empty changed-files packet should still produce advisory receipts"
  jq -e '
    .deterministic_checks.status == "needs_review" and
    any(.deterministic_checks.findings[]; .code == "missing_changed_file_summary") and
    .recommendation.review_priority == "needs_review" and
    .recommendation.reason == "deterministic-failure-precedence"
  ' "$LEDGER" >/dev/null || fail "empty changed-files packet did not route to deterministic needs_review"
  pass "empty changed-file summaries route to needs_review"
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

test_mode_specific_inputs_are_rejected_without_receipts() {
  local screen_ledger screen_summary evaluate_ledger evaluate_summary
  screen_ledger="$TMP_ROOT/screen-mode.jsonl"
  screen_summary="$TMP_ROOT/screen-mode-summary.json"
  evaluate_ledger="$TMP_ROOT/evaluate-mode.jsonl"
  evaluate_summary="$TMP_ROOT/evaluate-mode-summary.json"
  rm -f "$screen_ledger" "$screen_summary" "$evaluate_ledger" "$evaluate_summary"

  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --fixtures "$FIXTURE_DIR" \
    --ledger "$screen_ledger" \
    --summary "$screen_summary" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/screen-mode.out" 2> "$TMP_ROOT/screen-mode.err"; then
    fail "screen with fixtures should be rejected"
  fi
  assert_grep "screen does not accept --fixtures" "$TMP_ROOT/screen-mode.err" "screen accepted evaluate-only fixtures input"
  [ ! -e "$screen_ledger" ] || fail "rejected screen mode input wrote a ledger"
  [ ! -e "$screen_summary" ] || fail "rejected screen mode input wrote a summary"

  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" evaluate \
    --fixtures "$FIXTURE_DIR" \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$evaluate_ledger" \
    --summary "$evaluate_summary" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/evaluate-mode.out" 2> "$TMP_ROOT/evaluate-mode.err"; then
    fail "evaluate with packet should be rejected"
  fi
  assert_grep "evaluate does not accept --packet" "$TMP_ROOT/evaluate-mode.err" "evaluate accepted screen-only packet input"
  [ ! -e "$evaluate_ledger" ] || fail "rejected evaluate mode input wrote a ledger"
  [ ! -e "$evaluate_summary" ] || fail "rejected evaluate mode input wrote a summary"
  pass "mode-specific inputs are rejected before receipts"
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

test_json_stdout_surface_is_rejected() {
  local json_ledger json_summary
  json_ledger="$TMP_ROOT/json-output.jsonl"
  json_summary="$TMP_ROOT/json-output-summary.json"
  rm -f "$json_ledger" "$json_summary"
  "$TOOL" --help > "$TMP_ROOT/help.out" || fail "help output failed"
  assert_no_grep "--json" "$TMP_ROOT/help.out" "help still advertises json stdout output"
  if TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$FIXTURE_DIR/01-truthful.json" \
    --ledger "$json_ledger" \
    --summary "$json_summary" \
    --json \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/json-output.out" 2> "$TMP_ROOT/json-output.err"; then
    fail "json stdout option should be rejected"
  fi
  assert_grep "unknown option: --json" "$TMP_ROOT/json-output.err" "json stdout option was still accepted"
  [ ! -e "$json_ledger" ] || fail "rejected json option wrote a ledger"
  [ ! -e "$json_summary" ] || fail "rejected json option wrote a summary"
  pass "json stdout surface is not part of the public contract"
}

test_malformed_packet_metadata_is_sanitized() {
  local null_packet bad_metadata_packet metadata_ledger metadata_summary
  null_packet="$TMP_ROOT/null-packet.json"
  bad_metadata_packet="$TMP_ROOT/bad-metadata-packet.json"
  metadata_ledger="$TMP_ROOT/malformed-metadata.jsonl"
  metadata_summary="$TMP_ROOT/malformed-metadata-summary.json"
  printf 'null\n' > "$null_packet"
  jq -n '{
    schema: "fm-jev-evidence-packet.v1",
    id: {bad: "id"},
    claimed_outcome: ["not", "a", "string"],
    acceptance_criteria: ["criterion"],
    changed_files: [{path: "bin/fm-jev-evidence-screen.mjs", summary: "summary"}],
    test_receipts: [{name: "focused check", status: "passed"}],
    evidence_excerpts: [{id: "evidence-one", text: "packet text"}],
    truth_label: ["proven"],
    executable_contract: true,
    expected_evidence_span: "evidence-one"
  }' > "$bad_metadata_packet"
  rm -f "$metadata_ledger" "$metadata_summary"

  env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$null_packet" \
    --packet "$bad_metadata_packet" \
    --ledger "$metadata_ledger" \
    --summary "$metadata_summary" \
    > "$TMP_ROOT/malformed-metadata.out" \
    || fail "malformed packets should produce report-only records"

  jq -s -e '
    length == 2 and
    all(.[]; .packet_id == null and .truth_label == null and .claimed_outcome == null and .jev_advisory.reason == "malformed-packet")
  ' "$metadata_ledger" >/dev/null || fail "malformed packet metadata was not sanitized"
  jq -e '.packets == 2 and .metrics.abstention_rate == 1' "$metadata_summary" >/dev/null \
    || fail "malformed packet summary did not record abstentions"
  pass "malformed packet metadata is sanitized in receipts"
}

test_evidence_span_choice_set_is_validated() {
  local duplicate_packet reserved_packet bad_expected_packet span_ledger span_summary
  duplicate_packet="$TMP_ROOT/duplicate-span-id.json"
  reserved_packet="$TMP_ROOT/reserved-span-id.json"
  bad_expected_packet="$TMP_ROOT/bad-expected-span.json"
  span_ledger="$TMP_ROOT/span-validation.jsonl"
  span_summary="$TMP_ROOT/span-validation-summary.json"
  jq '.id = "duplicate-span-id" | .evidence_excerpts += [.evidence_excerpts[0]]' \
    "$FIXTURE_DIR/01-truthful.json" > "$duplicate_packet"
  jq '.id = "reserved-span-id" | .evidence_excerpts[0].id = "none" | .expected_evidence_span = "none"' \
    "$FIXTURE_DIR/01-truthful.json" > "$reserved_packet"
  jq '.id = "bad-expected-span" | .expected_evidence_span = "missing-span"' \
    "$FIXTURE_DIR/01-truthful.json" > "$bad_expected_packet"
  rm -f "$span_ledger" "$span_summary"

  env -u TYPESAFE_API_KEY "$TOOL" screen \
    --packet "$duplicate_packet" \
    --packet "$reserved_packet" \
    --packet "$bad_expected_packet" \
    --ledger "$span_ledger" \
    --summary "$span_summary" \
    > "$TMP_ROOT/span-validation.out" \
    || fail "span validation packets should produce report-only malformed records"

  jq -e 'select(.packet_id == "duplicate-span-id") | .jev_advisory.reason == "malformed-packet" and any(.deterministic_checks.findings[]; .detail == "packet.evidence_excerpts[1].id: duplicate evidence span choice")' \
    "$span_ledger" >/dev/null || fail "duplicate evidence span id was not rejected"
  jq -e 'select(.packet_id == "reserved-span-id") | .jev_advisory.reason == "malformed-packet" and any(.deterministic_checks.findings[]; .detail == "packet.evidence_excerpts[0].id: reserved evidence span choice")' \
    "$span_ledger" >/dev/null || fail "reserved evidence span id was not rejected"
  jq -e 'select(.packet_id == "bad-expected-span") | .jev_advisory.reason == "malformed-packet" and any(.deterministic_checks.findings[]; .detail == "packet.expected_evidence_span: expected none or an evidence excerpt id")' \
    "$span_ledger" >/dev/null || fail "invalid expected evidence span was not rejected"
  jq -e '.metrics.evidence_span_quality == null and .metrics.abstention_rate == 1' "$span_summary" >/dev/null \
    || fail "malformed span packets should not enter span quality scoring"
  pass "evidence span choices are validated as a bounded set"
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

test_model_echo_is_not_persisted() {
  local model_packet
  model_packet=$(write_packet_variant "$FIXTURE_DIR/01-truthful.json" model-echo)
  rm -f "$LEDGER" "$SUMMARY"
  TYPESAFE_API_KEY=test-key FAKE_TYPESAFE_LOG="$CALL_LOG" "$TOOL" screen \
    --packet "$model_packet" \
    --ledger "$LEDGER" \
    --summary "$SUMMARY" \
    --typesafe-command "$FAKE" \
    > "$TMP_ROOT/model-echo.out" \
    || fail "model echo packet should still produce report-only records"
  jq -e '.jev_advisory.model == "jev-latest"' "$LEDGER" >/dev/null \
    || fail "ledger persisted model text from the transport response"
  pass "model id is the local requested model, not transport echo"
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
test_output_aliases_are_rejected_without_receipts
test_output_preflight_rejects_unwritable_targets_before_transport
test_transport_request_omits_packet_extra_fields
test_summary_metric_edges_are_scored_from_public_outputs
test_invalid_usage_values_are_filtered
test_empty_changed_files_route_to_review
test_empty_fixture_directory_is_rejected_without_receipts
test_mode_specific_inputs_are_rejected_without_receipts
test_authority_boundaries_reject_control_flags
test_json_stdout_surface_is_rejected
test_malformed_packet_metadata_is_sanitized
test_evidence_span_choice_set_is_validated
test_low_confidence_and_malformed_response_route_to_review
test_confidence_floor_option_is_not_public
test_malformed_confidence_and_span_route_to_review
test_model_echo_is_not_persisted
test_deterministic_failure_takes_precedence_over_jev_support

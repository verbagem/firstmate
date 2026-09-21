#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const PACKET_SCHEMA = 'fm-jev-evidence-packet.v1';
const LEDGER_SCHEMA = 'fm-jev-evidence-ledger.v1';
const SUMMARY_SCHEMA = 'fm-jev-evidence-summary.v1';
const TRUTH_LABELS = new Set(['proven', 'unsupported', 'contradicted', 'ambiguous', 'out-of-scope']);
const SUPPORT_CHOICES = new Set(['supported', 'unsupported', 'ambiguous', 'out_of_scope']);
const CONTRADICTION_CHOICES = new Set(['yes', 'no', 'ambiguous']);
const MISSING_CHOICES = new Set(['none', 'direct_support', 'acceptance_criteria', 'test_receipts', 'changed_files', 'unknown']);
const RISK_CHOICES = new Set(['low', 'medium', 'high', 'out_of_scope']);
const REQUESTED_JEV_MODEL = 'jev-latest';
const MODEL_ID_PATTERN = /^[A-Za-z0-9._:-]{1,80}$/;
const CONFIDENCE_FLOOR = 0.6;
const USAGE_FIELDS = ['input_tokens', 'output_tokens', 'total_tokens', 'cost_usd'];
const TOKEN_USAGE_FIELDS = new Set(['input_tokens', 'output_tokens', 'total_tokens']);

function usage() {
  process.stdout.write(`fm-jev-evidence-screen.sh - advisory-only Jev evidence/completion screening pilot

Usage:
  fm-jev-evidence-screen.sh screen --packet <packet.json> --ledger <ledger.jsonl> --summary <summary.json> [--typesafe-command <path>]
  fm-jev-evidence-screen.sh evaluate --fixtures <dir> --ledger <ledger.jsonl> --summary <summary.json> [--typesafe-command <path>]

The result is report-only.
Missing keys, low confidence, malformed responses, and transport errors route to needs_review.
`);
}

function dieUsage(message) {
  process.stderr.write(`fm-jev-evidence-screen: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = [...argv];
  let command = 'screen';
  if (args[0] && !args[0].startsWith('-')) {
    command = args.shift();
  }
  if (command === '-h' || command === '--help') {
    usage();
    process.exit(0);
  }
  if (!['screen', 'evaluate'].includes(command)) {
    dieUsage(`unknown command: ${command}`);
  }
  const opts = {
    packets: [],
    fixtures: undefined,
    ledger: undefined,
    summary: undefined,
    typesafeCommand: undefined,
  };
  while (args.length > 0) {
    const arg = args.shift();
    switch (arg) {
      case '--packet':
        opts.packets.push(requireValue(args.shift(), '--packet'));
        break;
      case '--fixtures':
        opts.fixtures = requireValue(args.shift(), '--fixtures');
        break;
      case '--ledger':
        opts.ledger = requireValue(args.shift(), '--ledger');
        break;
      case '--summary':
        opts.summary = requireValue(args.shift(), '--summary');
        break;
      case '--typesafe-command':
        opts.typesafeCommand = requireValue(args.shift(), '--typesafe-command');
        break;
      case '-h':
      case '--help':
        usage();
        process.exit(0);
        break;
      default:
        if (arg.startsWith('--')) dieUsage(`unknown option: ${arg}`);
        dieUsage(`unexpected argument: ${arg}`);
    }
  }
  if (!opts.ledger) dieUsage('--ledger is required');
  if (!opts.summary) dieUsage('--summary is required');
  if (sameOutputFile(opts.ledger, opts.summary)) dieUsage('--ledger and --summary must be different paths');
  if (command === 'screen' && opts.packets.length === 0) dieUsage('screen requires at least one --packet');
  if (command === 'evaluate' && !opts.fixtures) dieUsage('evaluate requires --fixtures');
  return { command, opts };
}

function requireValue(value, flag) {
  if (!value) dieUsage(`${flag} requires a value`);
  return value;
}

function readJsonFile(filePath, label) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    throw new Error(`${label} unreadable: ${error.code || error.message}`);
  }
  try {
    return { value: JSON.parse(text), text };
  } catch (error) {
    throw new Error(`${label} invalid JSON: ${error.message}`);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function localJevModelId() {
  if (!MODEL_ID_PATTERN.test(REQUESTED_JEV_MODEL)) throw new Error('configured Jev model id is invalid');
  return REQUESTED_JEV_MODEL;
}

function existingFileIdentity(filePath) {
  try {
    const stat = fs.statSync(filePath);
    return `${stat.dev}:${stat.ino}`;
  } catch (error) {
    if (['ENOENT', 'ENOTDIR'].includes(error.code)) return null;
    throw error;
  }
}

function outputPathIsSymlink(filePath) {
  try {
    return fs.lstatSync(filePath).isSymbolicLink();
  } catch (error) {
    if (['ENOENT', 'ENOTDIR'].includes(error.code)) return false;
    throw error;
  }
}

function canonicalFuturePath(filePath) {
  const resolved = path.resolve(filePath);
  const parent = path.dirname(resolved);
  try {
    return path.join(fs.realpathSync.native(parent), path.basename(resolved));
  } catch (error) {
    if (['ENOENT', 'ENOTDIR'].includes(error.code)) return resolved;
    throw error;
  }
}

function sameOutputFile(left, right) {
  if (path.resolve(left) === path.resolve(right)) return true;
  if (outputPathIsSymlink(left) || outputPathIsSymlink(right)) return true;
  const leftIdentity = existingFileIdentity(left);
  const rightIdentity = existingFileIdentity(right);
  if (leftIdentity && rightIdentity && leftIdentity === rightIdentity) return true;
  return canonicalFuturePath(left) === canonicalFuturePath(right);
}

function safeUsage(usage) {
  if (!isPlainObject(usage)) return {};
  const result = {};
  for (const field of USAGE_FIELDS) {
    const value = usage[field];
    if (TOKEN_USAGE_FIELDS.has(field)) {
      if (Number.isSafeInteger(value) && value >= 0) result[field] = value;
    } else if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
      result[field] = value;
    }
  }
  return result;
}

function requireString(obj, key, at, errors) {
  if (typeof obj[key] !== 'string' || obj[key].length === 0) {
    errors.push(`${at}.${key}: required non-empty string`);
  }
}

function optionalString(obj, key, at, errors) {
  if (obj[key] !== undefined && (typeof obj[key] !== 'string' || obj[key].length === 0)) {
    errors.push(`${at}.${key}: required non-empty string when present`);
  }
}

function validatePacket(packet) {
  const errors = [];
  if (!isPlainObject(packet)) return ['packet: required object'];
  if (packet.schema !== PACKET_SCHEMA) errors.push(`schema: expected ${PACKET_SCHEMA}`);
  requireString(packet, 'id', 'packet', errors);
  requireString(packet, 'claimed_outcome', 'packet', errors);
  if (!TRUTH_LABELS.has(packet.truth_label)) errors.push('packet.truth_label: unsupported label');
  if (!Array.isArray(packet.acceptance_criteria) || packet.acceptance_criteria.length === 0) {
    errors.push('packet.acceptance_criteria: required non-empty array');
  } else {
    packet.acceptance_criteria.forEach((criterion, index) => {
      if (typeof criterion !== 'string' || criterion.length === 0) errors.push(`packet.acceptance_criteria[${index}]: required non-empty string`);
    });
  }
  if (!Array.isArray(packet.changed_files)) {
    errors.push('packet.changed_files: required array');
  } else {
    packet.changed_files.forEach((file, index) => {
      const at = `packet.changed_files[${index}]`;
      if (!isPlainObject(file)) {
        errors.push(`${at}: required object`);
        return;
      }
      requireString(file, 'path', at, errors);
      requireString(file, 'summary', at, errors);
    });
  }
  if (!Array.isArray(packet.test_receipts)) {
    errors.push('packet.test_receipts: required array');
  } else {
    packet.test_receipts.forEach((receipt, index) => {
      const at = `packet.test_receipts[${index}]`;
      if (!isPlainObject(receipt)) {
        errors.push(`${at}: required object`);
        return;
      }
      requireString(receipt, 'name', at, errors);
      if (!['passed', 'failed', 'missing', 'skipped'].includes(receipt.status)) {
        errors.push(`${at}.status: expected passed, failed, missing, or skipped`);
      }
      optionalString(receipt, 'kind', at, errors);
    });
  }
  if (!Array.isArray(packet.evidence_excerpts) || packet.evidence_excerpts.length === 0) {
    errors.push('packet.evidence_excerpts: required non-empty array');
  } else {
    packet.evidence_excerpts.forEach((excerpt, index) => {
      const at = `packet.evidence_excerpts[${index}]`;
      if (!isPlainObject(excerpt)) {
        errors.push(`${at}: required object`);
        return;
      }
      requireString(excerpt, 'id', at, errors);
      requireString(excerpt, 'text', at, errors);
      if (excerpt.supports_claim !== undefined && typeof excerpt.supports_claim !== 'boolean') errors.push(`${at}.supports_claim: required boolean when present`);
      if (excerpt.contradicts_claim !== undefined && typeof excerpt.contradicts_claim !== 'boolean') errors.push(`${at}.contradicts_claim: required boolean when present`);
      if (excerpt.supports_criteria !== undefined) {
        if (!Array.isArray(excerpt.supports_criteria) || excerpt.supports_criteria.some((item) => !Number.isSafeInteger(item) || item < 0)) {
          errors.push(`${at}.supports_criteria: required array of non-negative integer indexes when present`);
        }
      }
    });
  }
  if (packet.executable_contract !== undefined && typeof packet.executable_contract !== 'boolean') {
    errors.push('packet.executable_contract: required boolean when present');
  }
  if (packet.scope !== undefined) {
    if (!isPlainObject(packet.scope)) {
      errors.push('packet.scope: required object when present');
    } else if (packet.scope.allowed_paths !== undefined && (!Array.isArray(packet.scope.allowed_paths) || packet.scope.allowed_paths.some((item) => typeof item !== 'string' || item.length === 0))) {
      errors.push('packet.scope.allowed_paths: required array of non-empty strings when present');
    }
  }
  if (packet.head !== undefined) {
    if (!isPlainObject(packet.head)) {
      errors.push('packet.head: required object when present');
    } else {
      optionalString(packet.head, 'expected', 'packet.head', errors);
      optionalString(packet.head, 'observed', 'packet.head', errors);
    }
  }
  optionalString(packet, 'expected_evidence_span', 'packet', errors);
  return errors;
}

function deterministicChecks(packet) {
  const findings = [];
  if (packet.changed_files.length === 0) {
    findings.push({ code: 'missing_changed_file_summary', severity: 'high', detail: 'no changed-file summary is present' });
  }
  const allowed = packet.scope?.allowed_paths;
  if (Array.isArray(allowed) && allowed.length > 0) {
    for (const file of packet.changed_files) {
      if (!allowed.some((prefix) => file.path === prefix || file.path.startsWith(prefix.endsWith('/') ? prefix : `${prefix}/`))) {
        findings.push({ code: 'out_of_scope_diff', severity: 'high', detail: `${file.path} is outside the allowed evidence scope` });
      }
    }
  }
  if (packet.head?.expected && packet.head?.observed && packet.head.expected !== packet.head.observed) {
    findings.push({ code: 'stale_head', severity: 'high', detail: `expected ${packet.head.expected}, observed ${packet.head.observed}` });
  }
  if (packet.executable_contract !== false) {
    const passedReceipts = packet.test_receipts.filter((receipt) => receipt.status === 'passed');
    if (passedReceipts.length === 0) {
      findings.push({ code: 'missing_test_receipt', severity: 'high', detail: 'no passed executable test/check receipt is present' });
    }
  }
  if (packet.test_receipts.some((receipt) => receipt.status === 'failed')) {
    findings.push({ code: 'failed_test_receipt', severity: 'high', detail: 'a test/check receipt is failed' });
  }
  const contradicted = packet.evidence_excerpts.filter((excerpt) => excerpt.contradicts_claim === true).map((excerpt) => excerpt.id);
  if (contradicted.length > 0) {
    findings.push({ code: 'contradicting_evidence', severity: 'high', detail: `contradiction excerpts: ${contradicted.join(',')}` });
  }
  const supportedCriteria = new Set();
  for (const excerpt of packet.evidence_excerpts) {
    if (excerpt.supports_claim === true && Array.isArray(excerpt.supports_criteria)) {
      excerpt.supports_criteria.forEach((item) => supportedCriteria.add(item));
    }
  }
  const missingCriteria = packet.acceptance_criteria
    .map((_, index) => index)
    .filter((index) => !supportedCriteria.has(index));
  if (missingCriteria.length > 0) {
    findings.push({ code: 'unsupported_acceptance_criteria', severity: 'medium', detail: `criteria without direct evidence: ${missingCriteria.join(',')}` });
  }
  const supportingEvidenceIds = packet.evidence_excerpts.filter((excerpt) => excerpt.supports_claim === true).map((excerpt) => excerpt.id);
  if (supportingEvidenceIds.length === 0) {
    findings.push({ code: 'unsupported_claim', severity: 'medium', detail: 'no evidence excerpt directly supports the claimed outcome' });
  }
  return {
    status: findings.length > 0 ? 'needs_review' : 'passed',
    findings,
    supporting_evidence_ids: supportingEvidenceIds,
  };
}

function makeJevRequest(packet) {
  const criteria = Object.fromEntries(packet.evidence_excerpts.map((excerpt) => [excerpt.id, excerpt.text]));
  return {
    model: localJevModelId(),
    state: {
      packet: {
        id: packet.id,
        claimed_outcome: packet.claimed_outcome,
        acceptance_criteria: packet.acceptance_criteria,
        changed_files: packet.changed_files,
        test_receipts: packet.test_receipts,
        evidence_excerpts: packet.evidence_excerpts.map(({ id, text }) => ({ id, text })),
      },
      authority_boundary: 'advisory only; cannot pass/fail CI, approve merge, certify completion, suppress deterministic failure, or answer ask-user findings',
    },
    questions: {
      direct_support: {
        type: 'choice',
        criteria: {
          supported: 'The evidence directly supports the claimed outcome and acceptance criteria.',
          unsupported: 'The evidence does not directly support the claimed outcome.',
          ambiguous: 'The evidence is mixed or insufficient to judge directly.',
          out_of_scope: 'The packet is outside the completion/evidence-screening scope.',
        },
      },
      contradiction: {
        type: 'choice',
        criteria: {
          yes: 'One or more excerpts contradict the claimed outcome.',
          no: 'No excerpt contradicts the claimed outcome.',
          ambiguous: 'Contradiction cannot be determined from the packet.',
        },
      },
      missing_evidence: {
        type: 'choice',
        criteria: {
          none: 'No important evidence appears missing.',
          direct_support: 'Direct support for the claimed outcome is missing.',
          acceptance_criteria: 'Evidence for one or more acceptance criteria is missing.',
          test_receipts: 'A relevant executable test or check receipt is missing.',
          changed_files: 'Changed-file evidence is missing or unrelated.',
          unknown: 'The missing evidence category is unclear.',
        },
      },
      risk_category: {
        type: 'choice',
        criteria: {
          low: 'Low review risk.',
          medium: 'Medium review risk.',
          high: 'High review risk.',
          out_of_scope: 'Outside the advisory screening scope.',
        },
      },
      evidence_span: {
        type: 'choice',
        criteria: { none: 'No evidence span is useful.', ...criteria },
      },
    },
  };
}

function callJev(packet, opts) {
  if (!process.env.TYPESAFE_API_KEY) {
    return { status: 'needs_review', abstained: true, reason: 'missing-key', latency_ms: 0, model: 'none', usage: {} };
  }
  if (!opts.typesafeCommand) {
    return { status: 'needs_review', abstained: true, reason: 'no-transport-report-only-default', latency_ms: 0, model: 'none', usage: {} };
  }
  const request = makeJevRequest(packet);
  const started = Date.now();
  let stdout;
  try {
    const env = { ...process.env };
    delete env.TYPESAFE_API_KEY;
    delete env.TYPESAFE_API_KEY_PRIVATE;
    stdout = execFileSync(opts.typesafeCommand, [], {
      input: `${JSON.stringify(request)}\n`,
      encoding: 'utf8',
      timeout: 5000,
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch (error) {
    return {
      status: 'needs_review',
      abstained: true,
      reason: `transport-error:${error.status ?? error.signal ?? error.code ?? 'unknown'}`,
      latency_ms: Date.now() - started,
      model: localJevModelId(),
      usage: {},
    };
  }
  const latency = Date.now() - started;
  let response;
  try {
    response = JSON.parse(stdout);
  } catch (error) {
    return { status: 'needs_review', abstained: true, reason: 'malformed-response-json', latency_ms: latency, model: localJevModelId(), usage: {} };
  }
  const parsed = parseJevResponse(response, packet);
  return { ...parsed, latency_ms: latency };
}

function parseJevResponse(response, packet) {
  if (!isPlainObject(response) || !isPlainObject(response.answers)) {
    return { status: 'needs_review', abstained: true, reason: 'malformed-response-shape', model: localJevModelId(), usage: safeUsage(response?.usage) };
  }
  const usage = safeUsage(response.usage);
  const evidenceSpanChoices = new Set(['none', ...packet.evidence_excerpts.map((excerpt) => excerpt.id)]);
  const answer = (name, allowed) => {
    const item = response.answers[name];
    if (!isPlainObject(item) || typeof item.choice !== 'string' || !allowed.has(item.choice)) {
      return { ok: false, reason: `malformed-${name}` };
    }
    if (typeof item.confidence !== 'number' || !Number.isFinite(item.confidence)) {
      return { ok: false, reason: `malformed-${name}-confidence` };
    }
    if (item.confidence < 0 || item.confidence > 1) {
      return { ok: false, reason: `malformed-${name}-confidence` };
    }
    if (item.confidence < CONFIDENCE_FLOOR) {
      return { ok: false, lowConfidence: true, reason: `low-confidence-${name}`, choice: item.choice, confidence: item.confidence };
    }
    return { ok: true, choice: item.choice, confidence: item.confidence };
  };
  const directSupport = answer('direct_support', SUPPORT_CHOICES);
  const contradiction = answer('contradiction', CONTRADICTION_CHOICES);
  const missingEvidence = answer('missing_evidence', MISSING_CHOICES);
  const riskCategory = answer('risk_category', RISK_CHOICES);
  const span = response.answers.evidence_span;
  if (!directSupport.ok || !contradiction.ok || !missingEvidence.ok || !riskCategory.ok) {
    const failed = [directSupport, contradiction, missingEvidence, riskCategory].find((item) => !item.ok);
    return {
      status: 'needs_review',
      abstained: true,
      reason: failed.reason,
      model: localJevModelId(),
      usage,
    };
  }
  if (!isPlainObject(span) || typeof span.choice !== 'string' || !evidenceSpanChoices.has(span.choice) || typeof span.confidence !== 'number' || !Number.isFinite(span.confidence)) {
    return { status: 'needs_review', abstained: true, reason: 'malformed-evidence_span', model: localJevModelId(), usage };
  }
  if (span.confidence < 0 || span.confidence > 1) {
    return { status: 'needs_review', abstained: true, reason: 'malformed-evidence_span', model: localJevModelId(), usage };
  }
  if (span.confidence < CONFIDENCE_FLOOR) {
    return { status: 'needs_review', abstained: true, reason: 'low-confidence-evidence_span', model: localJevModelId(), usage };
  }
  const needsReview = directSupport.choice !== 'supported' || contradiction.choice !== 'no' || missingEvidence.choice !== 'none' || ['high', 'out_of_scope'].includes(riskCategory.choice);
  return {
    status: needsReview ? 'needs_review' : 'advisory_supported',
    abstained: false,
    reason: needsReview ? 'jev-advisory-risk' : 'jev-advisory-supports',
    model: localJevModelId(),
    direct_support: directSupport,
    contradiction,
    missing_evidence: missingEvidence,
    risk_category: riskCategory,
    evidence_span: { choice: span.choice, confidence: span.confidence },
    usage,
  };
}

function recommendation(deterministic, jev) {
  const boundary = {
    can_pass_ci: false,
    can_approve_merge: false,
    can_certify_completion: false,
    can_suppress_deterministic_failure: false,
    can_answer_ask_user: false,
  };
  if (deterministic.status !== 'passed') {
    return {
      review_priority: 'needs_review',
      suggested_lane: 'human_or_no_mistakes_review',
      reason: 'deterministic-failure-precedence',
      boundary,
    };
  }
  if (jev.status === 'needs_review') {
    return {
      review_priority: 'needs_review',
      suggested_lane: 'human_or_no_mistakes_review',
      reason: jev.reason,
      boundary,
    };
  }
  return {
    review_priority: 'normal',
    suggested_lane: 'existing_review_path',
    reason: 'report-only-advisory-support',
    boundary,
  };
}

function makeRecord(packetPath, packetText, packet, opts) {
  const schemaErrors = validatePacket(packet);
  let deterministic;
  let jev;
  if (schemaErrors.length > 0) {
    deterministic = { status: 'needs_review', findings: schemaErrors.map((detail) => ({ code: 'malformed_packet', severity: 'high', detail })), supporting_evidence_ids: [] };
    jev = { status: 'needs_review', abstained: true, reason: 'malformed-packet', latency_ms: 0, model: 'none', usage: {} };
  } else {
    deterministic = deterministicChecks(packet);
    jev = callJev(packet, opts);
  }
  const record = {
    schema: LEDGER_SCHEMA,
    created_at: new Date().toISOString(),
    packet_path: packetPath,
    packet_sha256: crypto.createHash('sha256').update(packetText).digest('hex'),
    packet_id: packet.id || null,
    truth_label: packet.truth_label || null,
    claimed_outcome: packet.claimed_outcome || null,
    deterministic_checks: deterministic,
    jev_advisory: jev,
    recommendation: recommendation(deterministic, jev),
  };
  return record;
}

function listFixturePackets(dir) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (error) {
    throw new Error(`fixtures unreadable: ${error.code || error.message}`);
  }
  return names
    .filter((name) => name.endsWith('.json'))
    .sort((a, b) => a.localeCompare(b))
    .map((name) => path.join(dir, name));
}

function ensureParent(filePath) {
  const parent = path.dirname(path.resolve(filePath));
  fs.mkdirSync(parent, { recursive: true });
}

function appendLedger(ledgerPath, records) {
  if (records.length === 0) throw new Error('no records to append');
  ensureParent(ledgerPath);
  const text = records.map((record) => JSON.stringify(record)).join('\n');
  fs.appendFileSync(ledgerPath, `${text}\n`, 'utf8');
}

function writeSummary(summaryPath, summary) {
  ensureParent(summaryPath);
  fs.writeFileSync(summaryPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
}

function ratio(numerator, denominator) {
  if (denominator === 0) return null;
  return Number((numerator / denominator).toFixed(4));
}

function usageTokenTotal(usage) {
  if (typeof usage?.total_tokens === 'number' && Number.isFinite(usage.total_tokens)) return usage.total_tokens;
  const input = typeof usage?.input_tokens === 'number' && Number.isFinite(usage.input_tokens) ? usage.input_tokens : 0;
  const output = typeof usage?.output_tokens === 'number' && Number.isFinite(usage.output_tokens) ? usage.output_tokens : 0;
  return input + output;
}

function summarize(records) {
  const unsupportedTruth = records.filter((record) => ['unsupported', 'contradicted'].includes(record.truth_label));
  const unsupportedCaught = unsupportedTruth.filter((record) => record.recommendation.review_priority === 'needs_review');
  const provenTruth = records.filter((record) => record.truth_label === 'proven');
  const falseEscalations = provenTruth.filter((record) => record.recommendation.review_priority === 'needs_review');
  const spanEligible = records.filter((record) => record.jev_advisory.abstained === false && record.expected_evidence_span);
  const spanExact = spanEligible.filter((record) => {
    const expected = record.expected_evidence_span;
    return expected && record.jev_advisory.evidence_span?.choice === expected;
  });
  const deterministicDisagreements = records.filter((record) => {
    const deterministicNeedsReview = record.deterministic_checks.status !== 'passed';
    const jevNeedsReview = record.jev_advisory.status === 'needs_review';
    if (record.jev_advisory.abstained) return false;
    return deterministicNeedsReview !== jevNeedsReview;
  });
  const totalLatency = records.reduce((sum, record) => sum + (Number(record.jev_advisory.latency_ms) || 0), 0);
  const totalTokens = records.reduce((sum, record) => sum + usageTokenTotal(record.jev_advisory.usage), 0);
  const totalCost = records.reduce((sum, record) => sum + (Number(record.jev_advisory.usage?.cost_usd) || 0), 0);
  const abstentions = records.filter((record) => record.jev_advisory.abstained).length;
  return {
    schema: SUMMARY_SCHEMA,
    created_at: new Date().toISOString(),
    packets: records.length,
    metrics: {
      unsupported_claim_recall: ratio(unsupportedCaught.length, unsupportedTruth.length),
      unsupported_claim_recall_count: `${unsupportedCaught.length}/${unsupportedTruth.length}`,
      false_escalation_rate: ratio(falseEscalations.length, provenTruth.length),
      false_escalation_count: `${falseEscalations.length}/${provenTruth.length}`,
      evidence_span_quality: ratio(spanExact.length, spanEligible.length),
      evidence_span_quality_count: `${spanExact.length}/${spanEligible.length}`,
      deterministic_disagreement_count: deterministicDisagreements.length,
      latency_ms_total: totalLatency,
      latency_ms_mean: ratio(totalLatency, records.length),
      tokens_total: totalTokens,
      cost_usd_total: Number(totalCost.toFixed(6)),
      abstention_rate: ratio(abstentions, records.length),
      abstention_count: `${abstentions}/${records.length}`,
    },
    authority_boundary: {
      advisory_only: true,
      can_pass_ci: false,
      can_approve_merge: false,
      can_certify_completion: false,
      can_suppress_deterministic_failure: false,
      can_answer_ask_user: false,
    },
  };
}

function attachExpectedSpan(records, packets) {
  return records.map((record, index) => ({
    ...record,
    expected_evidence_span: packets[index].expected_evidence_span || null,
  }));
}

function run() {
  const { command, opts } = parseArgs(process.argv.slice(2));
  const packetPaths = command === 'evaluate' ? listFixturePackets(opts.fixtures) : opts.packets;
  if (command === 'evaluate' && packetPaths.length === 0) dieUsage('evaluate requires at least one fixture packet');
  const packets = [];
  const records = [];
  for (const packetPath of packetPaths) {
    const { value, text } = readJsonFile(packetPath, `packet ${packetPath}`);
    packets.push(value);
    records.push(makeRecord(packetPath, text, value, opts));
  }
  const enriched = attachExpectedSpan(records, packets);
  appendLedger(opts.ledger, enriched);
  const summary = summarize(enriched);
  writeSummary(opts.summary, summary);
  process.stdout.write(`jev-evidence-screen: packets=${enriched.length} needs_review=${enriched.filter((record) => record.recommendation.review_priority === 'needs_review').length} ledger=${opts.ledger}\n`);
  process.stdout.write(`summary=${opts.summary}\n`);
}

try {
  run();
} catch (error) {
  process.stderr.write(`fm-jev-evidence-screen: ${error.message}\n`);
  process.exit(2);
}

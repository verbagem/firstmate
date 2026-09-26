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
const REVIEW_DEPTH_CHOICES = new Set(['focused', 'standard', 'deep', 'strong_model']);
const REQUESTED_JEV_MODEL = 'jev-latest';
const MODEL_ID_PATTERN = /^[A-Za-z0-9._:-]{1,80}$/;
const CONFIDENCE_FLOOR = 0.6;
const USAGE_FIELDS = ['input_tokens', 'output_tokens', 'total_tokens', 'cost_usd'];
const TOKEN_USAGE_FIELDS = new Set(['input_tokens', 'output_tokens', 'total_tokens']);
const MAX_STRING_LENGTH = 4000;
const MAX_COLLECTION_LENGTH = 32;
const TEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,80}$/;

function usage() {
  process.stdout.write(`fm-jev-evidence-screen.sh - advisory-only Jev evidence/completion screening pilot

Usage:
  fm-jev-evidence-screen.sh screen --packet <packet.json> --ledger <ledger.jsonl> --summary <summary.json> [--typesafe-command <path>]
  fm-jev-evidence-screen.sh evaluate --fixtures <dir> --ledger <ledger.jsonl> --summary <summary.json> [--typesafe-command <path>]

The result is report-only.
Missing keys, low confidence, malformed responses, and transport errors route to needs_review.
Suggested tests never omit packet-declared required tests.
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
  if (command === 'screen' && opts.fixtures) dieUsage('screen does not accept --fixtures');
  if (command === 'evaluate' && opts.packets.length > 0) dieUsage('evaluate does not accept --packet');
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
  const leftFuture = canonicalFuturePath(left);
  const rightFuture = canonicalFuturePath(right);
  return leftFuture === rightFuture || leftFuture.toLowerCase() === rightFuture.toLowerCase();
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

function safePacketString(packet, key) {
  if (!isPlainObject(packet)) return null;
  const value = packet[key];
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function safeReferenceId(packet, key) {
  const value = safePacketString(packet, key);
  return value && TEST_ID_PATTERN.test(value) ? value : null;
}

function safeTruthLabel(packet) {
  const label = safePacketString(packet, 'truth_label');
  return TRUTH_LABELS.has(label) ? label : null;
}

function validEvidenceSpanChoices(packet) {
  if (!isPlainObject(packet) || !Array.isArray(packet.evidence_excerpts)) return null;
  const choices = new Set();
  for (const excerpt of packet.evidence_excerpts) {
    if (!isPlainObject(excerpt) || typeof excerpt.id !== 'string' || !TEST_ID_PATTERN.test(excerpt.id) || excerpt.id === 'none' || choices.has(excerpt.id)) {
      return null;
    }
    choices.add(excerpt.id);
  }
  return choices;
}

function safeExpectedEvidenceSpan(packet) {
  const expected = safePacketString(packet, 'expected_evidence_span');
  if (!expected || !TEST_ID_PATTERN.test(expected)) return null;
  const choices = validEvidenceSpanChoices(packet);
  if (!choices) return null;
  return expected === 'none' || choices.has(expected) ? expected : null;
}

function sanitizedChangedFiles(packet) {
  return packet.changed_files.map((file) => ({ path: file.path, summary: file.summary }));
}

function sanitizedTestReceipts(packet) {
  return packet.test_receipts.map((receipt) => ({
    name: receipt.name,
    status: receipt.status,
    ...(receipt.kind === undefined ? {} : { kind: receipt.kind }),
  }));
}

function requireString(obj, key, at, errors, maxLength = MAX_STRING_LENGTH) {
  if (typeof obj[key] !== 'string' || obj[key].length === 0 || obj[key].length > maxLength) {
    errors.push(`${at}.${key}: required non-empty string`);
  }
}

function optionalString(obj, key, at, errors, maxLength = MAX_STRING_LENGTH) {
  if (obj[key] !== undefined && (typeof obj[key] !== 'string' || obj[key].length === 0 || obj[key].length > maxLength)) {
    errors.push(`${at}.${key}: required non-empty string when present`);
  }
}

function validateBoundedArray(value, at, errors, { required = false } = {}) {
  if (!Array.isArray(value) || (required && value.length === 0)) {
    errors.push(`${at}: required ${required ? 'non-empty ' : ''}array`);
    return false;
  }
  if (value.length > MAX_COLLECTION_LENGTH) {
    errors.push(`${at}: exceeds ${MAX_COLLECTION_LENGTH} items`);
    return false;
  }
  return true;
}

function validateBenchmark(benchmark, errors) {
  if (benchmark === undefined) return;
  if (!isPlainObject(benchmark)) {
    errors.push('packet.benchmark: required object when present');
    return;
  }
  const fields = {
    strong_model_review_ms_without_triage: 86400000,
    strong_model_review_ms_with_triage: 86400000,
    test_selection_turns_without_triage: 10000,
    test_selection_turns_with_triage: 10000,
  };
  for (const [key, maximum] of Object.entries(fields)) {
    if (!Number.isSafeInteger(benchmark[key]) || benchmark[key] < 0 || benchmark[key] > maximum) {
      errors.push(`packet.benchmark.${key}: required bounded non-negative integer`);
    }
  }
}

function sanitizedBenchmark(benchmark) {
  if (!isPlainObject(benchmark)) return null;
  return {
    strong_model_review_ms_without_triage: benchmark.strong_model_review_ms_without_triage,
    strong_model_review_ms_with_triage: benchmark.strong_model_review_ms_with_triage,
    test_selection_turns_without_triage: benchmark.test_selection_turns_without_triage,
    test_selection_turns_with_triage: benchmark.test_selection_turns_with_triage,
  };
}

function validatePacket(packet) {
  const errors = [];
  if (!isPlainObject(packet)) return ['packet: required object'];
  if (packet.schema !== PACKET_SCHEMA) errors.push(`schema: expected ${PACKET_SCHEMA}`);
  requireString(packet, 'id', 'packet', errors, 80);
  if (typeof packet.id === 'string' && !TEST_ID_PATTERN.test(packet.id)) {
    errors.push('packet.id: required bounded reference id');
  }
  requireString(packet, 'claimed_outcome', 'packet', errors);
  if (!TRUTH_LABELS.has(packet.truth_label)) errors.push('packet.truth_label: unsupported label');
  if (validateBoundedArray(packet.acceptance_criteria, 'packet.acceptance_criteria', errors, { required: true })) {
    packet.acceptance_criteria.forEach((criterion, index) => {
      if (typeof criterion !== 'string' || criterion.length === 0 || criterion.length > MAX_STRING_LENGTH) {
        errors.push(`packet.acceptance_criteria[${index}]: required non-empty string`);
      }
    });
  }
  if (validateBoundedArray(packet.changed_files, 'packet.changed_files', errors)) {
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
  if (validateBoundedArray(packet.test_receipts, 'packet.test_receipts', errors)) {
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
  if (validateBoundedArray(packet.evidence_excerpts, 'packet.evidence_excerpts', errors, { required: true })) {
    const excerptIds = new Set();
    packet.evidence_excerpts.forEach((excerpt, index) => {
      const at = `packet.evidence_excerpts[${index}]`;
      if (!isPlainObject(excerpt)) {
        errors.push(`${at}: required object`);
        return;
      }
      if (typeof excerpt.id !== 'string' || excerpt.id.length === 0 || !TEST_ID_PATTERN.test(excerpt.id)) {
        errors.push(`${at}.id: required non-empty string`);
      } else if (excerpt.id === 'none') {
        errors.push(`${at}.id: reserved evidence span choice`);
      } else if (excerptIds.has(excerpt.id)) {
        errors.push(`${at}.id: duplicate evidence span choice`);
      } else {
        excerptIds.add(excerpt.id);
      }
      requireString(excerpt, 'text', at, errors);
    });
    const expected = safePacketString(packet, 'expected_evidence_span');
    if (expected && expected !== 'none' && !excerptIds.has(expected)) {
      errors.push('packet.expected_evidence_span: expected none or an evidence excerpt id');
    }
  }
  if (packet.executable_contract !== undefined && typeof packet.executable_contract !== 'boolean') {
    errors.push('packet.executable_contract: required boolean when present');
  }
  if (packet.ask_user_open !== undefined && typeof packet.ask_user_open !== 'boolean') {
    errors.push('packet.ask_user_open: required boolean when present');
  }
  if (packet.test_candidates !== undefined && validateBoundedArray(packet.test_candidates, 'packet.test_candidates', errors)) {
    const testIds = new Set();
    packet.test_candidates.forEach((candidate, index) => {
      const at = `packet.test_candidates[${index}]`;
      if (!isPlainObject(candidate)) {
        errors.push(`${at}: required object`);
        return;
      }
      requireString(candidate, 'id', at, errors, 80);
      requireString(candidate, 'name', at, errors);
      optionalString(candidate, 'kind', at, errors, 80);
      if (typeof candidate.id === 'string' && (!TEST_ID_PATTERN.test(candidate.id) || candidate.id === 'none' || testIds.has(candidate.id))) {
        errors.push(`${at}.id: required unique bounded choice id`);
      } else if (typeof candidate.id === 'string') {
        testIds.add(candidate.id);
      }
      if (candidate.required !== undefined && typeof candidate.required !== 'boolean') {
        errors.push(`${at}.required: required boolean when present`);
      }
    });
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
  validateBenchmark(packet.benchmark, errors);
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
        findings.push({ code: 'out_of_scope_diff', severity: 'high', detail: 'a changed-file reference is outside the allowed evidence scope' });
      }
    }
  }
  if (packet.head?.expected && packet.head?.observed && packet.head.expected !== packet.head.observed) {
    findings.push({ code: 'stale_head', severity: 'high', detail: 'the observed head does not match the expected head' });
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
  if (packet.ask_user_open === true) {
    findings.push({ code: 'open_captain_decision', severity: 'high', detail: 'an existing captain decision remains open' });
  }
  return {
    status: findings.length > 0 ? 'needs_review' : 'passed',
    findings,
    supporting_evidence_ids: [],
  };
}

function makeJevRequest(packet) {
  const criteria = Object.fromEntries(packet.evidence_excerpts.map((excerpt) => [excerpt.id, excerpt.text]));
  const testCriteria = Object.fromEntries((packet.test_candidates || []).map((candidate) => [
    candidate.id,
    `${candidate.name}${candidate.kind ? ` (${candidate.kind})` : ''}`,
  ]));
  return {
    model: localJevModelId(),
    state: {
      packet: {
        id: packet.id,
        claimed_outcome: packet.claimed_outcome,
        acceptance_criteria: packet.acceptance_criteria,
        changed_files: sanitizedChangedFiles(packet),
        test_receipts: sanitizedTestReceipts(packet),
        evidence_excerpts: packet.evidence_excerpts.map(({ id, text }) => ({ id, text })),
        test_candidates: (packet.test_candidates || []).map(({ id, name, kind, required }) => ({
          id,
          name,
          ...(kind === undefined ? {} : { kind }),
          required: required === true,
        })),
        ask_user_open: packet.ask_user_open === true,
      },
      authority_boundary: 'advisory only; cannot pass/fail CI, approve merge, certify completion, suppress deterministic failure, waive required tests, or answer ask-user findings',
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
      review_depth: {
        type: 'choice',
        criteria: {
          focused: 'A focused review of the cited evidence is appropriate.',
          standard: 'The existing standard no-mistakes review depth is appropriate.',
          deep: 'Deep review is appropriate because evidence is incomplete, risky, or contradicted.',
          strong_model: 'Route the packet to an existing stronger reviewer.',
        },
      },
      selected_test: {
        type: 'choice',
        criteria: {
          none: 'No optional test can be suggested from this packet.',
          ...testCriteria,
        },
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
  const reviewDepth = answer('review_depth', REVIEW_DEPTH_CHOICES);
  const selectedTestChoices = new Set(['none', ...(packet.test_candidates || []).map((candidate) => candidate.id)]);
  const selectedTest = answer('selected_test', selectedTestChoices);
  const span = response.answers.evidence_span;
  if (!directSupport.ok || !contradiction.ok || !missingEvidence.ok || !riskCategory.ok || !reviewDepth.ok || !selectedTest.ok) {
    const failed = [directSupport, contradiction, missingEvidence, riskCategory, reviewDepth, selectedTest].find((item) => !item.ok);
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
    review_depth: reviewDepth,
    selected_test: selectedTest,
    usage,
  };
}

function recommendation(packet, deterministic, jev) {
  const requiredTests = (packet.test_candidates || []).filter((candidate) => candidate.required === true).map((candidate) => candidate.id);
  const selectedTest = jev.selected_test?.choice;
  const suggestedTests = [...new Set([
    ...requiredTests,
    ...(selectedTest && selectedTest !== 'none' ? [selectedTest] : []),
  ])];
  const boundary = {
    can_pass_ci: false,
    can_approve_merge: false,
    can_certify_completion: false,
    can_suppress_deterministic_failure: false,
    can_waive_required_tests: false,
    can_answer_ask_user: false,
    can_expand_authority: false,
  };
  if (deterministic.status !== 'passed') {
    return {
      review_priority: 'needs_review',
      review_depth: 'deep',
      suggested_lane: 'existing_no_mistakes_review',
      suggested_test_ids: requiredTests,
      reason: 'deterministic-failure-precedence',
      evidence_owner: 'no-mistakes',
      proposal_owner: 'bin/fm-proposal-card.sh',
      boundary,
    };
  }
  if (jev.status === 'needs_review') {
    return {
      review_priority: 'needs_review',
      review_depth: 'deep',
      suggested_lane: 'existing_no_mistakes_review',
      suggested_test_ids: requiredTests,
      reason: jev.reason,
      evidence_owner: 'no-mistakes',
      proposal_owner: 'bin/fm-proposal-card.sh',
      boundary,
    };
  }
  const requestedDepth = jev.review_depth?.choice || 'standard';
  const reviewDepth = requestedDepth === 'focused' && jev.risk_category?.choice !== 'low'
    ? 'standard'
    : requestedDepth;
  return {
    review_priority: 'normal',
    review_depth: reviewDepth,
    suggested_lane: reviewDepth === 'strong_model' ? 'existing_stronger_reviewer' : 'existing_no_mistakes_review',
    suggested_test_ids: suggestedTests,
    reason: 'report-only-advisory-support',
    evidence_owner: 'no-mistakes',
    proposal_owner: 'bin/fm-proposal-card.sh',
    boundary,
  };
}

function makeRecord(packetText, packet, opts) {
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
    packet_sha256: crypto.createHash('sha256').update(packetText).digest('hex'),
    packet_id: safeReferenceId(packet, 'id'),
    truth_label: safeTruthLabel(packet),
    claim_sha256: typeof packet?.claimed_outcome === 'string'
      ? crypto.createHash('sha256').update(packet.claimed_outcome).digest('hex')
      : null,
    evidence_references: validEvidenceSpanChoices(packet) ? [...validEvidenceSpanChoices(packet)] : [],
    benchmark: schemaErrors.length === 0 ? sanitizedBenchmark(packet.benchmark) : null,
    deterministic_checks: deterministic,
    jev_advisory: jev,
    recommendation: recommendation(isPlainObject(packet) ? packet : {}, deterministic, jev),
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

function preflightOutputPath(filePath, label) {
  const resolved = path.resolve(filePath);
  ensureParent(resolved);
  let stat;
  try {
    stat = fs.lstatSync(resolved);
  } catch (error) {
    if (error.code === 'ENOENT') {
      try {
        fs.accessSync(path.dirname(resolved), fs.constants.W_OK);
      } catch {
        throw new Error(`${label} output parent is not writable`);
      }
      return;
    }
    throw error;
  }
  if (stat.isDirectory()) throw new Error(`${label} output path is a directory`);
  if (stat.isSymbolicLink()) throw new Error(`${label} output path is a symlink`);
  try {
    fs.accessSync(resolved, fs.constants.W_OK);
  } catch {
    throw new Error(`${label} output path is not writable`);
  }
}

function preflightOutputs(opts) {
  preflightOutputPath(opts.ledger, 'ledger');
  preflightOutputPath(opts.summary, 'summary');
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

function reductionRatio(withoutTriage, withTriage) {
  if (withoutTriage <= 0) return null;
  return Number(((withoutTriage - withTriage) / withoutTriage).toFixed(4));
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
  const falseSafeLowReview = unsupportedTruth.filter((record) => (
    record.recommendation.review_priority !== 'needs_review'
    || record.recommendation.review_depth === 'focused'
  ));
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
  const deterministicFailures = records.filter((record) => record.deterministic_checks.status !== 'passed');
  const downgradedDeterministicFailures = deterministicFailures.filter((record) => (
    record.recommendation.review_priority !== 'needs_review'
    || record.recommendation.review_depth !== 'deep'
    || record.recommendation.reason !== 'deterministic-failure-precedence'
  ));
  const requiredTestWaivers = records.filter((record) => {
    const packetRequired = record.required_test_ids || [];
    const suggested = new Set(record.recommendation.suggested_test_ids || []);
    return packetRequired.some((id) => !suggested.has(id));
  });
  const askUserBypasses = records.filter((record) => (
    record.deterministic_checks.findings.some((finding) => finding.code === 'open_captain_decision')
    && record.recommendation.review_priority !== 'needs_review'
  ));
  const authorityExpansions = records.filter((record) => (
    Object.values(record.recommendation.boundary || {}).some((value) => value !== false)
  ));
  const qualifiedLowRisk = records.filter((record) => (
    record.truth_label === 'proven'
    && record.deterministic_checks.status === 'passed'
    && record.recommendation.review_depth === 'focused'
    && record.benchmark
  ));
  const reviewWithout = qualifiedLowRisk.reduce((sum, record) => sum + record.benchmark.strong_model_review_ms_without_triage, 0);
  const reviewWith = qualifiedLowRisk.reduce((sum, record) => sum + record.benchmark.strong_model_review_ms_with_triage, 0);
  const turnsWithout = qualifiedLowRisk.reduce((sum, record) => sum + record.benchmark.test_selection_turns_without_triage, 0);
  const turnsWith = qualifiedLowRisk.reduce((sum, record) => sum + record.benchmark.test_selection_turns_with_triage, 0);
  const reviewReduction = reductionRatio(reviewWithout, reviewWith);
  const turnReduction = reductionRatio(turnsWithout, turnsWith);
  const reproducibleShape = records.map((record) => ({
    packet_id: record.packet_id,
    packet_sha256: record.packet_sha256,
    deterministic_status: record.deterministic_checks.status,
    deterministic_codes: record.deterministic_checks.findings.map((finding) => finding.code),
    advisory_status: record.jev_advisory.status,
    advisory_reason: record.jev_advisory.reason,
    recommendation: record.recommendation,
  }));
  const stopReasons = [];
  if (downgradedDeterministicFailures.length > 0) stopReasons.push('deterministic-failure-hidden-or-downgraded');
  if (falseSafeLowReview.length > 0) stopReasons.push('false-safe-or-low-review-classification');
  if (requiredTestWaivers.length > 0) stopReasons.push('required-test-waived');
  if (askUserBypasses.length > 0) stopReasons.push('captain-decision-bypassed');
  if (authorityExpansions.length > 0) stopReasons.push('authority-expanded');
  const acceptance = {
    corpus_minimum_met: records.length >= 100,
    unsupported_claim_recall_met: unsupportedTruth.length > 0 && unsupportedCaught.length / unsupportedTruth.length >= 0.95,
    false_safe_low_review_count: falseSafeLowReview.length,
    deterministic_failure_preservation_met: downgradedDeterministicFailures.length === 0,
    required_test_preservation_met: requiredTestWaivers.length === 0,
    captain_decision_preservation_met: askUserBypasses.length === 0,
    authority_boundary_preservation_met: authorityExpansions.length === 0,
    reproducibility_sha256: crypto.createHash('sha256').update(JSON.stringify(reproducibleShape)).digest('hex'),
    stop_reasons: stopReasons,
  };
  acceptance.initial_acceptance_met = acceptance.corpus_minimum_met
    && acceptance.unsupported_claim_recall_met
    && acceptance.false_safe_low_review_count === 0
    && acceptance.deterministic_failure_preservation_met
    && acceptance.required_test_preservation_met
    && acceptance.captain_decision_preservation_met
    && acceptance.authority_boundary_preservation_met
    && acceptance.stop_reasons.length === 0;
  const savingsQualified = qualifiedLowRisk.length > 0
    && reviewReduction !== null && reviewReduction >= 0.2
    && turnReduction !== null && turnReduction >= 0.2
    && acceptance.initial_acceptance_met;
  return {
    schema: SUMMARY_SCHEMA,
    created_at: new Date().toISOString(),
    packets: records.length,
    metrics: {
      unsupported_claim_recall: ratio(unsupportedCaught.length, unsupportedTruth.length),
      unsupported_claim_recall_count: `${unsupportedCaught.length}/${unsupportedTruth.length}`,
      false_safe_low_review_count: falseSafeLowReview.length,
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
      deterministic_failure_count: deterministicFailures.length,
      qualified_low_risk_packets: qualifiedLowRisk.length,
      strong_model_review_time_reduction: reviewReduction,
      repeated_test_selection_turn_reduction: turnReduction,
      savings_claim_qualified: savingsQualified,
    },
    acceptance,
    authority_boundary: {
      advisory_only: true,
      can_pass_ci: false,
      can_approve_merge: false,
      can_certify_completion: false,
      can_suppress_deterministic_failure: false,
      can_waive_required_tests: false,
      can_answer_ask_user: false,
      can_expand_authority: false,
    },
  };
}

function attachExpectedSpan(records, packets) {
  return records.map((record, index) => ({
    ...record,
    expected_evidence_span: safeExpectedEvidenceSpan(packets[index]),
    required_test_ids: isPlainObject(packets[index]) && Array.isArray(packets[index].test_candidates)
      ? packets[index].test_candidates.filter((candidate) => candidate?.required === true).map((candidate) => candidate.id)
      : [],
  }));
}

function run() {
  const { command, opts } = parseArgs(process.argv.slice(2));
  const packetPaths = command === 'evaluate' ? listFixturePackets(opts.fixtures) : opts.packets;
  if (command === 'evaluate' && packetPaths.length === 0) dieUsage('evaluate requires at least one fixture packet');
  preflightOutputs(opts);
  const packets = [];
  const records = [];
  for (const packetPath of packetPaths) {
    const { value, text } = readJsonFile(packetPath, `packet ${packetPath}`);
    const values = command === 'evaluate' && Array.isArray(value) ? value : [value];
    for (const packet of values) {
      const packetText = values.length === 1 ? text : JSON.stringify(packet);
      packets.push(packet);
      records.push(makeRecord(packetText, packet, opts));
    }
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

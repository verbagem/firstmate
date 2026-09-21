#!/usr/bin/env node
import fs from 'node:fs';

const request = JSON.parse(fs.readFileSync(0, 'utf8'));
if (process.env.TYPESAFE_API_KEY || process.env.TYPESAFE_API_KEY_PRIVATE) {
  process.stderr.write('secret leaked to fake transport\n');
  process.exit(9);
}
if (process.env.EVIDENCE_REQUEST_LOG) {
  fs.appendFileSync(process.env.EVIDENCE_REQUEST_LOG, `${JSON.stringify(request)}\n`);
}
const id = request.state.packet.id;
const contradicted = new Set(['contradictory', 'deceptive-summary']).has(id);
const unsupported = new Set(['unsupported', 'missing-test']).has(id);
const outOfScope = id === 'unrelated-diff';
const direct = outOfScope ? 'out_of_scope' : unsupported || contradicted ? 'unsupported' : 'supported';
const contradiction = contradicted ? 'yes' : 'no';
const missing = unsupported ? 'direct_support' : outOfScope ? 'changed_files' : 'none';
const risk = outOfScope ? 'out_of_scope' : contradicted ? 'high' : unsupported ? 'medium' : 'low';
const spanById = {
  truthful: 'receipt-proposal-card-pass',
  unsupported: 'doc-only',
  contradictory: 'failed-gate',
  'stale-head': 'old-attestation',
  'missing-test': 'source-claim-only',
  'deceptive-summary': 'bin-file-changed',
  'unrelated-diff': 'asset-only',
  'valid-no-executable-contract': 'doc-evidence'
};
fs.appendFileSync(process.env.EVIDENCE_CALL_LOG, `${id}\n`);
process.stdout.write(JSON.stringify({
  model: 'fake-model-response-is-not-persisted',
  answers: {
    direct_support: { type: 'choice', choice: direct, confidence: 0.93 },
    contradiction: { type: 'choice', choice: contradiction, confidence: 0.92 },
    missing_evidence: { type: 'choice', choice: missing, confidence: 0.91 },
    risk_category: { type: 'choice', choice: risk, confidence: 0.9 },
    evidence_span: { type: 'choice', choice: spanById[id] || 'none', confidence: 0.94 }
  },
  usage: { input_tokens: 91, output_tokens: 29, total_tokens: 120, cost_usd: 0.00012 }
}));

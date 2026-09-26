#!/usr/bin/env node
import fs from "node:fs";
const request = JSON.parse(fs.readFileSync(0, "utf8"));
if (process.env.TYPESAFE_API_KEY || process.env.TYPESAFE_API_KEY_PRIVATE) process.exit(9);
const id = request.state.packet.id;
if (id === "malformed-response") {
  process.stdout.write("not-json\n");
  process.exit(0);
}
const corpusProven = id.startsWith("corpus-proven-");
const corpusUnsupported = id.startsWith("corpus-unsupported-") || id.startsWith("corpus-incomplete-");
const corpusContradicted = id.startsWith("corpus-contradicted-");
const corpusOpenDecision = id.startsWith("corpus-open-decision-");
const supportedIds = new Set(["truthful", "valid-no-executable-contract", "stale-head", "strong-reviewer", "ask-user-open", "medium-risk-supported", "low-confidence", "digest-baseline"]);
const unsupportedIds = new Set(["unsupported", "missing-test"]);
const contradictedIds = new Set(["contradictory", "deceptive-summary", "unrelated-diff"]);
const supported = corpusProven || supportedIds.has(id);
const unsupported = corpusUnsupported || unsupportedIds.has(id);
const contradicted = corpusContradicted || contradictedIds.has(id);
const outOfScope = id === "unrelated-diff";
const direct = outOfScope ? "out_of_scope" : supported ? "supported" : unsupported || contradicted ? "unsupported" : "ambiguous";
const contradiction = contradicted ? "yes" : "no";
const missing = unsupported ? "direct_support" : corpusOpenDecision ? "unknown" : "none";
const risk = contradicted || outOfScope || corpusOpenDecision ? "high" : unsupported || id === "medium-risk-supported" ? "medium" : "low";
const reviewDepth = id === "strong-reviewer" ? "strong_model" : supported && !outOfScope ? "focused" : "deep";
const selectedTest = request.state.packet.test_candidates.find((candidate) => !candidate.required)?.id || request.state.packet.test_candidates[0]?.id || "none";
const spanMap = {
  truthful: "receipt-proposal-card-pass",
  unsupported: "doc-only",
  contradictory: "failed-gate",
  "stale-head": "old-attestation",
  "missing-test": "source-claim-only",
  "deceptive-summary": "bin-file-changed",
  "unrelated-diff": "asset-only",
  "valid-no-executable-contract": "doc-evidence",
  "strong-reviewer": "receipt-proposal-card-pass",
  "ask-user-open": "receipt-proposal-card-pass",
  "medium-risk-supported": "receipt-proposal-card-pass",
  "low-confidence": "receipt-proposal-card-pass",
  "digest-baseline": "receipt-proposal-card-pass"
};
const span = id.startsWith("corpus-") ? request.state.packet.evidence_excerpts[0].id : (spanMap[id] || "none");
const confidence = id === "low-confidence" ? 0.41 : 0.92;
const usage = {input_tokens: process.env.FAKE_TYPESAFE_DIGEST_VARIANT === "usage" ? 101 : 100, output_tokens: 20, total_tokens: process.env.FAKE_TYPESAFE_DIGEST_VARIANT === "usage" ? 121 : 120, cost_usd: 0.00012, private_echo: request.state.packet.evidence_excerpts[0]?.text || ""};
process.stdout.write(JSON.stringify({
  model: "jev-fake-evidence",
  answers: {
    direct_support: {type: "choice", choice: direct, confidence},
    contradiction: {type: "choice", choice: contradiction, confidence: 0.91},
    missing_evidence: {type: "choice", choice: missing, confidence: 0.9},
    risk_category: {type: "choice", choice: risk, confidence: 0.9},
    evidence_span: {type: "choice", choice: span, confidence: 0.9},
    review_depth: {type: "choice", choice: reviewDepth, confidence: 0.9},
    selected_test: {type: "choice", choice: selectedTest, confidence: 0.9}
  },
  usage
}));

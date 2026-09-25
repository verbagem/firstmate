#!/usr/bin/env python3
"""Offline Jev context-retention replay evaluator.

This tool evaluates sanitized fixture transcripts only. It never reads live
agent context, never calls TypeSafe directly, and never mutates compaction,
session, prompt, watcher, daemon, or memory state.

Usage:
  bin/fm-jev-context-replay.py --fixtures tests/fixtures/jev-context-replay/transcripts.json --out-dir /tmp/jev-replay
  bin/fm-jev-context-replay.py --fixtures tests/fixtures/jev-context-replay/transcripts.json --transport tests/fixtures/jev-context-replay/fake-typesafe.py --out-dir /tmp/jev-replay
  bin/fm-jev-context-replay.py --fixtures FILE --proposal-file proposals.json --out-dir DIR

Inputs:
  --fixtures FILE       Sanitized transcript fixtures. See
                        tests/fixtures/jev-context-replay/transcripts.json.
  --proposal-file FILE  Optional cached Jev Choice answers keyed by segment id.
  --transport PATH      Optional local fake TypeSafe transport. The tool writes
                        one System One-shaped JSON request to stdin and reads a
                        JSON response from stdout. This is for offline tests.
  --out-dir DIR         Directory for ledger.jsonl and report.md.

Outputs:
  ledger.jsonl          Stable, diffable segment decisions for baseline and jev.
  report.md            Stable replay metrics and pass/fail summary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


PROTECTED_TYPES = {
    "captain_instruction",
    "accepted_requirement",
    "evidence_tool_output",
    "unknown",
}
PROTECTED_FLAGS = {
    "approval",
    "blocker",
    "unresolved_decision",
    "security_boundary",
    "source_receipt",
}
SEGMENT_TYPES = PROTECTED_TYPES | {"ordinary_progress", "superseded_data", "noise"}
ACTION_ORDER = {"keep": 0, "truncate": 1, "drop": 2}
LOW_CONFIDENCE_FLOOR = 0.60
JEV_INPUT_PRICE_PER_TOKEN = 0.042 / 1_000_000


class ReplayError(Exception):
    """One deterministic input or evaluation error."""


def die(message: str) -> None:
    print(f"fm-jev-context-replay: {message}", file=sys.stderr)
    raise SystemExit(2)


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def stable_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def normalized_unit_number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number) or number < 0 or number > 1:
        return None
    return number


def normalized_token_count(value: Any) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    number = float(value)
    if not math.isfinite(number) or number < 0:
        return 0
    return int(number) if number.is_integer() else number


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"missing input: {path}")
    except json.JSONDecodeError as exc:
        die(f"invalid JSON in {path}: {exc}")


def validate_fixtures(data: Any) -> list[dict[str, Any]]:
    if not isinstance(data, dict) or data.get("schema") != "fm-jev-context-replay-fixtures.v1":
        die("fixtures must use schema fm-jev-context-replay-fixtures.v1")
    transcripts = data.get("transcripts")
    if not isinstance(transcripts, list) or len(transcripts) < 30:
        die("fixtures must contain at least 30 transcripts")
    seen_segments: set[str] = set()
    for case in transcripts:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str):
            die("each transcript must have an id")
        segments = case.get("segments")
        questions = case.get("questions")
        if not isinstance(segments, list) or not segments:
            die(f"{case.get('id')}: segments must be a non-empty array")
        if not isinstance(questions, list) or not questions:
            die(f"{case.get('id')}: questions must be a non-empty array")
        local_ids: set[str] = set()
        for seg in segments:
            if not isinstance(seg, dict):
                die(f"{case['id']}: segment must be an object")
            seg_id = seg.get("id")
            seg_type = seg.get("type")
            text = seg.get("text")
            if not isinstance(seg_id, str) or not seg_id:
                die(f"{case['id']}: segment id must be a non-empty string")
            if seg_id in seen_segments:
                die(f"duplicate segment id: {seg_id}")
            if seg_type not in SEGMENT_TYPES:
                die(f"{case['id']}:{seg_id}: invalid segment type {seg_type!r}")
            if not isinstance(text, str) or text == "":
                die(f"{case['id']}:{seg_id}: text must be non-empty")
            flags = seg.get("flags", [])
            if not isinstance(flags, list) or not all(isinstance(flag, str) for flag in flags):
                die(f"{case['id']}:{seg_id}: flags must be an array of strings")
            local_ids.add(seg_id)
            seen_segments.add(seg_id)
        for question in questions:
            if not isinstance(question, dict) or not isinstance(question.get("id"), str):
                die(f"{case['id']}: question must have an id")
            required = question.get("required_segment_ids")
            if not isinstance(required, list) or not required:
                die(f"{case['id']}:{question.get('id')}: required_segment_ids must be non-empty")
            missing = [seg_id for seg_id in required if seg_id not in local_ids]
            if missing:
                die(f"{case['id']}:{question['id']}: missing required segment ids: {', '.join(missing)}")
    return transcripts


def required_segment_ids(transcripts: list[dict[str, Any]]) -> set[str]:
    result: set[str] = set()
    for case in transcripts:
        for question in case["questions"]:
            result.update(question["required_segment_ids"])
    return result


def is_protected(seg: dict[str, Any], required_ids: set[str]) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    if seg["type"] in PROTECTED_TYPES:
        reasons.append(f"type:{seg['type']}")
    for flag in seg.get("flags", []):
        if flag in PROTECTED_FLAGS:
            reasons.append(f"flag:{flag}")
    if seg["id"] in required_ids:
        reasons.append("required-evidence")
    return bool(reasons), reasons


def baseline_action(seg: dict[str, Any], required_ids: set[str]) -> tuple[str, list[str]]:
    protected, reasons = is_protected(seg, required_ids)
    if protected:
        return "keep", reasons
    if seg["type"] == "ordinary_progress":
        return "truncate", ["ordinary-progress-summary"]
    return "drop", [f"type:{seg['type']}"]


def build_typesafe_request(transcripts: list[dict[str, Any]]) -> dict[str, Any]:
    state = {
        "purpose": "offline context retention replay over sanitized fixtures",
        "segments": [
            {
                "transcript_id": case["id"],
                "segment_id": seg["id"],
                "type": seg["type"],
                "flags": seg.get("flags", []),
                "text": seg["text"],
            }
            for case in transcripts
            for seg in case["segments"]
        ],
    }
    questions = {}
    for case in transcripts:
        for seg in case["segments"]:
            questions[seg["id"]] = {
                "type": "choice",
                "instructions": {
                    "question": "Should this sanitized segment be kept, truncated, or dropped for future answerability?",
                    "segment_id": seg["id"],
                    "allowed_use": "advisory only; deterministic retention rules override this answer",
                },
                "criteria": {
                    "keep": "Retain the segment verbatim.",
                    "truncate": "Retain only a non-generative preview with provenance.",
                    "drop": "Omit this segment from retained context.",
                },
            }
    return {"model": "jev-latest", "state": state, "questions": questions}


def load_proposals(path: Path | None) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    if path is None:
        return {}, {"source": "none", "latency_ms": 0, "usage": {"input_tokens": 0, "output_tokens": 0}}
    raw = load_json(path)
    return parse_typesafe_response(raw, f"proposal-file:{path}")


def run_fake_transport(path: Path | None, request: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    if path is None:
        return {}, {"source": "none", "latency_ms": 0, "usage": {"input_tokens": 0, "output_tokens": 0}}
    started = time.monotonic()
    proc = subprocess.run(
        [str(path)],
        input=json.dumps(request, sort_keys=True),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    latency_ms = int((time.monotonic() - started) * 1000)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or f"exit {proc.returncode}"
        die(f"fake transport failed: {detail}")
    try:
        raw = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        die(f"fake transport returned invalid JSON: {exc}")
    proposals, meta = parse_typesafe_response(raw, f"fake-transport:{path}")
    meta["latency_ms"] = latency_ms
    return proposals, meta


def parse_typesafe_response(raw: Any, source: str) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    if not isinstance(raw, dict):
        die(f"{source}: response must be an object")
    answers = raw.get("answers", raw.get("proposals"))
    if not isinstance(answers, dict):
        die(f"{source}: response must contain answers or proposals object")
    proposals: dict[str, dict[str, Any]] = {}
    for seg_id, answer in answers.items():
        if not isinstance(answer, dict):
            continue
        choice = answer.get("choice", answer.get("action"))
        probabilities = answer.get("probabilities", {})
        confidence = answer.get("confidence")
        if not isinstance(probabilities, dict):
            probabilities = {}
        confidence_value = normalized_unit_number(confidence)
        proposals[seg_id] = {
            "action": choice if choice in ACTION_ORDER else "unknown",
            "probabilities": {
                key: number
                for key, value in probabilities.items()
                for number in [normalized_unit_number(value)]
                if key in ACTION_ORDER and number is not None
            },
            "confidence": confidence_value,
        }
    raw_usage = raw.get("usage") if isinstance(raw.get("usage"), dict) else {}
    usage = {
        "input_tokens": normalized_token_count(raw_usage.get("input_tokens", 0)),
        "output_tokens": normalized_token_count(raw_usage.get("output_tokens", 0)),
    }
    return proposals, {"source": source, "model": raw.get("model", "unknown"), "usage": usage}


def apply_jev_action(
    seg: dict[str, Any],
    proposal: dict[str, Any] | None,
    required_ids: set[str],
) -> tuple[str, str, list[str], dict[str, Any]]:
    protected, protection_reasons = is_protected(seg, required_ids)
    if proposal is None:
        return "keep", "missing-proposal", ["no-proposal"], {}
    proposed = proposal.get("action", "unknown")
    confidence = proposal.get("confidence")
    if proposed not in ACTION_ORDER:
        return "keep", "unknown-proposal", ["unknown-proposal"], proposal
    if confidence is None or confidence < LOW_CONFIDENCE_FLOOR:
        return "keep", "low-confidence", [f"confidence:{confidence}"], proposal
    if protected and proposed != "keep":
        return "keep", "deterministic-override", protection_reasons, proposal
    return proposed, "model-accepted", [f"confidence:{confidence}"], proposal


def retained_payload(action: str, seg: dict[str, Any]) -> dict[str, Any]:
    digest = sha256_text(seg["text"])
    if action == "keep":
        return {"text": seg["text"], "text_sha256": digest}
    if action == "truncate":
        preview = seg["text"][:160]
        if len(seg["text"]) > len(preview):
            preview = preview.rstrip() + "\n[truncated]"
        return {
            "preview": preview,
            "original_segment_id": seg["id"],
            "original_sha256": digest,
            "original_chars": len(seg["text"]),
        }
    return {"text_sha256": digest}


def answerability_metrics(
    strategy: str,
    rows: list[dict[str, Any]],
    transcripts: list[dict[str, Any]],
) -> dict[str, Any]:
    by_id = {row["segment_id"]: row for row in rows if row["strategy"] == strategy}
    missing_constraints: list[str] = []
    missing_evidence: list[str] = []
    unanswerable: list[str] = []
    for case in transcripts:
        for question in case["questions"]:
            lost = [
                seg_id
                for seg_id in question["required_segment_ids"]
                if by_id.get(seg_id, {}).get("final_action") == "drop" or seg_id not in by_id
            ]
            if lost:
                unanswerable.append(f"{case['id']}:{question['id']}")
            for seg_id in lost:
                seg_type = by_id.get(seg_id, {}).get("segment_type", "missing")
                if seg_type in {"captain_instruction", "accepted_requirement"}:
                    missing_constraints.append(seg_id)
                else:
                    missing_evidence.append(seg_id)
    strategy_rows = [row for row in rows if row["strategy"] == strategy]
    source_chars = sum(row["source_chars"] for row in strategy_rows)
    retained_chars = sum(row["retained_chars"] for row in strategy_rows)
    protected_count = sum(1 for row in strategy_rows if row["protected"])
    false_drops = [
        row["segment_id"]
        for row in strategy_rows
        if row["final_action"] == "drop" and row["protected"]
    ]
    return {
        "strategy": strategy,
        "questions": sum(len(case["questions"]) for case in transcripts),
        "answerable": sum(len(case["questions"]) for case in transcripts) - len(unanswerable),
        "unanswerable": len(unanswerable),
        "missing_constraints": sorted(set(missing_constraints)),
        "missing_evidence": sorted(set(missing_evidence)),
        "retention_ratio": round(retained_chars / source_chars, 6) if source_chars else 0,
        "false_drop_rate": round(len(false_drops) / protected_count, 6) if false_drops and protected_count else 0,
        "false_drop_count": len(false_drops),
        "false_drops": false_drops,
    }


def evaluate(transcripts: list[dict[str, Any]], proposals: dict[str, dict[str, Any]], meta: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    required_ids = required_segment_ids(transcripts)
    rows: list[dict[str, Any]] = []
    for case in transcripts:
        for index, seg in enumerate(case["segments"]):
            protected, protection_reasons = is_protected(seg, required_ids)
            base_action, base_reasons = baseline_action(seg, required_ids)
            for strategy in ("baseline", "jev"):
                if strategy == "baseline":
                    action = base_action
                    status = "deterministic"
                    reasons = base_reasons
                    proposal = {}
                else:
                    action, status, reasons, proposal = apply_jev_action(seg, proposals.get(seg["id"]), required_ids)
                payload = retained_payload(action, seg)
                retained_chars = 0
                if action == "keep":
                    retained_chars = len(payload["text"])
                elif action == "truncate":
                    retained_chars = len(payload["preview"])
                rows.append(
                    {
                        "schema": "fm-jev-context-replay-ledger.v1",
                        "strategy": strategy,
                        "transcript_id": case["id"],
                        "segment_index": index,
                        "segment_id": seg["id"],
                        "segment_type": seg["type"],
                        "protected": protected,
                        "protection_reasons": protection_reasons,
                        "final_action": action,
                        "decision_status": status,
                        "decision_reasons": reasons,
                        "proposal": proposal,
                        "retained": payload,
                        "source_chars": len(seg["text"]),
                        "retained_chars": retained_chars,
                    }
                )
    baseline = answerability_metrics("baseline", rows, transcripts)
    jev = answerability_metrics("jev", rows, transcripts)
    usage = meta.get("usage", {})
    input_tokens = normalized_token_count(usage.get("input_tokens", 0)) if isinstance(usage, dict) else 0
    output_tokens = normalized_token_count(usage.get("output_tokens", 0)) if isinstance(usage, dict) else 0
    failures = []
    for metric in (baseline, jev):
        if metric["missing_constraints"]:
            failures.append(f"{metric['strategy']}: captain instruction or accepted requirement lost")
        if metric["missing_evidence"]:
            failures.append(f"{metric['strategy']}: required evidence lost")
        if metric["false_drop_count"]:
            failures.append(f"{metric['strategy']}: protected segment dropped")
    report = {
        "schema": "fm-jev-context-replay-report.v1",
        "status": "fail" if failures else "pass",
        "failures": failures,
        "proposal_source": meta.get("source", "none"),
        "proposal_model": meta.get("model", "unknown"),
        "latency_ms": meta.get("latency_ms", 0),
        "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
        "estimated_cost_usd": round(input_tokens * JEV_INPUT_PRICE_PER_TOKEN, 8),
        "metrics": {"baseline": baseline, "jev": jev},
        "fixture_count": len(transcripts),
    }
    return rows, report


def write_outputs(out_dir: Path, rows: list[dict[str, Any]], report: dict[str, Any]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    ledger_path = out_dir / "ledger.jsonl"
    report_path = out_dir / "report.md"
    with ledger_path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(stable_json(row) + "\n")
    lines = [
        "# Jev Context-Retention Replay",
        "",
        f"Status: `{report['status']}`",
        f"Fixture transcripts: `{report['fixture_count']}`",
        f"Proposal source: `{report['proposal_source']}`",
        f"Proposal model: `{report['proposal_model']}`",
        f"Latency ms: `{report['latency_ms']}`",
        f"Input tokens: `{report['usage']['input_tokens']}`",
        f"Output tokens: `{report['usage']['output_tokens']}`",
        f"Estimated TypeSafe cost USD: `{report['estimated_cost_usd']}`",
        "False drop rate denominator: protected segment rows; zero protected rows reports `0`.",
        "",
        "| Strategy | Answerable | Unanswerable | Missing constraints | Missing evidence | Retention ratio | False drop rate | False drops |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name in ("baseline", "jev"):
        metric = report["metrics"][name]
        lines.append(
            f"| {name} | {metric['answerable']} | {metric['unanswerable']} | "
            f"{len(metric['missing_constraints'])} | {len(metric['missing_evidence'])} | "
            f"{metric['retention_ratio']} | {metric['false_drop_rate']} | {metric['false_drop_count']} |"
        )
    lines.extend(["", "Failures:"])
    if report["failures"]:
        lines.extend(f"- {failure}" for failure in report["failures"])
    else:
        lines.append("- none")
    lines.extend(
        [
            "",
            "Ledger: `ledger.jsonl`",
            "",
            "Boundary: this report is generated from sanitized fixtures only and is not an automatic compactor.",
        ]
    )
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Offline Jev context-retention replay evaluator")
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--proposal-file")
    parser.add_argument("--transport")
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args(argv)
    if args.proposal_file and args.transport:
        die("use either --proposal-file or --transport, not both")

    transcripts = validate_fixtures(load_json(Path(args.fixtures)))
    if args.transport:
        request = build_typesafe_request(transcripts)
        proposals, meta = run_fake_transport(Path(args.transport), request)
    else:
        proposals, meta = load_proposals(Path(args.proposal_file) if args.proposal_file else None)
    rows, report = evaluate(transcripts, proposals, meta)
    write_outputs(Path(args.out_dir), rows, report)
    print(f"status={report['status']} ledger={Path(args.out_dir) / 'ledger.jsonl'} report={Path(args.out_dir) / 'report.md'}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

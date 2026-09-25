#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-context-replay.py.
#
# Drives the public CLI with sanitized fixtures and a fake TypeSafe transport.
# No case touches live context or the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-context-replay.py"
FIXTURES="$ROOT/tests/fixtures/jev-context-replay/transcripts.json"
TMP_ROOT=$(fm_test_tmproot fm-jev-context-replay)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
OUT1="$TMP_ROOT/out1"
OUT2="$TMP_ROOT/out2"
OUT3="$TMP_ROOT/out3"
OUT4="$TMP_ROOT/out4"
OUT5="$TMP_ROOT/out5"
BAD="$TMP_ROOT/bad.json"
MALFORMED_PROPOSALS="$TMP_ROOT/malformed-proposals.json"
FAKE_TRANSPORT="$TMP_ROOT/fake-typesafe.py"
BASE_PATH=$PATH

assert_equals() {
  local expected=$1 actual=$2 msg=$3
  [ "$actual" = "$expected" ] || fail "$msg"$'\n'"expected: $expected"$'\n'"actual: $actual"
}

cat > "$FAKE_TRANSPORT" <<'PY'
#!/usr/bin/env python3
import json
import sys

request = json.load(sys.stdin)
answers = {}
for seg_id in sorted(request["questions"]):
    if seg_id == "c019-s3":
        answers[seg_id] = {
            "type": "choice",
            "choice": "drop",
            "confidence": 0.41,
            "probabilities": {"keep": 0.34, "truncate": 0.25, "drop": 0.41},
        }
    elif seg_id.endswith("-s1") or seg_id.endswith("-s2") or seg_id.endswith("-s3"):
        answers[seg_id] = {
            "type": "choice",
            "choice": "drop",
            "confidence": 0.97,
            "probabilities": {"keep": 0.01, "truncate": 0.02, "drop": 0.97},
        }
    else:
        answers[seg_id] = {
            "type": "choice",
            "choice": "truncate",
            "confidence": 0.88,
            "probabilities": {"keep": 0.06, "truncate": 0.88, "drop": 0.06},
        }
print(json.dumps({"model": "jev-1.13.0", "answers": answers, "usage": {"input_tokens": 1000, "output_tokens": 60}}))
PY
chmod +x "$FAKE_TRANSPORT"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'network-called\n' >> "${NETWORK_LOG:?}"
exit 99
SH
chmod +x "$FAKEBIN/curl"

count=$(python3 - "$FIXTURES" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1]))["transcripts"]))
PY
)
assert_equals 30 "$count" "fixture set has 30 transcripts"

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --transport "$FAKE_TRANSPORT" --out-dir "$OUT1" > "$TMP_ROOT/run1.out"

[ -s "$OUT1/ledger.jsonl" ] || fail "ledger is written"
[ -s "$OUT1/report.md" ] || fail "report is written"
grep -Fq "Status: \`pass\`" "$OUT1/report.md" || fail "report passes despite model trying to drop protected rows"
[ ! -e "$TMP_ROOT/network.log" ] || fail "fake network command was not invoked"

if ! python3 - "$OUT1/report.md" <<'PY'
import sys
from pathlib import Path

report = Path(sys.argv[1]).read_text()
if "False drop rate denominator: protected segment rows; zero protected rows reports `0`." not in report:
    raise SystemExit("false-drop denominator is not documented")
expected_header = "| Strategy | Answerable | Unanswerable | Missing constraints | Missing evidence | Retention ratio | False drop rate | False drops |"
if expected_header not in report:
    raise SystemExit("false-drop rate column missing")
jev_line = next(line for line in report.splitlines() if line.startswith("| jev |"))
cells = [cell.strip() for cell in jev_line.strip("|").split("|")]
if cells[-2:] != ["0", "0"]:
    raise SystemExit(f"expected zero false-drop rate and count, got {cells[-2:]}")
PY
then
  fail "report includes zero false-drop rate and denominator"
fi

if ! python3 - "$FIXTURES" "$OUT1/ledger.jsonl" <<'PY'
import json
import sys

fixtures = json.load(open(sys.argv[1]))
source = {seg["id"]: seg for case in fixtures["transcripts"] for seg in case["segments"]}
rows = [json.loads(line) for line in open(sys.argv[2])]
jev = [row for row in rows if row["strategy"] == "jev"]
protected_drops = [row["segment_id"] for row in jev if row["protected"] and row["final_action"] == "drop"]
if protected_drops:
    raise SystemExit(f"protected drops: {protected_drops}")
override = next(row for row in jev if row["segment_id"] == "c001-s1")
if override["decision_status"] != "deterministic-override" or override["final_action"] != "keep":
    raise SystemExit("captain instruction was not deterministically rescued")
unknown = next(row for row in jev if row["segment_id"] == "c019-s3")
if unknown["decision_status"] != "low-confidence" or unknown["final_action"] != "keep":
    raise SystemExit("low-confidence unknown row did not force keep")
kept = next(row for row in jev if row["segment_id"] == "c011-s1")
if kept["retained"]["text"] != source["c011-s1"]["text"]:
    raise SystemExit("kept text was not verbatim")
truncated = next(row for row in rows if row["strategy"] == "baseline" and row["segment_id"] == "c025-s2")
if truncated["final_action"] != "truncate":
    raise SystemExit("ordinary progress was not truncated by baseline")
if truncated["retained"].get("original_segment_id") != "c025-s2" or "original_sha256" not in truncated["retained"]:
    raise SystemExit("truncation provenance missing")
PY
then
  fail "ledger preserves protected context and provenance"
fi

if ! python3 - "$TOOL" "$TMP_ROOT/nonzero-metric-report" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("fm_jev_context_replay", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit("cannot load evaluator module")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

transcripts = [
    {
        "id": "case-metric",
        "questions": [{"id": "q-metric", "required_segment_ids": ["p1"]}],
    }
]
rows = [
    {
        "strategy": "jev",
        "segment_id": "p1",
        "segment_type": "captain_instruction",
        "protected": True,
        "final_action": "drop",
        "source_chars": 10,
        "retained_chars": 0,
    },
    {
        "strategy": "jev",
        "segment_id": "p2",
        "segment_type": "evidence_tool_output",
        "protected": True,
        "final_action": "keep",
        "source_chars": 10,
        "retained_chars": 10,
    },
    {
        "strategy": "jev",
        "segment_id": "n1",
        "segment_type": "noise",
        "protected": False,
        "final_action": "drop",
        "source_chars": 10,
        "retained_chars": 0,
    },
]
metric = module.answerability_metrics("jev", rows, transcripts)
if metric["false_drop_rate"] != 0.5:
    raise SystemExit(f"expected nonzero false-drop rate, got {metric['false_drop_rate']}")
if metric["false_drop_count"] != 1 or metric["false_drops"] != ["p1"]:
    raise SystemExit("false-drop compatibility fields changed")

zero_rows = [
    {
        "strategy": "jev",
        "segment_id": "n1",
        "segment_type": "noise",
        "protected": False,
        "final_action": "drop",
        "source_chars": 10,
        "retained_chars": 0,
    }
]
zero = module.answerability_metrics(
    "jev",
    zero_rows,
    [{"id": "case-zero", "questions": [{"id": "q-zero", "required_segment_ids": ["n1"]}]}],
)
if zero["false_drop_rate"] != 0:
    raise SystemExit(f"expected zero-denominator false-drop rate of 0, got {zero['false_drop_rate']}")

baseline = dict(zero, strategy="baseline")
report_dir = Path(sys.argv[2])
module.write_outputs(
    report_dir,
    [],
    {
        "status": "fail",
        "fixture_count": 1,
        "proposal_source": "synthetic-metric-contract",
        "proposal_model": "none",
        "latency_ms": 0,
        "usage": {"input_tokens": 0, "output_tokens": 0},
        "estimated_cost_usd": 0,
        "metrics": {"baseline": baseline, "jev": metric},
        "failures": ["jev: protected segment dropped"],
    },
)
rendered = (report_dir / "report.md").read_text()
expected_line = "| jev | 0 | 1 | 1 | 0 | 0.333333 | 0.5 | 1 |"
if expected_line not in rendered:
    raise SystemExit("report did not render nonzero false-drop rate and count")
PY
then
  fail "false-drop rate metrics cover zero and nonzero denominators"
fi

if ! python3 - "$FIXTURES" "$MALFORMED_PROPOSALS" <<'PY'
import json
import sys

fixtures = json.load(open(sys.argv[1]))
answers = {}
for case in fixtures["transcripts"]:
    for seg in case["segments"]:
        answers[seg["id"]] = {"choice": "keep", "confidence": 0.99, "probabilities": {"keep": 0.99}}
answers["c001-s3"] = {
    "choice": "drop",
    "confidence": True,
    "probabilities": {"keep": True, "truncate": -0.1, "drop": 1.25},
}
answers["c001-s6"] = {
    "choice": "drop",
    "confidence": float("nan"),
    "probabilities": {"keep": 0.4, "drop": float("inf")},
}
json.dump(
    {
        "model": "malformed-number-fixture",
        "answers": answers,
        "usage": {"input_tokens": True, "output_tokens": float("nan")},
    },
    open(sys.argv[2], "w"),
)
PY
then
  fail "malformed proposal fixture setup"
fi

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network5.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --proposal-file "$MALFORMED_PROPOSALS" --out-dir "$OUT5" > "$TMP_ROOT/run5.out"
[ ! -e "$TMP_ROOT/network5.log" ] || fail "proposal-file path did not call network"
if ! python3 - "$OUT5/ledger.jsonl" "$OUT5/report.md" <<'PY'
import json
import math
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
report = Path(sys.argv[2]).read_text()
ordinary = next(row for row in rows if row["strategy"] == "jev" and row["segment_id"] == "c001-s3")
if ordinary["final_action"] != "keep" or ordinary["decision_status"] != "low-confidence":
    raise SystemExit("malformed boolean confidence drove a model action")
if ordinary["proposal"]["confidence"] is not None:
    raise SystemExit("malformed confidence was retained as numeric")
if ordinary["proposal"]["probabilities"] != {}:
    raise SystemExit("invalid probability values reached the ledger")
noise = next(row for row in rows if row["strategy"] == "jev" and row["segment_id"] == "c001-s6")
if noise["proposal"]["confidence"] is not None or noise["proposal"]["probabilities"] != {"keep": 0.4}:
    raise SystemExit("non-finite proposal numbers were not normalized")
for row in rows:
    proposal = row["proposal"]
    confidence = proposal.get("confidence")
    if isinstance(confidence, bool):
        raise SystemExit("boolean confidence reached ledger")
    if confidence is not None and (not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or confidence < 0 or confidence > 1):
        raise SystemExit("invalid confidence reached ledger")
    for value in proposal.get("probabilities", {}).values():
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0 or value > 1:
            raise SystemExit("invalid probability reached ledger")
if "Input tokens: `0`" not in report or "Output tokens: `0`" not in report:
    raise SystemExit("malformed usage token counts reached report")
if "Estimated TypeSafe cost USD: `0.0`" not in report:
    raise SystemExit("malformed usage changed estimated cost")
PY
then
  fail "malformed proposal numbers are normalized through public output"
fi

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network2.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --out-dir "$OUT2" > "$TMP_ROOT/run2.out"
[ ! -e "$TMP_ROOT/network2.log" ] || fail "absent-key fallback did not call network"
grep -Fq "Status: \`pass\`" "$OUT2/report.md" || fail "absent-key fallback remains safe"

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network4.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --out-dir "$OUT4" > "$TMP_ROOT/run4.out"
[ ! -e "$TMP_ROOT/network4.log" ] || fail "repeat absent-key fallback did not call network"
cmp "$OUT2/ledger.jsonl" "$OUT4/ledger.jsonl" >/dev/null || fail "no-proposal ledger is reproducible"
cmp "$OUT2/report.md" "$OUT4/report.md" >/dev/null || fail "no-proposal report is reproducible"

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network3.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --transport "$FAKE_TRANSPORT" --out-dir "$OUT3" > "$TMP_ROOT/run3.out"
cmp "$OUT1/ledger.jsonl" "$OUT3/ledger.jsonl" >/dev/null || fail "ledger is reproducible"

if ! python3 - "$FIXTURES" "$BAD" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["transcripts"] = data["transcripts"][:30]
data["transcripts"][0]["questions"][0]["required_segment_ids"].append("missing-required-evidence")
json.dump(data, open(sys.argv[2], "w"))
PY
then
  fail "bad fixture setup"
fi
if "$TOOL" --fixtures "$BAD" --out-dir "$TMP_ROOT/bad-out" > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"; then
  fail "missing required evidence must fail evaluation"
fi
grep -Fq 'missing required segment ids' "$TMP_ROOT/bad.err" || fail "missing evidence failure is explicit"

pass "fm-jev-context-replay public interface preserves protected context offline"

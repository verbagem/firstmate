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
BAD="$TMP_ROOT/bad.json"
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

python3 - "$FIXTURES" "$OUT1/ledger.jsonl" <<'PY'
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

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network2.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --out-dir "$OUT2" > "$TMP_ROOT/run2.out"
[ ! -e "$TMP_ROOT/network2.log" ] || fail "absent-key fallback did not call network"
grep -Fq "Status: \`pass\`" "$OUT2/report.md" || fail "absent-key fallback remains safe"

PATH="$FAKEBIN:$BASE_PATH" NETWORK_LOG="$TMP_ROOT/network3.log" env -u TYPESAFE_API_KEY \
  "$TOOL" --fixtures "$FIXTURES" --transport "$FAKE_TRANSPORT" --out-dir "$OUT3" > "$TMP_ROOT/run3.out"
cmp "$OUT1/ledger.jsonl" "$OUT3/ledger.jsonl" >/dev/null || fail "ledger is reproducible"

python3 - "$FIXTURES" "$BAD" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["transcripts"] = data["transcripts"][:30]
data["transcripts"][0]["questions"][0]["required_segment_ids"].append("missing-required-evidence")
json.dump(data, open(sys.argv[2], "w"))
PY
if "$TOOL" --fixtures "$BAD" --out-dir "$TMP_ROOT/bad-out" > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"; then
  fail "missing required evidence must fail evaluation"
fi
grep -Fq 'missing required segment ids' "$TMP_ROOT/bad.err" || fail "missing evidence failure is explicit"

pass "fm-jev-context-replay public interface preserves protected context offline"

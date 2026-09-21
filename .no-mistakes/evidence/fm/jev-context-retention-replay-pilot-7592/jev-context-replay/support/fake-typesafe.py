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

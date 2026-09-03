#!/usr/bin/env bash
# Behavior tests for the exceptional-worker-graph contract schema.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCHEMA="$ROOT/.agents/skills/exceptional-worker-graph/references/worker-graph.schema.json"

test_contract_schema_accepts_and_rejects_graph_packets() {
  python3 - "$SCHEMA" <<'PY'
from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path


class ValidationError(Exception):
    pass


schema = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))


def validate(schema_node, value, path="root"):
    if "oneOf" in schema_node:
        matches = 0
        errors = []
        for candidate in schema_node["oneOf"]:
            merged = {key: val for key, val in schema_node.items() if key != "oneOf"}
            merged.update(candidate)
            try:
                validate(merged, value, path)
                matches += 1
            except ValidationError as exc:
                errors.append(str(exc))
        if matches != 1:
            raise ValidationError(f"{path}: oneOf matched {matches}; errors={errors}")
        return

    expected_type = schema_node.get("type")
    if expected_type == "object":
        if not isinstance(value, dict):
            raise ValidationError(f"{path}: expected object")
        required = schema_node.get("required", [])
        for key in required:
            if key not in value:
                raise ValidationError(f"{path}: missing {key}")
        allowed = set(schema_node.get("properties", {}).keys())
        if schema_node.get("additionalProperties") is False:
            extra = sorted(set(value.keys()) - allowed)
            if extra:
                raise ValidationError(f"{path}: extra properties {extra}")
        for key, child in schema_node.get("properties", {}).items():
            if key in value:
                validate(child, value[key], f"{path}.{key}")
    elif expected_type == "array":
        if not isinstance(value, list):
            raise ValidationError(f"{path}: expected array")
        if len(value) < schema_node.get("minItems", 0):
            raise ValidationError(f"{path}: too few items")
        item_schema = schema_node.get("items")
        if item_schema:
            for index, item in enumerate(value):
                validate(item_schema, item, f"{path}[{index}]")
    elif expected_type == "string":
        if not isinstance(value, str):
            raise ValidationError(f"{path}: expected string")
        if len(value) < schema_node.get("minLength", 0):
            raise ValidationError(f"{path}: string too short")
        pattern = schema_node.get("pattern")
        if pattern and not re.match(pattern, value):
            raise ValidationError(f"{path}: pattern mismatch")
    elif expected_type == "integer":
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValidationError(f"{path}: expected integer")
        if value < schema_node.get("minimum", value):
            raise ValidationError(f"{path}: below minimum")
    elif expected_type == "boolean":
        if not isinstance(value, bool):
            raise ValidationError(f"{path}: expected boolean")

    if "enum" in schema_node and value not in schema_node["enum"]:
        raise ValidationError(f"{path}: enum mismatch")


valid = {
    "version": 1,
    "engagement": {
        "planner": "fable-5.1",
        "reason": "cross-project migration planning needs specialist adjudication",
        "call_budget": 3,
        "calls_used": 1,
        "packet_scope": "summaries of constraints and candidate ownership only",
    },
    "nodes": [
        {
            "id": "map-risk",
            "purpose": "map migration risks",
            "dependencies": [],
            "ownership_boundary": {
                "scope": "read-only project audit",
                "paths": ["docs/", "bin/"],
                "exclusive": True,
            },
            "worker": {
                "selected_profile": {
                    "harness": "codex",
                    "model": "gpt-5",
                    "effort": "high",
                    "profile_id": "planning-high",
                }
            },
            "expected_output": "risk table with direct evidence",
            "verification": ["run focused behavior tests"],
            "stop_condition": "stop after a bounded report or a captain-only decision",
            "parallel_safe": True,
        },
        {
            "id": "implement-contract",
            "purpose": "apply accepted contract changes",
            "dependencies": ["map-risk"],
            "ownership_boundary": {
                "scope": "tracked Firstmate instructions only",
                "paths": [".agents/skills/"],
                "exclusive": True,
            },
            "worker": {
                "unresolved_profile_requirement": "choose current best supported implementation profile at dispatch"
            },
            "expected_output": "committed change and PR-ready tests",
            "verification": ["no-mistakes validation"],
            "stop_condition": "stop for Firstmate validation before dispatch",
            "parallel_safe": False,
        },
    ],
}


def assert_valid(packet):
    validate(schema, packet)


def assert_invalid(packet, expected):
    try:
        validate(schema, packet)
    except ValidationError as exc:
        if expected not in str(exc):
            raise SystemExit(f"expected error containing {expected!r}, got {exc}")
        return
    raise SystemExit(f"packet unexpectedly passed; expected {expected}")


assert_valid(valid)

missing_parallel = copy.deepcopy(valid)
del missing_parallel["nodes"][0]["parallel_safe"]
assert_invalid(missing_parallel, "missing parallel_safe")

extra_authority = copy.deepcopy(valid)
extra_authority["nodes"][0]["merge_authority"] = True
assert_invalid(extra_authority, "extra properties")

ambiguous_worker = copy.deepcopy(valid)
ambiguous_worker["nodes"][0]["worker"]["unresolved_profile_requirement"] = "also pick later"
assert_invalid(ambiguous_worker, "oneOf matched 2")

unknown_worker_field = copy.deepcopy(valid)
unknown_worker_field["nodes"][0]["worker"]["can_spawn_directly"] = True
assert_invalid(unknown_worker_field, "extra properties")

empty_verification = copy.deepcopy(valid)
empty_verification["nodes"][0]["verification"] = []
assert_invalid(empty_verification, "too few items")

policy = schema["x-firstmate-policy"]
assert policy["routine_work"] == "unchanged"
assert policy["fable_5_1"]["eligible_roles"] == ["planner", "adjudicator"]
assert policy["fable_5_1"]["default_call_budget"] == 3
assert policy["fable_5_1"]["outside_implementation_graph"] is True
for gate in [
    "existing_worker_support",
    "quota_and_runway",
    "project_authority",
    "isolation",
    "delivery_contract",
    "safety_contract",
]:
    assert gate in policy["firstmate_validates_nodes_for"]
PY
  pass "exceptional-worker-graph schema accepts bounded graph packets and rejects unsafe shapes"
}

test_contract_schema_accepts_and_rejects_graph_packets

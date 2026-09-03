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


schema = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

ANNOTATION_KEYS = {"$schema", "title", "description"}


class ValidationError(Exception):
    def __init__(self, path, message):
        super().__init__(f"{path}: {message}")
        self.path = path


def join(path, key):
    return f"{path}/{key}"


def local_validate(node, value, path=""):
    unknown = sorted(
        key
        for key in node
        if key not in ANNOTATION_KEYS and not key.startswith("x-") and key not in {
            "type", "required", "properties", "additionalProperties", "items",
            "minItems", "minLength", "pattern", "minimum", "maximum", "enum",
            "const", "oneOf", "not", "if", "then", "else",
        }
    )
    if unknown:
        raise SystemExit(f"schema keyword(s) {unknown} at {path or '/'} are not supported by the fallback validator")

    expected_type = node.get("type")
    checks = {
        "object": dict,
        "array": list,
        "string": str,
        "integer": int,
        "boolean": bool,
    }
    if expected_type is not None:
        py_type = checks[expected_type]
        if not isinstance(value, py_type) or (expected_type == "integer" and isinstance(value, bool)):
            raise ValidationError(path, f"expected {expected_type}")

    if isinstance(value, dict):
        for key in node.get("required", []):
            if key not in value:
                raise ValidationError(path, f"missing {key}")
        props = node.get("properties", {})
        if node.get("additionalProperties") is False:
            extra = sorted(set(value) - set(props))
            if extra:
                raise ValidationError(path, f"extra properties {extra}")
        for key, child in props.items():
            if key in value:
                local_validate(child, value[key], join(path, key))
    if isinstance(value, list):
        if len(value) < node.get("minItems", 0):
            raise ValidationError(path, "too few items")
        if "items" in node:
            for index, item in enumerate(value):
                local_validate(node["items"], item, join(path, index))
    if isinstance(value, str):
        if len(value) < node.get("minLength", 0):
            raise ValidationError(path, "string too short")
        if "pattern" in node and not re.match(node["pattern"], value):
            raise ValidationError(path, "pattern mismatch")
    if isinstance(value, int) and not isinstance(value, bool):
        if value < node.get("minimum", value):
            raise ValidationError(path, "below minimum")
        if value > node.get("maximum", value):
            raise ValidationError(path, "above maximum")
    if "enum" in node and value not in node["enum"]:
        raise ValidationError(path, "enum mismatch")
    if "const" in node and value != node["const"]:
        raise ValidationError(path, "const mismatch")
    if "not" in node:
        try:
            local_validate(node["not"], value, path)
        except ValidationError:
            pass
        else:
            raise ValidationError(path, "matched forbidden schema")
    if "oneOf" in node:
        matches = 0
        for candidate in node["oneOf"]:
            try:
                local_validate(candidate, value, path)
                matches += 1
            except ValidationError:
                pass
        if matches != 1:
            raise ValidationError(path, f"oneOf matched {matches}")
    if "if" in node:
        try:
            local_validate(node["if"], value, path)
        except ValidationError:
            branch = node.get("else")
        else:
            branch = node.get("then")
        if branch is not None:
            local_validate(branch, value, path)


def failing_path(packet):
    """Return None when the packet validates, else the instance path that failed."""
    try:
        import jsonschema
    except ImportError:
        try:
            local_validate(schema, packet)
        except ValidationError as exc:
            return exc.path
        return None
    validator = jsonschema.Draft202012Validator(schema)
    validator.check_schema(schema)
    error = jsonschema.exceptions.best_match(validator.iter_errors(packet))
    if error is None:
        return None
    return "".join(f"/{part}" for part in error.absolute_path)


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
    path = failing_path(packet)
    if path is not None:
        raise SystemExit(f"packet unexpectedly rejected at {path!r}")


def assert_invalid(packet, expected_path):
    path = failing_path(packet)
    if path is None:
        raise SystemExit(f"packet unexpectedly passed; expected rejection at {expected_path!r}")
    if path != expected_path:
        raise SystemExit(f"expected rejection at {expected_path!r}, got {path!r}")


assert_valid(valid)

missing_parallel = copy.deepcopy(valid)
del missing_parallel["nodes"][0]["parallel_safe"]
assert_invalid(missing_parallel, "/nodes/0")

extra_authority = copy.deepcopy(valid)
extra_authority["nodes"][0]["merge_authority"] = True
assert_invalid(extra_authority, "/nodes/0")

ambiguous_worker = copy.deepcopy(valid)
ambiguous_worker["nodes"][0]["worker"]["unresolved_profile_requirement"] = "also pick later"
assert_invalid(ambiguous_worker, "/nodes/0/worker")

unknown_worker_field = copy.deepcopy(valid)
unknown_worker_field["nodes"][0]["worker"]["can_spawn_directly"] = True
assert_invalid(unknown_worker_field, "/nodes/0/worker")

empty_verification = copy.deepcopy(valid)
empty_verification["nodes"][0]["verification"] = []
assert_invalid(empty_verification, "/nodes/0/verification")

over_budget = copy.deepcopy(valid)
over_budget["engagement"]["call_budget"] = 4
assert_invalid(over_budget, "/engagement/call_budget")

declined_extra_calls = copy.deepcopy(over_budget)
declined_extra_calls["engagement"]["captain_authorized_extra_calls"] = False
assert_invalid(declined_extra_calls, "/engagement/call_budget")

captain_authorized = copy.deepcopy(over_budget)
captain_authorized["engagement"]["captain_authorized_extra_calls"] = True
assert_valid(captain_authorized)

at_cap = copy.deepcopy(valid)
at_cap["engagement"]["call_budget"] = 3
at_cap["engagement"]["calls_used"] = 3
assert_valid(at_cap)
PY
  pass "exceptional-worker-graph schema accepts bounded graph packets, rejects unsafe shapes, and caps Fable calls at three without captain authorization"
}

test_contract_schema_accepts_and_rejects_graph_packets

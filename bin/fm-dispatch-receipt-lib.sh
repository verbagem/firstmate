# shellcheck shell=bash
# fm-dispatch-receipt-lib.sh - the single-resolution typed dispatch receipt.
#
# bin/fm-dispatch-resolve.sh is the only model resolution for a task. When it
# runs on a task's data/<id>/brief.md it replaces state/<id>.dispatch-receipt
# with this run's answer; bin/fm-spawn.sh enforces that receipt and never
# resolves a second time, so two model calls can never disagree about one
# intake. docs/configuration.md "Typed dispatch resolution" owns the operator
# contract; this file owns the receipt format.
#
# Format (mode 0600, one key=value per line):
#   schema=fm-dispatch-receipt.v1
#   brief_sha256=<sha256 of the brief the answer was resolved from>
#   status=clear|ambiguous|escalate|error
#   harness=<h>  model=<m>  effort=<e>   (clear only; empty otherwise)
#   resolved_at=<epoch seconds>
# A receipt whose brief_sha256 no longer matches the brief is stale and is
# never enforced.

FM_DISPATCH_RECEIPT_SCHEMA=fm-dispatch-receipt.v1

fm_dispatch_receipt_path() {  # <state-dir> <task-id>
  printf '%s/%s.dispatch-receipt\n' "$1" "$2"
}

fm_dispatch_brief_sha() {  # <brief-file>
  [ -f "$1" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fm_dispatch_receipt_field() {  # <receipt> <key>
  local line
  line=$(grep -m1 "^$2=" "$1" 2>/dev/null) || return 1
  printf '%s\n' "${line#*=}"
}

# A profile token must be one shell word with no quoting surprises.
fm_dispatch_receipt_token_ok() {  # <value>
  case "$1" in
    *[!A-Za-z0-9._:/@+-]*) return 1 ;;
  esac
  return 0
}

fm_dispatch_receipt_write() {  # <receipt> <brief> <status> <harness> <model> <effort>
  local receipt=$1 brief=$2 status=$3 harness=$4 model=$5 effort=$6 sha tmp
  case "$status" in clear|ambiguous|escalate|error) ;; *) return 1 ;; esac
  fm_dispatch_receipt_token_ok "$harness" && fm_dispatch_receipt_token_ok "$model" \
    && fm_dispatch_receipt_token_ok "$effort" || return 1
  [ "$status" != clear ] || [ -n "$harness" ] || return 1
  sha=$(fm_dispatch_brief_sha "$brief") || return 1
  tmp=$(umask 077; mktemp "$receipt.XXXXXX") || return 1
  if printf 'schema=%s\nbrief_sha256=%s\nstatus=%s\nharness=%s\nmodel=%s\neffort=%s\nresolved_at=%s\n' \
      "$FM_DISPATCH_RECEIPT_SCHEMA" "$sha" "$status" "$harness" "$model" "$effort" "$(date +%s)" > "$tmp" \
    && mv -f "$tmp" "$receipt"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

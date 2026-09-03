#!/usr/bin/env bash
# fm-no-mistakes-attestation-body.sh - print the live PR body for the
# Require no-mistakes gate.
#
# `git push no-mistakes` pushes the head first and rewrites the PR body with
# the head-bound attestation a few seconds later, so the pull_request
# synchronize payload that starts the gate still carries the previous body.
# Judging that stale payload fails the check against a PR whose live body is
# already compliant. This polls the forge until the live body's attestation
# names <head-sha> (or the timeout lapses), then prints the last body seen so
# the pinned shared action still renders the real verdict.
#
# Usage: fm-no-mistakes-attestation-body.sh <owner/repo> <pr-number> <head-sha> [timeout-seconds] [interval-seconds]
set -eu

[ $# -ge 3 ] || { echo "usage: $0 <owner/repo> <pr-number> <head-sha> [timeout-seconds] [interval-seconds]" >&2; exit 2; }
repo=$1 pr=$2 head=$3 timeout=${4:-180} interval=${5:-10}
deadline=$(( $(date +%s) + timeout ))
body=""
while :; do
  body=$(gh api "repos/$repo/pulls/$pr" --jq '.body // ""') || body=""
  case $body in
    *no-mistakes-pipeline-attestation:v1*\"head_sha\":\""$head"\"*) break ;;
  esac
  # ponytail: fixed poll budget; the pipeline rewrites the body well under a minute after push.
  [ "$(date +%s)" -lt "$deadline" ] || break
  echo "PR #$pr body attestation does not yet bind $head; polling again in ${interval}s" >&2
  sleep "$interval"
done
printf '%s' "$body"

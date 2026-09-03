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
  if [ "$(date +%s)" -ge "$deadline" ]; then
    bound=$(printf '%s' "$body" | sed -n 's/.*no-mistakes-pipeline-attestation:v1.*"head_sha":"\([0-9a-f]*\)".*/\1/p' | head -n 1)
    echo "PR #$pr body attestation still binds ${bound:-no head} after ${timeout}s, not $head; a later push never passes on an older attestation, so re-run 'git push no-mistakes' to republish the body against the current head" >&2
    break
  fi
  echo "PR #$pr body attestation does not yet bind $head; polling again in ${interval}s" >&2
  sleep "$interval"
done
printf '%s' "$body"

#!/usr/bin/env bash
# Operator-facing demo of the recovered paused-monitoring behavior.
# Drives the real bin/fm-watch.sh + bin/fm-wake-drain.sh and prints what a
# firstmate captain actually sees in the wake queue. Reuses the scaffolding
# helpers already defined in tests/fm-watch-triage.test.sh.
set -u
REPO=${1:?usage: paused-monitoring-demo.sh <repo-root>}
# The scaffolding helpers (make_case/seen_sig/hash_text/wait_for_exit/reap/
# wait_poll_cycle) live in the test file's prelude and resolve sibling paths via
# BASH_SOURCE, so materialize that prelude next to them and drop it on exit.
PRELUDE="$REPO/tests/.fm-paused-demo-prelude.sh"
head -3167 "$REPO/tests/fm-watch-triage.test.sh" > "$PRELUDE"
trap 'rm -f "$PRELUDE"' EXIT
# shellcheck disable=SC1090
. "$PRELUDE"

show_queue() {  # <state> <label>
  printf '\n  wake queue as the captain reads it (%s):\n' "$2"
  if [ -s "$3/.wake-queue" ]; then
    awk -F '\t' '{ printf "    [%s] %s\n", $3, $5 }' "$3/.wake-queue"
  else
    printf '    (empty - nothing surfaced, the watcher absorbed the poll)\n'
  fi
}

backdate() { local f=$1 t=$2; if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$t" '+%Y%m%d%H%M.%S')" "$f"; else touch -m -d "@$t" "$f"; fi; }

echo "================================================================"
echo "SCENARIO A  live agent declares 'paused: waiting on an external dependency'"
echo "            expected: the captain is interrupted ONCE, immediately"
echo "================================================================"
dir=$(make_case demo-live-pause); state="$dir/state"; fakebin="$dir/fakebin"
window="demo:fm-gate"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
printf 'idle external-decision gate\n' > "$capture_file"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
printf 'paused [key=route]: waiting on an external dependency\n' > "$statusf"
sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
printf '%s' "$(hash_text 'idle external-decision gate')" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting on an external dependency' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$REPO/bin/fm-watch.sh" > "$dir/watch.out" &
pid=$!
if wait_for_exit "$pid" 100; then echo "  watcher exited -> captain re-armed on a live external-decision gate"
else reap "$pid"; echo "  !! watcher did NOT surface the live pause"; fi
show_queue "$state" "live declared pause" "$state"

echo
echo "================================================================"
echo "SCENARIO B  the same declared pause after its agent has EXITED"
echo "            expected: absorbed; at most one bounded recheck over 6 polls"
echo "================================================================"
dir=$(make_case demo-exited-pause); state="$dir/state"; fakebin="$dir/fakebin"
window="demo:fm-held"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
printf 'idle bare shell after agent exit\n' > "$capture_file"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
backdate "$statusf" $(( $(date +%s) - 500 ))
sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
printf '%s' "$(hash_text 'idle bare shell after agent exit')" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
for round in 1 2 3 4 5 6; do
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$REPO/bin/fm-watch.sh" >> "$dir/watch.out" &
  pid=$!; wait_poll_cycle "$state" "$pid" >/dev/null 2>&1; reap "$pid"
done
n=$(awk -F '\t' -v w="$window" '$3=="stale" && $4==w {c++} END{print c+0}' "$state/.wake-queue")
echo "  6 unchanged polls of an exited paused pane -> $n captain interruption(s)"
show_queue "$state" "exited declared pause" "$state"

echo
echo "================================================================"
echo "SCENARIO C  TWO paused panes go stale in the SAME scan"
echo "            expected: ONE watcher interruption, BOTH records queued"
echo "================================================================"
dir=$(make_case demo-batch); state="$dir/state"; fakebin="$dir/fakebin"
capture_file="$dir/pane.txt"; printf 'idle, waiting on external dependency\n' > "$capture_file"
back=$(( $(date +%s) - 500 ))
for item in alpha beta; do
  window="demo:fm-held-$item"; statusf="$state/held-$item.status"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-$item.meta"
  printf 'paused: waiting on the external dependency\n' > "$statusf"
  backdate "$statusf" "$back"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-${item}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle, waiting on external dependency')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
done
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="demo:fm-held-alpha demo:fm-held-beta" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$REPO/bin/fm-watch.sh" > "$dir/watch.out" &
pid=$!
wait_for_exit "$pid" 100 || reap "$pid"
echo "  watcher exits: $(grep -c . "$dir/watch.out") interruption line(s) emitted"
sed 's/^/    watcher stdout: /' "$dir/watch.out"
show_queue "$state" "two paused rechecks batched" "$state"
echo

# The prelude is also removed explicitly: the sourced test prelude installs its
# own EXIT trap, which replaces the one set above.
rm -f "$PRELUDE"

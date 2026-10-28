#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  {
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'cursor=\n'
  } > "$home/state/.inactive-outcome-reconcile"
  touch "$home/state/.last-heartbeat" "$home/state/home-summary.json"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$home/state/.watch.lock/pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=9999999 \
    FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=9999999 \
    FM_INACTIVE_RECONCILE_SECS=900 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_perl_timeout_fallback_honors_cleanup_bound_before_escalating() {
  local home fallback_bin tool tool_path status watcher_pid
  home=$(make_home perl-fallback)
  fallback_bin="$home/fallback-bin"
  mkdir -p "$home/root/bin" "$fallback_bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  for tool in bash dirname mktemp rm perl grep cat; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the Perl fallback fixture"
    ln -s "$tool_path" "$fallback_bin/$tool"
  done
  cat > "$home/root/bin/fm-watch.sh" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
$SIG{INT} = 'IGNORE';
open my $pid_file, '>', "$ENV{FM_HOME}/watcher.pid" or die "open pid file: $!";
printf {$pid_file} "%s\n", $$;
close $pid_file;
sleep 7;
open my $cleanup_file, '>', "$ENV{FM_HOME}/cleanup-reached" or die "open cleanup marker: $!";
print {$cleanup_file} "reached\n";
close $cleanup_file;
END {
  if (open my $exit_file, '>', "$ENV{FM_HOME}/natural-exit") {
    print {$exit_file} "natural\n";
  }
}
sleep 20;
PL
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-watch.sh"

  status=0
  PATH="$fallback_bin" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?

  expect_code 124 "$status" "Perl fallback checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "Perl fallback did not return a quiet checkpoint"
  [ -e "$home/cleanup-reached" ] || fail "the Perl fallback killed the watcher before its 8-second cleanup bound"
  [ ! -e "$home/natural-exit" ] || fail "the INT-ignoring watcher exited naturally instead of being killed"
  [ -s "$home/watcher.pid" ] || fail "the INT-ignoring watcher did not start"
  watcher_pid=$(cat "$home/watcher.pid")
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "the INT-ignoring watcher survived the Perl fallback escalation"
  fi
  pass "Perl fallback honors the cleanup bound before escalating an INT-ignoring direct watcher"
}

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  append_wake "$home/state" check buried 'check: unacknowledged durable wake' \
    || fail "could not append the unacknowledged durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first recovery checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "first checkpoint did not announce the pending recovery"
  marker=$(cat "$home/state/.watcher-down")
  case "$marker" in
    announced:downtime:*) ;;
    *) fail "first checkpoint did not leave an announced generation: $marker" ;;
  esac
  [ -s "$home/state/.wake-queue" ] \
    || fail "durable wake did not stay unacknowledged after the announcement"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?

  expect_code 124 "$status" "announced recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "announced recovery checkpoint did not supervise for its bound"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "announced recovery was reannounced by the next checkpoint"
  [ "$(cat "$home/state/.watcher-down")" = "$marker" ] \
    || fail "announced recovery checkpoint changed the outstanding generation"
  grep "$(printf '\tcheck\tburied\tcheck: unacknowledged durable wake')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "unacknowledged durable wake was not retained"
  pass "an announced recovery is not reannounced by the next foreground checkpoint"
}

test_never_announced_recovery_is_announced_once() {
  local home out err status
  home=$(make_home pending-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.1.aaa\n' > "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "pending recovery checkpoint exit"
  [ "$(grep -c '^check: rearm-resurface$' "$out" || true)" -eq 1 ] \
    || fail "never-announced recovery did not surface exactly once: $(cat "$out")"
  [ "$(cat "$home/state/.watcher-down")" = 'announced:downtime:unreported.1.aaa' ] \
    || fail "never-announced recovery did not retain its announced generation"
  pass "a never-announced recovery still surfaces once from a foreground checkpoint"
}

test_queue_append_during_checkpoint_still_resurfaces() {
  local home out err status checkpoint_pid
  home=$(make_home queue-append)
  out="$home/out.txt"
  err="$home/err.txt"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "queue-append checkpoint did not take the watcher lock"
  }
  append_wake "$home/state" check concurrent 'check: appended during checkpoint' \
    || fail "could not append a durable wake during the checkpoint"
  status=0
  wait "$checkpoint_pid" || status=$?

  expect_code 0 "$status" "queue-append checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "queue append during checkpoint did not resurface"
  grep "$(printf '\tcheck\tconcurrent\tcheck: appended during checkpoint')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "queue append was not retained durably after checkpoint recovery"
  pass "a queue append during a foreground checkpoint still resurfaces"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'done: synthetic wake\n' > "$home/state/demo.status"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=9999999 \
    FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=9999999 \
    FM_INACTIVE_RECONCILE_SECS=900 "$CHECKPOINT" --seconds 20 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=9999999 \
    FM_INACTIVE_RECONCILE_SECS=900 "$CHECKPOINT" --seconds 20 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_checkpoint_owns_a_blocked_run_state_probe_group() {
  local home state fakebin window task capture key status probe_pid child_pid i
  home=$(make_case run-state-probe-group)
  state="$home/state"
  fakebin="$home/fakebin"
  mkdir -p "$home/data" "$home/config"
  window='test:fm-run-state-probe'
  task=run-state-probe
  capture="$home/pane.txt"
  printf 'idle while validation state is read\n' > "$capture"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/$task.meta"
  printf 'paused: awaiting validation\n' > "$state/$task.status"
  prime_status_seen "$state" "$state/$task.status"

  # First settle the pane into the already-paused steady state. The regression
  # is the later capped run-state probe, not first-sighting classification.
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting validation' \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 2 > "$home/prime.out" 2> "$home/prime.err" || status=$?
  expect_code 124 "$status" "run-state probe fixture setup: $(cat "$home/prime.out" "$home/prime.err")"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$home/prime-drain.out" 2> "$home/prime-drain.err" \
    || fail "could not present the intentional setup checkpoint recovery"
  ack_drain_err "$state" "$home/prime-drain.err" >/dev/null \
    || fail "could not acknowledge the intentional setup checkpoint recovery"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  : > "$state/.paused-$key"
  date +%s > "$state/.paused-rechecked-$key"
  rm -f "$state/.run-state-probed-$key" "$state/.run-state-probed-terminal-$key"

  cat > "$fakebin/fm-crew-state-blocked.sh" <<'SH'
#!/usr/bin/env bash
trap '' HUP INT TERM
printf '%s\n' "$$" > "$FM_PROBE_PID_FILE"
(
  trap '' HUP INT TERM
  printf '%s\n' "$$" > "$FM_PROBE_CHILD_PID_FILE"
  while :; do sleep 30; done
) &
wait "$!"
SH
  chmod +x "$fakebin/fm-crew-state-blocked.sh"

  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state-blocked.sh" \
    FM_PROBE_PID_FILE="$home/probe.pid" FM_PROBE_CHILD_PID_FILE="$home/probe-child.pid" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 3 > "$home/out.txt" 2> "$home/err.txt" || status=$?

  expect_code 124 "$status" "blocked run-state probe checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3s" \
    "blocked run-state probe did not return the quiet checkpoint contract"
  [ -s "$home/probe.pid" ] && [ -s "$home/probe-child.pid" ] \
    || fail "the checkpoint never exercised the blocked run-state probe and its child"
  probe_pid=$(cat "$home/probe.pid")
  child_pid=$(cat "$home/probe-child.pid")
  i=0
  while [ "$i" -lt 30 ] && { is_live_non_zombie "$probe_pid" || is_live_non_zombie "$child_pid"; }; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$probe_pid" || fail "the blocked run-state probe survived checkpoint cleanup"
  ! is_live_non_zombie "$child_pid" || fail "the blocked run-state probe child survived checkpoint cleanup"
  assert_absent "$state/.watch.lock/pid" "watch lock pid survived blocked run-state probe cleanup"
  pass "checkpoint owns and cleans a blocked run-state probe process group"
}

run_gnu_timeout_int_case() {  # <name> <code-root>
  local name=$1 code_root=$2 checkpoint home state fakebin window task capture started ended real_tr
  local i pid alive=0
  checkpoint="$code_root/bin/fm-watch-checkpoint.sh"
  home=$(make_case "$name")
  state="$home/state"
  fakebin="$home/fakebin"
  mkdir -p "$home/data" "$home/config"
  window='test:fm-gnu-timeout-int'
  task=gnu-timeout-int
  capture="$home/pane.txt"
  printf 'idle while validation state is read\n' > "$capture"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/$task.meta"
  printf 'paused: awaiting validation\n' > "$state/$task.status"
  prime_status_seen "$state" "$state/$task.status"
  printf 'done run-id=run-a' > "$state/.run-state-surfaced-$task"
  : > "$home/crew-state.log"
  : > "$home/probe-descendants.log"

  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
[ -z "${FM_FAKE_CREW_STATE_LOG:-}" ] || printf '%s\n' "$id" >> "$FM_FAKE_CREW_STATE_LOG"
(
  trap '' HUP INT TERM
  while :; do sleep 30; done
) &
printf '%s\n' "$!" >> "$FM_PROBE_DESCENDANT_PID_FILE"
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
SH
  chmod +x "$fakebin/fm-crew-state.sh"

  real_tr=$(command -v tr) || fail "could not locate tr for GNU timeout regression"
  cat > "$fakebin/tr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 2 ] && [ "$1" = ':/.' ] && [ "$2" = '___' ] \
  && (set -C; : > "$FM_INT_WINDOW_ONCE") 2>/dev/null; then
  trap '' INT
  : > "$FM_INT_WINDOW_ENTERED"
  sleep 3
fi
exec "$FM_REAL_TR" "$@"
SH
  chmod +x "$fakebin/tr"

  GNU_TIMEOUT_CASE_STATUS=0
  started=$(date +%s)
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE_LOG="$home/crew-state.log" \
    FM_PROBE_DESCENDANT_PID_FILE="$home/probe-descendants.log" \
    FM_FAKE_CREW_STATE='state: done · source: run-step · run-id=run-a' \
    FM_INT_WINDOW_ONCE="$home/int-window-once" FM_INT_WINDOW_ENTERED="$home/int-window-entered" \
    FM_REAL_TR="$real_tr" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$checkpoint" --seconds 2 > "$home/out.txt" 2> "$home/err.txt" || GNU_TIMEOUT_CASE_STATUS=$?
  ended=$(date +%s)
  GNU_TIMEOUT_CASE_ELAPSED=$((ended - started))
  GNU_TIMEOUT_CASE_HOME=$home
  GNU_TIMEOUT_CASE_PROBES=$(awk 'END { print NR + 0 }' "$home/crew-state.log" 2>/dev/null)
  GNU_TIMEOUT_CASE_DESCENDANTS=$(awk 'END { print NR + 0 }' "$home/probe-descendants.log" 2>/dev/null)
  i=0
  while [ "$i" -lt 30 ]; do
    alive=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      is_live_non_zombie "$pid" && alive=$((alive + 1))
    done < "$home/probe-descendants.log"
    [ "$alive" -gt 0 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  GNU_TIMEOUT_CASE_DESCENDANTS_ALIVE=$alive
  GNU_TIMEOUT_CASE_LOCK_PRESENT=0
  [ ! -e "$state/.watch.lock/pid" ] || GNU_TIMEOUT_CASE_LOCK_PRESENT=1
  GNU_TIMEOUT_CASE_ENTERED=0
  [ ! -e "$home/int-window-entered" ] || GNU_TIMEOUT_CASE_ENTERED=1
  GNU_TIMEOUT_CASE_QUIET=0
  grep -Fqx 'checkpoint: no actionable wake within 2s' "$home/out.txt" 2>/dev/null \
    && GNU_TIMEOUT_CASE_QUIET=1
  printf '# GNU timeout leg=%s rc=%s probes=%s elapsed_seconds=%s descendants=%s descendants_alive=%s lock_present=%s\n' \
    "$name" "$GNU_TIMEOUT_CASE_STATUS" "$GNU_TIMEOUT_CASE_PROBES" \
    "$GNU_TIMEOUT_CASE_ELAPSED" "$GNU_TIMEOUT_CASE_DESCENDANTS" \
    "$GNU_TIMEOUT_CASE_DESCENDANTS_ALIVE" "$GNU_TIMEOUT_CASE_LOCK_PRESENT"
  if [ "$alive" -gt 0 ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done < "$home/probe-descendants.log"
  fi
}

test_gnu_timeout_int_stops_before_another_run_state_probe() {
  local baseline=fd09a28216ddd5b00d8e1953a3b87134c20d1d00
  local old_root new_checkpoint_old_watcher_root old_archive timeout_bin timeout_version timeout_sha
  local old_checkpoint_sha old_watcher_sha current_checkpoint_sha current_watcher_sha
  local a_checkpoint_sha a_watcher_sha b_checkpoint_sha b_watcher_sha c_checkpoint_sha c_watcher_sha
  local a_status a_probes a_descendants a_entered
  local b_status b_probes b_elapsed b_descendants b_alive b_lock b_entered b_quiet
  local c_status c_probes c_elapsed c_descendants c_alive c_lock c_entered c_quiet
  local proof_errors=0

  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] \
    || fail "GNU timeout paired proof requires one matched Linux x86_64 execution"
  command -v timeout >/dev/null 2>&1 \
    || fail "GNU timeout paired proof requires timeout on PATH"
  timeout --version 2>/dev/null | head -n 1 | grep -qi coreutils \
    || fail "GNU timeout paired proof requires the coreutils implementation"
  command -v sha256sum >/dev/null 2>&1 \
    || fail "GNU timeout paired proof requires sha256sum"

  timeout_bin=$(command -v timeout)
  timeout_version=$("$timeout_bin" --version | head -n 1)
  timeout_sha=$(sha256sum "$timeout_bin" | awk '{print $1}')
  printf '# GNU timeout executable=%s sha256=%s version=%s\n' \
    "$timeout_bin" "$timeout_sha" "$timeout_version"

  old_root="$TMP_ROOT/gnu-timeout-old-root"
  new_checkpoint_old_watcher_root="$TMP_ROOT/gnu-timeout-new-checkpoint-old-watcher-root"
  old_archive="$TMP_ROOT/gnu-timeout-old-bin.tar"
  mkdir -p "$old_root" "$new_checkpoint_old_watcher_root"
  git -C "$ROOT" archive --format=tar --output="$old_archive" "$baseline" bin \
    || fail "could not archive immutable $baseline bin/ for the paired proof"
  tar -xf "$old_archive" -C "$old_root" \
    || fail "could not materialize immutable $baseline bin/ for the paired proof"
  cp -R "$old_root/bin" "$new_checkpoint_old_watcher_root/bin"
  cp "$ROOT/bin/fm-watch-checkpoint.sh" \
    "$new_checkpoint_old_watcher_root/bin/fm-watch-checkpoint.sh"

  old_checkpoint_sha=$(git -C "$ROOT" show "$baseline:bin/fm-watch-checkpoint.sh" | sha256sum | awk '{print $1}')
  old_watcher_sha=$(git -C "$ROOT" show "$baseline:bin/fm-watch.sh" | sha256sum | awk '{print $1}')
  current_checkpoint_sha=$(sha256sum "$ROOT/bin/fm-watch-checkpoint.sh" | awk '{print $1}')
  current_watcher_sha=$(sha256sum "$ROOT/bin/fm-watch.sh" | awk '{print $1}')
  a_checkpoint_sha=$(sha256sum "$old_root/bin/fm-watch-checkpoint.sh" | awk '{print $1}')
  a_watcher_sha=$(sha256sum "$old_root/bin/fm-watch.sh" | awk '{print $1}')
  b_checkpoint_sha=$(sha256sum "$new_checkpoint_old_watcher_root/bin/fm-watch-checkpoint.sh" | awk '{print $1}')
  b_watcher_sha=$(sha256sum "$new_checkpoint_old_watcher_root/bin/fm-watch.sh" | awk '{print $1}')
  c_checkpoint_sha=$(sha256sum "$ROOT/bin/fm-watch-checkpoint.sh" | awk '{print $1}')
  c_watcher_sha=$(sha256sum "$ROOT/bin/fm-watch.sh" | awk '{print $1}')
  printf '# GNU timeout leg=A checkpoint_sha256=%s watcher_sha256=%s\n' "$a_checkpoint_sha" "$a_watcher_sha"
  printf '# GNU timeout leg=B checkpoint_sha256=%s watcher_sha256=%s\n' "$b_checkpoint_sha" "$b_watcher_sha"
  printf '# GNU timeout leg=C checkpoint_sha256=%s watcher_sha256=%s\n' "$c_checkpoint_sha" "$c_watcher_sha"

  [ "$a_checkpoint_sha" = "$old_checkpoint_sha" ] || { echo "not ok - leg A checkpoint is not immutable $baseline" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$a_watcher_sha" = "$old_watcher_sha" ] || { echo "not ok - leg A watcher is not immutable $baseline" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_checkpoint_sha" = "$current_checkpoint_sha" ] || { echo "not ok - leg B checkpoint is not current" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_watcher_sha" = "$old_watcher_sha" ] || { echo "not ok - leg B watcher is not immutable $baseline" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_checkpoint_sha" = "$current_checkpoint_sha" ] || { echo "not ok - leg C checkpoint is not current" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_watcher_sha" = "$current_watcher_sha" ] || { echo "not ok - leg C watcher is not current" >&2; proof_errors=$((proof_errors + 1)); }

  run_gnu_timeout_int_case A "$old_root"
  a_status=$GNU_TIMEOUT_CASE_STATUS; a_probes=$GNU_TIMEOUT_CASE_PROBES
  a_descendants=$GNU_TIMEOUT_CASE_DESCENDANTS; a_entered=$GNU_TIMEOUT_CASE_ENTERED

  run_gnu_timeout_int_case B "$new_checkpoint_old_watcher_root"
  b_status=$GNU_TIMEOUT_CASE_STATUS; b_probes=$GNU_TIMEOUT_CASE_PROBES
  b_elapsed=$GNU_TIMEOUT_CASE_ELAPSED; b_descendants=$GNU_TIMEOUT_CASE_DESCENDANTS
  b_alive=$GNU_TIMEOUT_CASE_DESCENDANTS_ALIVE; b_lock=$GNU_TIMEOUT_CASE_LOCK_PRESENT
  b_entered=$GNU_TIMEOUT_CASE_ENTERED; b_quiet=$GNU_TIMEOUT_CASE_QUIET

  run_gnu_timeout_int_case C "$ROOT"
  c_status=$GNU_TIMEOUT_CASE_STATUS; c_probes=$GNU_TIMEOUT_CASE_PROBES
  c_elapsed=$GNU_TIMEOUT_CASE_ELAPSED; c_descendants=$GNU_TIMEOUT_CASE_DESCENDANTS
  c_alive=$GNU_TIMEOUT_CASE_DESCENDANTS_ALIVE; c_lock=$GNU_TIMEOUT_CASE_LOCK_PRESENT
  c_entered=$GNU_TIMEOUT_CASE_ENTERED; c_quiet=$GNU_TIMEOUT_CASE_QUIET

  [ "$a_status" -eq 137 ] || { echo "not ok - leg A baseline is INVALID: expected rc=137, got $a_status" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$a_probes" -gt 1 ] || { echo "not ok - leg A baseline is INVALID: expected a post-INT probe, got $a_probes probes" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$a_entered" -eq 1 ] || { echo "not ok - leg A never entered the INT command-substitution window" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$a_descendants" -gt 0 ] || { echo "not ok - leg A never started a real probe descendant" >&2; proof_errors=$((proof_errors + 1)); }

  [ "$b_status" -eq 124 ] || { echo "not ok - leg B expected rc=124, got $b_status" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_probes" -eq 1 ] || { echo "not ok - leg B started $b_probes probes; expected one" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_elapsed" -le 5 ] || { echo "not ok - leg B took ${b_elapsed}s past its 2s deadline" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_entered" -eq 1 ] && [ "$b_quiet" -eq 1 ] || { echo "not ok - leg B missed the INT window or quiet checkpoint contract" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_descendants" -gt 0 ] && [ "$b_alive" -eq 0 ] || { echo "not ok - leg B descendant cleanup failed: started=$b_descendants alive=$b_alive" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$b_lock" -eq 0 ] || { echo "not ok - leg B left the watcher lock behind" >&2; proof_errors=$((proof_errors + 1)); }

  [ "$c_status" -eq 124 ] || { echo "not ok - leg C expected rc=124, got $c_status" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_probes" -eq 1 ] || { echo "not ok - leg C started $c_probes probes; expected one" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_elapsed" -le 5 ] || { echo "not ok - leg C took ${c_elapsed}s past its 2s deadline" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_entered" -eq 1 ] && [ "$c_quiet" -eq 1 ] || { echo "not ok - leg C missed the INT window or quiet checkpoint contract" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_descendants" -gt 0 ] && [ "$c_alive" -eq 0 ] || { echo "not ok - leg C descendant cleanup failed: started=$c_descendants alive=$c_alive" >&2; proof_errors=$((proof_errors + 1)); }
  [ "$c_lock" -eq 0 ] || { echo "not ok - leg C left the watcher lock behind" >&2; proof_errors=$((proof_errors + 1)); }

  [ "$proof_errors" -eq 0 ] || fail "GNU timeout paired proof failed $proof_errors assertion(s); every leg ran"
  pass "GNU timeout paired proof: immutable old/old fails, while new/old and final new/new exit 124 with descendants and locks cleaned"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

if [ "${FM_GNU_TIMEOUT_PAIRED_PROOF_ONLY:-0}" = 1 ]; then
  test_gnu_timeout_int_stops_before_another_run_state_probe
  exit 0
fi

test_quiet_checkpoint_exits_124_cleanly
test_perl_timeout_fallback_honors_cleanup_bound_before_escalating
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_checkpoint_owns_a_blocked_run_state_probe_group
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_checkpoint_ends_quietly_at_its_bound

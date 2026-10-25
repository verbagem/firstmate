#!/usr/bin/env bash
# Tests for the tracked Pi task-recap extension (.pi/extensions/fm-task-recap.ts)
# and the fm-spawn.sh wiring that loads it: the real fm-spawn against a fake
# tmux and an isolated worktree proves the launch command it constructs, and a
# plain Node host drives the real tracked extension file (with the real
# bin/fm-pi-recap.sh behind it) to prove the widget behavior - dedup, the
# hasUI gate, absent-env-var safety, and home isolation - through its public
# pi.on()/ctx.ui.setWidget() interface, never by reading the extension's
# source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
EXT="$ROOT/.pi/extensions/fm-task-recap.ts"
TMP_ROOT=$(fm_test_tmproot fm-task-recap-extension)

# --- spawn-wiring fixtures (mirrors tests/fm-secondmate-harness.test.sh's
# make_launch_capturing_tmux and tests/fm-busy-adapter-wiring.test.sh's
# make_spawn_case) ---------------------------------------------------------

make_launch_capturing_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi claude
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness> <id> -> "<home>|<proj>|<wt>|<fakebin>"
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_launch_capturing_tmux "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_ship_pi_spawn_wires_the_recap_extension_and_env_vars() {
  local rec home proj wt fakebin id=recap-wire-ship-1 launchlog out cmd state_real
  rec=$(make_spawn_case wire-ship pi "$id")
  IFS='|' read -r home proj wt fakebin <<<"$rec"
  launchlog="$TMP_ROOT/wire-ship.launch"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "pi ship spawn should succeed: $out"
  assert_present "$launchlog" "no launch command was captured"
  cmd=$(cat "$launchlog")
  state_real=$(cd "$home/state" && pwd -P)
  # fm-spawn.sh shell_quotes every substituted path, so the captured launch
  # text carries them single-quoted.
  assert_contains "$cmd" "-e '$ROOT/.pi/extensions/fm-task-recap.ts'" "ship pi launch must load the tracked recap extension"
  assert_contains "$cmd" "FM_RECAP_TASK_ID='$id'" "ship pi launch must set FM_RECAP_TASK_ID"
  assert_contains "$cmd" "FM_RECAP_STATE_DIR='$state_real'" "ship pi launch must set FM_RECAP_STATE_DIR"
  assert_contains "$cmd" "FM_RECAP_DATA_DIR='$home/data'" "ship pi launch must set FM_RECAP_DATA_DIR"
  pass "a ship pi spawn's launch command loads fm-task-recap.ts with its task's FM_RECAP_* env vars"
}

test_secondmate_pi_spawn_never_wires_the_recap_extension() {
  local case_dir primary_home sm_home id=recap-wire-secondmate-1 fakebin launchlog out cmd
  case_dir="$TMP_ROOT/wire-secondmate"
  primary_home="$case_dir/primary-home"
  sm_home="$case_dir/sm-home"
  fakebin=$(make_launch_capturing_tmux "$case_dir/fake")
  mkdir -p "$primary_home/config" "$primary_home/state" "$primary_home/data" "$primary_home/projects"
  touch "$primary_home/state/.last-watcher-beat"
  # validate_firstmate_home_for_spawn needs the seed marker, AGENTS.md, bin/,
  # and a charter (mirrors tests/fm-secondmate-harness.test.sh's make_seeded_home).
  mkdir -p "$sm_home/bin" "$sm_home/data"
  printf '# Firstmate\n' > "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  printf 'charter\n' > "$sm_home/data/charter.md"
  launchlog="$TMP_ROOT/wire-secondmate.launch"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$primary_home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_LAUNCH_LOG="$launchlog" TMUX="fake,1,0" GROK_HOME="$primary_home/grok-home" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$sm_home" --harness pi --secondmate 2>&1)
  expect_code 0 $? "pi secondmate spawn should succeed: $out"
  assert_present "$launchlog" "no launch command was captured"
  cmd=$(cat "$launchlog")
  assert_not_contains "$cmd" "fm-task-recap.ts" "a secondmate is a firstmate instance, not a task - it must never load the recap widget"
  assert_not_contains "$cmd" "FM_RECAP_" "a secondmate launch must carry no FM_RECAP_* env var"
  pass "a pi secondmate spawn never loads fm-task-recap.ts or sets any FM_RECAP_* var"
}

test_other_harness_spawn_is_unaffected() {
  local rec home proj wt fakebin id=recap-wire-claude-1 launchlog out cmd
  rec=$(make_spawn_case wire-claude claude "$id")
  IFS='|' read -r home proj wt fakebin <<<"$rec"
  launchlog="$TMP_ROOT/wire-claude.launch"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude ship spawn should succeed: $out"
  assert_present "$launchlog" "no launch command was captured"
  cmd=$(cat "$launchlog")
  assert_not_contains "$cmd" "fm-task-recap.ts" "a non-Pi harness must never reference the Pi recap extension"
  assert_not_contains "$cmd" "FM_RECAP_" "a non-Pi harness launch must carry no FM_RECAP_* var"
  pass "a non-Pi harness (claude) spawn is completely unaffected by the recap wiring"
}

# --- widget behavior (drives the real tracked extension + real fm-pi-recap.sh) --

# drive_recap_ext <task-id> <state-dir> <data-dir> <hasui:0|1> <events-csv>:
# import the real extension once, fire the named lifecycle events in order,
# and print the JSON array of every ctx.ui.setWidget(key, lines, opts) call
# observed (empty array when none fired).
drive_recap_ext() {
  EXT="$EXT" FM_RECAP_TASK_ID="$1" FM_RECAP_STATE_DIR="$2" FM_RECAP_DATA_DIR="$3" \
    HASUI="$4" EVENTS="$5" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = {};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const calls = [];
const ctx = {
  hasUI: process.env.HASUI !== "0",
  ui: { setWidget: (key, lines, opts) => { calls.push({ key, lines, opts }); } },
};
for (const ev of process.env.EVENTS.split(",")) {
  await handlers[ev]({}, ctx);
  await mod.__fmTaskRecapTest.settle();
}
console.log(JSON.stringify(calls));
EOF
}

widget_call_count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))" <<<"$1"; }
widget_first_lines() { python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)[0]['lines']))" <<<"$1"; }
widget_key() { python3 -c "import json,sys; print(json.load(sys.stdin)[0]['key'])" <<<"$1"; }
widget_placement() { python3 -c "import json,sys; print(json.load(sys.stdin)[0]['opts']['placement'])" <<<"$1"; }

test_extension_renders_widget_on_session_start() {
  local state data id=recap-ext-basic out calls
  state="$TMP_ROOT/ext-basic/state"; data="$TMP_ROOT/ext-basic/data"
  mkdir -p "$state" "$data"
  printf -- '- [ ] %s - Fix the login bug (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id" > "$data/backlog.md"
  printf 'working: reproduced the bug\n' > "$state/$id.status"
  out=$(drive_recap_ext "$id" "$state" "$data" 1 session_start) || fail "drive failed: $out"
  calls=$(printf '%s' "$out" | tail -1)
  [ "$(widget_call_count "$calls")" = 1 ] || fail "expected exactly one setWidget call on session_start, got: $calls"
  [ "$(widget_key "$calls")" = "fm-task-recap" ] || fail "unexpected widget key: $calls"
  [ "$(widget_placement "$calls")" = "belowEditor" ] || fail "expected belowEditor placement: $calls"
  assert_contains "$(widget_first_lines "$calls")" "Fix the login bug" "widget lines should include the task title"
  assert_contains "$(widget_first_lines "$calls")" "In progress: reproduced the bug" "widget lines should include the current phase"
  pass "session_start renders the recap widget with the task's title and current phase"
}

test_extension_skips_unchanged_rerenders() {
  local state data id=recap-ext-dedup out calls count1 count2
  state="$TMP_ROOT/ext-dedup/state"; data="$TMP_ROOT/ext-dedup/data"
  mkdir -p "$state" "$data"
  printf -- '- [ ] %s - Fix the login bug (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id" > "$data/backlog.md"
  printf 'working: reproduced the bug\n' > "$state/$id.status"
  # session_start renders once; a turn_end with NO status-file change must not
  # render again (no unchanged noise); a following turn_end with a real
  # status-file change must render a third time.
  out=$(drive_recap_ext "$id" "$state" "$data" 1 session_start,turn_end) || fail "drive failed: $out"
  calls=$(printf '%s' "$out" | tail -1)
  count1=$(widget_call_count "$calls")
  [ "$count1" = 1 ] || fail "an unchanged turn_end must not add a second setWidget call, got $count1 calls: $calls"

  printf 'working: fix implemented\n' >> "$state/$id.status"
  out=$(drive_recap_ext "$id" "$state" "$data" 1 turn_end) || fail "second drive failed: $out"
  calls=$(printf '%s' "$out" | tail -1)
  count2=$(widget_call_count "$calls")
  [ "$count2" = 1 ] || fail "a genuinely changed status must render again in a fresh process, got $count2 calls: $calls"
  assert_contains "$(widget_first_lines "$calls")" "fix implemented" "the re-render must reflect the new phase"
  pass "an unchanged status file produces no repeat widget call, while a real change always renders"
}

test_turn_handlers_do_not_block_on_the_render() {
  local state data id=recap-ext-detached out
  state="$TMP_ROOT/ext-detached/state"; data="$TMP_ROOT/ext-detached/data"
  mkdir -p "$state" "$data"
  printf -- '- [ ] %s - Fix the login bug (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id" > "$data/backlog.md"
  printf 'working: reproduced the bug\n' > "$state/$id.status"
  # turn_start/turn_end must return synchronously (no promise handed back to
  # Pi) while the widget still lands once the detached render settles.
  out=$(EXT="$EXT" FM_RECAP_TASK_ID="$id" FM_RECAP_STATE_DIR="$state" FM_RECAP_DATA_DIR="$data" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = {};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const calls = [];
const ctx = { hasUI: true, ui: { setWidget: (key, lines) => { calls.push({ key, lines }); } } };
const results = {};
for (const ev of ["turn_start", "turn_end"]) {
  const before = calls.length;
  const r = handlers[ev]({}, ctx);
  results[ev] = { returnsPromise: r instanceof Promise, renderedAtReturn: calls.length - before };
  await mod.__fmTaskRecapTest.settle();
}
console.log(JSON.stringify({ results, finalCalls: calls.length, lines: calls[0]?.lines ?? [] }));
EOF
) || fail "drive failed: $out"
  local json; json=$(printf '%s' "$out" | tail -1)
  python3 - "$json" <<'PY2' || fail "turn handlers must not hand Pi a render promise: $json"
import json,sys
d=json.loads(sys.argv[1])
for ev in ("turn_start","turn_end"):
    assert d["results"][ev]["returnsPromise"] is False, ev
    assert d["results"][ev]["renderedAtReturn"] == 0, ev
assert d["finalCalls"] == 1, d
assert any("In progress: reproduced the bug" in l for l in d["lines"]), d
PY2
  pass "turn_start/turn_end return synchronously and the widget still renders once the detached render settles"
}

test_extension_respects_hasui_gate() {
  local state data id=recap-ext-nohasui out calls
  state="$TMP_ROOT/ext-nohasui/state"; data="$TMP_ROOT/ext-nohasui/data"
  mkdir -p "$state" "$data"
  printf -- '- [ ] %s - Fix the login bug (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id" > "$data/backlog.md"
  out=$(drive_recap_ext "$id" "$state" "$data" 0 session_start) || fail "drive failed: $out"
  calls=$(printf '%s' "$out" | tail -1)
  [ "$(widget_call_count "$calls")" = 0 ] || fail "ctx.hasUI=false must never call setWidget, got: $calls"
  pass "the widget never renders when ctx.hasUI is false (print/non-interactive mode)"
}

test_extension_noop_when_recap_env_vars_absent() {
  local out calls
  out=$(EXT="$EXT" HASUI=1 EVENTS=session_start node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = {};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const calls = [];
const ctx = { hasUI: true, ui: { setWidget: (key, lines, opts) => { calls.push({ key, lines, opts }); } } };
for (const ev of process.env.EVENTS.split(",")) { await handlers[ev]({}, ctx); await mod.__fmTaskRecapTest.settle(); }
console.log(JSON.stringify(calls));
EOF
) || fail "drive failed: $out"
  calls=$(printf '%s' "$out" | tail -1)
  [ "$(widget_call_count "$calls")" = 0 ] || fail "absent FM_RECAP_* env vars must never call setWidget, got: $calls"
  pass "the extension is a safe no-op (never throws, never renders) when FM_RECAP_* env vars are absent, matching an unwired non-Pi launch"
}

test_extension_never_throws_when_the_recap_script_is_missing() {
  local out calls
  out=$(drive_recap_ext "recap-ext-missingscript" "$TMP_ROOT/does-not-exist-state" "$TMP_ROOT/does-not-exist-data" 1 session_start,turn_start,turn_end) || fail "drive must not throw: $out"
  pass "a broken or missing recap script degrades to no widget update rather than throwing (inert on failure)"
}

test_two_homes_never_cross_contaminate() {
  local state_a data_a state_b data_b out_a out_b calls_a calls_b
  state_a="$TMP_ROOT/home-a/state"; data_a="$TMP_ROOT/home-a/data"
  state_b="$TMP_ROOT/home-b/state"; data_b="$TMP_ROOT/home-b/data"
  mkdir -p "$state_a" "$data_a" "$state_b" "$data_b"
  # Deliberately reuse the SAME task id across two different homes - only the
  # state/data directories distinguish them, exactly as two Firstmate homes
  # (or a primary and a secondmate) would.
  local id=shared-task-id
  printf -- '- [ ] %s - Home A task (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id" > "$data_a/backlog.md"
  printf 'working: home A progress\n' > "$state_a/$id.status"
  printf -- '- [ ] %s - Home B task (repo: demo) (kind: ship) (since 2026-08-01)\n' "$id" > "$data_b/backlog.md"
  printf 'blocked: home B is stuck\n' > "$state_b/$id.status"

  out_a=$(drive_recap_ext "$id" "$state_a" "$data_a" 1 session_start) || fail "home A drive failed: $out_a"
  calls_a=$(printf '%s' "$out_a" | tail -1)
  out_b=$(drive_recap_ext "$id" "$state_b" "$data_b" 1 session_start) || fail "home B drive failed: $out_b"
  calls_b=$(printf '%s' "$out_b" | tail -1)

  assert_contains "$(widget_first_lines "$calls_a")" "Home A task" "home A must render its own title"
  assert_not_contains "$(widget_first_lines "$calls_a")" "Home B" "home A must never see home B's data"
  assert_contains "$(widget_first_lines "$calls_b")" "Home B task" "home B must render its own title"
  assert_not_contains "$(widget_first_lines "$calls_b")" "Home A" "home B must never see home A's data"
  pass "two homes sharing the same task id never read or leak each other's recap data"
}

test_ship_pi_spawn_wires_the_recap_extension_and_env_vars
test_secondmate_pi_spawn_never_wires_the_recap_extension
test_other_harness_spawn_is_unaffected
test_extension_renders_widget_on_session_start
test_turn_handlers_do_not_block_on_the_render
test_extension_skips_unchanged_rerenders
test_extension_respects_hasui_gate
test_extension_noop_when_recap_env_vars_absent
test_extension_never_throws_when_the_recap_script_is_missing
test_two_homes_never_cross_contaminate

echo "all fm-task-recap-extension tests passed"

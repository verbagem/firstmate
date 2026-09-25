#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
windows_dir=${FM_FAKE_TMUX_WINDOW_DIR:-}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "$windows_dir" ] && [ -d "$windows_dir" ]; then
      for f in "$windows_dir"/*; do
        [ -f "$f" ] || continue
        basename -- "$f"
      done
    fi
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  new-window)
    if [ -n "$windows_dir" ]; then
      name=
      prev=
      for a in "$@"; do
        if [ "$prev" = "-n" ]; then
          name=$a
          break
        fi
        prev=$a
      done
      [ -n "$name" ] || exit 1
      mkdir -p "$windows_dir"
      [ ! -e "$windows_dir/$name" ] || exit 1
      : > "$windows_dir/$name"
      printf '@%s\n' "$name"
    fi
    exit 0
    ;;
  kill-window)
    if [ -n "$windows_dir" ]; then
      target=
      prev=
      for a in "$@"; do
        if [ "$prev" = "-t" ]; then
          target=$a
          break
        fi
        prev=$a
      done
      name=${target##*:=}
      [ -n "$name" ] && rm -f "$windows_dir/$name"
    fi
    exit 0
    ;;
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
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" --help "*)
    case "${FM_FAKE_CURSOR_HELP_MODE:-headless}" in
      headless)
        printf '%s\n' \
          'Usage: agent [options] [command] [prompt...]' \
          'Start the Cursor Agent' \
          '  --trust                      Trust the current workspace without prompting (only works with --print/headless mode)'
        ;;
      interactive)
        printf '%s\n' \
          'Usage: agent [options] [command] [prompt...]' \
          'Start the Cursor Agent' \
          '  --trust                      Trust the current workspace without prompting'
        ;;
      absent)
        printf '%s\n' 'Usage: agent [options]' 'Start the Cursor Agent'
        ;;
    esac
    exit 0
    ;;
  *" --list-models "*)
    [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
    printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
    exit 0
    ;;
  *" create-chat "*)
    [ "${FM_FAKE_CURSOR_TRUST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_TRUST_STATUS}"
    if [ -n "${FM_FAKE_CURSOR_TRUST_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_CURSOR_TRUST_LOG"
    fi
    printf '%s\n' "${FM_FAKE_CURSOR_CHAT_ID:-fake-chat-id}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
if [ -n "${FM_FAKE_DISPATCH_BODY:-}" ]; then
  printf '%s\n' "$FM_FAKE_DISPATCH_BODY" > "$out"
else
  cat > "$out" <<JSON
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"${FM_FAKE_DISPATCH_CHOICE:-default}","confidence":${FM_FAKE_DISPATCH_CONFIDENCE:-0.97},"probabilities":{"rule_1":${FM_FAKE_DISPATCH_RULE_PROBABILITY:-0.97},"default":${FM_FAKE_DISPATCH_DEFAULT_PROBABILITY:-0.03}}}},"usage":{"input_tokens":321,"output_tokens":42}}
JSON
fi
printf '%s' "${FM_FAKE_DISPATCH_HTTP:-200}"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --json ] || exit 2
cat <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[
{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":75,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.5}}]}},
{"provider":"cursor","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":90,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}},
{"provider":"grok","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"},"selection":{"spendPriority":-2}}]}},
{"provider":"kimi","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":88,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.7}}]}}
]}
JSON
SH
  chmod +x "$fakebin/curl" "$fakebin/quota-axi"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  cursortrustlog="$case_dir/cursor-trust.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$cursortrustlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

enable_cursor_dispatch_profile() {
  local home=$1 approval=${2:-}
  jq -n --arg approval "$approval" '{
    rules:[{
      when:"Well-specified implementation work.",
      use:[
        {harness:"grok",model:"grok-4",effort:"medium"},
        {harness:"cursor",model:"cursor-grok-4.6-medium"}
      ]
    }],
    default:{harness:"cursor",model:"cursor-grok-4.6-medium"}
  }
  | if $approval == "" then . else .rules[0].approval = $approval end' \
    > "$home/config/crew-dispatch.json"
  printf '%s\n' 'TYPESAFE_API_KEY=test-key' > "$home/.env"
}

enable_harness_only_grok_dispatch_profile() {
  local home=$1
  jq -n '{
    rules:[{
      when:"Well-specified implementation work.",
      use:[
        {harness:"grok"},
        {harness:"cursor",model:"cursor-grok-4.6-medium"}
      ]
    }],
    default:{harness:"cursor",model:"cursor-grok-4.6-medium"}
  }' > "$home/config/crew-dispatch.json"
  printf '%s\n' 'TYPESAFE_API_KEY=test-key' > "$home/.env"
}

enable_kimi_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"Other work","use":{"harness":"codex","model":"gpt-5","effort":"medium"}}],"default":{"harness":"kimi","model":"kimi-code/k3"}}' \
    > "$home/config/crew-dispatch.json"
  printf '%s\n' 'TYPESAFE_API_KEY=test-key' > "$home/.env"
}

last_dispatch_receipt() {
  tail -n 1 "$1/state/dispatch-receipts.jsonl"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_TMUX_WINDOW_DIR="${FM_TEST_TMUX_WINDOW_DIR:-}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    FM_FAKE_CURSOR_HELP_MODE="${FM_TEST_CURSOR_HELP_MODE:-headless}" \
    FM_FAKE_CURSOR_TRUST_STATUS="${FM_TEST_CURSOR_TRUST_STATUS:-0}" \
    FM_FAKE_CURSOR_TRUST_LOG="${FM_TEST_CURSOR_TRUST_LOG:-}" \
    HOME="${FM_TEST_HOME:-${HOME:-}}" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CURSOR_TRUST_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-claude-cursor-markers-z1b
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .resolver.status <<<"$receipt")" = off ] || fail "absent-key receipt did not record resolver status"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = absent_key ] || fail "absent-key receipt did not explain fallback"
  [ "$(jq -r .launched <<<"$receipt")" = null ] || fail "refused absent-key launch receipt claims a worker launched"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_clear_typed_cursor_selection_reaches_launch_and_receipt() {
  local rec id out status launch receipt
  id=profile-typed-cursor-z11b
  rec=$(make_spawn_case profile-typed-cursor claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"

  out=$(FM_TEST_CURSOR_MODELS=$'Available models\ncursor-grok-4.6-medium - Grok 4.6 Medium' \
    FM_TEST_CURSOR_TRUST_LOG="$CURSOR_TRUST_LOG" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "clear typed Cursor selection should launch without repeated profile flags"
  assert_contains "$out" "spawned $id harness=cursor" "clear typed selection did not reach Cursor"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-grok-4.6-medium'" "typed Cursor model did not reach the worker command"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .resolver.status <<<"$receipt")" = clear ] || fail "clear receipt lost resolver status"
  [ "$(jq -r .resolver.model <<<"$receipt")" = jev-1.13.0 ] || fail "clear receipt lost resolver model"
  [ "$(jq -r .resolver.tokens.input_tokens <<<"$receipt")" = 321 ] || fail "clear receipt lost input token count"
  [ "$(jq -r .selected.harness <<<"$receipt")" = cursor ] || fail "clear receipt lost selected harness"
  [ "$(jq -r .selected.effort <<<"$receipt")" = default ] || fail "clear receipt did not normalize omitted selected effort"
  [ "$(jq -r .launched.harness <<<"$receipt")" = cursor ] || fail "clear receipt lost launched harness"
  [ "$(jq -r .launched.model <<<"$receipt")" = cursor-grok-4.6-medium ] || fail "clear receipt lost launched model"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = none ] || fail "matching typed launch recorded a divergence"
  [ "$(jq -r '.quota_facts[] | select(.harness == "cursor") | .remaining_percent' <<<"$receipt")" = 90 ] \
    || fail "clear receipt lost current Cursor quota facts"
  assert_not_contains "$receipt" "brief for $id" "receipt persisted private brief text"
  assert_not_contains "$receipt" "test-key" "receipt persisted the resolver key"
  pass "clear typed Cursor selection reaches the launch command with a matching private receipt"
}

test_clear_divergence_requires_reason_and_ineligible_candidate_is_refused() {
  local rec id out status receipt
  id=profile-typed-divergence-z11c
  rec=$(make_spawn_case profile-typed-divergence claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort medium)
  status=$?
  expect_code 1 "$status" "unexplained clear-result divergence should refuse launch"
  assert_contains "$out" "pass --dispatch-override-reason" "clear divergence refusal did not name the required reason"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .divergence_reason <<<"$receipt")" = manual_override_missing_reason ] \
    || fail "unexplained divergence receipt lost its reason"
  [ "$(jq -r .launched <<<"$receipt")" = null ] || fail "divergence refusal claims a launch"

  rm -f "$HOME_DIR/state/dispatch-receipts.jsonl"
  out=$(FM_FAKE_DISPATCH_CHOICE=rule_1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness grok --model grok-4 --effort medium \
      --dispatch-override-reason supported_manual_override)
  status=$?
  expect_code 1 "$status" "a quota-ineligible candidate must not launch through manual override"
  assert_contains "$out" "profile is ineligible" "ineligible-candidate refusal did not explain the veto"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .divergence_reason <<<"$receipt")" = quota_runway_veto ] \
    || fail "ineligible-candidate receipt lost the quota veto"
  [ ! -s "$LAUNCH_LOG" ] || fail "ineligible candidate reached the worker launch command"

  id=profile-typed-harness-only-veto-z11c1
  rec=$(make_spawn_case profile-typed-harness-only-veto claude "$id")
  read_case_record "$rec"
  enable_harness_only_grok_dispatch_profile "$HOME_DIR"
  out=$(FM_FAKE_DISPATCH_CHOICE=rule_1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness grok \
      --dispatch-override-reason supported_manual_override)
  status=$?
  expect_code 1 "$status" "a harness-only override to an ineligible candidate must not launch"
  assert_contains "$out" "profile is ineligible" "harness-only ineligible refusal did not explain the veto"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .divergence_reason <<<"$receipt")" = quota_runway_veto ] \
    || fail "harness-only ineligible receipt lost the quota veto"
  [ ! -s "$LAUNCH_LOG" ] || fail "harness-only ineligible candidate reached the worker launch command"

  id=profile-typed-override-z11c2
  rec=$(make_spawn_case profile-typed-override claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort medium \
    --dispatch-override-reason supported_manual_override)
  status=$?
  expect_code 0 "$status" "a supported explained override to a profile without contradictory evidence should launch"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .selected.harness <<<"$receipt")" = cursor ] || fail "override receipt lost typed selection"
  [ "$(jq -r .launched.harness <<<"$receipt")" = codex ] || fail "override receipt lost actual launch"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = supported_manual_override ] \
    || fail "supported override receipt lost its reason"
  pass "clear divergence is explained and an ineligible candidate cannot be silently launched"
}

test_nonclear_and_launch_refusal_receipts_are_complete() {
  local rec id out status receipt
  id=profile-typed-nonclear-z11d
  rec=$(make_spawn_case profile-typed-nonclear claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"

  out=$(FM_FAKE_DISPATCH_CONFIDENCE=0.4 \
    FM_TEST_CURSOR_MODELS=$'Available models\ncursor-grok-4.6-medium - Grok 4.6 Medium' \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness cursor --model cursor-grok-4.6-medium)
  status=$?
  expect_code 0 "$status" "ambiguous typed result should allow the existing manual intake"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .resolver.status <<<"$receipt")" = ambiguous ] || fail "ambiguous receipt lost resolver status"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = non_clear_result ] || fail "ambiguous fallback was unexplained"

  id=profile-typed-error-z11e
  rec=$(make_spawn_case profile-typed-error claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"
  out=$(FM_FAKE_DISPATCH_HTTP=500 \
    FM_FAKE_DISPATCH_BODY="provider echoed private brief for $id and test-key" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort medium)
  status=$?
  expect_code 0 "$status" "typed resolver error should allow explicit existing intake"
  assert_contains "$out" "dispatch-resolve: error (http 500 after" "typed resolver error kept compact status diagnostics"
  assert_not_contains "$out" "provider echoed private brief" "spawn output must not forward provider response bodies"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .resolver.status <<<"$receipt")" = error ] || fail "error receipt lost resolver status"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = non_clear_result ] || fail "error fallback was unexplained"
  assert_not_contains "$receipt" "provider echoed private brief" "resolver-error receipt must not persist provider response bodies"

  id=profile-typed-success-metadata-z11e2
  rec=$(make_spawn_case profile-typed-success-metadata claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"
  out=$(FM_FAKE_DISPATCH_BODY="{\"model\":\"jev private brief for $id\",\"answers\":{\"rule\":{\"type\":\"choice\",\"choice\":\"default\",\"confidence\":0.97,\"probabilities\":{\"rule_1\":0.97,\"default\":0.03}}},\"usage\":{\"input_tokens\":321,\"output_tokens\":42,\"debug\":\"provider echoed test-key and brief for $id\"}}" \
    FM_TEST_CURSOR_MODELS=$'Available models\ncursor-grok-4.6-medium - Grok 4.6 Medium' \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "malicious provider success metadata should not block an otherwise valid typed launch"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r '.resolver.model | type' <<<"$receipt")" = null ] || fail "receipt persisted unsafe resolver model metadata"
  [ "$(jq -c '.resolver.tokens | keys' <<<"$receipt")" = '["input_tokens","output_tokens"]' ] \
    || fail "receipt persisted provider usage extras"
  assert_not_contains "$receipt" "private brief for $id" "receipt persisted unsafe provider model content"
  assert_not_contains "$receipt" "provider echoed test-key" "receipt persisted provider usage debug content"

  id=profile-typed-escalate-z11f
  rec=$(make_spawn_case profile-typed-escalate claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR" captain
  out=$(FM_FAKE_DISPATCH_CHOICE=rule_1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness cursor --model cursor-grok-4.6-medium)
  status=$?
  expect_code 1 "$status" "captain-approval typed result should refuse an unapproved launch"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .resolver.status <<<"$receipt")" = escalate ] || fail "escalate receipt lost resolver status"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = captain_approval_required ] \
    || fail "approval refusal receipt lost its reason"

  id=profile-typed-approved-z11f2
  rec=$(make_spawn_case profile-typed-approved claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR" captain
  out=$(FM_FAKE_DISPATCH_CHOICE=rule_1 \
    FM_TEST_CURSOR_MODELS=$'Available models\ncursor-grok-4.6-medium - Grok 4.6 Medium' \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness cursor --model cursor-grok-4.6-medium \
      --dispatch-override-reason captain_override)
  status=$?
  expect_code 0 "$status" "an explicitly approved typed result should launch"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .divergence_reason <<<"$receipt")" = captain_override ] \
    || fail "approved escalation receipt lost captain override reason"

  id=profile-typed-catalog-z11g
  rec=$(make_spawn_case profile-typed-catalog claude "$id")
  read_case_record "$rec"
  enable_cursor_dispatch_profile "$HOME_DIR"
  out=$(FM_TEST_CURSOR_MODELS=$'Available models\nother-model - Other' \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "clear selection rejected by the live catalog should refuse launch"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .resolver.status <<<"$receipt")" = clear ] || fail "catalog-refusal receipt lost clear selection"
  [ "$(jq -r .selected.harness <<<"$receipt")" = cursor ] || fail "catalog-refusal receipt lost selected profile"
  [ "$(jq -r .launched <<<"$receipt")" = null ] || fail "catalog-refusal receipt claims a worker launch"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = catalog_rejection ] \
    || fail "catalog-refusal receipt lost deterministic reason"
  pass "ambiguous, error, escalation, and launch-refusal paths each record one explained receipt"
}

test_kimi_adapter_refusals_record_adapter_unavailable() {
  local rec id out status receipt
  id=profile-typed-kimi-missing-z11h
  rec=$(make_spawn_case profile-typed-kimi-missing claude "$id")
  read_case_record "$rec"
  enable_kimi_dispatch_profile "$HOME_DIR"

  out=$(FM_TEST_HOME="$HOME_DIR" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "clear Kimi selection with no executable should refuse before launch"
  assert_contains "$out" "kimi executable not found" "missing Kimi binary refusal did not name the adapter"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .selected.harness <<<"$receipt")" = kimi ] || fail "missing-binary receipt lost selected Kimi profile"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = adapter_unavailable ] \
    || fail "missing-binary receipt did not record adapter_unavailable"
  [ "$(jq -r .launched <<<"$receipt")" = null ] || fail "missing-binary receipt claims a launch"

  id=profile-typed-kimi-hook-z11i
  rec=$(make_spawn_case profile-typed-kimi-hook claude "$id")
  read_case_record "$rec"
  enable_kimi_dispatch_profile "$HOME_DIR"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN_DIR/kimi"
  chmod +x "$FAKEBIN_DIR/kimi"
  out=$(FM_TEST_HOME="$HOME_DIR" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "clear Kimi selection with an unsafe hook install should refuse before launch"
  assert_contains "$out" "global turn-end hook could not be installed safely" \
    "Kimi hook-install refusal did not name the prelaunch dependency"
  receipt=$(last_dispatch_receipt "$HOME_DIR")
  [ "$(jq -r .selected.harness <<<"$receipt")" = kimi ] || fail "hook-refusal receipt lost selected Kimi profile"
  [ "$(jq -r .divergence_reason <<<"$receipt")" = adapter_unavailable ] \
    || fail "hook-refusal receipt did not record adapter_unavailable"
  [ "$(jq -r .launched <<<"$receipt")" = null ] || fail "hook-refusal receipt claims a launch"
  [ ! -s "$LAUNCH_LOG" ] || fail "Kimi prelaunch refusal reached the worker launch command"
  pass "Kimi binary and hook-install refusals record adapter_unavailable"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CURSOR_TRUST_LOG="$CURSOR_TRUST_LOG" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry autonomy, model, and exact workspace flags"
  assert_not_contains "$launch" "--trust" \
    "headless-only Cursor builds reject interactive --trust; fm-spawn must pretrust headlessly and omit it from the TTY launch"
  assert_contains "$(cat "$CURSOR_TRUST_LOG")" "--trust --workspace $WT_DIR create-chat" \
    "cursor launch did not pretrust the exact task workspace through the current headless contract"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_old_interactive_trust_contract_keeps_launch_flag() {
  local rec id out status launch
  id=profile-cursor-old-trust-z6c2
  rec=$(make_spawn_case profile-cursor-old-trust cursor "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CURSOR_HELP_MODE=interactive FM_TEST_CURSOR_TRUST_LOG="$CURSOR_TRUST_LOG" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-grok-4.5-high)
  status=$?
  expect_code 0 "$status" "cursor spawn on an old interactive-trust contract should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "old Cursor builds still need the interactive --trust launch flag"
  [ ! -s "$CURSOR_TRUST_LOG" ] \
    || fail "old Cursor interactive-trust path should not run a headless preflight: $(cat "$CURSOR_TRUST_LOG")"
  pass "cursor interactive trust contract keeps --trust on the TTY launch"
}

test_cursor_headless_trust_failure_refuses_launch() {
  local rec id out status retry_out retry_status window_dir
  id=profile-cursor-trust-fails-z6c3
  rec=$(make_spawn_case profile-cursor-trust-fails cursor "$id")
  read_case_record "$rec"
  window_dir="$CASE_DIR/tmux-windows"

  out=$(FM_TEST_CURSOR_TRUST_STATUS=42 FM_TEST_CURSOR_TRUST_LOG="$CURSOR_TRUST_LOG" \
    FM_TEST_TMUX_WINDOW_DIR="$window_dir" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-grok-4.5-high)
  status=$?
  expect_code 1 "$status" "cursor spawn must refuse when the current headless trust path fails"
  assert_contains "$out" "Cursor workspace trust preflight failed" \
    "cursor trust failure did not name the failed preflight"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor trust refusal must happen before the interactive launch is typed"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "cursor trust refusal must happen before task metadata is published"
  [ ! -e "$HOME_DIR/state/$id.cursor-session" ] || fail "cursor trust refusal must happen before cursor transcript binding is published"
  [ ! -e "$window_dir/fm-$id" ] || fail "cursor trust refusal must retract the unrecorded tmux endpoint"
  retry_out=$(FM_TEST_CURSOR_TRUST_LOG="$CURSOR_TRUST_LOG" \
    FM_TEST_TMUX_WINDOW_DIR="$window_dir" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-grok-4.5-high)
  retry_status=$?
  expect_code 0 "$retry_status" "cursor trust refusal must leave the same task id retryable"$'\n'"$retry_out"
  pass "cursor refuses unsafe trust states before launch"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id=profile-cursor-unsupported-z6d
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id=profile-cursor-catalog-unreachable-z6e
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CURSOR_LIST_STATUS=124 FM_TEST_CURSOR_TRUST_LOG="$CURSOR_TRUST_LOG" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=profile-pi-signed-secondmate-z8d
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_pi_ship_launch_wires_task_recap_widget_but_secondmate_does_not() {
  local rec id sm launch state_real
  id=profile-pi-recap-z8e
  rec=$(make_spawn_case profile-pi-recap pi "$id")
  read_case_record "$rec"
  state_real=$(cd "$HOME_DIR/state" && pwd -P)

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null
  expect_code 0 $? "pi ship spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_RECAP_TASK_ID='$id' FM_RECAP_STATE_DIR='$state_real' FM_RECAP_DATA_DIR='$HOME_DIR/data' " \
    "pi ship launch did not export the FM_RECAP_* env vars the recap widget reads"
  assert_contains "$launch" "-e '$ROOT/.pi/extensions/fm-task-recap.ts' " \
    "pi ship launch did not load the tracked fm-task-recap.ts widget"

  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id-sm"
  sm=$(cd "$sm" && pwd -P)
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id-sm" "$sm" --secondmate >/dev/null
  expect_code 0 $? "pi-signed secondmate spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "FM_RECAP_" "a secondmate has no task phase and must not export FM_RECAP_* vars"
  assert_not_contains "$launch" "fm-task-recap.ts" "a secondmate must not load the task recap widget"
  pass "pi ship launches carry the recap widget and its FM_RECAP_* env; secondmates get neither"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=profile-claude-cfgdir-z17
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=profile-claude-nocfgdir-z18
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=profile-codex-nocfgdir-z19
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_clear_typed_cursor_selection_reaches_launch_and_receipt
test_clear_divergence_requires_reason_and_ineligible_candidate_is_refused
test_nonclear_and_launch_refusal_receipts_are_complete
test_kimi_adapter_refusals_record_adapter_unavailable
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_cursor_threads_model_workspace_and_omits_effort_axis
test_cursor_old_interactive_trust_contract_keeps_launch_flag
test_cursor_headless_trust_failure_refuses_launch
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_pi_ship_launch_wires_task_recap_widget_but_secondmate_does_not
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"

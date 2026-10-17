#!/usr/bin/env bash
# Regression coverage for Firstmate's durable Treehouse reservation boundary.
# The fake Treehouse models the destructive ordering that exposed the defect:
# ordinary get selects the first available slot and resets it before returning.
# A preserved task record therefore has to become a state-only lease before the
# tmux stub performs that selection, not merely be checked afterward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-reservation)

make_reservation_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_TREEHOUSE_STATE:?}
log=${FM_FAKE_TREEHOUSE_LOG:?}
write_state() {
  local next=$1 tmp="$state.tmp.$$"
  printf '%s\n' "$next" > "$tmp"
  mv -f "$tmp" "$state"
}
case "${1:-}:${2:-}" in
  get:--help)
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
    exit 0
    ;;
  lease:--help)
    printf '%s\n' 'Usage: treehouse lease <name> [--lease-holder <holder>] [--json]'
    exit 0
    ;;
  status:--json)
    cat "$state"
    exit 0
    ;;
esac
if [ "${1:-}" = lease ]; then
  name=${2:-}
  holder=
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --lease-holder) holder=${2:-}; shift 2 ;;
      --lease-holder=*) holder=${1#--lease-holder=}; shift ;;
      --json) shift ;;
      *) shift ;;
    esac
  done
  [ -n "$name" ] && [ -n "$holder" ] || exit 2
  [ "${FM_FAKE_TREEHOUSE_LEASE_FAIL_HOLDER:-}" != "$holder" ] || exit 17
  count=$(jq -r --arg name "$name" '[.[] | select(.name == $name)] | length' "$state")
  [ "$count" -eq 1 ] || exit 3
  status=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .status' "$state")
  [ "$status" != leased ] || exit 4
  lease_id="lease-$name-$holder"
  next=$(jq -c --arg name "$name" --arg holder "$holder" --arg lease_id "$lease_id" '
    map(if .name == $name then
      .status = "leased" |
      .lease_id = $lease_id |
      .lease_holder = $holder |
      .leased_at = "2030-01-01T00:00:00Z"
    else . end)
  ' "$state") || exit 5
  write_state "$next"
  printf 'lease\t%s\t%s\n' "$name" "$holder" >> "$log"
  jq -cn --argjson rows "$next" --arg name "$name" '
    $rows[] | select(.name == $name) |
    {path,lease_id,lease_holder,leased_at}
  '
  exit 0
fi
if [ "${1:-}" = return ]; then
  exit 0
fi
exit 2
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) cat "${FM_FAKE_PANE_FILE:?}"; printf '\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option|kill-window) exit 0 ;;
  new-window)
    printf '%s\n' '@reservation-window'
    exit 0
    ;;
  send-keys)
    for argument in "$@"; do
      [ "$argument" = 'treehouse get' ] || continue
      selected=$(jq -r '.[] | select(.status == "available") | .path' "${FM_FAKE_TREEHOUSE_STATE:?}" | head -n 1)
      if [ -z "$selected" ]; then
        printf 'no-free-slot\n' >> "${FM_FAKE_TREEHOUSE_LOG:?}"
        exit 0
      fi
      next=$(jq -c --arg path "$selected" '
        map(if .path == $path then .status = "in-use" else . end)
      ' "$FM_FAKE_TREEHOUSE_STATE") || exit 1
      printf '%s\n' "$next" > "$FM_FAKE_TREEHOUSE_STATE"
      printf '%s\n' "$selected" > "${FM_FAKE_PANE_FILE:?}"
      printf 'reset\t%s\n' "$selected" >> "$FM_FAKE_TREEHOUSE_LOG"
      exit 0
    done
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <slot-count>
  local name=$1 slot_count=$2 case_dir home project origin fakebin i slot branch rows='[]'
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$origin"
  i=1
  while [ "$i" -le "$slot_count" ]; do
    slot="$case_dir/slot-$i"
    branch="fixture-$name-$i"
    git -C "$project" worktree add --quiet -b "$branch" "$slot"
    rows=$(jq -c --arg name "$i" --arg path "$slot" '
      . + [{name:$name,path:$path,status:"available",lease_id:"",lease_holder:"",leased_at:null,processes:[]}]
    ' <<<"$rows") || return 1
    i=$((i + 1))
  done
  printf '%s\n' "$rows" > "$case_dir/treehouse-state.json"
  : > "$case_dir/treehouse.log"
  printf '%s\n' "$project" > "$case_dir/pane-path"
  fakebin=$(make_reservation_fakebin "$case_dir/fake")
  printf '%s\n' "$case_dir|$home|$project|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  TREEHOUSE_STATE="$CASE_DIR/treehouse-state.json"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  PANE_FILE="$CASE_DIR/pane-path"
}

write_brief() {  # <task-id>
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  {
    printf '# Task\n\n'
    printf 'Delivery contract: mode=no-mistakes\n'
  } > "$HOME_DIR/data/$id/brief.md"
}

write_preserved_meta() {  # <task-id> <worktree> [kind]
  local id=$1 worktree=$2 kind=${3:-ship}
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$PROJECT_DIR"
    printf 'harness=codex\n'
    printf 'kind=%s\n' "$kind"
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'model=default\n'
    printf 'effort=default\n'
  } > "$HOME_DIR/state/$id.meta"
  printf 'paused: preserved for later work\n' > "$HOME_DIR/state/$id.status"
}

run_spawn() {  # <task-id> [spawn args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_TREEHOUSE_STATE="$TREEHOUSE_STATE" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_PANE_FILE="$PANE_FILE" \
    FM_FAKE_PROJECT="$PROJECT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_preserved_ship_is_leased_before_scout_allocation() {
  local rec old_id new_id old_slot free_slot out status reset_path
  old_id=jev-advisory-paused
  new_id=cold-email-scout
  rec=$(make_case preserved-skip 2)
  read_case "$rec"
  old_slot="$CASE_DIR/slot-1"
  free_slot="$CASE_DIR/slot-2"
  write_preserved_meta "$old_id" "$old_slot"
  write_brief "$new_id"

  out=$(run_spawn "$new_id" --scout)
  status=$?
  expect_code 0 "$status" "a free second slot should let the scout spawn after the preserved owner is leased: $out"
  assert_grep "treehouse_lease_holder=firstmate:$old_id" "$HOME_DIR/state/$old_id.meta" \
    "the preserved task metadata did not receive its reconciled lease owner"
  assert_grep "treehouse_lease_holder=firstmate:$new_id" "$HOME_DIR/state/$new_id.meta" \
    "the fresh scout metadata did not record its durable lease owner"
  assert_grep "worktree=$free_slot" "$HOME_DIR/state/$new_id.meta" \
    "the fresh scout did not receive the genuinely free slot"
  [ "$(jq -r --arg path "$old_slot" '.[] | select(.path == $path) | .status' "$TREEHOUSE_STATE")" = leased ] \
    || fail "the preserved slot was not leased before allocation"
  [ "$(jq -r --arg path "$old_slot" '.[] | select(.path == $path) | .lease_holder' "$TREEHOUSE_STATE")" = "firstmate:$old_id" ] \
    || fail "the preserved slot has the wrong lease holder"
  reset_path=$(sed -n 's/^reset[[:space:]]//p' "$TREEHOUSE_LOG")
  [ "$reset_path" = "$free_slot" ] \
    || fail "Treehouse reset '$reset_path' instead of only the free slot '$free_slot'"
  assert_not_contains "$(cat "$TREEHOUSE_LOG")" "$old_slot" \
    "allocation reset the preserved task's worktree"
  pass "a preserved ship record is leased before a fresh scout skips it and allocates a free slot"
}

test_genuinely_free_slot_still_allocates() {
  local rec id slot out status
  id=fresh-free-ship
  rec=$(make_case clean-free 1)
  read_case "$rec"
  slot="$CASE_DIR/slot-1"
  write_brief "$id"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a genuinely free slot should still allocate: $out"
  assert_grep "worktree=$slot" "$HOME_DIR/state/$id.meta" "the free slot was not recorded"
  assert_grep "treehouse_lease_holder=firstmate:$id" "$HOME_DIR/state/$id.meta" \
    "the free slot was not converted to the task's durable lease"
  pass "a clean genuinely free pooled worktree still allocates and becomes durably owned"
}

test_duplicate_preserved_owners_refuse_before_reset() {
  local rec first_id second_id new_id shared shared_real out status
  first_id=paused-hyperframes-theme
  second_id=stopped-cold-email
  new_id=another-fresh-worker
  rec=$(make_case duplicate-refusal 2)
  read_case "$rec"
  shared="$CASE_DIR/slot-1"
  shared_real=$(cd "$shared" && pwd -P)
  write_preserved_meta "$first_id" "$shared"
  write_preserved_meta "$second_id" "$shared"
  write_brief "$new_id"

  out=$(run_spawn "$new_id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate preserved owners must refuse a fresh allocation"
  assert_contains "$out" "$first_id" "the refusal did not name the first conflicting task"
  assert_contains "$out" "$second_id" "the refusal did not name the second conflicting task"
  assert_contains "$out" "$shared_real" "the refusal did not name the conflicting worktree"
  [ ! -s "$TREEHOUSE_LOG" ] || fail "duplicate ownership reached Treehouse mutation: $(cat "$TREEHOUSE_LOG")"
  [ "$(jq -r '.[0].status' "$TREEHOUSE_STATE")" = available ] \
    || fail "duplicate ownership changed the candidate slot instead of failing closed"
  pass "duplicate preserved task owners fail closed with both tasks and the worktree named before reset"
}

test_record_under_lifecycle_action_refuses_before_reset() {
  local rec old_id new_id old_slot old_slot_real lock holder i out status
  old_id=legacy-being-torn-down
  new_id=racing-fresh-ship
  rec=$(make_case lifecycle-race 2)
  read_case "$rec"
  old_slot="$CASE_DIR/slot-1"
  old_slot_real=$(cd "$old_slot" && pwd -P)
  write_preserved_meta "$old_id" "$old_slot"
  write_brief "$new_id"
  lock="$HOME_DIR/state/.control-$old_id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock/pid" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock/pid" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }

  out=$(run_spawn "$new_id" --mode no-mistakes --yolo off)
  status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "a record under a running lifecycle action must refuse fresh allocation: $out"
  assert_contains "$out" "$old_id" "the refusal did not name the task under a lifecycle action"
  assert_contains "$out" "$old_slot_real" "the refusal did not name that task's worktree"
  [ ! -s "$TREEHOUSE_LOG" ] || fail "the refusal reached Treehouse mutation: $(cat "$TREEHOUSE_LOG")"
  assert_no_grep "treehouse_lease_holder=" "$HOME_DIR/state/$old_id.meta" \
    "reconciliation rewrote a record whose lifecycle action holds its control lock"
  [ ! -e "$HOME_DIR/state/$new_id.meta" ] || fail "the refused spawn published task metadata"
  pass "a record held by a running lifecycle action fails closed before any lease or reset"
}

test_abort_after_fresh_lease_reports_unowned_lease() {
  local rec id slot slot_real out status
  id=freshen-refused-ship
  rec=$(make_case abort-after-lease 1)
  read_case "$rec"
  slot="$CASE_DIR/slot-1"
  slot_real=$(cd "$slot" && pwd -P)
  write_brief "$id"
  git -C "$slot" remote set-url origin "$CASE_DIR/missing-origin.git"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreachable origin must stop the fresh spawn: $out"
  [ "$(jq -r '.[0].status' "$TREEHOUSE_STATE")" = leased ] \
    || fail "the aborted spawn's slot should stay leased rather than be returned or reset"
  assert_contains "$out" "$slot_real" "the abort did not name the leased worktree"
  assert_contains "$out" "lease-1-firstmate:$id" "the abort did not name the leased identity"
  assert_contains "$out" "--if-lease-id 'lease-1-firstmate:$id'" \
    "the abort did not give the lease-guarded release command"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the aborted spawn published task metadata"
  pass "a spawn stopped after its fresh lease keeps the copy leased and reports the guarded release step"
}

test_abort_release_command_names_treehouse_listed_path_under_symlinked_root() {
  local rec id listed out status
  id=symlinked-root-ship
  rec=$(make_case abort-symlinked-root 1)
  read_case "$rec"
  ln -s "$CASE_DIR" "$CASE_DIR/pool-link"
  listed="$CASE_DIR/pool-link/slot-1"
  # Treehouse keys the slot and its lease by the unresolved pool path.
  jq -c --arg path "$listed" '.[0].path = $path' "$TREEHOUSE_STATE" > "$TREEHOUSE_STATE.next"
  mv -f "$TREEHOUSE_STATE.next" "$TREEHOUSE_STATE"
  write_brief "$id"
  git -C "$CASE_DIR/slot-1" remote set-url origin "$CASE_DIR/missing-origin.git"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreachable origin must stop the fresh spawn: $out"
  [ "$(jq -r '.[0].status' "$TREEHOUSE_STATE")" = leased ] \
    || fail "the aborted spawn's slot should stay leased rather than be returned or reset"
  assert_contains "$out" "treehouse return '$listed' --if-lease-id 'lease-1-firstmate:$id'" \
    "the guarded release command did not name the path Treehouse lists for the leased slot"
  pass "the guarded release command names Treehouse's listed path under a symlinked pool root"
}

test_preserved_ship_is_leased_before_scout_allocation
test_genuinely_free_slot_still_allocates
test_duplicate_preserved_owners_refuse_before_reset
test_record_under_lifecycle_action_refuses_before_reset
test_abort_after_fresh_lease_reports_unowned_lease
test_abort_release_command_names_treehouse_listed_path_under_symlinked_root

echo "# all fm-spawn worktree reservation tests passed"

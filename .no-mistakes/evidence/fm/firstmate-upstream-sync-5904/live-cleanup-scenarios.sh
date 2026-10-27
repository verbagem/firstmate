#!/usr/bin/env bash
set -euo pipefail

ROOT=/Users/temp/.no-mistakes/worktrees/acee6d463bcf/01M5WKWYKBCGKYKPBR9H5QS3TG
EXPECTED_HEAD=62423bcd6abd1e83b816e9ada7917154cc489c0d
if [ "${1:-}" = --cleanup ]; then
  case "${2:-}" in
    /tmp/fm-cleanup-live.*) chmod -R u+w "$2" 2>/dev/null || true; rm -rf -- "$2"; exit 0 ;;
    *) printf 'REFUSED cleanup of unexpected lab path %s\n' "${2:-<missing>}" >&2; exit 1 ;;
  esac
fi
LAB=$(mktemp -d /tmp/fm-cleanup-live.XXXXXX)
TMUX_DIR="$LAB/tmux"
USER_HOME="$LAB/user-home"
WORKER_PIDS=()
T3_FAKE_PID=

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# shellcheck source=/dev/null
. "$ROOT/tests/t3-fake-lib.sh"

cleanup() {
  local pid
  t3_fake_stop || true
  for pid in "${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux kill-server 2>/dev/null || true
  case "$LAB" in
    /tmp/fm-cleanup-live.*) chmod -R u+w "$LAB" 2>/dev/null || true; rm -rf -- "$LAB" ;;
    *) printf 'REFUSED cleanup of unexpected lab path %s\n' "$LAB" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "$TMUX_DIR" "$USER_HOME"
chmod 700 "$TMUX_DIR" "$USER_HOME"

head=$(git -C "$ROOT" rev-parse HEAD)
[ "$head" = "$EXPECTED_HEAD" ] || fail "wrong head $head"
[ -z "$(git -C "$ROOT" status --porcelain=v1)" ] || fail "worktree was dirty before live verification"
printf 'head=%s\n' "$head"
printf 'lab=%s\n' "$LAB"
printf 'tmux_socket_root=%s\n' "$TMUX_DIR"

lab_tmux() {
  env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux "$@"
}

window_alive() {
  lab_tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -Fxq "$1"
}

new_window() {
  lab_tmux new-window -d -t firstmate -n "$1" '/bin/sleep 600'
  window_alive "$1" || fail "window $1 did not start"
}

start_worker() {
  local dir=$1
  ( cd "$dir" && exec /bin/sleep 600 ) >/dev/null 2>&1 &
  STARTED_WORKER_PID=$!
  WORKER_PIDS+=("$STARTED_WORKER_PID")
  kill -0 "$STARTED_WORKER_PID" 2>/dev/null || fail "worker $STARTED_WORKER_PID did not start in $dir"
}

make_origin_project() {
  local dir=$1
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  printf 'baseline\n' > "$dir/seed/README.md"
  git -C "$dir/seed" add README.md
  git -C "$dir/seed" -c user.name='Live Test' -c user.email=live@example.invalid commit -qm baseline
  git -C "$dir/seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/project"
  printf '%s\n' "$dir/project"
}

make_local_project() {
  local dir=$1 with_codex=${2:-no}
  mkdir -p "$dir/project"
  git init -q -b main "$dir/project"
  printf 'baseline\n' > "$dir/project/README.md"
  if [ "$with_codex" = yes ]; then
    mkdir -p "$dir/project/.codex"
    printf 'model = "gpt-6-sol"\n' > "$dir/project/.codex/config.toml"
  fi
  git -C "$dir/project" add .
  git -C "$dir/project" -c user.name='Live Test' -c user.email=live@example.invalid commit -qm baseline
  printf '%s\n' "$dir/project"
}

make_home() {
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
  chmod 755 "$1" "$1/state" "$1/data" "$1/config" "$1/projects"
  touch "$1/state/.last-watcher-beat"
}

write_meta() {
  local file=$1
  shift
  : > "$file"
  printf '%s\n' "$@" >> "$file"
}

run_teardown() {
  local home=$1 pool=$2 id=$3 out=$4 err=$5
  set +e
  env -u TMUX \
    HOME="$USER_HOME" TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$pool" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 FM_TEARDOWN_GUARD_DONE=1 \
    DISABLE_AUTOUPDATER=1 \
    "$ROOT/bin/fm-teardown.sh" "$id" --force >"$out" 2>"$err"
  local rc=$?
  set -e
  return "$rc"
}

treehouse_status() {
  local project=$1 pool=$2
  ( cd "$project" && TREEHOUSE_ROOT="$pool" treehouse status --json )
}

treehouse_row_for_path() {
  local project=$1 pool=$2 wt=$3 want status row path got='[]'
  want=$(cd "$wt" && pwd -P)
  status=$(treehouse_status "$project" "$pool")
  while IFS= read -r row; do
    path=$(jq -r .path <<<"$row")
    path=$(cd "$path" 2>/dev/null && pwd -P || printf '%s' "$path")
    [ "$path" = "$want" ] || continue
    got=$(jq -c --argjson row "$row" '. + [$row]' <<<"$got")
  done < <(jq -c '.[]' <<<"$status")
  printf '%s\n' "$got"
}

claim_slot() {
  local wt=$1 id=$2 home=$3
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$(dirname "$wt")/.fm-slot-owner"
}

lease_slot() {
  local project=$1 pool=$2 name=$3 holder=$4
  ( cd "$project" && TREEHOUSE_ROOT="$pool" treehouse lease "$name" --lease-holder "$holder" --json )
}

return_slot() {
  local project=$1 pool=$2 wt=$3 lease_id=${4:-} holder=${5:-}
  local args=(return --force "$wt")
  [ -z "$lease_id" ] || args+=(--if-lease-id "$lease_id")
  [ -z "$holder" ] || args+=(--if-lease-holder "$holder")
  ( cd "$project" && TREEHOUSE_ROOT="$pool" treehouse "${args[@]}" >/dev/null )
}

env -u TMUX TMUX_TMPDIR="$TMUX_DIR" HOME="$USER_HOME" PATH="$PATH" \
  TREEHOUSE_ROOT="$LAB/treehouse" tmux -f /dev/null new-session -d -s firstmate -n main '/bin/sleep 3600'
window_alive main || fail 'private tmux server did not start'
pass 'private tmux server is live'

scenario_nested_archive() {
  local dir="$LAB/nested" home="$LAB/nested/home" sub="$LAB/nested/secondmate-home"
  local nested="$LAB/nested/secondmate-home/nested-home" project out err
  project=$(make_local_project "$dir")
  make_home "$home"
  make_home "$sub"
  make_home "$nested"
  printf 'domain\n' > "$sub/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  touch "$home/config/status-archive"
  new_window fm-domain
  new_window fm-nested
  new_window fm-grandchild
  write_meta "$home/state/domain.meta" \
    window=firstmate:fm-domain endpoint_task_id=domain backend=tmux \
    "worktree=$sub" "project=$project" kind=secondmate mode=local-only \
    "home=$sub" spawn_gen=live-domain
  write_meta "$sub/state/nested.meta" \
    window=firstmate:fm-nested endpoint_task_id=nested backend=tmux \
    "worktree=$nested" "project=$project" kind=secondmate mode=local-only \
    "home=$nested" spawn_gen=live-nested
  write_meta "$nested/state/grandchild.meta" \
    window=firstmate:fm-grandchild endpoint_task_id=grandchild backend=tmux \
    "worktree=$dir/missing-grandchild-worktree" "project=$project" kind=scout mode=local-only \
    spawn_gen=live-grandchild
  printf 'done: parent history\n' > "$home/state/domain.status"
  printf 'done: child history\n' > "$sub/state/nested.status"
  printf 'done: grandchild history\n' > "$nested/state/grandchild.status"
  out="$dir/out"; err="$dir/err"
  run_teardown "$home" "$dir/pool" domain "$out" "$err" \
    || fail "nested retirement failed: $(cat "$err")"
  ! window_alive fm-domain || fail 'parent endpoint survived nested retirement'
  ! window_alive fm-nested || fail 'nested endpoint survived nested retirement'
  ! window_alive fm-grandchild || fail 'grandchild endpoint survived nested retirement'
  [ ! -d "$sub" ] || fail 'secondmate home survived nested retirement'
  grep -Fq 'parent history' "$home/data/domain/status.log" || fail 'parent status was not archived'
  grep -Fq 'child history' "$home/data/domain/children/nested/status.log" || fail 'child status was not archived'
  grep -Fq 'grandchild history' "$home/data/domain/children/nested/children/grandchild/status.log" || fail 'grandchild status was not archived'
  pass 'scenario1 live=true nested no-pool retirement archived two levels without a project lock refusal'
}

spawn_scout() {
  local dir=$1 id=$2 project home pool out rc
  project=$(make_origin_project "$dir")
  home="$dir/home"; pool="$dir/pool"
  make_home "$home"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise disposable cleanup behavior for $id.

## Firstmate spec
Run idle in the private tmux lab until teardown.
EOF
  lab_tmux set-environment -g TREEHOUSE_ROOT "$pool"
  lab_tmux set-environment -g HOME "$USER_HOME"
  out="$dir/spawn.out"
  set +e
  env -u TMUX \
    HOME="$USER_HOME" TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$pool" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 FM_SPAWN_NO_GUARD=1 \
    DISABLE_AUTOUPDATER=1 CLAUDE_CONFIG_DIR='' \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" '/bin/sleep 600' --scout --backend tmux >"$out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "spawn $id failed: $(cat "$out")"
  [ -f "$home/state/$id.meta" ] || fail "spawn $id published no metadata"
  window_alive "fm-$id" || fail "spawn $id created no live endpoint"
  printf '%s|%s|%s\n' "$home" "$project" "$pool"
}

scenario_recursive_foreign_refusal() {
  local dir="$LAB/recursive-foreign" home="$LAB/recursive-foreign/home"
  local sub="$LAB/recursive-foreign/subhome" nested="$LAB/recursive-foreign/nestedhome"
  local project pool wt alloc lease name worker out err rc
  project=$(make_local_project "$dir")
  pool="$dir/pool"
  make_home "$home"; make_home "$sub"; make_home "$nested"
  printf 'domain-foreign\n' > "$sub/.fm-secondmate-home"
  printf 'nested-foreign\n' > "$nested/.fm-secondmate-home"
  alloc=$(cd "$project" && TREEHOUSE_ROOT="$pool" treehouse get --lease --lease-holder firstmate:other-task --no-fetch --json)
  wt=$(jq -r .path <<<"$alloc"); lease=$(jq -r .lease_id <<<"$alloc"); name=$(jq -r .name <<<"$alloc")
  git -C "$wt" switch -q -c fm/grandchild-foreign
  printf 'grandchild work\n' > "$wt/work.txt"
  claim_slot "$wt" grandchild-foreign "$nested"
  new_window fm-domain-foreign
  new_window fm-nested-foreign
  new_window fm-grandchild-foreign
  write_meta "$home/state/domain-foreign.meta" \
    window=firstmate:fm-domain-foreign endpoint_task_id=domain-foreign backend=tmux \
    "worktree=$sub" "project=$project" kind=secondmate mode=local-only "home=$sub" spawn_gen=live-domain-foreign
  write_meta "$sub/state/nested-foreign.meta" \
    window=firstmate:fm-nested-foreign endpoint_task_id=nested-foreign backend=tmux \
    "worktree=$nested" "project=$project" kind=secondmate mode=local-only "home=$nested" spawn_gen=live-nested-foreign
  write_meta "$nested/state/grandchild-foreign.meta" \
    window=firstmate:fm-grandchild-foreign endpoint_task_id=grandchild-foreign backend=tmux \
    "worktree=$wt" "project=$project" kind=ship mode=local-only spawn_gen=live-grandchild
  start_worker "$wt"; worker=$STARTED_WORKER_PID
  out="$dir/out"; err="$dir/err"; rc=0
  run_teardown "$home" "$pool" domain-foreign "$out" "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'recursive foreign lease unexpectedly allowed cleanup'
  window_alive fm-domain-foreign || fail 'parent endpoint closed before recursive lease refusal'
  window_alive fm-nested-foreign || fail 'nested endpoint closed before recursive lease refusal'
  window_alive fm-grandchild-foreign || fail 'grandchild endpoint closed before recursive lease refusal'
  kill -0 "$worker" 2>/dev/null || fail 'recursive lease refusal reaped worker'
  [ -f "$nested/state/grandchild-foreign.meta" ] || fail 'recursive lease refusal removed metadata'
  [ "$(cat "$wt/work.txt")" = 'grandchild work' ] || fail 'recursive lease refusal discarded work'
  [ -f "$(dirname "$wt")/.fm-slot-owner" ] || fail 'recursive lease refusal removed slot owner'
  [ "$(jq -r '.[0].lease_holder' <<<"$(treehouse_row_for_path "$project" "$pool" "$wt")")" = firstmate:other-task ] \
    || fail 'recursive lease refusal changed foreign lease'
  grep -Fq "holder 'firstmate:other-task'" "$err" \
    || fail "recursive refusal did not name foreign holder: $(cat "$err")"
  pass 'scenario2 live=true recursive foreign lease refused before endpoint, process, copy, lease, or record mutation'
  lab_tmux kill-window -t '=firstmate:=fm-domain-foreign' 2>/dev/null || true
  lab_tmux kill-window -t '=firstmate:=fm-nested-foreign' 2>/dev/null || true
  lab_tmux kill-window -t '=firstmate:=fm-grandchild-foreign' 2>/dev/null || true
  kill "$worker" 2>/dev/null || true
  return_slot "$project" "$pool" "$wt" "$lease" firstmate:other-task
  : "$name"
}

t3_world() {
  local thread=$1 wt=$2
  jq -cn --arg t "$thread" --arg p "$wt" \
    '{threads:{($t):{threadId:$t,projectId:"proj-1",status:"completed",activeRunId:null,archived:false,worktreePath:$p,pendingRequestCount:0,items:[],runs:[]}}}'
}

prepare_t3_case() {
  local dir=$1 id=$2 holder=$3 lease_mode=$4 with_codex=${5:-no}
  local project pool alloc wt lease name thread
  project=$(make_local_project "$dir" "$with_codex")
  pool="$dir/pool"
  make_home "$dir/home"
  alloc=$(cd "$project" && TREEHOUSE_ROOT="$pool" treehouse get --lease --lease-holder "$holder" --no-fetch --json)
  wt=$(jq -r .path <<<"$alloc"); lease=$(jq -r .lease_id <<<"$alloc"); name=$(jq -r .name <<<"$alloc")
  if [ "$lease_mode" = missing ]; then
    return_slot "$project" "$pool" "$wt" "$lease" "$holder"
  fi
  git -C "$wt" switch -q -c "fm/$id"
  printf 'task work\n' > "$wt/work.txt"
  claim_slot "$wt" "$id" "$dir/home"
  thread="mcp:$(printf '%s' "$id" | shasum -a 256 | awk '{print substr($1,1,8)"-1111-4111-8111-111111111111"}')"
  t3_fake_case "$dir/t3-case" "$(t3_world "$thread" "$wt")"
  t3_fake_credential "$dir/home/config/t3code-token"
  write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" backend=t3code \
    "worktree=$wt" "project=$project" kind=scout mode=local-only harness=claude \
    "t3_thread_id=$thread" t3_project_id=proj-1 spawn_gen="live-$id" \
    "treehouse_lease_id=$lease" "treehouse_lease_holder=$id"
  PREP_PROJECT=$project
  PREP_POOL=$pool
  PREP_WT=$wt
  PREP_LEASE=$lease
  PREP_NAME=$name
  PREP_THREAD=$thread
}

scenario_t3_lease_matrix() {
  local label dir id holder mode project pool wt lease name thread worker out err rc rows state_file status status_rc
  for label in missing foreign ambiguous; do
    dir="$LAB/t3-$label"; id="t3-$label"; holder="$id"; mode=held
    [ "$label" != missing ] || mode=missing
    [ "$label" != foreign ] || holder=other-task
    prepare_t3_case "$dir" "$id" "$holder" "$mode"
    project=$PREP_PROJECT; pool=$PREP_POOL; wt=$PREP_WT
    lease=$PREP_LEASE; name=$PREP_NAME; thread=$PREP_THREAD
    if [ "$label" = ambiguous ]; then
      state_file=$(rg --files --hidden --no-ignore "$pool" -g treehouse-state.json)
      [ "$(printf '%s\n' "$state_file" | wc -l | tr -d ' ')" -eq 1 ] \
        || fail "expected one disposable Treehouse state file, got: $state_file"
      [ -n "$state_file" ] || fail 'could not locate disposable Treehouse state'
      cp "$state_file" "$dir/treehouse-state.before.json"
      jq '.worktrees += [(.worktrees[0] | .name = "2")]' "$state_file" > "$dir/treehouse-state.next.json"
      mv "$dir/treehouse-state.next.json" "$state_file"
      set +e
      status=$(treehouse_status "$project" "$pool" 2>"$dir/status.err")
      status_rc=$?
      set -e
      [ "$status_rc" -eq 0 ] || fail "real Treehouse rejected duplicate fixture: state=$(jq -c . "$state_file") error=$(cat "$dir/status.err")"
      rows=$(jq --arg p "$wt" '[.[] | select(.path == $p)] | length' <<<"$status")
      [ "$rows" -eq 2 ] || fail "real Treehouse did not expose the duplicated inventory row (rows=$rows)"
      # The first real status read normalizes the synthetic second row and may
      # preserve pre-existing scratch in its recovery backup. Stage the task's
      # live work after that normalization so only teardown is under test.
      printf 'task work\n' > "$wt/work.txt"
    fi
    start_worker "$wt"; worker=$STARTED_WORKER_PID
    out="$dir/out"; err="$dir/err"; rc=0
    run_teardown "$dir/home" "$pool" "$id" "$out" "$err" || rc=$?
    [ "$rc" -ne 0 ] || fail "$label T3 lease unexpectedly allowed cleanup"
    [ -z "$(t3_fake_mutations)" ] || fail "$label T3 lease changed endpoint before refusal: $(t3_fake_mutations)"
    kill -0 "$worker" 2>/dev/null || fail "$label T3 refusal reaped worker"
    [ -f "$dir/home/state/$id.meta" ] || fail "$label T3 refusal removed metadata"
    [ -f "$wt/work.txt" ] && [ "$(cat "$wt/work.txt")" = 'task work' ] \
      || fail "$label T3 refusal discarded work: stderr=$(cat "$err") status=$(treehouse_status "$project" "$pool" 2>/dev/null || true)"
    [ -f "$(dirname "$wt")/.fm-slot-owner" ] || fail "$label T3 refusal removed slot owner"
    case "$label" in
      missing) grep -Fq 'not listed under a Treehouse lease' "$err" || fail 'missing T3 lease refusal reason absent' ;;
      foreign) grep -Fq "holder 'other-task'" "$err" || fail 'foreign T3 lease refusal reason absent' ;;
      ambiguous) grep -Fq 'listed 2 times' "$err" || fail 'ambiguous T3 lease refusal reason absent' ;;
    esac
    pass "scenario3-$label live=true T3 refusal preserved endpoint, process, copy, lease state, and record"
    kill "$worker" 2>/dev/null || true
    if [ "$label" = ambiguous ]; then
      cp "$dir/treehouse-state.before.json" "$state_file"
    fi
    if [ "$label" != missing ]; then
      return_slot "$project" "$pool" "$wt" "$lease" "$holder"
    fi
    : "$name" "$thread"
  done
}

scenario_spawn_guard() {
  local dir="$LAB/spawn-guard" rec home project pool id=ordinary-guard wt row name out err rc lease holder listed meta next
  rec=$(spawn_scout "$dir" "$id")
  IFS='|' read -r home project pool <<<"$rec"
  wt=$(sed -n 's/^worktree=//p' "$home/state/$id.meta")
  row=$(treehouse_row_for_path "$project" "$pool" "$wt")
  [ "$(jq length <<<"$row")" -eq 1 ] \
    || fail "spawned ordinary copy not present once in Treehouse inventory: wt=$wt meta=$(tr '\n' ' ' < "$home/state/$id.meta") status=$(treehouse_status "$project" "$pool" 2>/dev/null || true)"
  name=$(jq -r '.[0].name' <<<"$row")
  listed=$(jq -r '.[0].path' <<<"$row")
  lease=$(jq -r '.[0].lease_id // ""' <<<"$row")
  holder=$(jq -r '.[0].lease_holder // ""' <<<"$row")
  [ -f "$(dirname "$wt")/.fm-slot-owner" ] || fail 'spawn did not publish slot owner claim'
  [ -n "$lease" ] && [ "$holder" = "firstmate:$id" ] || fail 'real spawn did not publish its initial reservation'
  # Convert the real spawn into the legacy unrecorded-copy state under test:
  # release its modern reservation, keep its Firstmate owner claim and record,
  # then recreate the same private endpoint on the same available pool copy.
  return_slot "$project" "$pool" "$listed" "$lease" "$holder"
  lab_tmux kill-window -t "=firstmate:=fm-$id" 2>/dev/null || true
  lab_tmux new-window -d -t firstmate -n "fm-$id" -c "$wt" '/bin/sleep 600'
  printf 'legacy live work\n' > "$wt/work.txt"
  meta="$home/state/$id.meta"; next="$home/state/$id.meta.next"
  grep -v '^treehouse_lease_' "$meta" > "$next"
  mv "$next" "$meta"
  row=$(treehouse_row_for_path "$project" "$pool" "$wt")
  [ -z "$(jq -r '.[0].lease_id // ""' <<<"$row")" ] || fail 'legacy ordinary fixture still had a durable lease'
  window_alive "fm-$id" || fail 'legacy ordinary fixture did not recreate endpoint'
  out="$dir/out"; err="$dir/err"
  run_teardown "$home" "$pool" "$id" "$out" "$err" || fail "guarded ordinary cleanup failed: $(cat "$err")"
  ! window_alive "fm-$id" || fail 'guarded ordinary cleanup left endpoint alive'
  [ ! -f "$home/state/$id.meta" ] || fail 'guarded ordinary cleanup left metadata'
  row=$(treehouse_row_for_path "$project" "$pool" "$wt")
  [ "$(jq -r '.[0].status' <<<"$row")" = available ] || fail 'guarded ordinary cleanup did not return copy'
  [ -z "$(jq -r '.[0].lease_id // ""' <<<"$row")" ] || fail 'guarded ordinary cleanup stranded lease'
  [ ! -e "$(dirname "$wt")/.fm-slot-owner" ] || fail 'guarded ordinary cleanup stranded slot owner'
  pass 'scenario4-permitted live=true real spawn took a guard lease and cleanup completed'

  dir="$LAB/spawn-guard-refusal"; id=ordinary-guard-refusal
  rec=$(spawn_scout "$dir" "$id")
  IFS='|' read -r home project pool <<<"$rec"
  wt=$(sed -n 's/^worktree=//p' "$home/state/$id.meta")
  row=$(treehouse_row_for_path "$project" "$pool" "$wt")
  name=$(jq -r '.[0].name' <<<"$row")
  listed=$(jq -r '.[0].path' <<<"$row")
  lease=$(jq -r '.[0].lease_id // ""' <<<"$row")
  holder=$(jq -r '.[0].lease_holder // ""' <<<"$row")
  return_slot "$project" "$pool" "$listed" "$lease" "$holder"
  lab_tmux kill-window -t "=firstmate:=fm-$id" 2>/dev/null || true
  lab_tmux new-window -d -t firstmate -n "fm-$id" -c "$wt" '/bin/sleep 600'
  printf 'legacy live work\n' > "$wt/work.txt"
  meta="$home/state/$id.meta"; next="$home/state/$id.meta.next"
  grep -v '^treehouse_lease_' "$meta" > "$next"
  mv "$next" "$meta"
  lease_slot "$project" "$pool" "$name" firstmate:other-task > "$dir/foreign-lease.json"
  out="$dir/out"; err="$dir/err"; rc=0
  run_teardown "$home" "$pool" "$id" "$out" "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'foreign guard holder unexpectedly allowed ordinary cleanup'
  window_alive "fm-$id" || fail 'ordinary guard refusal closed endpoint'
  [ -f "$home/state/$id.meta" ] || fail 'ordinary guard refusal removed metadata'
  [ -d "$wt" ] || fail 'ordinary guard refusal removed copy'
  [ -f "$(dirname "$wt")/.fm-slot-owner" ] || fail 'ordinary guard refusal removed slot owner'
  [ "$(jq -r '.[0].lease_holder' <<<"$(treehouse_row_for_path "$project" "$pool" "$wt")")" = firstmate:other-task ] \
    || fail 'ordinary guard refusal changed foreign lease'
  grep -Fq "holder 'firstmate:other-task'" "$err" || fail 'ordinary guard refusal did not name holder'
  pass 'scenario4-refused live=true lost guard preserved endpoint, copy, lease, and record'
  lab_tmux kill-window -t "=firstmate:=fm-$id" 2>/dev/null || true
  return_slot "$project" "$pool" "$(jq -r .path "$dir/foreign-lease.json")" \
    "$(jq -r .lease_id "$dir/foreign-lease.json")" firstmate:other-task
}

scenario_t3_codex_cleanup() {
  local dir="$LAB/t3-codex" id=t3-codex-valid project pool wt lease name thread worker out err original row
  prepare_t3_case "$dir" "$id" "$id" held yes
  project=$PREP_PROJECT; pool=$PREP_POOL; wt=$PREP_WT
  lease=$PREP_LEASE; name=$PREP_NAME; thread=$PREP_THREAD
  original=$(cat "$wt/.codex/config.toml")
  "$ROOT/bin/fm-t3code-codex-env.sh" install "$wt" FM_TASK_ID="$id"
  grep -Fq '[shell_environment_policy]' "$wt/.codex/config.toml" || fail 'Codex environment overlay was not installed'
  start_worker "$wt"; worker=$STARTED_WORKER_PID
  out="$dir/out"; err="$dir/err"
  run_teardown "$dir/home" "$pool" "$id" "$out" "$err" || fail "valid T3 Codex cleanup failed: $(cat "$err")"
  [ "$(t3_fake_mutations)" = t3_thread_organize ] || fail "valid T3 cleanup did not archive exactly its endpoint: $(t3_fake_mutations)"
  ! kill -0 "$worker" 2>/dev/null || fail 'valid T3 cleanup left worktree process alive'
  [ ! -f "$dir/home/state/$id.meta" ] || fail 'valid T3 cleanup left metadata'
  [ "$(cat "$wt/.codex/config.toml")" = "$original" ] || fail 'valid T3 cleanup did not restore project Codex config'
  row=$(treehouse_row_for_path "$project" "$pool" "$wt")
  [ "$(jq -r '.[0].status' <<<"$row")" = available ] || fail 'valid T3 cleanup did not return copy'
  [ -z "$(jq -r '.[0].lease_id // ""' <<<"$row")" ] || fail 'valid T3 cleanup stranded bare-id lease'
  [ ! -e "$(dirname "$wt")/.fm-slot-owner" ] || fail 'valid T3 cleanup stranded slot owner'
  pass 'scenario5 live=true valid T3 Codex cleanup archived endpoint, restored config, and returned exact bare-id lease'
  : "$lease" "$name" "$thread"
}

t3_fake_start "$LAB/t3-server"
scenario_nested_archive
scenario_recursive_foreign_refusal
scenario_t3_lease_matrix
scenario_spawn_guard
scenario_t3_codex_cleanup

[ -z "$(git -C "$ROOT" status --porcelain=v1)" ] || fail 'verification dirtied the worktree'
pass 'all five requested live cleanup scenarios passed'

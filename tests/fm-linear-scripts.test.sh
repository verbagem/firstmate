#!/usr/bin/env bash
# Behavior and parse checks for retained Linear bridge helper scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_linear_node_scripts_parse() {
  local script
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found"
    return 0
  fi
  for script in \
    bin/fm-linear-team-reshape.mjs \
    bin/fm-linear-team-scaffold.mjs; do
    node --check "$ROOT/$script" >/dev/null \
      || fail "$script failed node --check"
  done
  pass "linear scripts parse as Node modules"
}

test_linear_poll_publishes_waiting_intake_without_dispatch() {
  local dir script_root command_center calls exec_log out brief final_body
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  dir=$(fm_test_tmproot fm-linear-poll)
  command_center="$dir/command-center"
  script_root="$command_center/ops/firstmate"
  calls="$dir/fetch.jsonl"
  exec_log="$dir/exec.log"
  mkdir -p "$script_root/bin" "$command_center/_config"
  cp "$ROOT/bin/fm-linear-poll.mjs" "$script_root/bin/fm-linear-poll.mjs"
  printf '%s\n' \
    'BH1VE_SUPABASE_URL=https://supabase.test' \
    'BH1VE_SUPABASE_SERVICE_KEY=test-supabase' \
    > "$command_center/_config/.env"
  cat > "$script_root/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-brief %s\n' "$*" >> "${FM_LINEAR_EXEC_LOG:?}"
mkdir -p "$(dirname "$0")/../data/$1"
printf '{TASK}\n{FIRSTMATE_SPEC}\n' > "$(dirname "$0")/../data/$1/brief.md"
SH
  cat > "$script_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-spawn %s\n' "$*" >> "${FM_LINEAR_EXEC_LOG:?}"
SH
  chmod +x "$script_root/bin/fm-brief.sh" "$script_root/bin/fm-spawn.sh"
  cat > "$dir/mock-fetch.cjs" <<'JS'
const fs = require("node:fs");
const row = {
  id: "queue-1",
  linear_identifier: "FIR-42",
  linear_issue_id: "issue-42",
  linear_team_id: "69890873-b361-445d-a39f-f9f470d4aa9e",
  linear_url: "https://linear.test/issue/FIR-42",
  title: "Repair dispatch ownership",
  description: "Keep judgement with Firstmate."
};
global.fetch = async (url, init = {}) => {
  const method = init.method || "GET";
  const body = init.body ? JSON.parse(init.body) : null;
  fs.appendFileSync(process.env.FM_LINEAR_FETCH_LOG, JSON.stringify({ url: String(url), method, body }) + "\n");
  if (String(url).startsWith("https://api.linear.app/")) throw new Error("unexpected Linear mutation");
  if (method === "GET") return { ok: true, status: 200, json: async () => [row] };
  if (String(url).includes("status=eq.pending")) return { ok: true, status: 200, json: async () => [{ ...row, status: "claimed" }] };
  return { ok: true, status: 200, json: async () => [{ ...row, ...body }] };
};
JS

  out=$(NODE_OPTIONS="--require=$dir/mock-fetch.cjs" \
    FM_LINEAR_FETCH_LOG="$calls" FM_LINEAR_EXEC_LOG="$exec_log" \
    node "$script_root/bin/fm-linear-poll.mjs" 2> "$dir/stderr") \
    || fail "linear poll failed: $(cat "$dir/stderr")"
  brief="$script_root/data/linear-fir-42/brief.md"
  assert_present "$brief" "linear poll did not publish the durable intake scaffold"
  assert_contains "$out" 'waiting-for-dispatch FIR-42 -> linear-fir-42' "linear poll did not report its stop state"
  assert_contains "$(cat "$brief")" 'Status: waiting-for-dispatch' "intake scaffold did not record its stop state"
  assert_contains "$(cat "$brief")" '## Captain'"'"'s intent' "intake scaffold omitted the source request"
  assert_contains "$(cat "$brief")" '## Firstmate spec' "intake scaffold omitted the Firstmate-owned specification section"
  assert_contains "$(cat "$brief")" 'Dispatch profile' "intake scaffold did not leave dispatch judgement explicit"
  [ ! -e "$exec_log" ] || fail "linear poll launched a brief or worker command: $(cat "$exec_log")"
  [ "$(jq -s '[.[] | select(.url | startswith("https://api.linear.app/"))] | length' "$calls")" -eq 0 ] \
    || fail "linear poll mutated the Linear issue before dispatch"
  final_body=$(jq -sc '[.[] | select(.method == "PATCH" and (.url | contains("id=eq.queue-1")))] | last | .body' "$calls")
  [ "$(jq -r .status <<<"$final_body")" = waiting_for_dispatch ] \
    || fail "queue row did not stop in waiting_for_dispatch: $final_body"
  [ "$(jq -r .firstmate_task_id <<<"$final_body")" = linear-fir-42 ] \
    || fail "queue row did not retain the durable Firstmate task id"
  pass "linear poll publishes a durable intake and stops before dispatch authority"
}

test_linear_node_scripts_parse
test_linear_poll_publishes_waiting_intake_without_dispatch

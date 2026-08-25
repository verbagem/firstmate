#!/usr/bin/env bash
# Captain-lane transcript harness.
#
# Runs the REAL tracked Pi primary watcher extension against a fixture Firstmate
# home and records every FIRSTMATE_OP follow-up that would land in the captain's
# main command lane. The extension, bin/fm-wake-drain.sh and bin/fm-wake-lib.sh
# are taken from the git revision named by $1 so the same scenario can be
# replayed against the pre-fix and post-fix trees.
#
# usage: captain-lane-harness.sh <git-rev> <scenario>
#   scenario = empty-rearm | queued-row | open-decision | unread-note | real-signal
set -u
REV=$1
SCENARIO=$2
SRC_REPO=${SRC_REPO:?}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/captain-lane.XXXXXX")
repo="$WORK/root"; home="$WORK/home"
mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state" "$home/config" \
  "$repo/node_modules/@earendil-works/pi-coding-agent" \
  "$repo/node_modules/@earendil-works/pi-tui" "$repo/node_modules/typebox"

cd "$SRC_REPO" || exit 1
git show "$REV:.pi/extensions/fm-primary-pi-watch.ts" > "$repo/.pi/extensions/fm-primary-pi-watch.ts" || exit 1
git show "$REV:bin/fm-wake-drain.sh" > "$repo/bin/fm-wake-drain.sh" || exit 1
git show "$REV:bin/fm-wake-lib.sh" > "$repo/bin/fm-wake-lib.sh" || exit 1
for f in .pi/extensions/lib/fm-calm-visibility.ts .pi/extensions/lib/fm-operational-input.ts \
         bin/fm-operational-input.sh bin/fm-classify-lib.sh bin/fm-line-cap-lib.sh; do
  cp "$SRC_REPO/$f" "$repo/$f" || exit 1
done
chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-wake-drain.sh"
printf '%s' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent { render() { return []; } invalidate() {} }
JS
printf '%s' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/@earendil-works/pi-tui/package.json"
cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box { addChild() {} clear() {} setBgFn() {} }
export class Container {}
export class Text {}
JS
printf '%s' '{"name":"typebox","type":"module","exports":"./index.js"}' \
  > "$repo/node_modules/typebox/package.json"
cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = { Object(p) { return { type: "object", properties: p, additionalProperties: false }; } };
JS

# Scenario state: what the captain-work peek would find in the fleet.
REASON='check: rearm-resurface'
case "$SCENARIO" in
  empty-rearm)   : ;;   # nothing queued, no decision, no unread note
  queued-row)    printf '1700000000\t1\tcheck\tstartup-network\tcheck: startup-network\n' > "$home/state/.wake-queue" ;;
  open-decision) printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/task1.status" ;;
  unread-note)   printf 'note: captain said use REST not RPC\n' > "$home/state/task1.status" ;;
  real-signal)   REASON='signal: worker.status' ;;
  *) echo "unknown scenario $SCENARIO" >&2; exit 2 ;;
esac

# Scripted watcher: closes with the scenario reason for the first CYCLES arms,
# i.e. the watcher keeps re-arming and resurfacing exactly as it did on the Pi.
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# FM_CONFIRM_RC models fm-watch-arm.sh failing to confirm silent handling.
if [ "${1:-}" = --handling-delivered ]; then exit "${FM_CONFIRM_RC:-0}"; fi
count=0
[ -f "$FM_ARM_LOG" ] && count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
count=$((count + 1))
printf 'arm=%s count=%s\n' "$$" "$count" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$count"
# ONESHOT models a single real occurrence: the reason surfaces on the first
# close only. Otherwise every close before the final one resurfaces it, which
# is how the observed rearm-resurface storm actually looked.
if { [ "${FM_ONESHOT:-0}" = 1 ] && [ "$count" -eq 1 ]; } \
  || { [ "${FM_ONESHOT:-0}" != 1 ] && [ "$count" -lt "${FM_CYCLES:?}" ]; }; then
  printf '%s\n' "${FM_REASON:?}"
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
chmod +x "$repo/bin/fm-watch-arm.sh"

NODE_NO_WARNINGS=1 PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$WORK/arm.log" \
FM_STOP_FILE="$WORK/stop" FM_REASON="$REASON" FM_CYCLES="${CYCLES:-12}" \
FM_ONESHOT="${ONESHOT:-0}" FM_CONFIRM_RC="${CONFIRM_RC:-0}" \
SCENARIO="$SCENARIO" REV_LABEL="${REV_LABEL:-$REV}" \
node --input-type=module <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const lane = [];
let tool = null;
const pi = {
  on() {}, registerCommand() {},
  registerTool(c) { if (c.name === "fm_watch_arm_pi") tool = c; },
  sendUserMessage: async (m) => { lane.push(m); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const arms = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
await tool.execute("captain-lane", {}, undefined, undefined, {});
const want = Number(process.env.FM_CYCLES);
for (let i = 0; i < 600 && arms() < want; i += 1) await new Promise((r) => setTimeout(r, 10));
await new Promise((r) => setTimeout(r, 250));
writeFileSync(process.env.FM_STOP_FILE, "stop\n");

console.log(`=== tree ${process.env.REV_LABEL} | scenario ${process.env.SCENARIO} | watcher re-armed ${arms()}x ===`);
console.log(`captain command lane received ${lane.length} FIRSTMATE_OP follow-up(s):`);
if (lane.length === 0) console.log("  (lane silent)");
lane.forEach((m, i) => {
  const first = m.split("\n").find((l) => l.trim()) || "";
  console.log(`  ${String(i + 1).padStart(3)}. ${first.replace(/⁣/g, "").slice(0, 96)}`);
});
console.log("");
EOF
rc=$?
rm -rf "$WORK"
exit $rc

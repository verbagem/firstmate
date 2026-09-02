// fm-task-recap: captain-facing recap widget for a Firstmate-managed Pi
// ship/scout task. Loaded only for that kind of spawn (fm-spawn.sh's
// launch_template, pi|pi-signed branch) via an explicit -e path outside the
// task's own worktree, exactly like the busy-state extension it sits beside
// - never inside the project, so it never trips Pi's project-trust dialog.
//
// This is a presentation surface only: every field comes from bin/fm-pi-recap.sh,
// which is itself a pure read of the SAME authoritative owners the fleet-state
// digest and supervision protocol already use (bin/fm-classify-lib.sh's status
// folding, state/<id>.meta's pr=, and the task's data/backlog.md title). No
// parallel state is created here or in the shell script it calls.
//
// Uses Pi's native ctx.ui.setWidget(key, lines, {placement: "belowEditor"}) -
// the same mechanism the captain's own pai-bq-statusline extension proves
// works under Herdr (live-verified: distinct widget keys coexist, neither
// replaces the other; see docs/verification/runtime-backends.md). A distinct
// WIDGET_KEY from pai-bq-statusline.ts's is what makes that coexistence safe.
//
// Required env vars (set only for ship/scout Pi launches by fm-spawn.sh):
//   FM_RECAP_TASK_ID   the task id
//   FM_RECAP_STATE_DIR the firstmate home's state directory (absolute)
//   FM_RECAP_DATA_DIR  the firstmate home's data directory (absolute)
// Any missing var, a script failure, or the absence of ctx.ui is a silent
// no-op: a failure to render the recap must never touch the worker's turn.
import { execFile } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const WIDGET_KEY = "fm-task-recap";
const RENDER_TIMEOUT_MS = 2000;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const recapScript = resolve(extensionDir, "../../bin/fm-pi-recap.sh");

const taskId = process.env.FM_RECAP_TASK_ID;
const stateDir = process.env.FM_RECAP_STATE_DIR;
const dataDir = process.env.FM_RECAP_DATA_DIR;

function runRecapScript(id: string, state: string, data: string): Promise<string[]> {
  return new Promise((resolve_) => {
    execFile(
      recapScript,
      ["render", id, state, data],
      { timeout: RENDER_TIMEOUT_MS },
      (err, stdout) => {
        if (err) {
          resolve_([]);
          return;
        }
        resolve_(
          stdout
            .split("\n")
            .map((line) => line.trimEnd())
            .filter((line) => line.length > 0),
        );
      },
    );
  });
}

// Meaningful-change dedup: skip the widget call entirely when the rendered
// text is byte-identical to the last successful render this process has
// shown. Cheap in-memory string compare - no cache file, no new state - and
// it is exactly what "no unchanged noise" needs, since fm-pi-recap.sh is a
// pure function of the task's durable records: identical output means
// nothing captain-relevant changed.
let lastRendered: string | undefined;
let inFlight: Promise<void> = Promise.resolve();

async function render(pi: ExtensionAPI, ctx: ExtensionContext): Promise<void> {
  try {
    if (!ctx.hasUI || !taskId || !stateDir || !dataDir) return;
    const lines = await runRecapScript(taskId, stateDir, dataDir);
    if (lines.length === 0) return;
    const rendered = lines.join("\n");
    if (rendered === lastRendered) return;
    lastRendered = rendered;
    ctx.ui.setWidget(WIDGET_KEY, lines, { placement: "belowEditor" });
  } catch {
    // Inert on any failure - the recap is never allowed to affect the turn.
  }
}

// Turn boundaries never wait on the recap: the render (an execFile of a bash
// script, bounded by RENDER_TIMEOUT_MS) runs off Pi's critical path and the
// widget catches up whenever it finishes. session_start still awaits so the
// first frame the captain sees already carries the recap.
function renderDetached(pi: ExtensionAPI, ctx: ExtensionContext): void {
  inFlight = render(pi, ctx);
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => render(pi, ctx));
  pi.on("turn_start", (_event, ctx) => { renderDetached(pi, ctx); });
  pi.on("turn_end", (_event, ctx) => { renderDetached(pi, ctx); });
}

export const __fmTaskRecapTest = {
  runRecapScript,
  resetForTest: () => { lastRendered = undefined; },
  settle: () => inFlight,
};

#!/usr/bin/env node
// Poll the linear_dispatch_queue Supabase table (the Vercel webhook's bridge
// table - see ops/linear-dispatch-webhook/) for Linear issues that entered
// Next + agent-ready, claim them, and publish a durable Firstmate intake for
// each. This is Component 2's Firstmate-side half of
// resources/modern-ai-productivity-pack/01-SHARED-WORKSPACE.md's dispatch flow.
//
// Design (see ops/firstmate/data/learnings.md "Linear Modern AI Productivity
// Pack integration" for the full architecture and IDs):
//   Linear (Next + agent-ready) -> Vercel webhook -> Supabase queue row (pending)
//     -> this poller claims it (compare-and-swap on status='pending') and:
//        1. best-effort creates a Notion Task under the matching business
//           Project (skipped gracefully if no mapping exists yet)
//        2. writes a complete local intake scaffold
//        3. marks the Supabase row waiting_for_dispatch
// Firstmate still owns task classification, delivery mode, merge authority,
// model-profile resolution, and worker launch.
//
// Run manually (one pass) or wire into a periodic wakeup; this script does
// not loop or daemonize itself - one invocation is one pass over pending rows.
//
// Routing is by Linear TEAM, not Project (2026-07-20 restructure: every
// business is now its own Linear team with the standard 5-state/3-label
// shape - see bin/fm-linear-team-scaffold.mjs / fm-linear-team-reshape.mjs -
// rather than one shared team holding a Project per business). The webhook
// is workspace-wide (allPublicTeams) so it fires for issues in any team.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const FM_ROOT = path.resolve(fileURLToPath(import.meta.url), "..", "..");
const COMMAND_CENTER_ROOT = path.resolve(FM_ROOT, "..", "..");
const ENV_PATH = path.join(COMMAND_CENTER_ROOT, "_config", ".env");

// Linear team id -> where a crewmate should work + which Notion Project gets
// the plan-before-dispatch Task. All 13 teams have a Notion Project as of
// 2026-07-21 (the first 9 businesses shipped with the standard Project
// template's Nav+Tasks+Notes views; the other 9 do NOT - Notion's
// template-apply API was reproducibly broken that session, see the
// yellow-callout note on each of those pages and re-apply template
// `1f66723139938114b8bae87d6a26e0f2` once it's confirmed working again).
const TEAM_ROUTING = {
  "2371d781-641f-4fb9-9664-812a2b9ba01a": { name: "Command Center", repo: "claude-skills", business: null, notionProject: "https://app.notion.com/p/3a36723139938117832dcdc360491d11" },
  "f4d9d1c1-8cf9-4d17-82da-6a8591bf9544": { name: "BuyBox", repo: "command-center", business: "businesses/on-hold/buybox/", notionProject: "https://app.notion.com/p/3a467231399381298d1dc8d032cc45d5" },
  "69890873-b361-445d-a39f-f9f470d4aa9e": { name: "Firstmate", repo: "claude-skills", business: null, notionProject: "https://app.notion.com/p/3a36723139938117832dcdc360491d11" },
  "92040d34-1452-4921-8e2a-38efa678f9ff": { name: "Cold Email", repo: "command-center", business: "businesses/cold-email/", notionProject: "https://app.notion.com/p/3a467231399381d8a49ae92824b3540f" },
  "3f86ee73-9df5-4eeb-87d5-aa447725adb1": { name: "Upwork", repo: "command-center", business: "businesses/upwork/", notionProject: "https://app.notion.com/p/3a467231399381c7a5f6f009ba3d1979" },
  "2b259fd2-bae3-4574-9d4f-f1932d8483e5": { name: "EpicOS", repo: "command-center", business: "businesses/epic-os/", notionProject: "https://app.notion.com/p/3a467231399381ebbc39fe0cc55cd9bd" },
  "1a76e9c8-2227-4da7-b73d-26b3193e8e41": { name: "UltraStays", repo: "command-center", business: "businesses/ultra-stays/", notionProject: "https://app.notion.com/p/3a467231399381a5b145fcb1122a1d47" },
  "2d7acd3b-f909-4876-aa29-27e9c84880d7": { name: "BrandonQ", repo: "command-center", business: "businesses/brandonq/", notionProject: "https://app.notion.com/p/3a4672313993818f9e39fc271e34fb38" },
  "c7976784-da5b-4459-aea8-465433b30c02": { name: "OmniFlows", repo: "command-center", business: "businesses/omniflows/", notionProject: "https://app.notion.com/p/3a467231399381ae90fcc57e04da16b0" },
  "ee5b177c-7fca-44ee-b2f8-774541ae656a": { name: "MonetizedMind", repo: "command-center", business: "businesses/monetized-mind/", notionProject: "https://app.notion.com/p/124672313993802f9cb2dc949f59947f" },
  "bd9a7a03-d1d6-4cd0-8041-571a7595bd91": { name: "Real Estate", repo: "command-center", business: "businesses/real-estate/", notionProject: "https://app.notion.com/p/3a367231399381648a3ed28272e1e717" },
  "a1b2d189-a7ce-4603-ac63-57c0554376f0": { name: "Acquisitions", repo: "command-center", business: "businesses/acquisitions/", notionProject: "https://app.notion.com/p/3a467231399381f6a3fcc48c46eb8f0d" },
  "a8ea0815-4072-4cbc-9921-4b02462c0fc0": { name: "Content Machine", repo: "command-center", business: "businesses/content-machine/", notionProject: "https://app.notion.com/p/3a46723139938191937ffa5a8c7ff6b0" },
};

const NOTION_TASKS_DATA_SOURCE_ID = "1f667231-3993-81da-a58d-000bdacdb111";

function loadEnv(envPath) {
  const env = {};
  if (!existsSync(envPath)) return env;
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    env[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
  return env;
}

const env = loadEnv(ENV_PATH);
const SUPABASE_URL = env.BH1VE_SUPABASE_URL;
const SUPABASE_SERVICE_KEY = env.BH1VE_SUPABASE_SERVICE_KEY;
const NOTION_API_KEY = env.NOTION_API_KEY;

function fail(message) {
  process.stderr.write(`fm-linear-poll: ${message}\n`);
  process.exitCode = 1;
}

if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
  fail("missing BH1VE_SUPABASE_URL / BH1VE_SUPABASE_SERVICE_KEY in _config/.env");
  process.exit(1);
}
// NOTION_API_KEY is optional: if absent, createNotionTask logs and skips
// rather than blocking intake publication.

async function supabase(pathAndQuery, init = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    ...init,
    headers: {
      apikey: SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`supabase ${init.method || "GET"} ${pathAndQuery} -> ${res.status}: ${body}`);
  }
  return res.json();
}

async function claimPendingRows() {
  // Compare-and-swap: only rows still status='pending' actually update, so two
  // concurrent poll runs can never both claim the same row.
  const claimedAt = new Date().toISOString();
  const rows = await supabase(
    `linear_dispatch_queue?status=eq.pending&order=created_at.asc&limit=10`,
  );
  const claimed = [];
  for (const row of rows) {
    const updated = await supabase(
      `linear_dispatch_queue?id=eq.${row.id}&status=eq.pending`,
      {
        method: "PATCH",
        body: JSON.stringify({ status: "claimed", claimed_at: claimedAt, claimed_by: "firstmate-primary" }),
      },
    );
    if (updated.length > 0) claimed.push(updated[0]);
  }
  return claimed;
}

async function markRow(id, fields) {
  await supabase(`linear_dispatch_queue?id=eq.${id}`, { method: "PATCH", body: JSON.stringify(fields) });
}

function slugify(identifier) {
  return `linear-${identifier.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
}

function notionProjectPageId(notionProjectUrl) {
  // Notion page URLs from notion-create-pages/notion-fetch look like
  // https://app.notion.com/p/<32-hex-no-dashes>; the raw REST API wants a
  // UUID (dashes optional, but insert them for clarity/consistency with how
  // Notion itself renders ids elsewhere in this repo's memory files).
  const hex = notionProjectUrl.split("/p/")[1];
  if (!hex || hex.length < 32) throw new Error(`unrecognized Notion page URL: ${notionProjectUrl}`);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

async function createNotionTask(routing, row) {
  if (!routing.notionProject) return null;
  if (!NOTION_API_KEY) {
    process.stdout.write(`notion task skipped for ${row.linear_identifier}: NOTION_API_KEY not set in _config/.env\n`);
    return null;
  }
  // Real creation via Notion's REST API directly (not the notion-workspace
  // MCP tools - this is a plain node script, not an agent turn, so it has no
  // MCP access). This is Gate 1 of the plan-before-dispatch rule in
  // data/captain.md: the Task must actually exist before the crewmate spawns,
  // not a request-for-later.
  const res = await fetch("https://api.notion.com/v1/pages", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${NOTION_API_KEY}`,
      "Notion-Version": "2025-09-03",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      parent: { data_source_id: NOTION_TASKS_DATA_SOURCE_ID },
      properties: {
        Name: { title: [{ text: { content: `Linear ${row.linear_identifier}: ${row.title}` } }] },
        Status: { status: { name: "To Do" } },
        Project: { relation: [{ id: notionProjectPageId(routing.notionProject) }] },
      },
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`notion task create failed: ${res.status} ${body}`);
  }
  const page = await res.json();
  return page.id;
}

async function publishIntake(row) {
  const routing = TEAM_ROUTING[row.linear_team_id];
  if (!routing) {
    await markRow(row.id, { status: "failed" });
    process.stdout.write(`skipped ${row.linear_identifier}: no TEAM_ROUTING entry for team id "${row.linear_team_id}"\n`);
    return;
  }

  const taskId = slugify(row.linear_identifier);
  try {
    const notionTaskId = await createNotionTask(routing, row);
    const taskDir = path.join(FM_ROOT, "data", taskId);
    const briefPath = path.join(taskDir, "brief.md");
    const businessLine = routing.business ? `Business area: \`${routing.business}\`.\n\n` : "";
    const taskText =
      `${businessLine}${row.title}\n\n${row.description || "(no description on the Linear issue)"}\n\n` +
      `Source: Linear issue ${row.linear_identifier} — ${row.linear_url}`;
    const notionLine = notionTaskId ? `\nNotion task: ${notionTaskId}` : "";
    const scaffold = `# Linear intake\n\n` +
      `Status: waiting-for-dispatch\n` +
      `Task id: ${taskId}\n` +
      `Project: projects/${routing.repo}${notionLine}\n\n` +
      `# Task\n\n## Captain's intent\n\n${taskText}\n\n` +
      `## Firstmate spec\n\n` +
      `Firstmate must classify this intake, write the implementation or research specification, ` +
      `choose any delivery mode and merge authority, and resolve the dispatch profile before launch.\n\n` +
      `# Unresolved dispatch decisions\n\n` +
      `- Task kind\n- Delivery mode\n- Merge authority\n- Dispatch profile\n`;
    mkdirSync(taskDir, { recursive: true });
    writeFileSync(briefPath, scaffold, { mode: 0o600 });

    await markRow(row.id, { status: "waiting_for_dispatch", firstmate_task_id: taskId });
    process.stdout.write(`waiting-for-dispatch ${row.linear_identifier} -> ${taskId}\n`);
  } catch (error) {
    await markRow(row.id, { status: "failed" });
    process.stdout.write(`failed ${row.linear_identifier}: ${error.message}\n`);
  }
}

async function main() {
  const claimed = await claimPendingRows();
  if (claimed.length === 0) {
    process.stdout.write("no pending Linear dispatch rows\n");
    return;
  }
  for (const row of claimed) {
    await publishIntake(row);
  }
}

main().catch((error) => {
  fail(error.stack || error.message);
  process.exit(1);
});

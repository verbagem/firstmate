#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CATALOG_SCHEMA = 'fm-local-inference-catalog.v1';
const HARDWARE_SCHEMA = 'fm-local-inference-hardware.v1';
const RANK_SCHEMA = 'fm-local-inference-ranking.v1';
const PROBE_SCHEMA = 'fm-local-inference-probe.v1';
const ALLOWED_CAPABILITIES = new Set(['chat', 'tools', 'vision', 'embeddings', 'reasoning', 'json_mode']);

function usage() {
  process.stdout.write(`fm-local-inference.sh - inspect opt-in local-inference capacity without orchestration authority

Usage:
  fm-local-inference.sh [status] [--catalog <path>] [--json]
  fm-local-inference.sh catalog --catalog <path> [--json]
  fm-local-inference.sh hardware [--json]
  fm-local-inference.sh rank --catalog <path> [--hardware <path>] [--context-tokens <n>] [--reserve-mib <n>] [--require-capability <name>] [--json]
  fm-local-inference.sh probe --catalog <path> --provider <id> [--timeout-ms <n>] [--json]

Catalog providers must be OpenAI-compatible loopback endpoints with no embedded credentials.
Models require id, upstream_id, quantization, context_tokens, estimated_memory_mib, capabilities, and license.
Default output is compact text; --json emits deterministic structured output.
`);
}

function dieUsage(message) {
  process.stderr.write(`fm-local-inference: ${message}\n`);
  process.exit(2);
}

function parsePositiveInteger(value, name) {
  if (!/^[1-9][0-9]*$/.test(String(value ?? ''))) {
    dieUsage(`${name} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    dieUsage(`${name} is too large`);
  }
  return parsed;
}

function parseNonnegativeInteger(value, name) {
  if (!/^(0|[1-9][0-9]*)$/.test(String(value ?? ''))) {
    dieUsage(`${name} must be a non-negative integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    dieUsage(`${name} is too large`);
  }
  return parsed;
}

function defaultCatalogPath() {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const root = path.resolve(scriptDir, '..');
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const config = process.env.FM_CONFIG_OVERRIDE || path.join(home, 'config');
  return path.join(config, 'local-inference-catalog.json');
}

function parseArgs(argv) {
  const args = [...argv];
  let command = 'status';
  if (args[0] && !args[0].startsWith('-')) {
    command = args.shift();
  }
  if (command === '-h' || command === '--help') {
    usage();
    process.exit(0);
  }

  const opts = {
    json: false,
    catalog: undefined,
    hardware: undefined,
    provider: undefined,
    timeoutMs: 3000,
    contextTokens: 0,
    reserveMib: 2048,
    capabilities: [],
  };

  while (args.length > 0) {
    const arg = args.shift();
    switch (arg) {
      case '-h':
      case '--help':
        usage();
        process.exit(0);
        break;
      case '--json':
        opts.json = true;
        break;
      case '--catalog':
        opts.catalog = args.shift();
        if (!opts.catalog) dieUsage('--catalog requires a path');
        break;
      case '--hardware':
        opts.hardware = args.shift();
        if (!opts.hardware) dieUsage('--hardware requires a path');
        break;
      case '--provider':
        opts.provider = args.shift();
        if (!opts.provider) dieUsage('--provider requires an id');
        break;
      case '--timeout-ms':
        opts.timeoutMs = parsePositiveInteger(args.shift(), '--timeout-ms');
        break;
      case '--context-tokens':
        opts.contextTokens = parseNonnegativeInteger(args.shift(), '--context-tokens');
        break;
      case '--reserve-mib':
        opts.reserveMib = parseNonnegativeInteger(args.shift(), '--reserve-mib');
        break;
      case '--require-capability': {
        const cap = args.shift();
        if (!cap) dieUsage('--require-capability requires a name');
        if (!ALLOWED_CAPABILITIES.has(cap)) {
          dieUsage(`unsupported capability '${cap}'`);
        }
        if (!opts.capabilities.includes(cap)) opts.capabilities.push(cap);
        break;
      }
      default:
        dieUsage(`unknown option: ${arg}`);
    }
  }
  return { command, opts };
}

function readJsonFile(filePath, label) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    throw new Error(`${label} unreadable: ${error.code || error.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} invalid JSON: ${error.message}`);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function checkAllowed(obj, allowed, at, errors) {
  for (const key of Object.keys(obj)) {
    if (!allowed.has(key)) {
      errors.push(`${at}.${key}: unsupported field`);
    }
  }
}

function requireString(obj, key, at, errors) {
  if (typeof obj[key] !== 'string' || obj[key].length === 0) {
    errors.push(`${at}.${key}: required non-empty string`);
  }
}

function requirePositiveInteger(obj, key, at, errors) {
  if (!Number.isSafeInteger(obj[key]) || obj[key] <= 0) {
    errors.push(`${at}.${key}: required positive integer`);
  }
}

function requirePositiveNumber(obj, key, at, errors) {
  if (typeof obj[key] !== 'number' || !Number.isFinite(obj[key]) || obj[key] <= 0) {
    errors.push(`${at}.${key}: required positive number`);
  }
}

function validateOptionalEvidence(obj, key, at, errors) {
  if (obj[key] === undefined) return;
  const evidence = obj[key];
  const evidenceAt = `${at}.${key}`;
  if (!isPlainObject(evidence)) {
    errors.push(`${evidenceAt}: required object when present`);
    return;
  }
  checkAllowed(evidence, new Set(['score', 'tokens_per_second', 'source']), evidenceAt, errors);
  if (evidence.score !== undefined && (typeof evidence.score !== 'number' || !Number.isFinite(evidence.score))) {
    errors.push(`${evidenceAt}.score: required finite number when present`);
  }
  if (evidence.tokens_per_second !== undefined && (typeof evidence.tokens_per_second !== 'number' || !Number.isFinite(evidence.tokens_per_second) || evidence.tokens_per_second <= 0)) {
    errors.push(`${evidenceAt}.tokens_per_second: required positive number when present`);
  }
  if (evidence.source !== undefined && (typeof evidence.source !== 'string' || evidence.source.length === 0)) {
    errors.push(`${evidenceAt}.source: required non-empty string when present`);
  }
}

function isLoopbackUrl(raw) {
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    return { ok: false, reason: 'invalid-url' };
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return { ok: false, reason: 'unsupported-scheme' };
  }
  if (parsed.username || parsed.password) {
    return { ok: false, reason: 'embedded-credentials' };
  }
  if (parsed.search || parsed.hash) {
    return { ok: false, reason: 'query-or-fragment' };
  }
  const host = parsed.hostname.toLowerCase();
  const loopback = host === 'localhost' || host === '::1' || host === '[::1]' || /^127\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}$/.test(host);
  if (!loopback) {
    return { ok: false, reason: 'non-loopback-host' };
  }
  return { ok: true, url: parsed };
}

function validateCatalog(catalog) {
  const errors = [];
  if (!isPlainObject(catalog)) {
    return { ok: false, errors: ['catalog: required object'] };
  }
  checkAllowed(catalog, new Set(['version', 'providers']), 'catalog', errors);
  if (catalog.version !== 1) {
    errors.push('catalog.version: required value 1');
  }
  if (!Array.isArray(catalog.providers) || catalog.providers.length === 0) {
    errors.push('catalog.providers: required non-empty array');
    return { ok: errors.length === 0, errors };
  }

  const providerIds = new Set();
  const modelIds = new Set();
  catalog.providers.forEach((provider, pIndex) => {
    const pAt = `catalog.providers[${pIndex}]`;
    if (!isPlainObject(provider)) {
      errors.push(`${pAt}: required object`);
      return;
    }
    checkAllowed(provider, new Set(['id', 'endpoint_id', 'type', 'base_url', 'models']), pAt, errors);
    requireString(provider, 'id', pAt, errors);
    requireString(provider, 'endpoint_id', pAt, errors);
    requireString(provider, 'type', pAt, errors);
    requireString(provider, 'base_url', pAt, errors);
    if (typeof provider.id === 'string') {
      if (!/^[A-Za-z0-9_.:-]+$/.test(provider.id)) errors.push(`${pAt}.id: unsupported characters`);
      if (providerIds.has(provider.id)) errors.push(`${pAt}.id: duplicate provider id`);
      providerIds.add(provider.id);
    }
    if (provider.type !== 'openai-compatible') {
      errors.push(`${pAt}.type: unsupported provider type '${provider.type}'`);
    }
    if (typeof provider.base_url === 'string') {
      const boundary = isLoopbackUrl(provider.base_url);
      if (!boundary.ok) errors.push(`${pAt}.base_url: ${boundary.reason}`);
    }
    if (!Array.isArray(provider.models) || provider.models.length === 0) {
      errors.push(`${pAt}.models: required non-empty array`);
      return;
    }
    provider.models.forEach((model, mIndex) => {
      const mAt = `${pAt}.models[${mIndex}]`;
      if (!isPlainObject(model)) {
        errors.push(`${mAt}: required object`);
        return;
      }
      checkAllowed(model, new Set([
        'id',
        'upstream_id',
        'quantization',
        'context_tokens',
        'estimated_memory_mib',
        'capabilities',
        'license',
        'speed_evidence',
        'intelligence_evidence',
      ]), mAt, errors);
      requireString(model, 'id', mAt, errors);
      requireString(model, 'upstream_id', mAt, errors);
      requireString(model, 'quantization', mAt, errors);
      requirePositiveInteger(model, 'context_tokens', mAt, errors);
      requirePositiveNumber(model, 'estimated_memory_mib', mAt, errors);
      requireString(model, 'license', mAt, errors);
      if (typeof model.id === 'string') {
        if (!/^[A-Za-z0-9_.:/-]+$/.test(model.id)) errors.push(`${mAt}.id: unsupported characters`);
        if (modelIds.has(model.id)) errors.push(`${mAt}.id: duplicate model id`);
        modelIds.add(model.id);
      }
      if (!isPlainObject(model.capabilities)) {
        errors.push(`${mAt}.capabilities: required object`);
      } else {
        checkAllowed(model.capabilities, ALLOWED_CAPABILITIES, `${mAt}.capabilities`, errors);
        for (const [key, value] of Object.entries(model.capabilities)) {
          if (typeof value !== 'boolean') {
            errors.push(`${mAt}.capabilities.${key}: required boolean`);
          }
        }
      }
      validateOptionalEvidence(model, 'speed_evidence', mAt, errors);
      validateOptionalEvidence(model, 'intelligence_evidence', mAt, errors);
    });
  });
  return { ok: errors.length === 0, errors };
}

function normalizeCatalog(catalog) {
  const providers = catalog.providers.map((provider) => ({
    id: provider.id,
    endpoint_id: provider.endpoint_id,
    type: provider.type,
    base_url: provider.base_url,
    models: provider.models.map((model) => ({
      id: model.id,
      upstream_id: model.upstream_id,
      quantization: model.quantization,
      context_tokens: model.context_tokens,
      estimated_memory_mib: model.estimated_memory_mib,
      capabilities: Object.fromEntries(Object.keys(model.capabilities).sort().map((key) => [key, model.capabilities[key]])),
      license: model.license,
      ...(model.speed_evidence ? { speed_evidence: model.speed_evidence } : {}),
      ...(model.intelligence_evidence ? { intelligence_evidence: model.intelligence_evidence } : {}),
    })),
  }));
  providers.sort((a, b) => a.id.localeCompare(b.id) || a.endpoint_id.localeCompare(b.endpoint_id));
  for (const provider of providers) {
    provider.models.sort((a, b) => a.id.localeCompare(b.id));
  }
  return { schema: CATALOG_SCHEMA, version: 1, providers };
}

function loadCatalog(filePath) {
  const catalog = readJsonFile(filePath, 'catalog');
  const verdict = validateCatalog(catalog);
  if (!verdict.ok) {
    const error = new Error(`catalog validation failed:\n${verdict.errors.map((line) => `- ${line}`).join('\n')}`);
    error.validationErrors = verdict.errors;
    throw error;
  }
  return normalizeCatalog(catalog);
}

function readLinuxMeminfo() {
  try {
    const text = fs.readFileSync('/proc/meminfo', 'utf8');
    const values = new Map();
    for (const line of text.split('\n')) {
      const match = line.match(/^([^:]+):\s+([0-9]+)\s+kB$/);
      if (match) values.set(match[1], Number(match[2]));
    }
    const total = values.get('MemTotal');
    const available = values.get('MemAvailable');
    if (Number.isFinite(total)) {
      return {
        total_mib: Math.floor(total / 1024),
        available_mib: Number.isFinite(available) ? Math.floor(available / 1024) : null,
        source: '/proc/meminfo',
      };
    }
  } catch {
    return null;
  }
  return null;
}

function readMacosMemory() {
  let text;
  try {
    text = execFileSync('vm_stat', [], { encoding: 'utf8', timeout: 2000 });
  } catch {
    return null;
  }
  const pageSize = Number(text.match(/page size of (\d+) bytes/)?.[1]);
  if (!Number.isSafeInteger(pageSize) || pageSize <= 0) return null;
  const pages = (label) => Number(text.match(new RegExp(`^${label}:\\s+(\\d+)\\.`, 'm'))?.[1]);
  const free = pages('Pages free');
  const inactive = pages('Pages inactive');
  const speculative = pages('Pages speculative');
  const purgeable = pages('Pages purgeable');
  if (![free, inactive, speculative].every((v) => Number.isSafeInteger(v))) return null;
  const reclaimable = free + inactive + speculative + (Number.isSafeInteger(purgeable) ? purgeable : 0);
  return { available_mib: Math.floor((reclaimable * pageSize) / 1024 / 1024), source: 'vm_stat' };
}

function collectHardware() {
  const linux = process.platform === 'linux' ? readLinuxMeminfo() : null;
  const macos = !linux && process.platform === 'darwin' ? readMacosMemory() : null;
  const totalMib = linux?.total_mib ?? Math.floor(os.totalmem() / 1024 / 1024);
  let availableMib;
  let source;
  if (linux) {
    availableMib = linux.available_mib;
    source = linux.source;
  } else if (process.platform === 'darwin') {
    availableMib = macos ? macos.available_mib : null;
    source = macos ? macos.source : 'node-os';
  } else {
    availableMib = Math.floor(os.freemem() / 1024 / 1024);
    source = 'node-os';
  }
  const cpus = os.cpus();
  return {
    schema: HARDWARE_SCHEMA,
    platform: process.platform,
    arch: process.arch,
    memory: {
      total_mib: Number.isFinite(totalMib) && totalMib > 0 ? totalMib : null,
      available_mib: Number.isFinite(availableMib) && availableMib >= 0 ? availableMib : null,
      source,
    },
    cpu: {
      logical_cores: cpus.length || null,
      model: cpus[0]?.model || null,
    },
  };
}

function validateHardware(hardware) {
  const errors = [];
  if (!isPlainObject(hardware)) return { ok: false, errors: ['hardware: required object'] };
  checkAllowed(hardware, new Set(['schema', 'platform', 'arch', 'memory', 'cpu']), 'hardware', errors);
  if (hardware.schema !== undefined && hardware.schema !== HARDWARE_SCHEMA) {
    errors.push(`hardware.schema: expected ${HARDWARE_SCHEMA}`);
  }
  if (hardware.platform !== undefined && typeof hardware.platform !== 'string') errors.push('hardware.platform: required string when present');
  if (hardware.arch !== undefined && typeof hardware.arch !== 'string') errors.push('hardware.arch: required string when present');
  if (!isPlainObject(hardware.memory)) {
    errors.push('hardware.memory: required object');
  } else {
    checkAllowed(hardware.memory, new Set(['total_mib', 'available_mib', 'source']), 'hardware.memory', errors);
    for (const key of ['total_mib', 'available_mib']) {
      const value = hardware.memory[key];
      if (value !== null && (!Number.isSafeInteger(value) || value < 0)) {
        errors.push(`hardware.memory.${key}: required non-negative integer or null`);
      }
    }
    if (hardware.memory.source !== undefined && typeof hardware.memory.source !== 'string') {
      errors.push('hardware.memory.source: required string when present');
    }
  }
  if (hardware.cpu !== undefined) {
    if (!isPlainObject(hardware.cpu)) {
      errors.push('hardware.cpu: required object when present');
    } else {
      checkAllowed(hardware.cpu, new Set(['logical_cores', 'model']), 'hardware.cpu', errors);
    }
  }
  return { ok: errors.length === 0, errors };
}

function loadHardware(opts) {
  if (!opts.hardware) return collectHardware();
  const hardware = readJsonFile(opts.hardware, 'hardware');
  const verdict = validateHardware(hardware);
  if (!verdict.ok) {
    const error = new Error(`hardware validation failed:\n${verdict.errors.map((line) => `- ${line}`).join('\n')}`);
    error.validationErrors = verdict.errors;
    throw error;
  }
  return {
    schema: HARDWARE_SCHEMA,
    platform: hardware.platform ?? 'fixture',
    arch: hardware.arch ?? 'unknown',
    memory: {
      total_mib: hardware.memory.total_mib ?? null,
      available_mib: hardware.memory.available_mib ?? null,
      source: hardware.memory.source ?? 'fixture',
    },
    cpu: hardware.cpu ?? { logical_cores: null, model: null },
  };
}

function flattenModels(catalog) {
  const flattened = [];
  for (const provider of catalog.providers) {
    for (const model of provider.models) {
      flattened.push({ provider, model });
    }
  }
  return flattened;
}

function rankModels(catalog, hardware, opts) {
  const available = hardware.memory.available_mib;
  const usable = available === null ? null : Math.max(available - opts.reserveMib, 0);
  const rows = flattenModels(catalog).map(({ provider, model }) => {
    const reasons = [];
    for (const cap of opts.capabilities) {
      if (model.capabilities[cap] !== true) reasons.push(`missing-capability:${cap}`);
    }
    if (opts.contextTokens > 0 && model.context_tokens < opts.contextTokens) {
      reasons.push('requested-context-exceeds-capacity');
    }
    let admission = 'admitted';
    if (available === null) {
      admission = 'unknown';
      reasons.push('available-memory-unknown');
    } else if (model.estimated_memory_mib > usable) {
      admission = 'rejected';
      reasons.push('insufficient-memory-headroom');
    }
    if (reasons.some((reason) => reason.startsWith('missing-capability:') || reason === 'requested-context-exceeds-capacity')) {
      admission = 'rejected';
    }
    return {
      rank: 0,
      model_id: model.id,
      upstream_id: model.upstream_id,
      provider_id: provider.id,
      endpoint_id: provider.endpoint_id,
      admission,
      reasons,
      requested_context_tokens: opts.contextTokens,
      context_capacity_tokens: model.context_tokens,
      estimated_memory_mib: model.estimated_memory_mib,
      reserve_mib: opts.reserveMib,
      available_memory_mib: available,
      usable_memory_mib: usable,
      quantization: model.quantization,
      license: model.license,
      capabilities: model.capabilities,
      intelligence_score: model.intelligence_evidence?.score ?? null,
      speed_tokens_per_second: model.speed_evidence?.tokens_per_second ?? null,
    };
  });
  const admissionOrder = new Map([['admitted', 0], ['unknown', 1], ['rejected', 2]]);
  rows.sort((a, b) => (
    admissionOrder.get(a.admission) - admissionOrder.get(b.admission) ||
    (b.intelligence_score ?? -Infinity) - (a.intelligence_score ?? -Infinity) ||
    (b.speed_tokens_per_second ?? -Infinity) - (a.speed_tokens_per_second ?? -Infinity) ||
    a.estimated_memory_mib - b.estimated_memory_mib ||
    a.provider_id.localeCompare(b.provider_id) ||
    a.model_id.localeCompare(b.model_id)
  ));
  rows.forEach((row, index) => { row.rank = index + 1; });
  return {
    schema: RANK_SCHEMA,
    requested_context_tokens: opts.contextTokens,
    required_capabilities: [...opts.capabilities].sort(),
    reserve_mib: opts.reserveMib,
    hardware,
    results: rows,
  };
}

function modelsUrl(baseUrl) {
  const base = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  return new URL('models', base).toString();
}

async function probeProvider(catalog, opts) {
  if (!opts.provider) dieUsage('probe requires --provider <id>');
  const provider = catalog.providers.find((candidate) => candidate.id === opts.provider);
  if (!provider) dieUsage(`provider '${opts.provider}' not found in catalog`);
  const boundary = isLoopbackUrl(provider.base_url);
  if (!boundary.ok) {
    dieUsage(`provider '${opts.provider}' is not probeable: ${boundary.reason}`);
  }
  if (provider.type !== 'openai-compatible') {
    return {
      schema: PROBE_SCHEMA,
      provider_id: provider.id,
      endpoint_id: provider.endpoint_id,
      status: 'unsupported-provider',
      models_discovered: [],
      source: null,
    };
  }
  const url = modelsUrl(provider.base_url);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), opts.timeoutMs);
  try {
    const response = await fetch(url, {
      method: 'GET',
      signal: controller.signal,
      headers: {},
      redirect: 'error',
    });
    if (!response.ok) {
      return {
        schema: PROBE_SCHEMA,
        provider_id: provider.id,
        endpoint_id: provider.endpoint_id,
        status: 'http-error',
        http_status: response.status,
        models_discovered: [],
        source: '/models',
      };
    }
    const body = await response.json();
    const data = Array.isArray(body?.data) ? body.data : [];
    const models = data
      .map((entry) => entry?.id)
      .filter((id) => typeof id === 'string' && id.length > 0)
      .sort();
    return {
      schema: PROBE_SCHEMA,
      provider_id: provider.id,
      endpoint_id: provider.endpoint_id,
      status: 'ok',
      http_status: response.status,
      models_discovered: models,
      source: '/models',
    };
  } catch (error) {
    const status = error?.name === 'AbortError' ? 'timeout' : 'network-error';
    return {
      schema: PROBE_SCHEMA,
      provider_id: provider.id,
      endpoint_id: provider.endpoint_id,
      status,
      models_discovered: [],
      source: '/models',
    };
  } finally {
    clearTimeout(timeout);
  }
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function printStatus(catalogPath, json) {
  if (!fs.existsSync(catalogPath)) {
    const result = { schema: 'fm-local-inference-status.v1', enabled: false, catalog_path: catalogPath, reason: 'missing-catalog' };
    if (json) printJson(result);
    else process.stdout.write(`local-inference=disabled catalog=${catalogPath} reason=missing-catalog\n`);
    return;
  }
  const catalog = loadCatalog(catalogPath);
  const modelCount = catalog.providers.reduce((sum, provider) => sum + provider.models.length, 0);
  const result = { schema: 'fm-local-inference-status.v1', enabled: true, catalog_path: catalogPath, providers: catalog.providers.length, models: modelCount };
  if (json) printJson(result);
  else process.stdout.write(`local-inference=configured providers=${result.providers} models=${result.models} catalog=${catalogPath}\n`);
}

function printCatalog(catalog, json) {
  if (json) {
    printJson(catalog);
    return;
  }
  const modelCount = catalog.providers.reduce((sum, provider) => sum + provider.models.length, 0);
  process.stdout.write(`catalog=valid providers=${catalog.providers.length} models=${modelCount}\n`);
  for (const provider of catalog.providers) {
    process.stdout.write(`provider=${provider.id} endpoint=${provider.endpoint_id} type=${provider.type} models=${provider.models.length}\n`);
  }
}

function printHardware(hardware, json) {
  if (json) {
    printJson(hardware);
    return;
  }
  process.stdout.write(`platform=${hardware.platform} arch=${hardware.arch} memory_total_mib=${hardware.memory.total_mib ?? 'unknown'} memory_available_mib=${hardware.memory.available_mib ?? 'unknown'} source=${hardware.memory.source}\n`);
}

function printRanking(ranking, json) {
  if (json) {
    printJson(ranking);
    return;
  }
  process.stdout.write(`ranking models=${ranking.results.length} reserve_mib=${ranking.reserve_mib} requested_context_tokens=${ranking.requested_context_tokens} available_memory_mib=${ranking.hardware.memory.available_mib ?? 'unknown'}\n`);
  for (const row of ranking.results) {
    const reason = row.reasons.length > 0 ? row.reasons.join(',') : 'none';
    process.stdout.write(`rank=${row.rank} model=${row.model_id} provider=${row.provider_id} admission=${row.admission} memory_mib=${row.estimated_memory_mib} context=${row.context_capacity_tokens} reasons=${reason}\n`);
  }
}

function printProbe(probe, json) {
  if (json) {
    printJson(probe);
    return;
  }
  const status = probe.http_status === undefined ? probe.status : `${probe.status} http_status=${probe.http_status}`;
  process.stdout.write(`provider=${probe.provider_id} endpoint=${probe.endpoint_id} status=${status} discovered=${probe.models_discovered.length}\n`);
}

async function main() {
  const { command, opts } = parseArgs(process.argv.slice(2));
  const catalogPath = opts.catalog || defaultCatalogPath();
  try {
    switch (command) {
      case 'status':
        printStatus(catalogPath, opts.json);
        break;
      case 'catalog': {
        if (!opts.catalog) dieUsage('catalog requires --catalog <path>');
        printCatalog(loadCatalog(catalogPath), opts.json);
        break;
      }
      case 'hardware':
        printHardware(collectHardware(), opts.json);
        break;
      case 'rank': {
        if (!opts.catalog) dieUsage('rank requires --catalog <path>');
        const catalog = loadCatalog(catalogPath);
        const hardware = loadHardware(opts);
        const ranking = rankModels(catalog, hardware, opts);
        printRanking(ranking, opts.json);
        break;
      }
      case 'probe': {
        if (!opts.catalog) dieUsage('probe requires --catalog <path>');
        const catalog = loadCatalog(catalogPath);
        const probe = await probeProvider(catalog, opts);
        printProbe(probe, opts.json);
        break;
      }
      default:
        dieUsage(`unknown command: ${command}`);
    }
  } catch (error) {
    if (opts.json) {
      printJson({
        schema: 'fm-local-inference-error.v1',
        error: error.validationErrors ? 'validation-failed' : 'failed',
        message: error.message,
        ...(error.validationErrors ? { details: error.validationErrors } : {}),
      });
    } else {
      process.stderr.write(`fm-local-inference: ${error.message}\n`);
    }
    process.exit(2);
  }
}

await main();

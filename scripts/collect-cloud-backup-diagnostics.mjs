#!/usr/bin/env node
/** Explicit, local-only collection. Raw pipes never reach stdout/stderr or disk. */
import { spawn } from 'node:child_process';
import { open } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const LIMITS = Object.freeze({
  lineBytes: 2048, inputBytes: 1024 * 1024, durationMs: 30000,
  events: 288, detailedEvents: 256, summaries: 32, operations: 16, operationEvents: 32,
  outputBytes: 128 * 1024, op: 2147483647,
});
export const REPORT_BASENAME = 'cloud-backup-diagnostics.txt';
const words = value => new Set(value.split(' '));
export const KINDS = words('UNKNOWN BACKUP HISTORY RESTORE DELETE CLEAR CACHE SYNC ICON DEVICE_INFO CRYPTO UI');
export const STAGES = words('UNKNOWN DEVICE_INFO BACKUP_BEGIN ENCRYPT_END WRITE_END PUBLISH_END BACKUP_END POST_PUBLISH_VERIFY PUBLICATION_GUARD PUBLICATION_CLEANUP FS_OPEN FS_WRITE FS_CLOSE FS_VERIFY HISTORY_BEGIN CACHE_ADMIT CACHE_START CACHE_PROGRESS CACHE_END CACHE_STOP CACHE_DRAIN READ_END HEADER_PARSE HISTORY_END CLEAR_BEGIN DELETE_GUARD UNLINK_BEGIN UNLINK_END DELETE_END CLEAR_END ICON_IO ICON_CLEAR SYNC_START SYNC_STATE CRYPTO_RESULT HEADER_VALIDATE UI_ACTION UI_RESULT UI_REFRESH RESTORE_END FS_PREPARE FS_STAGE FS_ENCODE FS_STAGE_MOVE TEMP_CLEANUP RESTORE_BEGIN RESTORE_DECRYPT RESTORE_VALIDATE ACCOUNT_STATE ACCOUNT_AUTHORIZE ACCOUNT_INIT TIME_PARSE');
const RESULTS = words('UNKNOWN BEGIN OK FAIL BLOCKED CANCELLED PENDING');
const FAILURES = words('FAIL BLOCKED CANCELLED');
export const REASONS = words('UNKNOWN NONE IO_ERROR INVALID_ARGUMENT NOT_FOUND NO_SPACE TIMEOUT CANCELLED INFLIGHT_UNCONFIRMED BUSY INVALID_FORMAT EMPTY_CONTENT IDENTITY_UNAVAILABLE NAME_UNAVAILABLE URI_MISMATCH SHORT_WRITE SYNC_REJECTED PARTIAL_FAILURE UNAVAILABLE TRUNCATED DECRYPT_FAILED NOT_READY NOT_SIGNED_IN ENCODING_FAILED MISMATCH');
const DOMAINS = words('UNKNOWN FS CACHE SYNC CRYPTO APP');
const LOCATIONS = words('UNKNOWN LOCAL CLOUD BOTH');
const STATES = words('UNKNOWN IDLE RUNNING COMPLETED FAILED STOPPED');
const SCOPES = words('UNKNOWN ALL DEVICE SAME_NAME SINGLE');
const ARTIFACTS = words('UNKNOWN TOKEN ICON');
const SOURCES = words('UNKNOWN INITIAL CACHED RETRY FALLBACK');
export const UI_ACTIONS = words('UNKNOWN FEEDBACK UNKNOWN_SOURCE_CLEANUP');
const IO_MODES = words('UNKNOWN STRING ARRAY_BUFFER TYPED_ARRAY');
const FORMAT_MODES = words('UNKNOWN LEGACY ENCRYPTED');
const ELAPSED = words('LT_100MS LT_1S LT_10S LT_60S GE_60S UNAVAILABLE');
const FS_STAGES = words('FS_OPEN FS_WRITE FS_CLOSE FS_VERIFY WRITE_END PUBLISH_END POST_PUBLISH_VERIFY PUBLICATION_GUARD PUBLICATION_CLEANUP READ_END UNLINK_BEGIN UNLINK_END ICON_IO ICON_CLEAR HISTORY_END FS_PREPARE FS_STAGE FS_STAGE_MOVE TEMP_CLEANUP');
const CACHE_STAGES = words('CACHE_ADMIT CACHE_START CACHE_PROGRESS CACHE_END CACHE_STOP CACHE_DRAIN');
const SYNC_STAGES = words('SYNC_START SYNC_STATE');
const CRYPTO_STAGES = words('ENCRYPT_END CRYPTO_RESULT HEADER_VALIDATE HEADER_PARSE RESTORE_DECRYPT RESTORE_VALIDATE');
const ITEM_STAGES = words('FS_OPEN FS_WRITE FS_CLOSE FS_VERIFY CACHE_ADMIT CACHE_START CACHE_PROGRESS CACHE_END CACHE_STOP CACHE_DRAIN READ_END HEADER_PARSE DELETE_GUARD UNLINK_BEGIN UNLINK_END ICON_IO ICON_CLEAR HEADER_VALIDATE');
const FIELDS = ['v', 'op', 'kind', 'stage', 'result', 'reason', 'elapsed', 'item', 'errorDomain', 'code',
  'location', 'state', 'mode', 'scope', 'artifact', 'source', 'uiAction', 'identityAvailable', 'nameAvailable',
  'uriMatches', 'contentNonEmpty', 'writeComplete', 'headerParsed', 'unlinkAttempted', 'alreadyAbsent',
  'syncStartAccepted', 'partialFailure', 'drained', 'truncated'];
const BASE = ['v', 'kind', 'stage', 'result', 'reason'];
const BOOLEANS = new Set(FIELDS.slice(FIELDS.indexOf('identityAvailable')));
const STATUSES = words('COLLECTION_COMPLETE COLLECTION_WINDOW_ENDED DEVICE_UNAVAILABLE COLLECTION_FAILED INPUT_LIMIT OUTPUT_FAILED OUTPUT_EXISTS INVALID_ARGUMENTS');
const DISCARD_REASONS = words('OTHER_LOG INVALID_EVENT LINE_LIMIT EVENT_LIMIT OUTPUT_LIMIT');

function domainAllowed(stage, domain) {
  return domain === 'UNKNOWN' || (domain === 'APP' && stage !== 'UNKNOWN') ||
    (domain === 'FS' && FS_STAGES.has(stage)) || (domain === 'CACHE' && CACHE_STAGES.has(stage)) ||
    (domain === 'SYNC' && SYNC_STAGES.has(stage)) || (domain === 'CRYPTO' && CRYPTO_STAGES.has(stage));
}
// Mirrored SDK-verified stage subsets; never accept a numeric range of filesystem errors.
function fileCodeAllowed(stage, code) {
  if (code === 13900020) return true;
  switch (stage) {
    case 'FS_CLOSE':
      return [13900004, 13900005, 13900008, 13900025, 13900041].includes(code);
    case 'FS_STAGE':
      return [13900001, 13900002, 13900008, 13900011, 13900012, 13900013, 13900015,
        13900018, 13900025, 13900028, 13900030, 13900033, 13900041].includes(code);
    case 'PUBLICATION_GUARD':
    case 'FS_PREPARE':
      return [13900001, 13900002, 13900005, 13900008, 13900011, 13900012, 13900013, 13900015,
        13900018, 13900023, 13900025, 13900028, 13900030, 13900033, 13900041].includes(code);
    case 'FS_STAGE_MOVE':
    case 'PUBLISH_END':
      return [13900001, 13900002, 13900008, 13900011, 13900012, 13900013, 13900014, 13900015,
        13900016, 13900018, 13900019, 13900025, 13900027, 13900028, 13900032, 13900033, 13900041].includes(code);
    case 'FS_WRITE':
    case 'WRITE_END':
      return [13900001, 13900004, 13900005, 13900008, 13900010, 13900013, 13900024,
        13900025, 13900034, 13900041].includes(code);
    case 'FS_OPEN':
      return [13900001, 13900002, 13900004, 13900008, 13900012, 13900015,
        13900018, 13900025, 13900027, 13900041].includes(code);
    case 'FS_VERIFY':
      return [13900002, 13900004, 13900005, 13900008, 13900012, 13900018].includes(code);
    case 'READ_END':
    case 'HISTORY_END':
    case 'ICON_IO':
      return [13900001, 13900002, 13900004, 13900005, 13900008, 13900012, 13900018,
        13900025, 13900041].includes(code);
    case 'PUBLICATION_CLEANUP':
    case 'TEMP_CLEANUP':
    case 'UNLINK_BEGIN':
    case 'UNLINK_END':
    case 'ICON_CLEAR':
      return [13900001, 13900002, 13900005, 13900008, 13900011, 13900012, 13900013,
        13900014, 13900018, 13900019, 13900027, 13900030, 13900032, 13900033].includes(code);
    default: return false;
  }
}
function codeAllowed(stage, domain, code) {
  if (code === 'UNKNOWN') return true;
  if (code === '0') return domain === 'SYNC' && stage === 'SYNC_STATE';
  if (!/^[1-9][0-9]{0,7}$/.test(code)) return false;
  const value = Number(code);
  if (domain === 'FS') return fileCodeAllowed(stage, value);
  if (domain === 'CACHE' && words('CACHE_START CACHE_END').has(stage)) {
    if ([401, 13600001, 13900002, 13900025, 14000002].includes(value)) return true;
  }
  if (domain === 'CACHE' && words('CACHE_PROGRESS CACHE_END').has(stage) && value >= 1 && value <= 5) return true;
  if (domain === 'CACHE' && stage === 'CACHE_STOP') return [401, 13600001, 13900002, 14000002].includes(value);
  if (domain === 'SYNC' && stage === 'SYNC_START') return [401, 13600001, 22400001, 22400002, 22400003].includes(value);
  return domain === 'SYNC' && stage === 'SYNC_STATE' && value >= 1 && value <= 8;
}
export function allowedFields(stage) {
  const allowed = new Set([...BASE, 'op', 'elapsed', 'errorDomain', 'code', 'truncated']);
  const add = fields => { for (const field of fields.split(' ')) allowed.add(field); };
  if (ITEM_STAGES.has(stage)) add('item location');
  if (words('DEVICE_INFO BACKUP_BEGIN HEADER_PARSE').has(stage)) add('identityAvailable nameAvailable');
  if (stage === 'DEVICE_INFO') add('source');
  if (words('UI_ACTION UI_RESULT UI_REFRESH').has(stage)) add('uiAction');
  if (CACHE_STAGES.has(stage)) add('state uriMatches');
  if (stage === 'SYNC_STATE') add('state');
  if (FS_STAGES.has(stage) || CRYPTO_STAGES.has(stage)) add('mode contentNonEmpty');
  if (words('CACHE_DRAIN CACHE_STOP DELETE_GUARD ICON_IO PUBLICATION_GUARD PUBLICATION_CLEANUP').has(stage)) add('drained');
  if (words('FS_WRITE FS_CLOSE FS_VERIFY WRITE_END PUBLISH_END').has(stage)) add('writeComplete');
  if (CRYPTO_STAGES.has(stage) || words('FS_VERIFY READ_END ICON_CLEAR POST_PUBLISH_VERIFY').has(stage)) add('headerParsed');
  if (words('CLEAR_BEGIN DELETE_GUARD UNLINK_BEGIN UNLINK_END CLEAR_END DELETE_END ICON_CLEAR').has(stage)) {
    add('scope unlinkAttempted alreadyAbsent');
  }
  if (words('SYNC_START PUBLISH_END BACKUP_END CLEAR_END DELETE_END UI_RESULT PUBLICATION_CLEANUP').has(stage)) add('syncStartAccepted');
  if (words('BACKUP_END HISTORY_END CLEAR_END DELETE_END ICON_CLEAR UI_RESULT RESTORE_END PUBLICATION_GUARD PUBLICATION_CLEANUP').has(stage)) add('partialFailure');
  if (words('ICON_IO ICON_CLEAR SYNC_START SYNC_STATE').has(stage)) add('artifact');
  return allowed;
}

// Only the exact tag, optionally with the known hilog prefix. Never search for a tag inside a SDK message.
// One optional bounded ASCII process-name segment, never a path or nested tag. Prefix is discarded.
const WIRE = /^(?:(?:\d{2}-\d{2}|\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2}\.\d{3,9} +\d+ +\d+ +[DIWEF] +[A-Z]?0{0,4}[Ff][Ff]00\/(?:[A-Za-z0-9_][A-Za-z0-9_.:-]{0,127}\/)?)?CloudBackupDiag: (v=1 .+)$/;
export function parseDiagnosticLine(line) {
  if (typeof line !== 'string' || Buffer.byteLength(line, 'utf8') > LIMITS.lineBytes || /[^\x20-\x7e]/.test(line)) return null;
  const match = WIRE.exec(line);
  if (!match) return null;
  const parsed = Object.create(null);
  for (const token of match[1].split(' ')) {
    const pair = /^([a-zA-Z]+)=([A-Z0-9_]+|true|false)$/.exec(token);
    if (!pair || !FIELDS.includes(pair[1]) || Object.hasOwn(parsed, pair[1])) return null;
    parsed[pair[1]] = pair[2];
  }
  if (BASE.some(key => !Object.hasOwn(parsed, key)) || parsed.v !== '1' || !KINDS.has(parsed.kind) ||
      !STAGES.has(parsed.stage) || !RESULTS.has(parsed.result) || !REASONS.has(parsed.reason)) return null;
  const detailed = Object.hasOwn(parsed, 'op');
  if (!detailed) {
    if (Object.keys(parsed).length !== BASE.length || !FAILURES.has(parsed.result)) return null;
  } else {
    if (!/^[1-9][0-9]{0,9}$/.test(parsed.op) || Number(parsed.op) > LIMITS.op || !ELAPSED.has(parsed.elapsed)) return null;
    const allowed = allowedFields(parsed.stage);
    if (Object.keys(parsed).some(key => !allowed.has(key))) return null;
    if (Object.hasOwn(parsed, 'item') && parsed.item !== '1' && parsed.item !== '2') return null;
    if (Object.hasOwn(parsed, 'errorDomain') !== Object.hasOwn(parsed, 'code')) return null;
    if (Object.hasOwn(parsed, 'errorDomain') && (!DOMAINS.has(parsed.errorDomain) ||
      !domainAllowed(parsed.stage, parsed.errorDomain) || !codeAllowed(parsed.stage, parsed.errorDomain, parsed.code))) return null;
    if (parsed.code === '0' && parsed.reason !== 'NONE') return null;
    for (const [key, values] of [['location', LOCATIONS], ['state', STATES], ['scope', SCOPES],
      ['artifact', ARTIFACTS], ['source', SOURCES], ['uiAction', UI_ACTIONS]]) {
      if (Object.hasOwn(parsed, key) && !values.has(parsed[key])) return null;
    }
    if (Object.hasOwn(parsed, 'mode') && !(FS_STAGES.has(parsed.stage) ? IO_MODES : FORMAT_MODES).has(parsed.mode)) return null;
    for (const key of BOOLEANS) {
      if (Object.hasOwn(parsed, key) && parsed[key] !== 'true' && parsed[key] !== 'false') return null;
    }
    if (Object.hasOwn(parsed, 'truncated') && parsed.truncated !== 'true') return null;
  }
  // Rebuild a fresh object in contract order. Never return the raw line or prefix.
  const event = Object.create(null);
  for (const key of FIELDS) {
    if (Object.hasOwn(parsed, key)) event[key] = parsed[key];
  }
  return event;
}
export function serializeDiagnosticEvent(event) {
  // Revalidate exported callers too; no arbitrary key/value reaches the report serializer.
  if (event === null || typeof event !== 'object') return null;
  try {
    const descriptors = Object.getOwnPropertyDescriptors(event);
    if (Object.values(descriptors).some(value => !Object.hasOwn(value, 'value') || typeof value.value !== 'string')) return null;
    const tokens = [];
    for (const key of Object.keys(descriptors)) {
      if (!FIELDS.includes(key)) return null;
      tokens.push(`${key}=${descriptors[key].value}`);
    }
    const safe = parseDiagnosticLine(`CloudBackupDiag: ${tokens.join(' ')}`);
    if (!safe) return null;
    return `CloudBackupDiag: ${FIELDS.filter(key => Object.hasOwn(safe, key)).map(key => `${key}=${safe[key]}`).join(' ')}`;
  } catch { return null; }
}

export class DiagnosticCollector {
  #input = 0;
  #pending = [];
  #pendingBytes = 0;
  #dropping = false;
  #stopped = false;
  #events = [];
  #discarded = new Set();
  #outputBytes = 0;
  #operations = new Map();
  #details = 0;
  #summaries = 0;
  #seen = new Set();
  get stopped() { return this.#stopped; }
  discard(reason) { if (DISCARD_REASONS.has(reason)) this.#discarded.add(reason); }
  feed(chunk) {
    if (this.#stopped) return;
    const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    if (this.#input + data.length > LIMITS.inputBytes) { this.#stopped = true; this.#pending = []; return; }
    this.#input += data.length;
    let start = 0;
    for (let index = 0; index < data.length; index++) {
      if (data[index] !== 10) continue;
      this.#part(data.subarray(start, index));
      if (!this.#dropping) {
        let line = Buffer.concat(this.#pending, this.#pendingBytes);
        if (line.at(-1) === 13) line = line.subarray(0, -1);
        this.#line(line.toString('utf8'));
      }
      this.#pending = []; this.#pendingBytes = 0; this.#dropping = false;
      start = index + 1;
    }
    this.#part(data.subarray(start));
  }
  // stderr is only counted for the global input budget and then discarded.
  discardInput(chunk) {
    if (this.#stopped) return;
    this.#input += Buffer.byteLength(chunk);
    if (this.#input > LIMITS.inputBytes) { this.#stopped = true; this.#pending = []; }
  }
  #part(part) {
    if (this.#dropping || part.length === 0) return;
    if (this.#pendingBytes + part.length > LIMITS.lineBytes) {
      this.#pending = []; this.#pendingBytes = 0; this.#dropping = true; this.discard('LINE_LIMIT'); return;
    }
    this.#pending.push(Buffer.from(part)); this.#pendingBytes += part.length;
  }
  #line(line) {
    const event = parseDiagnosticLine(line);
    if (!event) { this.discard(line.includes('CloudBackupDiag') ? 'INVALID_EVENT' : 'OTHER_LOG'); return; }
    const serialized = serializeDiagnosticEvent(event);
    if (!serialized || this.#seen.has(serialized)) return;
    if (this.#events.length >= LIMITS.events || (event.op ? this.#details >= LIMITS.detailedEvents : this.#summaries >= LIMITS.summaries)) {
      this.discard('EVENT_LIMIT'); return;
    }
    if (event.op) {
      const previous = this.#operations.get(event.op);
      if ((!previous && this.#operations.size >= LIMITS.operations) || (previous &&
        (previous.count >= LIMITS.operationEvents || previous.kind !== event.kind))) { this.discard('EVENT_LIMIT'); return; }
    }
    const bytes = Buffer.byteLength(serialized) + 1;
    if (this.#outputBytes + bytes > LIMITS.outputBytes) { this.discard('OUTPUT_LIMIT'); return; }
    if (event.op) {
      const previous = this.#operations.get(event.op);
      this.#operations.set(event.op, { kind: event.kind, count: (previous?.count ?? 0) + 1 }); this.#details++;
    } else this.#summaries++;
    this.#events.push(serialized); this.#seen.add(serialized); this.#outputBytes += bytes;
  }
  finish() {
    if (!this.#stopped && !this.#dropping && this.#pendingBytes > 0) {
      this.#line(Buffer.concat(this.#pending, this.#pendingBytes).toString('utf8').replace(/\r$/, ''));
    }
    this.#pending = []; this.#pendingBytes = 0;
  }
  report(status = 'COLLECTION_COMPLETE') {
    const safeStatus = STATUSES.has(status) ? status : 'COLLECTION_FAILED';
    return ['Cloud backup diagnostics v1', `STATUS ${safeStatus}`,
      ...[...this.#discarded].sort().map(reason => `DISCARD ${reason}`), ...this.#events, ''].join('\n');
  }
}

export async function collectFromHdc({ device, executable, spawnCommand = spawn } = {}) {
  const collector = new DiagnosticCollector();
  // Arguments are not a shell command; a target can never become a log/report field.
  if (device !== undefined && (typeof device !== 'string' || !/^[A-Za-z0-9_.:-]{1,128}$/.test(device) ||
    /[^A-Za-z0-9_.:-]/.test(device))) return collector.report('INVALID_ARGUMENTS');
  const hdc = executable ?? (process.platform === 'win32' ?
    'C:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe' : 'hdc');
  const args = [...(device ? ['-t', device] : []), 'shell', 'hilog', '-T', 'CloudBackupDiag', '-D', '0xFF00'];
  let child;
  try { child = spawnCommand(hdc, args, { shell: false, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true }); }
  catch { return collector.report('DEVICE_UNAVAILABLE'); }
  return await new Promise(resolveReport => {
    let settled = false;
    let timer;
    const settle = (status, kill = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (kill) {
        try { child.kill(); } catch { /* No raw kill error fallback. */ }
        // A failed native kill must not keep our report waiting on an open pipe indefinitely.
        try { child.stdout.destroy(); child.stderr.destroy(); child.unref?.(); } catch { /* Fixed status only. */ }
      }
      collector.finish();
      resolveReport(collector.report(status));
    };
    timer = setTimeout(() => settle('COLLECTION_WINDOW_ENDED', true), LIMITS.durationMs);
    try {
      child.stdout.on('data', chunk => {
        if (settled) return;
        collector.feed(chunk);
        if (collector.stopped) settle('INPUT_LIMIT', true);
      });
      child.stderr.on('data', chunk => {
        if (settled) return;
        collector.discardInput(chunk);
        if (collector.stopped) settle('INPUT_LIMIT', true);
      });
      child.stdout.on('error', () => settle('COLLECTION_FAILED', true));
      child.stderr.on('error', () => settle('COLLECTION_FAILED', true));
      child.on('error', () => settle('DEVICE_UNAVAILABLE', true));
      child.on('close', code => settle(code === 0 ? 'COLLECTION_COMPLETE' : 'COLLECTION_FAILED'));
    } catch { settle('COLLECTION_FAILED', true); }
  });
}

function rebuildReport(report) {
  if (typeof report !== 'string' || Buffer.byteLength(report) > LIMITS.outputBytes + 512) return null;
  const lines = report.split('\n');
  if (lines.shift() !== 'Cloud backup diagnostics v1' || lines.at(-1) !== '') return null;
  lines.pop();
  const statusLine = lines.shift();
  if (!statusLine?.startsWith('STATUS ') || !STATUSES.has(statusLine.slice(7))) return null;
  const collector = new DiagnosticCollector();
  for (const line of lines) {
    if (line.startsWith('DISCARD ') && DISCARD_REASONS.has(line.slice(8))) collector.discard(line.slice(8));
    else {
      const event = parseDiagnosticLine(line);
      const safe = event && serializeDiagnosticEvent(event);
      if (!safe) return null;
      collector.feed(Buffer.from(`${safe}\n`));
    }
  }
  collector.finish();
  return collector.report(statusLine.slice(7));
}

export async function writeReport(directory, report) {
  const safeReport = rebuildReport(report);
  if (safeReport === null) return 'OUTPUT_FAILED';
  let handle;
  try {
    handle = await open(join(resolve(directory), REPORT_BASENAME), 'wx', 0o600);
    await handle.writeFile(safeReport, { encoding: 'utf8' });
    return 'COLLECTION_COMPLETE';
  } catch (error) {
    return error?.code === 'EEXIST' ? 'OUTPUT_EXISTS' : 'OUTPUT_FAILED';
  } finally { if (handle) { try { await handle.close(); } catch { /* Never print OS paths. */ } } }
}

export async function main(argv = process.argv.slice(2)) {
  if (argv.length === 1 && argv[0] === '--help') {
    process.stdout.write('Usage: node scripts/collect-cloud-backup-diagnostics.mjs [--device <serial>] [--hdc <path>] [--output-dir <existing-directory>]\n');
    process.stdout.write('Collects validated CloudBackupDiag events locally for at most 30 seconds. No raw log copies or uploads.\n');
    process.stdout.write('An explicit output directory creates cloud-backup-diagnostics.txt without overwriting an existing file.\n');
    return 0;
  }
  let device;
  let executable;
  let directory;
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!['--device', '--hdc', '--output-dir'].includes(flag) || !argv[index + 1] || seen.has(flag)) {
      process.stderr.write('STATUS INVALID_ARGUMENTS\n'); return 1;
    }
    seen.add(flag);
    if (flag === '--device') device = argv[index + 1];
    if (flag === '--hdc') executable = argv[index + 1];
    if (flag === '--output-dir') directory = argv[index + 1];
  }
  const report = await collectFromHdc({ device, executable });
  if (directory === undefined) process.stdout.write(report);
  else {
    const status = await writeReport(directory, report);
    process.stdout.write(`STATUS ${status}\n`);
    if (status !== 'COLLECTION_COMPLETE') return 1;
  }
  return /STATUS (COLLECTION_COMPLETE|COLLECTION_WINDOW_ENDED)\n/.test(report) ? 0 : 1;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(code => { process.exitCode = code; }).catch(() => {
    process.stderr.write('STATUS COLLECTION_FAILED\n'); process.exitCode = 1;
  });
}

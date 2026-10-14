#!/usr/bin/env node
/** Narrow syntactic regression gate, not a whole-app privacy audit or a runtime proof. */
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCOPED_FILES = Object.freeze([
  'common/src/main/ets/utils/CloudBackupDiagnostics.ets',
  'common/src/main/ets/utils/DeviceInfoHelper.ets',
  'common/src/main/ets/utils/CloudBackupCrypto.ets',
  'common/src/main/ets/utils/CloudBackupMetadata.ets',
  'common/src/main/ets/utils/CloudFileCacheLoader.ets',
  'common/src/main/ets/utils/CloudBackupManager.ets',
  'common/src/main/ets/utils/IconPackCloudBackup.ets',
  'common/src/main/ets/utils/StoragePorts.ets',
  'common/src/main/ets/utils/CloudSyncTask.ets',
  'common/src/main/ets/utils/CloudBackupOperationGate.ets',
  'common/src/main/ets/utils/CloudBackupSyncService.ets',
  'common/src/main/ets/utils/CloudBackupStaging.ets',
  'common/src/main/ets/utils/CloudBackupPublicationGuard.ets',
  'common/src/main/ets/utils/CloudSyncLastFailure.ets',
  'common/src/main/ets/utils/IconPackZipGate.ets',
  // Icon-pack cloud publication protocol (previous-keep-old + intent/commit): scoped with the
  // default rules only — its receipt persistence legitimately serializes JSON, so it must NOT
  // join IMPORT_BOUNDARY's blanket JSON ban; diagnostics still must use the facade, never a sink.
  'common/src/main/ets/utils/IconPackPublication.ets',
  'common/src/main/ets/utils/HuaweiAccountManager.ets',
  'common/src/main/ets/utils/SyncTimeHelper.ets',
  'entry/src/main/ets/pages/Index.ets', // Partial: HuaweiAccountManager.init() promise chain only.
  'entry/src/main/ets/pages/ShowCloudSyncDetailsPage.ets',
  'entry/src/main/ets/pages/ShowCloudBackupHistoryPage.ets',
  'entry/src/main/ets/entryability/EntryAbility.ets',
  // Icon-pack import boundary: SubItemIconManager must converge on the fixed-enum diag helper;
  // the zip reader stays zero-output and the gate file stays pure (2026-10-13 audit P2-1).
  'entry/src/main/ets/components/SubItemIconManager.ets',
  'entry/src/main/ets/components/IconPackZipReader.ts',
  'entry/src/main/ets/utils/IconPackImportDiag.ets',
]);
const SINK = SCOPED_FILES[0];
const TASK = 'common/src/main/ets/utils/CloudSyncTask.ets';
const ENTRY = 'entry/src/main/ets/entryability/EntryAbility.ets';
const INDEX = 'entry/src/main/ets/pages/Index.ets';
const ACCOUNT = 'common/src/main/ets/utils/HuaweiAccountManager.ets';
const TIME = 'common/src/main/ets/utils/SyncTimeHelper.ets';
const SUBITEM = 'entry/src/main/ets/components/SubItemIconManager.ets';
const ZIP_READER = 'entry/src/main/ets/components/IconPackZipReader.ts';
const DIAG_LOG = 'entry/src/main/ets/utils/IconPackImportDiag.ets';
const ZIP_GATE = 'common/src/main/ets/utils/IconPackZipGate.ets';
// New icon-import files: no raw exception text at all, and error codes may never be
// masked with a `?? 0`/`?? ''` placeholder (that is how an unknown code masquerades
// as a real one in fixed-enum diagnostics). unlike the account wrapper, which owns a
// reviewed fixed `0` fallback in its business error contract.
const IMPORT_BOUNDARY = new Set([SUBITEM, ZIP_READER, DIAG_LOG, ZIP_GATE]);

// Comments are ignored but literal tokens retain their positions. This catches aliases at the import,
// destructuring or member reference, rather than relying on the subsequent call's spelling.
function tokensOf(source) {
  const tokens = [];
  const pattern = /\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`|[A-Za-z_$][\w$]*|\d+|[^\s]/g;
  for (const match of source.matchAll(pattern)) {
    const value = match[0];
    if (value.startsWith('//') || value.startsWith('/*')) continue;
    tokens.push({ value, at: match.index, literal: /^['"`]/.test(value) });
  }
  return tokens;
}
function calls(tokens, position) {
  const next = tokens[position + 1]?.value;
  return next === '.' || next === '[' || next === '?' || next === '(';
}
function endOfCall(tokens, start) {
  let depth = 0;
  for (let index = start; index < tokens.length; index++) {
    if (tokens[index].value === '(') depth++;
    if (tokens[index].value === ')' && --depth === 0) return index;
  }
  return tokens.length - 1;
}
// Token-balanced chain extraction preserves original positions and does not grandfather other Index logs.
// Missing account-init anchor fails closed rather than silently treating a moved/aliased chain as audited.
function accountInitTokens(tokens) {
  const ranges = [];
  const anchor = ['HuaweiAccountManager', '.', 'getInstance', '(', ')', '.', 'init', '(', ')'];
  for (let index = 0; index < tokens.length; index++) {
    if (!anchor.every((value, offset) => tokens[index + offset]?.value === value)) continue;
    let end = index + anchor.length - 1;
    while (tokens[end + 1]?.value === '.' && ['then', 'catch', 'finally'].includes(tokens[end + 2]?.value) &&
      tokens[end + 3]?.value === '(') end = endOfCall(tokens, end + 3);
    ranges.push([index, end]);
  }
  return tokens.filter((_, index) => ranges.some(([start, end]) => index >= start && index <= end));
}
export function checkSource(source, filename) {
  const allTokens = tokensOf(source);
  const tokens = filename === INDEX ? accountInitTokens(allTokens) : allTokens;
  const issues = [];
  const add = (rule, at) => {
    const line = source.slice(0, at).split('\n').length;
    if (!issues.some(issue => issue.rule === rule && issue.line === line)) issues.push({ file: filename, rule, line });
  };
  const entry = filename === ENTRY;
  const sink = filename === SINK;
  const importBoundary = IMPORT_BOUNDARY.has(filename);
  const strictBoundary = filename === ACCOUNT || filename === TIME || filename === INDEX || importBoundary;
  if (filename === INDEX && tokens.length === 0) add('INDEX_ACCOUNT_SCOPE_MISSING', 0);
  // If the page imports an alternate sink name, partial token checks cannot establish safe account-init use.
  if (filename === INDEX) {
    for (let index = 0; index < allTokens.length; index++) {
      if (['hilog', 'Logger', 'logger', 'console'].includes(allTokens[index].value) &&
        allTokens[index + 1]?.value === 'as') add('INDEX_SINK_ALIAS', allTokens[index].at);
    }
  }
  const caught = new Set();
  for (let index = 0; index < tokens.length; index++) {
    if (tokens[index].value === 'catch' && tokens[index + 1]?.value === '(') caught.add(tokens[index + 2]?.value);
  }
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    const value = token.value;
    if (entry) {
      // EntryAbility is deliberately partial: only direct cloud/device-init related logging and
      // an expression chained to init are in scope; unrelated window/card diagnostics are not.
      if (['hilog', 'Logger', 'logger', 'console'].includes(value) && calls(tokens, index)) {
        const open = tokens.findIndex((item, offset) => offset > index && item.value === '(');
        const end = open >= 0 ? endOfCall(tokens, open) : index;
        const body = tokens.slice(index, end + 1).map(item => item.value).join(' ');
        if (/DeviceInfoHelper|CloudBackup|CloudSync|ODID|[Oo][Dd][Ii][Dd]|deviceId|deviceName|cloudDir|云备份|设备信息/.test(body)) {
          add('ENTRY_CLOUD_RAW_LOG', token.at);
        }
      }
      if (value === 'DeviceInfoHelper' && tokens[index + 1]?.value === '.') {
        const end = tokens.findIndex((item, offset) => offset > index && item.value === ';');
        const body = tokens.slice(index, end < 0 ? index + 20 : end).map(item => item.value).join(' ');
        if (/\binit\s*\(/.test(body) && /\b(hilog|Logger|logger|console)\b/.test(body)) add('ENTRY_INIT_RAW_LOG', token.at);
      }
      continue;
    }
    if (!token.literal && ['console', 'Logger', 'logger'].includes(value)) add('UNAPPROVED_SINK', token.at);
    if (!sink && !token.literal && value === 'hilog') add('UNAPPROVED_SINK', token.at);
    if (token.literal && /^['"](?:@ohos\.hilog|[^'"]*\/Logger)['"]$/.test(value)) add('UNAPPROVED_SINK_IMPORT', token.at);
    if (!sink && token.literal && /^['"]@kit\.PerformanceAnalysisKit['"]$/.test(value)) {
      add('UNAPPROVED_SINK_IMPORT', token.at);
    }
    if (token.literal && value.startsWith('`') && /\$\{[\s\S]*\b(?:console|hilog|Logger|logger)\s*[.[]/.test(value)) {
      add('UNAPPROVED_SINK', token.at);
    }
    if (!sink && !token.literal && ['CloudBackupDiagnosticRecorder', 'HilogDiagnosticSink'].includes(value)) {
      add('RECORDER_BYPASS', token.at);
    }
    if (filename === TASK && !token.literal && ['CloudBackupDiagnostics'].includes(value)) {
      add('TASKPOOL_FACADE', token.at);
    }
    if (strictBoundary && ((!token.literal && ['message', 'stack', 'cause'].includes(value) &&
      ['.', '?'].includes(tokens[index - 1]?.value)) || (token.literal &&
      /^['"](?:message|stack|cause)['"]$/.test(value) && tokens[index - 1]?.value === '['))) {
      add('RAW_ERROR_MEMBER', token.at);
    }
    if (strictBoundary && value === 'JSON' && tokens[index + 1]?.value === '.' &&
      tokens[index + 2]?.value === 'stringify') add('RAW_ERROR_SERIALIZATION', token.at);
    // Unknown-code placeholder: `code ?? 0` / `code ?? ''` turns an unreadable or hostile
    // getter into a plausible code. Import boundary must surface it as the facade's UNKNOWN.
    // The scanner yields `??` as two separate `?` tokens, hence the pair check.
    if (importBoundary && value === 'code' && tokens[index + 1]?.value === '?' &&
      tokens[index + 2]?.value === '?' &&
      (tokens[index + 3]?.literal === true || /^\d/.test(tokens[index + 3]?.value ?? ''))) {
      add('UNKNOWN_CODE_FALLBACK', token.at);
    }
    if (filename === ACCOUNT && value === 'super' && tokens[index + 1]?.value === '(') {
      const end = endOfCall(tokens, index + 1);
      const args = tokens.slice(index + 2, end);
      if (args.length !== 1 || !args[0].literal || args[0].value.includes('${')) add('RAW_ERROR_WRAPPING', token.at);
    }
    if (filename === ACCOUNT && value === 'new' && tokens[index + 1]?.value === 'HuaweiAccountLoginError' &&
      tokens[index + 2]?.value === '(') {
      const end = endOfCall(tokens, index + 2);
      // The fixed business wrapper accepts one code only, never a second message/cause argument.
      if (tokens.slice(index + 3, end).some(item => item.value === ',')) add('RAW_ERROR_WRAPPING', token.at);
    }
    if (value === 'new' && /^(?:Error|BusinessError)$/.test(tokens[index + 1]?.value ?? '') && tokens[index + 2]?.value === '(') {
      const end = endOfCall(tokens, index + 2);
      const args = tokens.slice(index + 3, end);
      // Fixed messages are business errors, not emitted diagnostics. Dynamic wrapping can leak on a caller's logger.
      if (args.length !== 1 || !args[0].literal || (args[0].value.startsWith('`') && args[0].value.includes('${'))) {
        add('RAW_ERROR_WRAPPING', token.at);
      }
    }
    if (value === 'JSON' && tokens[index + 1]?.value === '.' && tokens[index + 2]?.value === 'stringify' &&
      tokens[index + 3]?.value === '(' && caught.has(tokens[index + 4]?.value)) add('RAW_ERROR_SERIALIZATION', token.at);
    // A raw interpolation inside a template token would otherwise evade the token scanner.
    if (token.literal && value.startsWith('`') && /\$\{[^}]*\b(?:JSON\s*\.\s*stringify\s*\(|(?:message|stack|cause)\b)/.test(value)) {
      add('RAW_ERROR_INTERPOLATION', token.at);
    }
    // Template literals hide `code ?? 0` from the token stream; scan the literal text too.
    if (importBoundary && token.literal && value.startsWith('`') &&
      /\$\{[^}]*\bcode\b\s*\?\?\s*(?:\d|['"`])/.test(value)) {
      add('UNKNOWN_CODE_FALLBACK', token.at);
    }
  }
  if (sink) {
    const raw = tokens.filter(token => !token.literal && token.value === 'hilog');
    const authorized = /hilog\s*\.\s*info\s*\(\s*0xFF00\s*,\s*'CloudBackupDiag'\s*,\s*'%\{public\}s'\s*,\s*line\s*\)/g;
    // One import and exactly one fixed sink call. A second direct logger is not silently grandfathered.
    if (raw.length !== 2 || [...source.matchAll(authorized)].length !== 1) add('SINK_CONTRACT', 0);
    if (/Date\s*\.\s*now\s*\(/.test(tokens.map(token => token.literal ? '' : token.value).join(' '))) add('WALL_CLOCK', 0);
  }
  return issues;
}
export async function checkRepository(root = fileURLToPath(new URL('..', import.meta.url))) {
  const issues = [];
  for (const file of SCOPED_FILES) {
    try { issues.push(...checkSource(await readFile(resolve(root, file), 'utf8'), file)); }
    catch { issues.push({ file, line: 0, rule: 'SCOPED_FILE_UNAVAILABLE' }); }
  }
  return issues;
}
async function main() {
  const issues = await checkRepository();
  if (issues.length > 0) {
    // Only committed scope names, source positions and fixed categories, never source/error contents.
    for (const issue of issues) process.stderr.write(`${issue.file}:${issue.line} ${issue.rule}\n`);
    process.exitCode = 1;
  } else process.stdout.write('Cloud backup diagnostic privacy gate passed (scoped static checks only).\n');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { process.stderr.write('PRIVACY_CHECK_FAILED\n'); process.exitCode = 1; });
}

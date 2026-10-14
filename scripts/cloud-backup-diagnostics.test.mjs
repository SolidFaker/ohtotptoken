import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import {
  DiagnosticCollector, LIMITS, REPORT_BASENAME, STAGES, KINDS, REASONS, UI_ACTIONS, parseDiagnosticLine,
  serializeDiagnosticEvent, collectFromHdc, writeReport,
} from './collect-cloud-backup-diagnostics.mjs';
import { checkSource, SCOPED_FILES } from './check-cloud-backup-diagnostic-privacy.mjs';

// Execute the real pure recorder with SDK ports stubbed, without copying its business rules.
// This supplements, not replaces, the ArkTS SDK check and registered Hypium suite.
const source = await readFile(new URL('../common/src/main/ets/utils/CloudBackupDiagnostics.ets', import.meta.url), 'utf8');
const exports = [...source.matchAll(/export (?:class|enum|function) (\w+)/g)].map(match => match[1]);
const transpiled = stripTypeScriptTypes(source.replace(/^import .*?;\r?\n/gm, ''), { mode: 'transform' })
  .replace(/\bexport\s+/g, '');
const sdk = { process: { pid: 1, tid: 1 }, systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 0 },
  hilog: { info: () => {} } };
const api = runInNewContext(`${transpiled}\n({${exports.join(',')}});`, sdk);
const {
  CloudBackupDiagnosticRecorder: Recorder, DiagnosticKind: Kind, DiagnosticStage: Stage,
  DiagnosticResult: Result, DiagnosticReason: Reason, DiagnosticErrorDomain: Domain,
  normalizeDiagnosticSummary, normalizeDiagnosticCode, appendDiagnosticSummary, classifyDiagnosticError,
} = api;
const SENTINELS = ['SYNTH_ODID_7F3', 'SYNTH_UNION_ID', 'SYNTH_DEVICE_NAME', 'SYNTH_TOKEN_SECRET',
  'SYNTH_STEAM_CREDENTIAL', 'SYNTH_HEADER', 'SYNTH_CIPHERTEXT', 'SYNTH_PACK_UUID', '/synthetic/private/token.otpb'];
function setup(mainThread = true) {
  const lines = [];
  const clock = { value: 0, fail: false, now() { if (this.fail) throw new Error(SENTINELS[0]); return this.value; } };
  const sink = { fail: false, write(line) { if (this.fail) throw new Error(SENTINELS[1]); lines.push(line); } };
  const recorder = new Recorder(sink, clock, { isMainThread: () => mainThread });
  return { recorder, clock, sink, lines };
}
const detail = (overrides = '') => `CloudBackupDiag: v=1 op=1 kind=BACKUP stage=FS_WRITE result=FAIL reason=INVALID_ARGUMENT elapsed=LT_1S${overrides}`;
const safeSummary = 'CloudBackupDiag: v=1 kind=BACKUP stage=FS_WRITE result=FAIL reason=IO_ERROR';
function assertNoSentinels(text) { for (const sentinel of SENTINELS) assert.equal(text.includes(sentinel), false); }
function assertWire(lines) { for (const line of lines) assert.ok(parseDiagnosticLine(`CloudBackupDiag: ${line}`), line); }

test('producer and collector use the same closed enum contract', () => {
  assert.deepEqual([...KINDS].sort(), Object.values(Kind).sort());
  assert.deepEqual([...STAGES].sort(), Object.values(Stage).sort());
  assert.deepEqual([...REASONS].sort(), Object.values(Reason).sort());
  assert.deepEqual([...UI_ACTIONS].sort(), Object.values(api.DiagnosticUiAction).sort());
  const { recorder, lines } = setup();
  recorder.enable();
  for (const stage of Object.values(Stage)) {
    const context = recorder.begin(Kind.BACKUP);
    recorder.mark(context, stage, Result.FAIL, {
      reason: Reason.IO_ERROR, errorDomain: Domain.FS, code: 13900020, item: 1,
      location: 'LOCAL', state: 'RUNNING', mode: 'STRING', scope: 'ALL', artifact: 'TOKEN', source: 'CACHED',
      identityAvailable: true, nameAvailable: false, uriMatches: true, contentNonEmpty: true,
      writeComplete: false, headerParsed: true, unlinkAttempted: true, alreadyAbsent: false,
      syncStartAccepted: false, partialFailure: true, drained: true, truncated: true,
    });
    recorder.end(context);
  }
  assert.equal(lines.length, STAGES.size);
  assertWire(lines);
});

test('default summaries are minimal, rolling bounded, and deduplicated across contexts/sessions', () => {
  const { recorder, clock, lines } = setup();
  assert.equal(recorder.isEnabled(), false);
  const context = recorder.begin(Kind.BACKUP);
  recorder.mark(context, Stage.BACKUP_END, Result.OK);
  assert.equal(lines.length, 0);
  for (let index = 0; index < 100; index++) recorder.mark(recorder.begin(Kind.BACKUP), Stage.WRITE_END, Result.FAIL,
    { reason: Reason.IO_ERROR, item: 1, contentNonEmpty: true });
  assert.equal(lines.length, 1);
  assert.equal(lines[0], 'v=1 kind=BACKUP stage=WRITE_END result=FAIL reason=IO_ERROR');
  clock.value = 59999;
  recorder.fail(context, Stage.WRITE_END, Domain.FS, new Error(SENTINELS[0]));
  assert.equal(lines.length, 2); // UNKNOWN is a different failure category.
  recorder.enable(); recorder.disable();
  recorder.mark(context, Stage.WRITE_END, Result.FAIL, { reason: Reason.IO_ERROR });
  assert.equal(lines.length, 2);
  clock.value = 60000;
  recorder.mark(context, Stage.WRITE_END, Result.FAIL, { reason: Reason.IO_ERROR });
  assert.equal(lines.length, 3);
  for (const stage of Object.values(Stage)) for (const reason of Object.values(Reason)) {
    recorder.mark(context, stage, Result.FAIL, { reason });
  }
  assert.equal(lines.length, 32);
  clock.value = 600000;
  recorder.mark(context, Stage.WRITE_END, Result.FAIL, { reason: Reason.IO_ERROR });
  assert.equal(lines.length, 33);
  assertWire(lines);
});

test('generation changes, sleep expiry, and disabled contexts cannot join a new detail session', () => {
  const { recorder, clock, lines } = setup();
  const disabled = recorder.begin(Kind.BACKUP);
  assert.equal(recorder.enable(), true);
  const old = recorder.begin(Kind.BACKUP);
  recorder.mark(old, Stage.BACKUP_BEGIN, Result.BEGIN);
  assert.equal(recorder.remainingTimeMs(), 600000);
  clock.value = 599999;
  assert.equal(recorder.isEnabled(), true);
  clock.value = 600000; // includes a simulated full sleep, with no timers running.
  recorder.mark(old, Stage.BACKUP_END, Result.OK);
  assert.equal(recorder.isEnabled(), false);
  assert.equal(lines.length, 1);
  recorder.enable();
  recorder.mark(old, Stage.BACKUP_END, Result.OK);
  recorder.mark(disabled, Stage.BACKUP_END, Result.OK);
  recorder.mark(old, Stage.BACKUP_END, Result.FAIL, { reason: Reason.IO_ERROR });
  assert.equal(lines.length, 2);
  assert.equal(lines[1].includes('op='), false);
  const fresh = recorder.begin(Kind.BACKUP);
  assert.ok(fresh.op > old.op);
  recorder.mark(fresh, Stage.BACKUP_BEGIN, Result.BEGIN);
  recorder.disable();
  recorder.mark(fresh, Stage.BACKUP_END, Result.OK);
  assert.equal(lines.length, 3);
  assertWire(lines);
});

test('main-thread guard prevents TaskPool numbering and output', () => {
  const { recorder, lines } = setup(false);
  assert.equal(recorder.enable(), false);
  const context = recorder.begin(Kind.HISTORY);
  assert.equal(context.op, 0);
  recorder.mark(context, Stage.HISTORY_END, Result.FAIL);
  assert.equal(lines.length, 0);
});

test('sink and clock failure never throw, backwards clock closes rather than extends detail session', () => {
  const { recorder, clock, sink, lines } = setup();
  recorder.enable();
  const context = recorder.begin(Kind.BACKUP);
  sink.fail = true;
  assert.doesNotThrow(() => recorder.mark(context, Stage.BACKUP_BEGIN, Result.BEGIN));
  sink.fail = false;
  clock.value = 1000;
  assert.equal(recorder.isEnabled(), true);
  clock.value = 999;
  assert.doesNotThrow(() => recorder.mark(context, Stage.BACKUP_END, Result.FAIL));
  assert.equal(recorder.isEnabled(), false);
  clock.fail = true;
  assert.equal(recorder.enable(), false);
  assert.equal(lines.length, 0);
});

test('raw errors/proxies/getters/toJSON/toString are never inspected or invoked', () => {
  const { recorder, lines } = setup();
  recorder.enable();
  let touched = 0;
  const hostile = new Proxy({}, { get() { touched++; throw new Error(SENTINELS[0]); },
    getOwnPropertyDescriptor() { touched++; throw new Error(SENTINELS[0]); } });
  const getter = {
    get code() { touched++; return 13900020; }, get message() { touched++; return SENTINELS[1]; },
    get cause() { touched++; return { secret: SENTINELS[2] }; },
    toJSON() { touched++; return SENTINELS[3]; }, toString() { touched++; return SENTINELS[4]; },
  };
  for (const error of [hostile, getter, new Error(SENTINELS.join(' ')), SENTINELS[4], null, undefined, '13900020']) {
    const context = recorder.begin(Kind.BACKUP);
    recorder.fail(context, Stage.FS_WRITE, Domain.FS, error);
    recorder.end(context);
  }
  assert.equal(touched, 0);
  assert.ok(lines.every(line => line.includes('code=UNKNOWN')));
  assertNoSentinels(lines.join('\n'));
  assertWire(lines);
});

test('details rebuild discards unknown fields and coerces neither objects nor booleans', () => {
  const { recorder, lines } = setup(); recorder.enable();
  const context = recorder.begin(Kind.BACKUP);
  let serialized = 0;
  recorder.mark(context, Stage.FS_WRITE, Result.FAIL, {
    reason: SENTINELS[0], code: 987654321, errorDomain: Domain.FS, item: 9000,
    mode: SENTINELS[1], contentNonEmpty: 'false', writeComplete: 1,
    path: SENTINELS[8], key: SENTINELS[3], header: SENTINELS[5], ciphertext: SENTINELS[6],
    device: SENTINELS[2], toJSON() { serialized++; return SENTINELS[7]; },
  });
  assert.equal(serialized, 0);
  assertNoSentinels(lines.join('\n'));
  assert.equal(lines[0].includes('item='), false);
  assert.equal(lines[0].includes('contentNonEmpty='), false);
  assert.equal(lines[0].includes('writeComplete='), false);
  assertWire(lines);
  // An accessor returning alternating values cannot evade the second normalization pass.
  let reads = 0;
  recorder.mark(context, Stage.FS_VERIFY, Result.FAIL, { get writeComplete() { return ++reads === 1 ? true : SENTINELS[3]; } });
  assertNoSentinels(lines.join('\n'));
  assertWire(lines);
  const before = lines.length;
  recorder.mark(context, Stage.FS_WRITE, Result.FAIL, { get writeComplete() { throw new Error(SENTINELS[0]); } });
  assert.equal(lines.length, before);
});

test('verified codes are stage/domain specific and collector has exactly the same mapping', () => {
  const valid = [
    ['FS_WRITE', 'FS', 13900020], ['FS_OPEN', 'FS', 13900002], ['FS_WRITE', 'FS', 13900025],
    ['HISTORY_END', 'FS', 13900002], ['CACHE_START', 'CACHE', 401], ['CACHE_START', 'CACHE', 13600001],
    ['CACHE_START', 'CACHE', 13900002], ['CACHE_START', 'CACHE', 13900025], ['CACHE_START', 'CACHE', 14000002],
    ['CACHE_STOP', 'CACHE', 401], ['CACHE_STOP', 'CACHE', 13600001], ['CACHE_STOP', 'CACHE', 13900002],
    ['CACHE_STOP', 'CACHE', 14000002], ['SYNC_START', 'SYNC', 22400001], ['SYNC_START', 'SYNC', 22400002],
    ['SYNC_START', 'SYNC', 22400003], ['SYNC_START', 'SYNC', 401], ['SYNC_START', 'SYNC', 13600001],
    ...[13900004, 13900005, 13900008, 13900025, 13900041].map(code => ['FS_CLOSE', 'FS', code]),
    ...[13900001, 13900002, 13900008, 13900011, 13900012, 13900013, 13900015, 13900018,
      13900020, 13900025, 13900028, 13900030, 13900033, 13900041].map(code => ['FS_STAGE', 'FS', code]),
    ['FS_PREPARE', 'FS', 13900012], ['FS_STAGE_MOVE', 'FS', 13900015], ['PUBLISH_END', 'FS', 13900015],
    ['READ_END', 'FS', 13900012], ['HISTORY_END', 'FS', 13900012], ['TEMP_CLEANUP', 'FS', 13900012],
    ...[1, 2, 3, 4, 5].map(code => ['CACHE_PROGRESS', 'CACHE', code]),
    ...[0, 1, 2, 3, 4, 5, 6, 7, 8].map(code => ['SYNC_STATE', 'SYNC', code]),
  ];
  for (const [stage, domain, code] of valid) {
    assert.equal(normalizeDiagnosticCode(stage, domain, code), code);
    assert.ok(parseDiagnosticLine(`CloudBackupDiag: v=1 op=1 kind=BACKUP stage=${stage} result=FAIL reason=${code === 0 ? 'NONE' : 'UNKNOWN'} elapsed=LT_1S errorDomain=${domain} code=${code}`));
  }
  for (const stage of Object.values(Stage)) for (const domain of Object.values(Domain)) {
    for (const code of [0, 1, 5, 6, 8, 9, 401, 13600001, 13900001, 13900002, 13900004, 13900005, 13900008,
      13900010, 13900011, 13900012, 13900013, 13900014, 13900015, 13900016, 13900018, 13900019, 13900020,
      13900023, 13900024, 13900025, 13900027, 13900028, 13900030, 13900032, 13900033, 13900034, 13900041,
      13900042, 14000002, 22400001, 22400003, 99999999]) {
      const approved = normalizeDiagnosticCode(stage, domain, code) !== 'UNKNOWN';
      const wire = parseDiagnosticLine(`CloudBackupDiag: v=1 op=1 kind=BACKUP stage=${stage} result=FAIL reason=${code === 0 ? 'NONE' : 'UNKNOWN'} elapsed=LT_1S errorDomain=${domain} code=${code}`);
      assert.equal(wire !== null, approved, `${stage}/${domain}/${code}`);
    }
  }
  for (const code of ['13900020', -1, NaN, Infinity, 13900020.5]) assert.equal(normalizeDiagnosticCode(Stage.FS_WRITE, Domain.FS, code), 'UNKNOWN');
});

test('new stages retain only compatible domains and reviewed boolean fields', () => {
  for (const stage of ['ACCOUNT_STATE', 'ACCOUNT_AUTHORIZE', 'ACCOUNT_INIT', 'TIME_PARSE', 'FS_ENCODE', 'RESTORE_BEGIN']) {
    for (const domain of Object.values(Domain)) {
      const safe = normalizeDiagnosticSummary(stage, Result.FAIL, { errorDomain: domain, code: 1001502012,
        reason: Reason.NOT_READY, path: SENTINELS[8], timestamp: 1745385600000, count: 42, bytes: 1024 });
      assert.equal(safe.details.errorDomain, domain === Domain.APP ? Domain.APP : Domain.UNKNOWN);
      assert.equal(safe.details.code, 'UNKNOWN');
      assertNoSentinels(JSON.stringify(safe));
    }
  }
  for (const stage of ['RESTORE_DECRYPT', 'RESTORE_VALIDATE']) {
    for (const domain of [Domain.CRYPTO, Domain.APP]) {
      const safe = normalizeDiagnosticSummary(stage, Result.FAIL, { errorDomain: domain, code: 13900012 });
      assert.equal(safe.details.errorDomain, domain);
      assert.equal(safe.details.code, 'UNKNOWN');
    }
  }
  const { recorder, lines } = setup(); recorder.enable();
  const context = recorder.begin(Kind.ICON);
  recorder.mark(context, Stage.ICON_CLEAR, Result.FAIL, { reason: Reason.INVALID_FORMAT, headerParsed: false });
  recorder.mark(context, Stage.ICON_IO, Result.BLOCKED, { reason: Reason.INFLIGHT_UNCONFIRMED, drained: false });
  assert.ok(lines[0].includes('headerParsed=false'));
  assert.ok(lines[1].includes('drained=false'));
  assertWire(lines);
});

test('post-publish verify stage carries only reviewed fields and round-trips through the collector', () => {
  // 校验失败三态只允许 reason/headerParsed；数量、文件名、路径无出口。
  const { recorder, lines } = setup(); recorder.enable();
  const context = recorder.begin(Kind.BACKUP);
  recorder.mark(context, Stage.POST_PUBLISH_VERIFY, Result.FAIL,
    { reason: Reason.MISMATCH, headerParsed: true, item: 1, location: 'CLOUD', truncated: true });
  recorder.mark(context, Stage.POST_PUBLISH_VERIFY, Result.FAIL,
    { reason: Reason.INVALID_FORMAT, errorDomain: Domain.FS, code: 13900020 });
  recorder.mark(context, Stage.POST_PUBLISH_VERIFY, Result.OK, { headerParsed: true, contentNonEmpty: true });
  assert.ok(lines[0].includes('stage=POST_PUBLISH_VERIFY'));
  assert.ok(lines[0].includes('reason=MISMATCH'));
  assert.ok(lines[0].includes('headerParsed=true'));
  assert.ok(!lines[0].includes('item='));
  assert.ok(!lines[0].includes('location='));
  assert.ok(lines[1].includes('code=13900020'));
  assert.equal(lines.length, 3); // 两个失败指纹各一条 + 校验通过的 OK 事件。
  assert.ok(lines[2].includes('result=OK'));
  assertWire(lines);
  const wire = `CloudBackupDiag: v=1 op=1 kind=BACKUP stage=POST_PUBLISH_VERIFY result=FAIL reason=MISMATCH elapsed=LT_1S headerParsed=true`;
  const parsed = parseDiagnosticLine(wire);
  assert.ok(parsed);
  assert.equal(serializeDiagnosticEvent(parsed), wire);
  // 隐私越界字段必须被整体拒绝，而不是静默剥除后被误信为已审查。
  assert.equal(parseDiagnosticLine(`${wire} reason=MISMATCH`), null);
  assert.equal(parseDiagnosticLine(wire.replace('headerParsed=true', 'writeComplete=true')), null);
  // POST_PUBLISH_VERIFY 未列入 FS 码白名单：具体错误码收敛为 UNKNOWN。
  assert.equal(parseDiagnosticLine(wire.replace('headerParsed=true', 'errorDomain=FS code=13900002')), null);
});

test('publication guard events use the existing modes without leaking journal identifiers', () => {
  for (const enabled of [false, true]) {
    const { recorder, lines } = setup();
    if (enabled) recorder.enable();
    const context = recorder.begin(Kind.BACKUP);
    for (const stage of [Stage.PUBLICATION_GUARD, Stage.PUBLICATION_CLEANUP]) {
      recorder.mark(context, stage, Result.FAIL, {
        reason: Reason.IO_ERROR, errorDomain: Domain.FS, code: 13900012,
        drained: false, partialFailure: true, syncStartAccepted: false,
        item: 1, location: 'LOCAL', fileName: SENTINELS[0], cloudRoot: SENTINELS[8],
        scopeDigest: SENTINELS[1], source: SENTINELS[4], tokenCount: 42,
      });
    }
    assert.equal(lines.length, 2);
    assertWire(lines);
    assertNoSentinels(lines.join('\n'));
    for (const line of lines) {
      const event = parseDiagnosticLine(`CloudBackupDiag: ${line}`);
      assert.equal(Object.hasOwn(event, 'op'), enabled);
      assert.equal(Object.hasOwn(event, 'drained'), enabled);
      assert.equal(Object.hasOwn(event, 'item'), false);
      assert.equal(Object.hasOwn(event, 'location'), false);
      if (!enabled) assert.deepEqual(Object.keys(event), ['v', 'kind', 'stage', 'result', 'reason']);
    }
    recorder.end(context);
  }
  const wire = 'CloudBackupDiag: v=1 op=1 kind=BACKUP stage=PUBLICATION_CLEANUP result=FAIL reason=IO_ERROR elapsed=LT_1S drained=false';
  for (const field of ['fileName=PRIVATE', 'scopeDigest=PRIVATE', 'item=1', 'location=LOCAL', 'uiAction=FEEDBACK']) {
    assert.equal(parseDiagnosticLine(`${wire} ${field}`), null);
  }
});

test('UI actions admit only fixed enums and never a route, user label or free text', () => {
  const { recorder, lines } = setup(); recorder.enable();
  const context = recorder.begin(Kind.UI);
  for (const stage of [Stage.UI_ACTION, Stage.UI_RESULT, Stage.UI_REFRESH]) {
    recorder.mark(context, stage, Result.FAIL, {
      uiAction: api.DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP, reason: Reason.SYNC_REJECTED,
      partialFailure: true, syncStartAccepted: false, route: SENTINELS[8], count: 17,
    });
  }
  recorder.mark(context, Stage.UI_RESULT, Result.FAIL, { uiAction: SENTINELS[2] });
  recorder.mark(context, Stage.FS_WRITE, Result.FAIL, { uiAction: api.DiagnosticUiAction.FEEDBACK });
  assertNoSentinels(lines.join('\n'));
  assertWire(lines);
  for (const line of lines.slice(0, 3)) assert.ok(line.includes('uiAction=UNKNOWN_SOURCE_CLEANUP'));
  assert.ok(lines[3].includes('uiAction=UNKNOWN'));
  assert.equal(lines[4].includes('uiAction='), false);
  const wire = `CloudBackupDiag: ${lines[1]}`;
  assert.equal(parseDiagnosticLine(wire.replace('uiAction=UNKNOWN_SOURCE_CLEANUP', 'uiAction=PRIVATE')), null);
  assert.equal(parseDiagnosticLine(`${wire} route=PRIVATE`), null);
});

test('SYNC_STATE zero means NONE and no other domain or stage allows zero', () => {
  assert.equal(classifyDiagnosticError(Stage.SYNC_STATE, Domain.SYNC, 0).reason, Reason.NONE);
  const safe = normalizeDiagnosticSummary(Stage.SYNC_STATE, Result.OK,
    { errorDomain: Domain.SYNC, code: 0, reason: Reason.UNAVAILABLE });
  assert.equal(safe.details.reason, Reason.NONE);
  const { recorder, lines } = setup(); recorder.enable();
  recorder.mark(recorder.begin(Kind.SYNC), Stage.SYNC_STATE, Result.OK, safe.details);
  assert.ok(lines[0].includes('reason=NONE'));
  assert.ok(lines[0].includes('code=0'));
  assertWire(lines);
  const wire = `CloudBackupDiag: ${lines[0]}`;
  assert.equal(parseDiagnosticLine(wire.replace('reason=NONE', 'reason=UNKNOWN')), null);
  assert.equal(parseDiagnosticLine(wire.replace('stage=SYNC_STATE', 'stage=SYNC_START')), null);
  for (const domain of [Domain.FS, Domain.APP, Domain.CACHE, Domain.CRYPTO, Domain.UNKNOWN]) {
    assert.equal(parseDiagnosticLine(wire.replace('errorDomain=SYNC', `errorDomain=${domain}`)), null);
  }
  assert.equal(classifyDiagnosticError(Stage.FS_CLOSE, Domain.FS, 13900041).reason, Reason.NO_SPACE);
});

test('progress, representative failures, operation and session budgets are bounded', () => {
  const { recorder, lines } = setup(); recorder.enable();
  const cache = recorder.begin(Kind.CACHE);
  for (let index = 0; index < 1000; index++) recorder.mark(cache, Stage.CACHE_PROGRESS, Result.PENDING,
    { state: index % 2 ? 'RUNNING' : 'IDLE', uriMatches: false });
  assert.equal(lines.length, 1);
  recorder.end(cache);
  const batch = recorder.begin(Kind.HISTORY);
  for (let index = 0; index < 500; index++) recorder.mark(batch, Stage.READ_END, Result.OK, { contentNonEmpty: true });
  assert.equal(lines.length, 1);
  for (const reason of Object.values(Reason)) recorder.mark(batch, Stage.READ_END, Result.FAIL, { reason });
  assert.equal(lines.length, 3);
  assert.equal(lines[1].includes('item=1'), true);
  assert.equal(lines[2].includes('item=2'), true);
  recorder.mark(batch, Stage.HISTORY_END, Result.FAIL, { reason: Reason.PARTIAL_FAILURE, partialFailure: true });
  assert.equal(lines[3].includes('truncated=true'), true);
  recorder.end(batch);
  for (let op = 0; op < 20; op++) {
    const context = recorder.begin(Kind.BACKUP);
    for (const stage of Object.values(Stage)) for (const reason of Object.values(Reason)) {
      recorder.mark(context, stage, Result.FAIL, { reason });
    }
    recorder.end(context);
    if (context.op === 0) break;
  }
  const detailed = lines.filter(line => line.includes('op='));
  assert.equal(detailed.length, 256);
  assert.ok(lines.length <= 288); // Exhausted/new contexts may still use the separate default summary budget.
  assert.equal(detailed.at(-1).includes('truncated=true'), true);
  const counts = new Map();
  for (const line of detailed) { const op = /op=(\d+)/.exec(line)[1]; counts.set(op, (counts.get(op) ?? 0) + 1); }
  assert.ok([...counts.values()].every(count => count <= 32));
  assertWire(lines);
});

test('context allocation and finish release are capped; caller-mutated op cannot become an identifier', () => {
  const { recorder, lines } = setup(); recorder.enable();
  const contexts = Array.from({ length: 17 }, () => recorder.begin(Kind.BACKUP));
  assert.equal(contexts[16].op, 0);
  recorder.end(contexts[0]);
  const fresh = recorder.begin(Kind.BACKUP);
  assert.ok(fresh.op > 0);
  fresh.op = SENTINELS[0]; // JavaScript hostile caller bypasses ArkTS readonly.
  recorder.mark(fresh, Stage.BACKUP_END, Result.OK);
  assertNoSentinels(lines.join('\n'));
  assertWire(lines);
});

test('TaskPool pure summaries are bounded, normalized, and replayed through current generation', () => {
  const summaries = [];
  for (const reason of Object.values(Reason)) appendDiagnosticSummary(summaries, Stage.READ_END, Result.FAIL, { reason, path: SENTINELS[8] });
  appendDiagnosticSummary(summaries, Stage.READ_END, Result.OK, {});
  assert.equal(summaries.length, 2);
  assert.equal(summaries[1].details.truncated, true);
  assertNoSentinels(JSON.stringify(summaries));
  const { recorder, lines } = setup(); recorder.enable();
  const context = recorder.begin(Kind.HISTORY);
  recorder.disable(); recorder.enable(); recorder.replay(context, summaries);
  assert.equal(lines.length, 2);
  assert.ok(lines.every(line => !line.includes('op=')));
  assertWire(lines);
  assert.equal(normalizeDiagnosticSummary(SENTINELS[0], SENTINELS[1], {}).stage, Stage.UNKNOWN);
});

test('collector rebuilds only fixed tag events and removes all native prefixes', () => {
  const collector = new DiagnosticCollector();
  collector.feed(Buffer.from(`10-10 12:13:14.123 987 654 I A0ff00/CloudBackupDiag: ${safeSummary.split(': ')[1]}\n`));
  collector.feed(Buffer.from(`${SENTINELS.join(' ')}\n`));
  collector.feed(Buffer.from(`10-10 12:13:14.123 987 654 E A12345/SDK: ${detail()} ${SENTINELS[1]}\n`));
  collector.feed(Buffer.from(`${detail(' errorDomain=FS code=13900020 writeComplete=false')}\n`));
  collector.finish();
  const report = collector.report();
  assertNoSentinels(report);
  assert.equal(report.includes('12:13:14'), false);
  assert.equal(report.includes('987'), false);
  assert.equal(report.includes('A0ff00'), false);
  assert.ok(report.includes('code=13900020'));
  assert.equal(report.match(/CloudBackupDiag:/g).length, 2);
});

test('collector accepts one bounded process segment and strips sentinel prefixes', () => {
  const payload = safeSummary.slice('CloudBackupDiag: '.length);
  const prefix = '2026-10-10 12:13:14.123 987 654 I A0FF00/';
  const accepted = [`${prefix}CloudBackupDiag: ${payload}`,
    `${prefix}processName/CloudBackupDiag: ${payload}`,
    `${prefix}smartcityshenzhen.yylx.totptoken:worker-1/CloudBackupDiag: ${payload}`,
    `${prefix}${SENTINELS[0]}/CloudBackupDiag: ${payload}`,
    `${prefix}${'a'.repeat(128)}/CloudBackupDiag: ${payload}`];
  const collector = new DiagnosticCollector();
  for (const line of accepted) {
    assert.ok(parseDiagnosticLine(line));
    collector.feed(Buffer.from(`${line}\n`));
  }
  const rejected = [
    `${prefix}/CloudBackupDiag: ${payload}`, `${prefix}first/second/CloudBackupDiag: ${payload}`,
    `${prefix}${SENTINELS[8]}/CloudBackupDiag: ${payload}`, `${prefix}../CloudBackupDiag: ${payload}`,
    `${prefix}process name/CloudBackupDiag: ${payload}`, `${prefix}process\\name/CloudBackupDiag: ${payload}`,
    `${prefix}流程/CloudBackupDiag: ${payload}`, `${prefix}${'a'.repeat(129)}/CloudBackupDiag: ${payload}`,
    `${prefix}${SENTINELS[0]}\u001b/CloudBackupDiag: ${payload}`,
    `${prefix}${SENTINELS[0]}/OtherTag: CloudBackupDiag: ${payload}`,
    `${prefix.replace('A0FF00', 'A0FF01')}${SENTINELS[0]}/CloudBackupDiag: ${payload}`,
    `${SENTINELS[0]} ${prefix}CloudBackupDiag: ${payload}`,
    `${SENTINELS[0]}/CloudBackupDiag: ${payload}`,
  ];
  for (const line of rejected) {
    assert.equal(parseDiagnosticLine(line), null);
    collector.feed(Buffer.from(`${line}\n`));
  }
  collector.finish();
  const report = collector.report();
  assertNoSentinels(report);
  assert.equal(report.includes('12:13:14'), false);
  assert.equal(report.includes('processName'), false);
  assert.equal(report.includes('smartcityshenzhen'), false);
  assert.equal(report.match(/CloudBackupDiag:/g).length, 1);
});

test('collector rejects unknown fields, invalid stage fields, malformed numeric values and injected lines', () => {
  const invalid = [
    detail(' path=SYNTH_ODID_7F3'), detail(' identityAvailable=true'), detail(' code=13900020'),
    detail(' errorDomain=CACHE code=13900020'), detail(' item=3'), detail(' item=01'),
    detail(' errorDomain=FS code=98765432'), detail(' writeComplete=1'), detail(' mode=ENCRYPTED'),
    detail(' truncated=false'), detail(' reason=IO_ERROR'), detail(' header=SYNTH_HEADER'),
    detail().replace('op=1', 'op=2147483648'), detail().replace('op=1', 'op=01'),
    detail().replace('op=1', 'op=-1'), detail().replace('v=1', 'v=2'), detail().replace('elapsed=LT_1S', 'elapsed=400'),
    `SDK: ${detail()}`, `SecretPrefix CloudBackupDiag: ${safeSummary.split(': ')[1]}`,
    `10-10 12:13:14.123 987 654 I A12345/${detail()}`,
    detail().replace('CloudBackupDiag:', 'CloudBackupDiagOther:'), `${detail()}\n${SENTINELS[1]}`,
    detail(' writeComplete=false\u001b'), `${detail()}\n`, `${detail()}\r`, `${detail()}\u2028`,
    `${safeSummary} op=1`, `${safeSummary} elapsed=LT_1S`,
    safeSummary.replace('result=FAIL', 'result=OK'), `${detail()} __proto__=UNKNOWN`,
  ];
  for (const line of invalid) assert.equal(parseDiagnosticLine(line), null, line);
  assert.equal(serializeDiagnosticEvent({ v: '1', toJSON: () => SENTINELS[0] }), null);
  assert.equal(serializeDiagnosticEvent({ get v() { throw new Error(SENTINELS[0]); } }), null);
});

test('collector line, total input, output and event budgets work across chunk boundaries', () => {
  const collector = new DiagnosticCollector();
  collector.feed(Buffer.from('X'.repeat(LIMITS.lineBytes + 1)));
  collector.feed(Buffer.from(`${SENTINELS[0]}\n${safeSummary}\n`));
  for (const byte of Buffer.from(`${detail(' writeComplete=false')}\r\n`)) collector.feed(Buffer.from([byte]));
  collector.finish();
  assertNoSentinels(collector.report());
  assert.ok(collector.report().includes('DISCARD LINE_LIMIT'));
  assert.equal(collector.report().match(/CloudBackupDiag:/g).length, 2);
  collector.feed(Buffer.alloc(LIMITS.inputBytes));
  assert.equal(collector.stopped, true);
  const bounded = new DiagnosticCollector();
  for (let op = 1; op <= 1000; op++) bounded.feed(Buffer.from(`${detail().replace('op=1 ', `op=${op} `)}\n`));
  bounded.finish();
  assert.equal(bounded.report().match(/CloudBackupDiag:/g).length, LIMITS.operations);
  assert.ok(Buffer.byteLength(bounded.report()) < LIMITS.outputBytes);
  const all = new DiagnosticCollector();
  for (let op = 1; op <= 9; op++) for (const stage of STAGES) {
    all.feed(Buffer.from(`CloudBackupDiag: v=1 op=${op} kind=BACKUP stage=${stage} result=FAIL reason=UNKNOWN elapsed=LT_1S\n`));
  }
  for (const stage of STAGES) all.feed(Buffer.from(`CloudBackupDiag: v=1 kind=BACKUP stage=${stage} result=FAIL reason=UNKNOWN\n`));
  all.finish();
  assert.equal(all.report().match(/CloudBackupDiag:/g).length, LIMITS.events);
  assert.equal(all.report().match(/ op=/g).length, LIMITS.detailedEvents);
});

function fakeChild() {
  const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.killed = false; child.kill = () => { child.killed = true; };
  return child;
}
test('collection failure and hostile stderr do not expose target/path/command output', async () => {
  const child = fakeChild();
  let captured;
  const pending = collectFromHdc({ device: 'SYNTH_DEVICE_SERIAL', spawnCommand(executable, args, options) {
    captured = { args, options }; queueMicrotask(() => {
      child.stdout.write(`${safeSummary}\n`); child.stderr.write(SENTINELS.join(' ')); child.emit('close', 7);
    }); return child;
  } });
  const report = await pending;
  assertNoSentinels(report); assert.equal(report.includes('SYNTH_DEVICE_SERIAL'), false);
  assert.ok(report.includes('STATUS COLLECTION_FAILED'));
  assert.equal(captured.options.shell, false);
  assert.deepEqual(captured.args.slice(0, 2), ['-t', 'SYNTH_DEVICE_SERIAL']);
  assert.ok(!captured.args.includes('-r'));
  const unavailable = await collectFromHdc({ spawnCommand() { throw new Error(SENTINELS[8]); } });
  assertNoSentinels(unavailable); assert.ok(unavailable.includes('DEVICE_UNAVAILABLE'));
});

test('device selector rejects control/newline injection without spawning or echoing it', async () => {
  for (const device of ['SYNTH_DEVICE_SERIAL\n', 'SYNTH_DEVICE_SERIAL\r', 'SYNTH_DEVICE_SERIAL;command', SENTINELS[8]]) {
    let spawned = false;
    const report = await collectFromHdc({ device, spawnCommand() { spawned = true; throw new Error('unexpected'); } });
    assert.equal(spawned, false);
    assert.ok(report.includes('INVALID_ARGUMENTS'));
    assert.equal(report.includes('SYNTH_DEVICE_SERIAL'), false);
    assertNoSentinels(report);
  }
});

test('collection terminates at the fixed deadline and input budget', async context => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  const child = fakeChild();
  const pending = collectFromHdc({ spawnCommand: () => child });
  context.mock.timers.tick(LIMITS.durationMs);
  assert.ok((await pending).includes('COLLECTION_WINDOW_ENDED'));
  assert.equal(child.killed, true);
  const tooLarge = fakeChild();
  const next = collectFromHdc({ spawnCommand: () => tooLarge });
  tooLarge.stderr.write(Buffer.alloc(LIMITS.inputBytes + 1, 65));
  assert.ok((await next).includes('INPUT_LIMIT'));
  assert.equal(tooLarge.killed, true);
});

test('explicit output uses a fixed basename, exclusive creation, and never creates raw copies', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-diag-synthetic-'));
  try {
    const collector = new DiagnosticCollector(); collector.feed(Buffer.from(`${safeSummary}\n${SENTINELS[0]}\n`)); collector.finish();
    const report = collector.report();
    assert.equal(await writeReport(directory, report), 'COLLECTION_COMPLETE');
    assert.equal(await writeReport(directory, report), 'OUTPUT_EXISTS');
    assert.equal(await writeReport(directory, SENTINELS[0]), 'OUTPUT_FAILED');
    assert.deepEqual(await readdir(directory), [REPORT_BASENAME]);
    assert.equal(await readFile(join(directory, REPORT_BASENAME), 'utf8'), report);
    assertNoSentinels(report);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

const cloudFile = 'common/src/main/ets/utils/CloudBackupManager.ets';
test('static privacy gate blocks direct/aliased raw sinks and dynamic exception wrapping', () => {
  const invalid = [
    "import { hilog as other } from '@kit.PerformanceAnalysisKit'; other.info(1, 'x', message);",
    "import * as sdk from '@kit.PerformanceAnalysisKit'; sdk['hilog'].info(1, 'x', raw);",
    'const template = `${console.log(secret)}`;',
    'console.log(error);', "console['log'](error);", "import logger from './Logger'; logger.error(raw);",
    'const { error } = hilog;', 'throw new Error(JSON.stringify(error));', 'throw new Error(`failed ${error}`);',
    'try {} catch (failure) { const raw = JSON.stringify(failure); }',
    "import { CloudBackupDiagnosticRecorder as Bypass } from './CloudBackupDiagnostics';",
  ];
  for (const code of invalid) assert.ok(checkSource(code, cloudFile).length > 0, code);
  assert.equal(checkSource("// console.log(secret)\nthrow new Error('FIXED_FAILURE');", cloudFile).length, 0);
  assert.ok(checkSource('CloudBackupDiagnostics.mark(ctx,stage,result);', 'common/src/main/ets/utils/CloudSyncTask.ets').length > 0);
  assert.equal(checkSource('appendDiagnosticSummary(result,stage,result);', 'common/src/main/ets/utils/CloudSyncTask.ets').length, 0);
  assert.equal(checkSource(source, 'common/src/main/ets/utils/CloudBackupDiagnostics.ets').length, 0);
});

const accountFile = 'common/src/main/ets/utils/HuaweiAccountManager.ets';
const timeFile = 'common/src/main/ets/utils/SyncTimeHelper.ets';
const indexFile = 'entry/src/main/ets/pages/Index.ets';
const accountSource = await readFile(new URL(`../${accountFile}`, import.meta.url), 'utf8');
const timeSource = await readFile(new URL(`../${timeFile}`, import.meta.url), 'utf8');
const indexSource = await readFile(new URL(`../${indexFile}`, import.meta.url), 'utf8');
function executableSource(value) {
  return stripTypeScriptTypes(value.replace(/^import[\s\S]*?;\r?\n/gm, ''), { mode: 'transform' }).replace(/\bexport\s+/g, '');
}
function diagnosticPorts(fixture) {
  return { ...api, CloudBackupDiagnostics: {
    begin: kind => fixture.recorder.begin(kind),
    mark: (...args) => fixture.recorder.mark(...args),
    end: context => fixture.recorder.end(context),
  } };
}
function accountFixture(error, setupError = false) {
  const fixture = setup(); fixture.recorder.enable();
  const authentication = {
    IdType: { UNION_ID: 1 }, State: { AUTHORIZED: 1 },
    HuaweiIDProvider: class {
      createAuthorizationWithHuaweiIDRequest() { if (setupError) throw error; return {}; }
      getHuaweiIDState() { return Promise.reject(error); }
    },
    AuthenticationController: class { executeRequest() { return Promise.reject(error); } },
  };
  const accountApi = runInNewContext(`${executableSource(accountSource)}\n({ HuaweiAccountManager, HuaweiAccountErrorCode, normalizeHuaweiAccountLoginError });`, {
    ...diagnosticPorts(fixture), authentication, util: { generateRandomUUID: () => SENTINELS[0] },
    PreferenceManager: { getInstance: () => ({ getValue: async () => false }) },
  });
  return { ...fixture, ...accountApi };
}

test('account authorization keeps cancellation/refusal branches with fixed errors and no message access', async () => {
  for (const code of [1001502012, 1001500002, 1001502001, 1001502005, 1001502009, 12300001, 987654321, '1001502012']) {
    let codeReads = 0; let rawReads = 0;
    const error = { get code() { codeReads++; return code; },
      get message() { rawReads++; return SENTINELS[1]; }, get stack() { rawReads++; return SENTINELS[8]; },
      get cause() { rawReads++; return SENTINELS[2]; }, toString() { rawReads++; return SENTINELS[3]; },
      toJSON() { rawReads++; return SENTINELS[4]; } };
    const fixture = accountFixture(error);
    const manager = fixture.HuaweiAccountManager.getInstance();
    await assert.rejects(manager.login({ getHostContext: () => ({}) }), failure => {
      assert.equal(failure.message, 'Huawei account authorization failed');
      assert.equal(failure.code, typeof code === 'number' && code !== 987654321 ? code : 0);
      assert.equal(fixture.HuaweiAccountManager.isUserCancel(failure.code), code === 1001502012);
      if (code === 1001500002) assert.equal(fixture.HuaweiAccountManager.getLoginErrorResource(failure.code), null);
      return true;
    });
    assert.equal(codeReads, 1); assert.equal(rawReads, 0);
    assert.ok(fixture.lines[0].includes('stage=ACCOUNT_AUTHORIZE'));
    assert.equal(fixture.lines[0].includes(`result=${code === 1001502012 ? 'CANCELLED' : 'FAIL'}`), true);
    assertNoSentinels(fixture.lines.join('\n'));
    assert.equal(fixture.lines.some(line => /100150|12300001|987654321/.test(line)), false);
    assertWire(fixture.lines);
  }
});

test('account SDK synchronous failure and throwing code getter produce only fixed fallback', async () => {
  let codeReads = 0; let messageReads = 0;
  const error = { get code() { codeReads++; throw new Error(SENTINELS[0]); },
    get message() { messageReads++; throw new Error(SENTINELS[1]); } };
  for (const setupError of [false, true]) {
    const fixture = accountFixture(error, setupError);
    await assert.rejects(fixture.HuaweiAccountManager.getInstance().login({ getHostContext: () => ({}) }), failure => {
      assert.equal(failure.code, 0); assert.equal(failure.message, 'Huawei account authorization failed'); return true;
    });
    assertNoSentinels(fixture.lines.join('\n')); assertWire(fixture.lines);
  }
  assert.equal(codeReads, 2); assert.equal(messageReads, 0);
  const fixture = accountFixture(error);
  let touched = 0;
  const hostile = new Proxy({}, { get() { touched++; throw new Error(SENTINELS[3]); } });
  assert.equal(fixture.normalizeHuaweiAccountLoginError(hostile).code, 0);
  assert.equal(touched, 0); // Pure numeric normalizer, not the SDK business-code boundary.
});

test('account state failure does not inspect any raw exception property', async () => {
  let touched = 0;
  const hostile = new Proxy({}, { get() { touched++; throw new Error(SENTINELS[0]); } });
  const fixture = accountFixture(hostile);
  fixture.HuaweiAccountManager.getInstance().checkAuthState();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(touched, 0);
  assert.ok(fixture.lines[0].includes('stage=ACCOUNT_STATE'));
  assertWire(fixture.lines); assertNoSentinels(fixture.lines.join('\n'));
});

test('time parse failure and Index account-init rejection emit fixed technical events only', async () => {
  const fixture = setup(); fixture.recorder.enable();
  let touched = 0;
  const hostile = new Proxy({}, { get() { touched++; throw new Error(SENTINELS[0]); } });
  const timeApi = runInNewContext(`${executableSource(timeSource)}\n({ SyncTimeHelper });`, {
    ...diagnosticPorts(fixture), Date: class { constructor() { throw hostile; } }, padZero: () => '',
  });
  assert.equal(timeApi.SyncTimeHelper.parseStoredTimestamp('2026-10-10 12:34'), 0);
  const start = indexSource.indexOf('HuaweiAccountManager.getInstance().init().then');
  const end = indexSource.indexOf('this.subscribeDistributedAccountLogout();', start);
  assert.ok(start >= 0 && end > start);
  const chain = stripTypeScriptTypes(indexSource.slice(start, end), { mode: 'transform' });
  await runInNewContext(`(function() { return ${chain} }).call({});`, {
    ...diagnosticPorts(fixture),
    HuaweiAccountManager: { getInstance: () => ({ init: () => Promise.reject(hostile) }) },
    hiTraceMeter: { finishTrace() {} },
  });
  assert.equal(touched, 0);
  assert.ok(fixture.lines[0].includes('stage=TIME_PARSE'));
  assert.ok(fixture.lines[1].includes('stage=ACCOUNT_INIT'));
  assert.equal(fixture.lines.join('\n').includes('2026'), false);
  assertNoSentinels(fixture.lines.join('\n')); assertWire(fixture.lines);
});

test('native account/time sources and staging journal are explicitly scoped, with precise Index coverage', () => {
  for (const file of [accountFile, timeFile, indexFile, 'common/src/main/ets/utils/StoragePorts.ets',
    'common/src/main/ets/utils/CloudBackupStaging.ets']) assert.ok(SCOPED_FILES.includes(file));
  for (const [file, value] of [[accountFile, accountSource], [timeFile, timeSource], [indexFile, indexSource]]) {
    assert.deepEqual(checkSource(value, file), []);
  }
  for (const file of [accountFile, timeFile]) {
    for (const value of ["console.log(error)", "const text = error.message;", "const text = error['stack'];",
      'const text = JSON.stringify(error);', 'throw new Error(error.message);']) assert.ok(checkSource(value, file).length > 0);
  }
  assert.ok(checkSource('super(message);', accountFile).length > 0);
  assert.ok(checkSource('new HuaweiAccountLoginError(error.code, error.message);', accountFile).length > 0);
  const clean = 'HuaweiAccountManager.getInstance().init().then(() => {}).catch(() => {});';
  assert.deepEqual(checkSource(`${clean} hilog.error(err.code, TAG, err.message);`, indexFile), []);
  for (const value of [
    'HuaweiAccountManager.getInstance().init().then(() => {}).catch(err => hilog.error(err.code, TAG, err.message));',
    "HuaweiAccountManager.getInstance().init().catch(err => { const text = err['message']; });",
    "HuaweiAccountManager.getInstance().init().catch(err => { throw new Error(`${err.message}`); });",
    "HuaweiAccountManager.getInstance().init().catch(err => { const x = () => {}; console.log(err); });",
    'const manager = HuaweiAccountManager.getInstance(); manager.init().catch(err => console.log(err));',
  ]) assert.ok(checkSource(value, indexFile).length > 0);
});

test('publication journal and failure state cannot introduce alternate sensitive sinks', async () => {
  for (const name of ['CloudBackupPublicationGuard', 'CloudSyncLastFailure']) {
    const file = `common/src/main/ets/utils/${name}.ets`;
    assert.ok(SCOPED_FILES.includes(file));
    const text = await readFile(new URL(`../${file}`, import.meta.url), 'utf8');
    assert.deepEqual(checkSource(text, file), []);
    for (const injected of ["console.error(error);", "hilog.error(0xFF00, 'Guard', '%{public}s', cloudRoot);",
      "const rejected = JSON.stringify(error);"]) {
      assert.ok(checkSource(`${text}\ntry {} catch (error) { ${injected} }`, file).length > 0);
    }
  }
});

// 2026-10-13 audit P2-1: the icon import path must converge on the fixed-enum diag facade.
// Scope pins four files; the reader stays zero-output, the gate file stays pure, SubItemIconManager
// must lose every direct sink and raw-exception channel, and the diag helper accepts numbers only.
const subItemFile = 'entry/src/main/ets/components/SubItemIconManager.ets';
const zipGateFile = 'common/src/main/ets/utils/IconPackZipGate.ets';
const zipReaderFile = 'entry/src/main/ets/components/IconPackZipReader.ts';
const diagLogFile = 'entry/src/main/ets/utils/IconPackImportDiag.ets';
const publicationFile = 'common/src/main/ets/utils/IconPackPublication.ets';
test('icon import boundary is pinned and bans raw exceptions, unknown-code masks and alternate sinks', async () => {
  for (const file of [subItemFile, zipGateFile, zipReaderFile, diagLogFile, publicationFile]) {
    assert.ok(SCOPED_FILES.includes(file), file);
  }
  // Receipt persistence serializes JSON by design; only caught-variable serialization is banned here.
  assert.deepEqual(
    checkSource('saveReceipt({ get name() { return "r"; } });\nconst text = JSON.stringify(receipt);', publicationFile),
    []);
  assert.ok(checkSource('try {} catch (error) { const text = JSON.stringify(error); }', publicationFile).length > 0);
  assert.ok(checkSource("hilog.error(0, 'Publication', '%{public}s', receiptName);", publicationFile).length > 0);
  // The audited incident pattern: raw exception text into a direct sink.
  const invalid = [
    [subItemFile, "hilog.error(0, 'SubItemIconManager', 'Icon pack import failed: ' + JSON.stringify(err));"],
    [subItemFile, "hilog.error(0, 'SubItemIconManager', 'rematch token failed: ' + JSON.stringify(e));"],
    // Raw message/stack text, including into user-facing snackbars and via bracket access.
    [subItemFile, "showSnackBar((err as BusinessError).message ?? `fallback`, type);"],
    [subItemFile, "const text = err['stack'];"],
    [subItemFile, "const text = error.cause;"],
    // Unknown-code mask: an unreadable getter must not become a plausible numeric code.
    [subItemFile, 'const detail = `code=${(err as BusinessError).code ?? 0}`;'],
    [subItemFile, "const code = err.code ?? '';"],
    [diagLogFile, 'const code = code ?? 0;'],
    // Throwing-getter sentinel: the member read itself is banned, sink or no sink.
    [subItemFile, "const hostile = { get message() { return 'SYNTH_PACK_CACHE/x.zip'; } };\nconst leaked = hostile.message;"],
    [subItemFile, "const hostile = { get message() { return 'SYNTH_PACK_CACHE/x.zip'; } };\nhilog.error(0, 'T', hostile.message);"],
    // Reader/gate/helper must not grow sinks.
    [zipGateFile, 'console.error(error);'],
    [zipGateFile, "hilog.error(0, 'Gate', '%{public}s', relativePath);"],
    [zipReaderFile, "hilog.info(0, 'ZipReader', 'entries');"],
    [diagLogFile, 'const text = error.message;'],
    [diagLogFile, 'const text = JSON.stringify(error);'],
  ];
  for (const [file, snippet] of invalid) {
    assert.ok(checkSource(snippet, file).length > 0, `${file}: ${snippet}`);
  }
  // Throwing getter classification stays explicit in the issues, not silent:
  const getter = checkSource(
    "const hostile = { get message() { return 'SYNTH_PACK_CACHE/x.zip'; } };\nhilog.error(0, 'T', hostile.message);",
    subItemFile).map(issue => issue.rule).sort();
  assert.deepEqual(getter, ['RAW_ERROR_MEMBER', 'UNAPPROVED_SINK']);
  const mask = checkSource('const detail = `code=${(err as BusinessError).code ?? 0}`;', subItemFile)
    .map(issue => issue.rule);
  assert.deepEqual(mask, ['UNKNOWN_CODE_FALLBACK']);
  // Intended end state passes: facade-only helper, numeric-only code extraction.
  const cleanHelper = [
    "import { CloudBackupDiagnostics, DiagnosticKind, DiagnosticStage, DiagnosticResult, DiagnosticReason, " +
      "DiagnosticErrorDomain } from 'common';",
    'export function iconPackImportDiagFail(code: number | undefined): void {',
    '  const context = CloudBackupDiagnostics.begin(DiagnosticKind.ICON);',
    '  CloudBackupDiagnostics.fail(context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.FS, code);',
    '  CloudBackupDiagnostics.end(context);',
    '}',
  ].join('\n');
  assert.deepEqual(checkSource(cleanHelper, diagLogFile), []);
  const cleanCatch = 'try {} catch (err) { ' +
    "const code = typeof (err as BusinessError).code === 'number' ? (err as BusinessError).code as number : undefined; " +
    'iconPackImportDiagFail(code); }';
  assert.deepEqual(checkSource(cleanCatch, subItemFile), []);
  // Gate file keeps its pure enum verdicts; codes compared, never masked.
  const cleanGate = 'export function map(error: BusinessError): string { ' +
    "return error.code === 900003 ? 'NOT_ZIP_OR_DAMAGED' : 'IO_ERROR'; }";
  assert.deepEqual(checkSource(cleanGate, zipGateFile), []);
  // Already-committed pure files must keep passing the widened scope.
  assert.deepEqual(checkSource(await readFile(new URL(`../${zipGateFile}`, import.meta.url), 'utf8'), zipGateFile), []);
  assert.deepEqual(checkSource(await readFile(new URL(`../${zipReaderFile}`, import.meta.url), 'utf8'), zipReaderFile), []);
});

test('EntryAbility static scope covers cloud/device logging, not unrelated application logs', () => {
  const file = 'entry/src/main/ets/entryability/EntryAbility.ets';
  assert.equal(checkSource("hilog.info(0, 'test', 'Ability onCreate'); DeviceInfoHelper.getInstance().init();", file).length, 0);
  assert.ok(checkSource("hilog.info(0, 'test', `ODID=${odid}`);", file).length > 0);
  assert.ok(checkSource('DeviceInfoHelper.getInstance().init().catch(err => console.log(err));', file).length > 0);
});

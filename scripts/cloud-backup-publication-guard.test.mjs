import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { setup as managerSetup, withStaging } from './cloud-backup-restore.test.mjs';
import { setup as stagingSetup } from './cloud-backup-staging.test.mjs';

const ROOT = '/synthetic/SYNTH_PRIVATE_CLOUD';
const LOCAL = '/synthetic/SYNTH_LOCAL_FILES';
const SCOPE = 'a'.repeat(64);
const FINAL = 'otp_backup_42.enc';
const PRIVATE = 'SYNTH_PRIVATE_GUARD_ERROR';
const source = await readFile(new URL('../common/src/main/ets/utils/CloudBackupPublicationGuard.ets', import.meta.url), 'utf8');
const code = stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''), { mode: 'transform' }).replace(/\bexport\s+/g, '');
const nativeError = (code = 13900005) => Object.assign(new Error(PRIVATE), { code });
const formal = fixture => [...fixture.files.keys()].filter(path => /\/otp_backup_-?\d+\.enc$/.test(path));
function restart(fixture) {
  fixture.manager.resetForTest();
  fixture.manager.useDepsForTest(fixture.deps);
}
function seedCandidate(fixture, fileName = 'otp_backup_777.enc') {
  const id = 'publication-987654';
  const receipt = { id, version: 1, scope: fixture.account.key, cloudRoot: fixture.deps.cloudDir,
    fileName, source: `${fixture.deps.cloudDir}/.cloud-backup-owned-123456/content.tmp`, state: 'CANDIDATE' };
  fixture.publication.receipts.set(id, receipt);
  return receipt;
}
function assertIsolated(record) {
  assert.equal(record.metadataStatus, 'INVALID');
  assert.equal(record.tokenCountKnown, false);
  assert.equal(record.tokenCount, 0);
  assert.equal(record.deviceId, '');
  assert.equal(record.identityStatus, 'ID_MISSING');
}

for (const failure of ['formalReadFailure', 'formalOverride']) {
  test(`publication P1 ${failure} plus unlink failure stays isolated across restart and retries sync safely`, async () => {
    const f = managerSetup();
    const stage = withStaging(f);
    if (failure === 'formalOverride') f.behavior.formalOverride = await f.encrypted(); // header count 4 vs snapshot 0
    else f.behavior.formalReadFailure = true;
    f.behavior.failDelete = true;
    f.behavior.failSync = true;
    const result = await f.manager.backupToCloudResult();
    assert.equal(result.reason, 'POST_VERIFY_FAILED');
    assert.equal(result.partialFailure, true);
    assert.equal(result.syncStartAccepted, false);
    assert.equal(f.captures.sync, 0, 'failed unlink must not authorize a sync acknowledgement');
    assert.equal(f.publication.receipts.size, 1);
    assert.equal([...f.publication.receipts.values()][0].state, 'REJECTED');
    const path = formal(f)[0];
    const id = path.slice(f.deps.cloudDir.length + 1);
    f.behavior.formalReadFailure = false;
    f.behavior.failSync = false;
    restart(f);
    // History staging sync may forget the stage, never the independent rejected evidence.
    const history = await f.manager.listBackupHistoryResult();
    assert.equal(history.success, true);
    assertIsolated(history.records[0]);
    assert.equal(f.publication.receipts.size, 1);
    assert.equal((await f.manager.restoreFromBackupRecordResult(id)).reason, 'POST_VERIFY_FAILED');
    assert.equal(f.captures.attempts, 0);
    assert.equal(await f.manager.retryPendingCleanup(), false);
    assert.equal(f.files.has(path), true);
    f.behavior.failDelete = false;
    f.behavior.failSync = true;
    assert.equal(await f.manager.retryPendingCleanup(), false);
    assert.equal(f.files.has(path), false);
    assert.equal(f.publication.receipts.size, 1, 'unlink success + sync rejection must retain isolation');
    restart(f);
    f.behavior.failSync = false;
    assert.equal(await f.manager.retryPendingCleanup(), true);
    assert.equal(f.publication.receipts.size, 0);
    assert.equal(stage.receipts.size, 0);
    const output = f.lines.join('\n');
    for (const secret of [PRIVATE, path, f.account.key, id]) assert.equal(output.includes(secret), false);
  });
}

test('publication candidate save failure never publishes or touches an existing foreign final', async () => {
  const f = managerSetup();
  f.publication.save = async () => { throw nativeError(); };
  const foreign = `${f.deps.cloudDir}/otp_backup_1.enc`;
  f.files.set(foreign, 'SYNTH_FOREIGN');
  const result = await f.manager.backupToCloudResult();
  assert.equal(result.reason, 'WRITE_FAILED');
  assert.equal(f.captures.publishes, 0);
  assert.equal(f.files.get(foreign), 'SYNTH_FOREIGN');
  assert.equal(f.behavior.deletedPaths.includes(foreign), false);
  assert.equal(f.captures.sync, 0);
});

for (const boundary of ['PUBLISHED', 'REJECTED', 'VERIFIED']) {
  test(`publication ${boundary} proof store failure remains isolated and never grants automatic delete`, async () => {
    const f = managerSetup();
    if (boundary === 'REJECTED') f.behavior.formalReadFailure = true;
    const mark = f.publication.mark.bind(f.publication);
    f.publication.mark = async (id, state) => {
      if (state === boundary) throw nativeError();
      await mark(id, state);
    };
    const result = await f.manager.backupToCloudResult();
    assert.equal(result.reason, boundary === 'REJECTED' ? 'POST_VERIFY_FAILED' : 'WRITE_FAILED');
    const path = formal(f)[0];
    assert.ok(path);
    assert.equal(f.behavior.deletedPaths.includes(path), false);
    assert.equal(f.captures.sync, 0);
    f.publication.mark = mark;
    f.behavior.formalReadFailure = false;
    restart(f);
    assertIsolated((await f.manager.listBackupHistoryResult()).records[0]);
    assert.equal(await f.manager.retryPendingCleanup(), true, 'per-file isolation is not unresolved native I/O');
    assert.equal(f.manager.isCleanupPending(), false);
    assert.equal(f.files.has(path), true);
    assert.equal(f.behavior.deletedPaths.includes(path), false);
  });
}

test('publication collision cancels candidate while source exists and never isolates or deletes foreign target', async () => {
  const f = managerSetup();
  f.behavior.collideFormal = true;
  assert.equal((await f.manager.backupToCloudResult()).reason, 'WRITE_FAILED');
  const path = formal(f)[0];
  assert.equal(f.files.get(path), 'SYNTH_FOREIGN_BACKUP');
  assert.equal(f.publication.receipts.size, 0);
  assert.equal(f.behavior.deletedPaths.includes(path), false);
  assert.equal(await f.manager.retryPendingCleanup(), true);
  assert.equal(f.files.get(path), 'SYNTH_FOREIGN_BACKUP');
});

test('restart candidate source inspection precedes staging recovery and leaves colliding foreign header normally visible', async () => {
  const f = managerSetup();
  const stage = withStaging(f);
  const receipt = seedCandidate(f);
  const directory = receipt.source.slice(0, receipt.source.lastIndexOf('/'));
  stage.directories.add(directory);
  stage.receipts.set('receipt-123456', { id: 'receipt-123456', version: 1, scope: stage.scope,
    cloudRoot: f.deps.cloudDir, stage: '.cloud-backup-owned-123456' });
  f.files.set(receipt.source, 'SYNTH_OWN_STAGE');
  const foreign = await f.crypto.encrypt('{"tokens":[]}', f.crypto.getMode(true), f.account.key, 0, 777, 'foreign-device', 'Foreign');
  const path = `${receipt.cloudRoot}/${receipt.fileName}`;
  f.files.set(path, foreign);
  f.deps.staging = stage.staging;
  restart(f);
  const history = await f.manager.listBackupHistoryResult();
  assert.equal(history.records[0].metadataStatus, 'VALID');
  assert.equal(history.records[0].deviceId, 'foreign-device');
  assert.equal(f.publication.receipts.size, 0);
  assert.equal(f.files.has(receipt.source), false);
  assert.equal(f.files.get(path), foreign);
  assert.equal(f.behavior.deletedPaths.includes(path), false);
});

test('restart after move but before published proof is failclosed; exact candidate is never auto-reaped', async () => {
  const f = managerSetup();
  const receipt = seedCandidate(f);
  const path = `${receipt.cloudRoot}/${receipt.fileName}`;
  f.files.set(path, await f.encrypted());
  restart(f);
  assertIsolated((await f.manager.listBackupHistoryResult()).records[0]);
  assert.equal((await f.manager.restoreFromBackupRecordResult(receipt.fileName)).reason, 'POST_VERIFY_FAILED');
  assert.equal(await f.manager.retryPendingCleanup(), true);
  assert.equal(f.manager.isCleanupPending(), false);
  assert.equal(f.files.has(path), true);
  assert.equal(f.behavior.deletedPaths.includes(path), false);
  assert.equal((await f.manager.backupToCloudResult()).success, true);
  const healthy = formal(f).find(candidate => candidate !== path);
  assert.equal((await f.manager.restoreFromBackupRecordResult(healthy.slice(f.deps.cloudDir.length + 1))).success, true);
  assert.equal((await f.manager.restoreFromBackupRecordResult(receipt.fileName)).reason, 'POST_VERIFY_FAILED');
  assert.equal((await f.manager.deleteBackupRecordResult(receipt.fileName)).success, true);
  assert.equal(f.publication.receipts.size, 0);
  assert.equal(f.files.has(path), false);
});

test('offline rejected cleanup is per-file isolation; history, healthy restore, new backup and explicit delete remain reachable', async () => {
  const f = managerSetup();
  f.behavior.formalReadFailure = true;
  f.behavior.failDelete = true;
  assert.equal((await f.manager.backupToCloudResult()).reason, 'POST_VERIFY_FAILED');
  const path = formal(f)[0];
  const id = path.slice(f.deps.cloudDir.length + 1);
  f.behavior.formalReadFailure = false;
  f.behavior.failSync = true;
  restart(f);
  assertIsolated((await f.manager.listBackupHistoryResult()).records[0]);
  assert.equal(f.manager.isCleanupPending(), false);
  assert.equal((await f.manager.restoreFromBackupRecordResult(id)).reason, 'POST_VERIFY_FAILED');
  assert.equal((await f.manager.backupToCloudResult()).reason, 'SYNC_FAILED');
  const healthy = formal(f).find(candidate => candidate !== path);
  assert.equal((await f.manager.restoreFromBackupRecordResult(healthy.slice(f.deps.cloudDir.length + 1))).success, true);
  assert.equal(f.manager.isCleanupPending(), false);
  f.behavior.failDelete = false;
  assert.equal((await f.manager.deleteBackupRecordResult(id)).reason, 'SYNC_FAILED');
  assert.equal(f.publication.receipts.size, 1, 'sync rejection preserves rejected deletion evidence');
  assert.equal(await f.manager.retryPendingCleanup(), false);
  assert.equal(f.manager.isCleanupPending(), false);
  f.behavior.failSync = false;
  assert.equal((await f.manager.deleteBackupRecordResult(id)).success, true);
  assert.equal(f.publication.receipts.size, 0);
});

for (const scope of ['single', 'all']) {
  test(`explicit ${scope} clear forgets only exact deleted isolation after sync acceptance, never after rejection`, async () => {
    const f = managerSetup();
    const receipt = seedCandidate(f);
    const path = `${receipt.cloudRoot}/${receipt.fileName}`;
    f.files.set(path, await f.encrypted());
    f.behavior.failSync = true;
    const clear = () => scope === 'single' ? f.manager.deleteBackupRecordResult(receipt.fileName) : f.manager.clearCloudStorageResult();
    assert.equal((await clear()).reason, 'SYNC_FAILED');
    assert.equal(f.files.has(path), false);
    assert.equal(f.publication.receipts.size, 1);
    assert.equal(f.manager.isCleanupPending(), false);
    f.behavior.failSync = false;
    // ALL cannot enumerate an already absent filename: retain exact proof until explicit per-record ENOENT acknowledgement.
    if (scope === 'all') f.files.set(path, await f.encrypted());
    assert.equal((await clear()).success, true);
    assert.equal(f.publication.receipts.size, 0);
  });
}

test('guard load corruption or I/O failure blocks restore, history, all/same-name clear and new publication', async () => {
  for (const corrupt of [false, true]) {
    const f = managerSetup();
    f.put(await f.encrypted());
    if (corrupt) f.publication.receipts.set('bad', { id: '../foreign' });
    else f.publication.load = async () => { throw nativeError(); };
    for (const call of [() => f.restore(), () => f.manager.listBackupHistoryResult(),
      () => f.manager.clearCloudStorageResult(), () => f.manager.clearDeviceNameCloudStorageResult(),
      () => f.manager.deleteBackupRecordResult('otp_backup_1745385600000.enc'), () => f.manager.backupToCloudResult()]) {
      assert.equal((await call()).reason, 'CLEANUP_PENDING');
    }
    assert.equal(f.captures.deletes + f.captures.publishes + f.captures.reads + f.captures.sync, 0);
  }
});

test('production history TaskPool result uses the same isolation filter and does not admit candidate to quota', async () => {
  const f = managerSetup();
  const receipt = seedCandidate(f, 'otp_backup_253402300799000.enc');
  f.files.set(`${receipt.cloudRoot}/${receipt.fileName}`, await f.encrypted());
  const direct = await f.manager.listBackupHistoryResult();
  assertIsolated(direct.records[0]);
  f.manager.useDepsForTest({ ...f.deps, historyTask: async () => ({ complete: true, diagnostics: [],
    records: [{ ...direct.records[0], metadataStatus: 'VALID', tokenCountKnown: true, tokenCount: 4,
      deviceId: 'synthetic-device', identityStatus: 'COMPLETE' }] }) });
  assertIsolated((await f.manager.listBackupHistoryResult()).records[0]);
  f.manager.useDepsForTest(f.deps);
  for (let index = 0; index < f.manager.maxBackupCount; index++) assert.equal((await f.manager.backupToCloudResult()).success, true);
  assert.equal(f.captures.deletes, 0, 'isolated backup must not consume any of the five valid slots');
  assert.equal((await f.manager.backupToCloudResult()).success, true);
  assert.equal(f.captures.deletes, 1);
  assert.equal(f.files.has(`${receipt.cloudRoot}/${receipt.fileName}`), true);
});

test('verified backup with ordinary sync rejection remains restorable after restart and is never cleaned as rejected', async () => {
  const f = managerSetup();
  f.behavior.failSync = true;
  const result = await f.manager.backupToCloudResult();
  assert.equal(result.reason, 'SYNC_FAILED');
  assert.equal(result.localComplete, true);
  assert.equal([...f.publication.receipts.values()][0].state, 'VERIFIED');
  const path = formal(f)[0];
  restart(f);
  assert.equal((await f.manager.restoreFromBackupRecordResult(path.slice(f.deps.cloudDir.length + 1))).success, true);
  assert.equal(f.files.has(path), true);
  assert.equal(f.captures.deletes, 0);
});

function nativeSetup() {
  const base = stagingSetup(undefined, true);
  const api = runInNewContext(`${code}\n({CloudBackupPublicationGuard,NativeCloudBackupPublicationPort,CloudPublicationState});`,
    { ...base.sdk, buffer: { from: (value, encoding) => { const b = Buffer.from(value, encoding);
      return { length: b.length, readUInt8: i => b[i] }; } } });
  const io = new api.NativeCloudBackupPublicationPort(LOCAL);
  const guard = new api.CloudBackupPublicationGuard(ROOT, SCOPE, io);
  return { ...base, api, io, guard, fresh: () => new api.CloudBackupPublicationGuard(ROOT, SCOPE, io) };
}

test('actual native publication candidate and release finish fsync and close before committed state is visible', async () => {
  const f = nativeSetup();
  const source = `${ROOT}/.cloud-backup-owned-123456/content.tmp`;
  f.port.put(source);
  assert.equal(await f.guard.recover(f.context), true);
  const id = await f.guard.register(source, FINAL, f.context);
  const candidate = `${LOCAL}/.cloud-backup-publications/${id}/candidate.pending`;
  const flush = f.port.events.findIndex(event => event.op === 'fsync' && event.path === candidate);
  const close = f.port.events.findIndex(event => event.op === 'close' && event.path === candidate);
  assert.ok(flush >= 0 && flush < close);
  await f.port.move(source, `${ROOT}/${FINAL}`);
  await f.guard.published(id, f.context);
  await f.guard.verified(id, f.context);
  const pending = `${LOCAL}/.cloud-backup-publications/${id}/verified.pending`;
  const final = `${LOCAL}/.cloud-backup-publications/${id}/verified.json`;
  const synced = f.port.events.findIndex(event => event.op === 'fsync' && event.path === pending);
  const closed = f.port.events.findIndex(event => event.op === 'close' && event.path === pending);
  const moved = f.port.events.findIndex(event => event.op === 'move' && event.destination === final);
  assert.ok(synced >= 0 && synced < closed && closed < moved);
  assert.equal((await f.io.load())[0].state, 'VERIFIED');
  assert.equal(await f.fresh().recover(f.context), true);
  assert.equal((await f.io.load()).length, 0);
  assert.equal(f.port.nodes.has(`${ROOT}/${FINAL}`), true);
});

for (const state of ['published', 'rejected', 'verified']) {
  for (const boundary of ['open', 'nativeWrite', 'fsync', 'close', 'move']) {
    test(`native ${state} ${boundary} proof failure cannot unlock or create deletion ownership after restart`, async () => {
      const f = nativeSetup();
      const source = `${ROOT}/.cloud-backup-owned-123456/content.tmp`;
      f.port.put(source);
      await f.guard.recover(f.context);
      const id = await f.guard.register(source, FINAL, f.context);
      await f.port.move(source, `${ROOT}/${FINAL}`);
      if (state !== 'published') await f.guard.published(id, f.context);
      f.port.failures.set(boundary, path => path.endsWith(`/${state}.pending`) ? nativeError() : undefined);
      const transition = state === 'published' ? 'published' : state === 'rejected' ? 'reject' : 'verified';
      await assert.rejects(f.guard[transition](id, f.context));
      assert.equal(f.guard.isAvailable(), false);
      f.port.failures.clear();
      const next = f.fresh();
      const readable = await next.recover(f.context);
      assert.equal(readable, true, 'known LOCAL pending fragments are removed without granting publication proof');
      assert.deepEqual([...next.isolatedFileNames()], [FINAL]);
      assert.equal(next.rejected().length, 0);
      assert.equal(f.port.nodes.has(`${ROOT}/${FINAL}`), true);
    });
  }
}

for (const boundary of ['open', 'nativeWrite', 'fsync', 'close', 'move']) {
  test(`native candidate ${boundary} failure with failed local cleanup recovers only precommit fragments`, async () => {
    const f = nativeSetup();
    await f.guard.recover(f.context);
    const source = `${ROOT}/.cloud-backup-owned-123456/content.tmp`;
    f.port.put(source);
    f.port.put(`${ROOT}/${FINAL}`, 'file', 'SYNTH_FOREIGN');
    f.port.failures.set(boundary, path => path.endsWith('/candidate.pending') ? nativeError() : undefined);
    f.port.failures.set('removeDirectory', nativeError());
    await assert.rejects(f.guard.register(source, FINAL, f.context));
    assert.equal(f.guard.isAvailable(), false);
    assert.equal(f.port.calls('move').some(call => call.destination === `${ROOT}/${FINAL}`), false);
    f.port.failures.clear();
    assert.equal(await f.fresh().recover(f.context), true);
    assert.equal((await f.io.load()).length, 0);
    assert.equal(f.port.nodes.has(source), true);
    assert.equal(f.port.nodes.get(`${ROOT}/${FINAL}`).content, 'SYNTH_FOREIGN');
    assert.equal(f.port.calls('unlink').length, 0);
    assert.ok(f.port.calls('removeDirectory').every(call => call.path.startsWith(`${LOCAL}/.cloud-backup-publications/`)));
  });
}

test('native malformed journal and proof read errors failclosed without deleting any cloud target', async () => {
  const f = nativeSetup();
  const source = `${ROOT}/.cloud-backup-owned-123456/content.tmp`;
  f.port.put(source);
  await f.guard.recover(f.context);
  const id = await f.guard.register(source, FINAL, f.context);
  await f.port.move(source, `${ROOT}/${FINAL}`);
  f.port.failures.set('nativeRead', nativeError());
  assert.equal(await f.fresh().recover(f.context), false);
  f.port.failures.clear();
  const file = `${LOCAL}/.cloud-backup-publications/${id}/candidate.json`;
  f.port.put(file, 'file', '{broken');
  assert.equal(await f.fresh().recover(f.context), false);
  assert.equal(f.port.nodes.has(`${ROOT}/${FINAL}`), true);
  assert.equal(f.port.calls('unlink').length, 0);
});

test('native guard diagnostics avoid hostile error getters and every receipt identifier', async () => {
  const f = nativeSetup();
  let reads = 0;
  const hostile = { get code() { return 13900005; }, get message() { reads++; return PRIVATE; },
    get stack() { reads++; return ROOT; }, toString() { reads++; return SCOPE; } };
  f.port.failures.set('mkdir', hostile);
  assert.equal(await f.guard.recover(f.context), false);
  assert.equal(reads, 0);
  const output = JSON.stringify({ lines: f.lines, calls: f.diagnosticCalls });
  for (const secret of [PRIVATE, ROOT, LOCAL, SCOPE, FINAL]) assert.equal(output.includes(secret), false);
});

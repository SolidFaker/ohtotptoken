import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { parseDiagnosticLine } from './collect-cloud-backup-diagnostics.mjs';

// Execute production ArkTS, including its receipt validation and diagnostic recorder.
// Only SDK/I/O boundaries are replaced; no staging/ownership rules live in the fake.
async function executable(name) {
  const source = await readFile(new URL(`../common/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''), { mode: 'transform' })
    .replace(/\bexport\s+/g, '');
}
const [stagingCode, storageCode, diagnosticCode] = await Promise.all([
  executable('CloudBackupStaging'), executable('StoragePorts'), executable('CloudBackupDiagnostics'),
]);
const ROOT = '/synthetic/SYNTH_PRIVATE_CLOUD';
const FILES = '/synthetic/SYNTH_LOCAL_FILES';
const SCOPE = 'a'.repeat(64);
const OTHER_SCOPE = 'b'.repeat(64);
const CONTENT = 'SYNTH_PRIVATE_CIPHERTEXT.header.payload';
const CONTEXT_SECRET = 'SYNTH_PRIVATE_ERROR_MESSAGE';
const FINAL = `${ROOT}/otp_backup_42.enc`;
const error = (code = 13900005) => Object.assign(new Error(CONTEXT_SECRET), { code });
const clone = value => structuredClone(value);
const parent = path => path.slice(0, path.lastIndexOf('/'));
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

class MemoryPort {
  nodes = new Map([[ROOT, { kind: 'directory' }], [FILES, { kind: 'directory' }]]);
  receipts = new Map();
  events = [];
  failures = new Map();
  directorySequence = 0;
  receiptSequence = 0;
  syncAccepted = true;
  writeStarted;
  suspendedWrite;
  returnedDirectory;
  returnedReceiptId;

  record(op, path, destination) {
    this.events.push({ op, path, destination });
    const configured = this.failures.get(op);
    const failure = typeof configured === 'function' ? configured(path) : configured;
    if (failure !== undefined) throw failure;
  }
  calls(op) { return this.events.filter(event => event.op === op); }
  put(path, kind = 'file', content = CONTENT) {
    this.nodes.set(path, kind === 'file' ? { kind, content } : { kind });
  }
  async createDirectory(prefix) {
    this.record('createDirectory', prefix);
    const directory = this.returnedDirectory ?? prefix.replace('XXXXXX', String(++this.directorySequence).padStart(6, '0'));
    if (this.nodes.has(directory)) throw error(13900015);
    this.put(directory, 'directory');
    return directory;
  }
  async inspect(path) {
    this.record('inspect', path);
    const node = this.nodes.get(path);
    return node === undefined ? undefined : {
      directory: node.kind === 'directory', regular: node.kind === 'file', symbolic: node.kind === 'symlink',
    };
  }
  async list(path) {
    this.record('list', path);
    if (this.nodes.get(path)?.kind !== 'directory') throw error(13900018);
    return [...this.nodes.keys()].filter(name => parent(name) === path).map(name => name.slice(path.length + 1));
  }
  async save(receipt) {
    this.record('save', receipt.stage);
    const id = this.returnedReceiptId ?? `receipt-${String(++this.receiptSequence).padStart(6, '0')}`;
    this.receipts.set(id, clone({ ...receipt, id }));
    return id;
  }
  async load() { this.record('load'); return [...this.receipts.values()].map(clone); }
  async forget(id) { this.record('forget', id); this.receipts.delete(id); }
  async write(path, content) {
    this.record('writeBegin', path);
    this.put(path, 'file', content.slice(0, 7));
    this.writeStarted?.resolve(path);
    // An abandoned unresolved write models process death without running catch/finally.
    if (this.suspendedWrite !== undefined) return this.suspendedWrite.promise;
    this.record('write', path);
    this.put(path, 'file', content);
  }
  async move(source, destination) {
    this.record('move', source, destination);
    if (this.nodes.has(destination)) throw error(13900015);
    if (!this.nodes.has(source)) throw error(13900002);
    this.nodes.set(destination, this.nodes.get(source));
    this.nodes.delete(source);
  }
  async unlink(path) {
    this.record('unlink', path);
    if (!this.nodes.has(path)) throw error(13900002);
    if (this.nodes.get(path).kind === 'directory') throw error(13900019);
    this.nodes.delete(path);
  }
  async removeDirectory(path) {
    this.record('removeDirectory', path);
    if (!this.nodes.has(path)) throw error(13900002);
    // Match SDK rmdir's destructive recursive semantics, not an empty-only fake.
    for (const name of [...this.nodes.keys()]) {
      if (name === path || name.startsWith(`${path}/`)) this.nodes.delete(name);
    }
  }
  async sync() { this.record('sync'); return this.syncAccepted; }
  restart() {
    const next = new MemoryPort();
    next.nodes = clone(this.nodes);
    next.receipts = clone(this.receipts);
    next.directorySequence = this.directorySequence;
    next.receiptSequence = this.receiptSequence;
    return next;
  }
}

export function setup(port = new MemoryPort(), native = false) {
  const lines = [];
  const diagnosticCalls = [];
  const diagnostics = runInNewContext(`${diagnosticCode}\n({CloudBackupDiagnosticRecorder, DiagnosticKind,
    DiagnosticStage, DiagnosticResult, DiagnosticReason, DiagnosticErrorDomain, DiagnosticMode});`, {
    process: { pid: 1, tid: 1 }, systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 0 },
    hilog: { info() {} },
  });
  const recorder = new diagnostics.CloudBackupDiagnosticRecorder(
    { write(line) { lines.push(line); } }, { now: () => 0 }, { isMainThread: () => true });
  recorder.enable();
  const sdk = {
    ...diagnostics,
    buffer: { from: (value, encoding) => Buffer.from(value, encoding) },
    CloudBackupDiagnostics: {
      mark(...args) { diagnosticCalls.push({ method: 'mark', args }); recorder.mark(...args); },
      fail(...args) { diagnosticCalls.push({ method: 'fail', args }); recorder.fail(...args); },
    },
    CloudBackupSyncService: { getInstance: () => ({ start: () => port.sync() }) },
  };
  if (native) sdk.fs = nativeFs(port);
  const storage = runInNewContext(`${storageCode}\n({FileIoFsGateway, fileIoDiagnosticCode});`, sdk);
  const api = runInNewContext(`${stagingCode}\n({CloudBackupStaging, NativeCloudBackupStagingPort, CLOUD_STAGE_JOURNAL});`,
    { ...sdk, ...storage });
  const io = native ? new api.NativeCloudBackupStagingPort(FILES) : port;
  const context = recorder.begin(diagnostics.DiagnosticKind.BACKUP);
  return { port, api, context, lines, diagnosticCalls, io, sdk: { ...sdk, ...storage },
    staging: new api.CloudBackupStaging(ROOT, SCOPE, io),
    newInstance: (root = ROOT, scope = SCOPE) => new api.CloudBackupStaging(root, scope, io) };
}

// Minimal native filesystem emulator for the real receipt save/fsync/close adapter.
function nativeFs(port) {
  const handles = new Map();
  let sequence = 0;
  function open(path, mode) {
    port.record('open', path);
    if (mode & 2) port.put(path, 'file', '');
    if (!port.nodes.has(path)) throw error(13900002);
    const fd = ++sequence;
    handles.set(fd, { path, offset: 0 });
    return { fd };
  }
  function write(fd, data) {
    const handle = handles.get(fd);
    port.record('nativeWrite', handle.path);
    const bytes = Buffer.from(new Uint8Array(data));
    const length = port.nativeWriteLength ?? bytes.length;
    if (Number.isInteger(length) && length > 0 && length <= bytes.length) {
      const previous = Buffer.from(port.nodes.get(handle.path).content);
      const next = Buffer.concat([previous.subarray(0, handle.offset), bytes.subarray(0, length)]);
      port.put(handle.path, 'file', next.toString('utf8'));
      handle.offset += length;
    }
    return length;
  }
  function close(file) {
    const fd = typeof file === 'number' ? file : file.fd;
    const path = handles.get(fd)?.path;
    handles.delete(fd);
    port.record('close', path);
  }
  return {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    async mkdir(path) { port.record('mkdir', path); port.put(path, 'directory'); },
    mkdtemp: prefix => port.createDirectory(prefix),
    async lstat(path) {
      const state = await port.inspect(path);
      if (state === undefined) throw error(13900002);
      return { isDirectory: () => state.directory, isFile: () => state.regular, isSymbolicLink: () => state.symbolic };
    },
    listFile: path => port.list(path),
    listFileSync: path => [...port.nodes.keys()].filter(name => parent(name) === path).map(name => name.slice(path.length + 1)),
    async stat(path) {
      const node = port.nodes.get(typeof path === 'number' ? handles.get(path).path : path);
      if (node === undefined) throw error(13900002);
      return { size: Buffer.byteLength(node.content ?? ''), location: 1, isDirectory: () => node.kind === 'directory' };
    },
    open: async (path, mode) => open(path, mode), openSync: open,
    write: async (fd, data) => write(fd, data), writeSync: write,
    async read(fd, data) {
      const handle = handles.get(fd);
      port.record('nativeRead', handle.path);
      const bytes = Buffer.from(port.nodes.get(handle.path).content).subarray(handle.offset, handle.offset + data.byteLength);
      new Uint8Array(data).set(bytes);
      handle.offset += bytes.length;
      return bytes.length;
    },
    async fsync(fd) { port.record('fsync', handles.get(fd).path); },
    close: async file => close(file), closeSync: close,
    async moveFile(source, destination, mode) { assert.equal(mode, 1); await port.move(source, destination); },
    unlink: path => port.unlink(path), rmdir: path => port.removeDirectory(path),
  };
}

function seed(port, overrides = {}, content = CONTENT) {
  const receipt = { id: 'receipt-654321', version: 1, scope: SCOPE, cloudRoot: ROOT,
    stage: '.cloud-backup-owned-654321', ...overrides };
  port.receipts.set(receipt.id, clone(receipt));
  const directory = `${receipt.cloudRoot}/${receipt.stage}`;
  port.put(directory, 'directory');
  if (content !== undefined) port.put(`${directory}/content.tmp`, 'file', content);
  return { receipt, directory, source: `${directory}/content.tmp` };
}
function noDestruction(port) {
  for (const op of ['unlink', 'removeDirectory', 'forget', 'move']) assert.equal(port.calls(op).length, 0, op);
}
function neverDeleted(port, path) {
  assert.equal(port.calls('unlink').some(call => call.path === path), false);
  assert.equal(port.calls('removeDirectory').some(call => path === call.path || path.startsWith(`${call.path}/`)), false);
}

test('create persists the exact receipt before writing; publish/discard/ack preserve the formal destination', async () => {
  const { port, staging, context } = setup();
  const source = await staging.create(CONTENT, context);
  const receipt = [...port.receipts.values()][0];
  assert.equal(source, `${ROOT}/${receipt.stage}/content.tmp`);
  assert.equal(port.nodes.get(source).content, CONTENT);
  assert.ok(port.events.findIndex(event => event.op === 'save') < port.events.findIndex(event => event.op === 'writeBegin'));
  await staging.acknowledgeSync(context);
  assert.equal(port.receipts.size, 1, 'ack cannot forget an active, uncleaned stage');
  await staging.publish(source, FINAL, context);
  assert.equal(port.nodes.has(source), false);
  assert.equal(port.nodes.get(FINAL).content, CONTENT);
  assert.equal(await staging.discard(source, context), true);
  assert.equal(port.nodes.has(parent(source)), false);
  assert.equal(port.receipts.size, 1, 'cleanup alone does not acknowledge cloud sync');
  assert.equal(await port.sync(), true);
  await staging.acknowledgeSync(context);
  await staging.acknowledgeSync(context);
  assert.equal(port.receipts.size, 0);
  assert.equal(port.calls('forget').length, 1);
  assert.equal(await staging.discard(source, context), false);
  neverDeleted(port, FINAL);
});

test('discard removes only its registered ciphertext and recovery syncs before forgetting', async () => {
  const { port, staging, context } = setup();
  const source = await staging.create(CONTENT, context);
  assert.equal(await staging.discard(`${ROOT}/unowned.tmp`, context), false);
  assert.equal(await staging.discard(source, context), true);
  assert.equal(port.receipts.size, 1);
  assert.equal(await staging.recover(context), true);
  assert.equal(port.receipts.size, 0);
  assert.ok(port.events.findIndex(event => event.op === 'sync') < port.events.findIndex(event => event.op === 'forget'));
  assert.deepEqual(port.calls('unlink').map(call => call.path), [source]);
});

test('receipt save failure leaves at most an unregistered empty directory and never writes ciphertext', async () => {
  const { port, staging, context, newInstance } = setup();
  port.failures.set('save', error());
  await assert.rejects(staging.create(CONTENT, context));
  assert.equal(port.calls('writeBegin').length, 0);
  assert.equal(port.receipts.size, 0);
  const directories = [...port.nodes.keys()];
  port.failures.clear();
  assert.equal(await newInstance().recover(context), true);
  assert.deepEqual([...port.nodes.keys()], directories);
  noDestruction(port);
});

test('actual native receipt save must finish fsync and close before opening cloud content', async () => {
  const { port, staging, context, io } = setup(new MemoryPort(), true);
  const source = await staging.create(CONTENT, context);
  const saved = await io.load();
  assert.equal(saved.length, 1);
  assert.equal(saved[0].stage, parent(source).slice(ROOT.length + 1));
  const savedPath = `${FILES}/.cloud-backup-journal/${saved[0].id}/receipt.json`;
  const flushed = port.events.findIndex(event => event.op === 'fsync' && event.path === savedPath);
  const closed = port.events.findIndex(event => event.op === 'close' && event.path === savedPath);
  const opened = port.events.findIndex(event => event.op === 'open' && event.path === source);
  assert.ok(flushed >= 0 && flushed < closed && closed < opened);
  assert.equal(port.nodes.get(source).content, CONTENT);
  await staging.publish(source, FINAL, context);
  assert.equal(await staging.discard(source, context), true);
  assert.equal((await io.load()).length, 1);
  await port.sync();
  await staging.acknowledgeSync(context);
  assert.equal((await io.load()).length, 0);
  neverDeleted(port, FINAL);
});

for (const boundary of ['open', 'nativeWrite', 'fsync', 'close']) {
  test(`actual receipt ${boundary} failure never opens or writes cloud content`, async () => {
    const { port, staging, context } = setup(new MemoryPort(), true);
    port.failures.set(boundary, path => path.endsWith('/receipt.json') ? error() : undefined);
    await assert.rejects(staging.create(CONTENT, context));
    assert.equal(port.calls('open').some(call => call.path.endsWith('/content.tmp')), false);
    assert.equal([...port.nodes.values()].some(node => node.content?.includes(CONTENT)), false);
    assert.equal(port.calls('move').length, 0);
    assert.equal(port.calls('close').length, boundary === 'open' ? 0 : 1);
    assert.equal((await port.list(`${FILES}/.cloud-backup-journal`)).length, 0);
    assert.ok(port.calls('removeDirectory').every(call => call.path.startsWith(`${FILES}/.cloud-backup-journal/`)));
  });
}

test('repeated receipt write failures cannot exhaust registration after the fault is removed', async () => {
  const { port, staging, context, io } = setup(new MemoryPort(), true);
  port.failures.set('nativeWrite', path => path.endsWith('/receipt.json') ? error() : undefined);
  for (let index = 0; index < 130; index++) {
    await assert.rejects(staging.create(CONTENT, context));
  }
  assert.equal((await port.list(`${FILES}/.cloud-backup-journal`)).length, 0);
  assert.equal(port.calls('open').some(call => call.path.endsWith('/content.tmp')), false);
  port.failures.clear();
  const source = await staging.create(CONTENT, context);
  assert.equal(port.nodes.get(source).content, CONTENT);
  assert.equal((await io.load()).length, 1);
});

test('failed local cleanup stays outside active receipt quota and is retried safely', async () => {
  const { port, staging, context, io } = setup(new MemoryPort(), true);
  port.failures.set('nativeWrite', path => path.endsWith('/receipt.json') ? error() : undefined);
  port.failures.set('removeDirectory', error());
  for (let index = 0; index < 130; index++) await assert.rejects(staging.create(CONTENT, context));
  assert.equal((await port.list(`${FILES}/.cloud-backup-journal`)).length, 130);
  port.failures.clear();
  const source = await staging.create(CONTENT, context);
  assert.equal(port.nodes.get(source).content, CONTENT);
  assert.equal((await io.load()).length, 1);
  assert.equal((await port.list(`${FILES}/.cloud-backup-journal`)).length, 1);
  assert.equal(port.calls('unlink').length, 0);
});

test('actual receipt invalid short-write progress fails closed before ciphertext creation', async () => {
  for (const length of [0, -1, 0.5, NaN, Infinity, 999999]) {
    const { port, staging, context } = setup(new MemoryPort(), true);
    port.nativeWriteLength = length;
    await assert.rejects(staging.create(CONTENT, context));
    assert.equal(port.calls('fsync').length, 0);
    assert.equal(port.calls('close').length, 1);
    assert.equal(port.calls('open').some(call => call.path.endsWith('/content.tmp')), false);
  }
});

test('a process dying mid-write is recovered by a new instance, while the active instance does not reap it', async () => {
  const { port, staging, context } = setup();
  port.writeStarted = deferred();
  port.suspendedWrite = deferred();
  const abandoned = staging.create(CONTENT, context);
  void abandoned.catch(() => {});
  const source = await port.writeStarted.promise;
  assert.equal(port.nodes.get(source).content, CONTENT.slice(0, 7));
  assert.equal(port.receipts.size, 1);
  assert.equal(await staging.recover(context), true);
  noDestruction(port);
  const restarted = setup(port.restart());
  assert.equal(await restarted.staging.recover(restarted.context), true);
  assert.equal(restarted.port.nodes.has(source), false);
  assert.equal(restarted.port.receipts.size, 0);
  assert.equal(restarted.port.calls('sync').length, 1);
});

test('write rejection with failed immediate cleanup retains durable evidence for restart recovery', async () => {
  const { port, staging, context } = setup();
  port.failures.set('write', error());
  port.failures.set('unlink', error());
  await assert.rejects(staging.create(CONTENT, context));
  assert.equal(port.receipts.size, 1);
  const source = port.calls('writeBegin')[0].path;
  assert.equal(port.nodes.has(source), true);
  const next = setup(port.restart());
  assert.equal(await next.staging.recover(next.context), true);
  assert.equal(next.port.nodes.has(source), false);
  assert.equal(next.port.receipts.size, 0);
});

test('crash after publication preserves the formal backup and recovery removes only the empty stage', async () => {
  const { port, staging, context } = setup();
  const source = await staging.create(CONTENT, context);
  await staging.publish(source, FINAL, context);
  const next = setup(port.restart());
  assert.equal(await next.staging.recover(next.context), true);
  assert.equal(next.port.nodes.get(FINAL).content, CONTENT);
  assert.equal(next.port.nodes.has(parent(source)), false);
  assert.equal(next.port.receipts.size, 0);
  neverDeleted(next.port, FINAL);
});

test('no-replace publication collision preserves both the foreign final and our recoverable receipt', async () => {
  const { port, staging, context, newInstance } = setup();
  port.put(FINAL, 'file', 'SYNTH_FOREIGN_BACKUP');
  const source = await staging.create(CONTENT, context);
  await assert.rejects(staging.publish(source, FINAL, context));
  assert.equal(port.nodes.get(FINAL).content, 'SYNTH_FOREIGN_BACKUP');
  assert.equal(port.nodes.get(source).content, CONTENT);
  assert.equal(port.receipts.size, 1);
  assert.equal(await staging.discard(source, context), true);
  assert.equal(await newInstance().recover(context), true);
  assert.equal(port.nodes.get(FINAL).content, 'SYNTH_FOREIGN_BACKUP');
  neverDeleted(port, FINAL);
});

test('recovery filters exact account scope and cloud root without touching skipped receipts', async () => {
  const { port, staging, context } = setup();
  const own = seed(port);
  const account = seed(port, { id: 'receipt-111111', stage: '.cloud-backup-owned-111111', scope: OTHER_SCOPE });
  const root = seed(port, { id: 'receipt-222222', stage: '.cloud-backup-owned-222222', cloudRoot: '/synthetic/other-cloud' });
  assert.equal(await staging.recover(context), true);
  assert.equal(port.nodes.has(own.source), false);
  for (const skipped of [account, root]) {
    assert.equal(port.nodes.get(skipped.source).content, CONTENT);
    assert.equal(port.receipts.has(skipped.receipt.id), true);
    assert.equal(port.calls('inspect').some(call => call.path === skipped.directory), false);
  }
  assert.deepEqual(port.calls('forget').map(call => call.path), [own.receipt.id]);
});

for (const change of ['unknown-child', 'unknown-directory', 'stage-symlink', 'content-symlink', 'stage-file', 'content-directory']) {
  test(`${change} blocks cleanup and acknowledgement without forgetting ownership evidence`, async () => {
    const { port, staging, context } = setup();
    const owned = seed(port);
    if (change === 'unknown-child') port.put(`${owned.directory}/foreign.txt`);
    if (change === 'unknown-directory') port.put(`${owned.directory}/foreign`, 'directory');
    if (change === 'stage-symlink') port.put(owned.directory, 'symlink');
    if (change === 'content-symlink') port.put(owned.source, 'symlink');
    if (change === 'stage-file') port.put(owned.directory, 'file');
    if (change === 'content-directory') port.put(owned.source, 'directory');
    const before = clone(port.nodes);
    assert.equal(await staging.recover(context), false);
    await staging.acknowledgeSync(context);
    assert.deepEqual(port.nodes, before);
    assert.equal(port.receipts.size, 1);
    noDestruction(port);
    assert.equal(port.calls('sync').length, 0);
  });
}

for (const boundary of ['inspect', 'list', 'unlink', 'removeDirectory']) {
  test(`${boundary} failure retains the receipt, retries cleanup, then syncs and forgets`, async () => {
    const { port, staging, context } = setup();
    const owned = seed(port);
    port.failures.set(boundary, error());
    assert.equal(await staging.recover(context), false);
    await staging.acknowledgeSync(context);
    assert.equal(port.receipts.size, 1);
    assert.equal(port.calls('forget').length, 0);
    assert.equal(port.calls('sync').length, 0);
    port.failures.clear();
    assert.equal(await staging.recover(context), true);
    assert.equal(port.nodes.has(owned.directory), false);
    assert.equal(port.receipts.size, 0);
    assert.equal(port.calls('sync').length, 1);
  });
}

for (const rejected of [false, true]) {
  test(`sync ${rejected ? 'rejection' : 'non-acceptance'} retains a cleaned receipt across restart`, async () => {
    const { port, staging, context } = setup();
    const owned = seed(port);
    if (rejected) port.failures.set('sync', error());
    else port.syncAccepted = false;
    assert.equal(await staging.recover(context), false);
    assert.equal(port.nodes.has(owned.directory), false);
    assert.equal(port.receipts.size, 1);
    assert.equal(port.calls('forget').length, 0);
    const next = setup(port.restart());
    assert.equal(await next.staging.recover(next.context), true);
    assert.equal(next.port.receipts.size, 0);
    assert.equal(next.port.calls('sync').length, 1);
    assert.equal(next.port.calls('unlink').length, 0);
  });
}

test('forget failure retains evidence and can be retried without deleting any formal file', async () => {
  const { port, staging, context } = setup();
  seed(port);
  port.put(FINAL);
  port.failures.set('forget', error());
  await staging.recover(context);
  assert.equal(port.receipts.size, 1);
  assert.equal(port.calls('sync').length, 1);
  port.failures.clear();
  assert.equal(await staging.recover(context), true);
  assert.equal(port.receipts.size, 0);
  assert.equal(port.calls('forget').length, 2);
  neverDeleted(port, FINAL);
});

test('a previously cleaned stage that reappears with unknown content cannot be acknowledged away', async () => {
  const { port, staging, context } = setup();
  const owned = seed(port);
  port.syncAccepted = false;
  assert.equal(await staging.recover(context), false);
  port.put(owned.directory, 'directory');
  port.put(`${owned.directory}/foreign.txt`, 'file', 'SYNTH_FOREIGN_CONTENT');
  port.syncAccepted = true;
  assert.equal(await staging.recover(context), false);
  assert.equal(port.receipts.size, 1, 'failed revalidation must invalidate an earlier cleaned candidate');
  assert.equal(port.calls('forget').length, 0);
  assert.equal(port.nodes.get(`${owned.directory}/foreign.txt`).content, 'SYNTH_FOREIGN_CONTENT');
});

test('legacy pending/stage and unregistered owned-looking names are never scanned or deleted', async () => {
  const { port, staging, context } = setup();
  port.put(`${ROOT}/.otp_backup_pending_42.tmp`);
  port.put(`${ROOT}/.cloud-backup-stage-ABC123`, 'directory');
  port.put(`${ROOT}/.cloud-backup-stage-ABC123/content.tmp`);
  port.put(`${ROOT}/.cloud-backup-owned-ABC123`, 'directory');
  port.put(`${ROOT}/.cloud-backup-owned-ABC123/content.tmp`);
  port.put(FINAL);
  const before = clone(port.nodes);
  assert.equal(await staging.recover(context), true);
  assert.deepEqual(port.nodes, before);
  assert.deepEqual(port.events.map(event => event.op), ['load']);
});

test('invalid receipts fail closed before inspecting or deleting any cloud path', async () => {
  const valid = { id: 'receipt-000001', version: 1, scope: SCOPE, cloudRoot: ROOT, stage: '.cloud-backup-owned-000001' };
  const invalid = [null, {}, 'foreign', { ...valid, version: 2 }, { ...valid, id: '../receipt-000001' },
    { ...valid, scope: 'not-an-account-scope' }, { ...valid, cloudRoot: `${ROOT}/../elsewhere` },
    { ...valid, stage: '../otp_backup_42.enc' }, { ...valid, stage: FINAL },
    { ...valid, stage: '.cloud-backup-owned-000001/nested' }, { ...valid, stage: 'otp_backup_42.enc' }];
  for (const receipt of invalid) {
    const { port, staging, context } = setup();
    port.receipts.set('fixture', receipt);
    port.put(FINAL);
    assert.equal(await staging.recover(context), false);
    assert.equal(port.calls('inspect').length, 0);
    assert.equal(port.calls('sync').length, 0);
    assert.equal(port.receipts.size, 1);
    noDestruction(port);
  }
});

test('receipt identifiers and stage names reject trailing newline rather than matching a prefix', async () => {
  for (const field of ['id', 'scope', 'stage']) {
    const { port, staging, context } = setup();
    const owned = seed(port);
    port.receipts.set(owned.receipt.id, { ...owned.receipt, [field]: `${owned.receipt[field]}\n` });
    assert.equal(await staging.recover(context), false, field);
    assert.equal(port.calls('inspect').length, 0, field);
    assert.equal(port.calls('forget').length, 0, field);
  }
});

test('invalid constructor, returned stage, receipt id and load intent never allow a content write', async () => {
  const rig = setup();
  for (const root of ['', '/', 'relative/cloud', `${ROOT}/`, `${ROOT}//child`, `${ROOT}/../child`, `${ROOT}/./child`, `${ROOT}\\child`, `${ROOT}\0`]) {
    assert.throws(() => rig.newInstance(root));
  }
  for (const scope of ['', 'x'.repeat(64), 'a'.repeat(63)]) assert.throws(() => rig.newInstance(ROOT, scope));
  for (const directory of ['/outside/.cloud-backup-owned-000001', `${ROOT}/../.cloud-backup-owned-000001`,
    `${ROOT}/.cloud-backup-owned-000001/nested`, `${ROOT}/otp_backup_42.enc`]) {
    const { port, staging, context } = setup();
    port.returnedDirectory = directory;
    await assert.rejects(staging.create(CONTENT, context));
    assert.equal(port.calls('save').length, 0);
    assert.equal(port.calls('writeBegin').length, 0);
    noDestruction(port);
  }
  for (const id of ['../receipt-000001', '', 'receipt-000001/child']) {
    const { port, staging, context } = setup();
    port.returnedReceiptId = id;
    await assert.rejects(staging.create(CONTENT, context));
    assert.equal(port.calls('writeBegin').length, 0);
    noDestruction(port);
  }
  const { port, staging, context } = setup();
  port.failures.set('load', error());
  await assert.rejects(staging.create(CONTENT, context));
  assert.equal(port.calls('createDirectory').length, 0);
  assert.equal(port.calls('writeBegin').length, 0);
});

test('directory creation rejection cannot claim or remove an existing foreign stage', async () => {
  const { port, staging, context } = setup();
  const directory = `${ROOT}/.cloud-backup-owned-000001`;
  port.put(directory, 'directory');
  port.put(`${directory}/content.tmp`, 'file', 'SYNTH_FOREIGN_CONTENT');
  await assert.rejects(staging.create(CONTENT, context));
  assert.equal(port.nodes.get(`${directory}/content.tmp`).content, 'SYNTH_FOREIGN_CONTENT');
  assert.equal(port.calls('save').length, 0);
  assert.equal(port.calls('writeBegin').length, 0);
  noDestruction(port);
});

test('publication rejects unowned sources, traversal, unsafe timestamps and changed content without a move', async () => {
  const { port, staging, context } = setup();
  const source = await staging.create(CONTENT, context);
  for (const destination of ['/outside/otp_backup_42.enc', `${ROOT}/../otp_backup_42.enc`,
    `${ROOT}//otp_backup_42.enc`, `${ROOT}/otp_backup_42.enc\n`, `${ROOT}/otp_backup_9007199254740992.enc`,
    `${ROOT}/otp_backup_42.enc/child`, source]) {
    await assert.rejects(staging.publish(source, destination, context));
  }
  await assert.rejects(staging.publish(`${ROOT}/unregistered.tmp`, FINAL, context));
  for (const kind of ['symlink', 'directory']) {
    port.put(source, kind);
    await assert.rejects(staging.publish(source, FINAL, context));
  }
  port.nodes.delete(source);
  await assert.rejects(staging.publish(source, FINAL, context));
  assert.equal(port.calls('move').length, 0);
  assert.equal(port.calls('forget').length, 0);
});

test('native loading skips incomplete local receipts without inferring cloud ownership', async () => {
  const { port, staging, context } = setup(new MemoryPort(), true);
  const journal = `${FILES}/.cloud-backup-journal`;
  port.put(journal, 'directory');
  port.put(`${journal}/receipt-000001`, 'directory');
  port.put(`${journal}/receipt-000002`, 'directory');
  port.put(`${journal}/receipt-000002/receipt.json`, 'file', '{"incomplete":');
  port.put(`${ROOT}/.cloud-backup-owned-000001`, 'directory');
  port.put(`${ROOT}/.cloud-backup-owned-000001/content.tmp`);
  assert.equal(await staging.recover(context), true);
  assert.equal((await port.list(journal)).length, 0);
  assert.equal(port.calls('unlink').length, 0);
  assert.equal(port.calls('move').length, 0);
  assert.ok(port.calls('removeDirectory').every(call => call.path.startsWith(`${journal}/`)));
  assert.equal(port.calls('inspect').some(call => call.path.startsWith(`${ROOT}/`)), false);
});

test('malformed local entries do not block valid recovery or grant cloud deletion ownership', async () => {
  const { port, staging, context, io } = setup(new MemoryPort(), true);
  const journal = `${FILES}/.cloud-backup-journal`;
  port.put(journal, 'directory');
  const owned = seed(port);
  const ownedLocal = `${journal}/${owned.receipt.id}`;
  port.put(ownedLocal, 'directory');
  port.put(`${ownedLocal}/receipt.json`, 'file', JSON.stringify(owned.receipt));
  port.put(FINAL, 'file', 'SYNTH_EXISTING_FORMAL');
  const foreign = `${ROOT}/.cloud-backup-owned-foreign`;
  port.put(foreign, 'directory');
  port.put(`${foreign}/content.tmp`, 'file', 'SYNTH_FOREIGN');
  for (let index = 0; index < 130; index++) {
    const directory = `${journal}/receipt-${String(index).padStart(6, '0')}`;
    port.put(directory, 'directory');
    const corrupt = ['{}', '{', JSON.stringify({ ...owned.receipt, stage: '../otp_backup_42.enc' }),
      JSON.stringify({ ...owned.receipt, version: 99 }), '[]'][index % 5];
    port.put(`${directory}/receipt.json`, 'file', corrupt);
  }
  const unknown = `${journal}/receipt-999998`;
  const symbolic = `${journal}/receipt-999999`;
  port.put(unknown, 'directory');
  port.put(`${unknown}/other-data`, 'file', 'SYNTH_UNEXPECTED');
  port.put(symbolic, 'symlink');
  assert.equal(await staging.recover(context), true);
  assert.equal(port.nodes.has(owned.source), false);
  assert.equal(port.nodes.has(ownedLocal), false);
  assert.equal(port.nodes.get(FINAL).content, 'SYNTH_EXISTING_FORMAL');
  assert.equal(port.nodes.get(`${foreign}/content.tmp`).content, 'SYNTH_FOREIGN');
  assert.equal(port.nodes.get(`${unknown}/other-data`).content, 'SYNTH_UNEXPECTED');
  assert.equal(port.nodes.get(symbolic).kind, 'symlink');
  assert.equal((await io.load()).length, 0);
  port.directorySequence = 130;
  const source = await staging.create(CONTENT, context);
  assert.equal(port.nodes.get(source).content, CONTENT);
  assert.deepEqual(port.calls('unlink').map(call => call.path), [owned.source]);
  neverDeleted(port, FINAL);
  neverDeleted(port, foreign);
});

test('temporary receipt read failure preserves ownership and cannot be mistaken for malformed JSON', async () => {
  const { port, staging, context, io } = setup(new MemoryPort(), true);
  const source = await staging.create(CONTENT, context);
  port.failures.set('nativeRead', error());
  await assert.rejects(io.load());
  assert.equal(port.calls('removeDirectory').length, 0);
  assert.equal(port.calls('unlink').length, 0);
  port.failures.clear();
  assert.equal((await io.load()).length, 1);
  assert.equal(port.nodes.get(source).content, CONTENT);
});

test('active valid receipts still enforce the registration capacity without deleting any ownership evidence', async () => {
  const { port, io } = setup(new MemoryPort(), true);
  const journal = `${FILES}/.cloud-backup-journal`;
  port.put(journal, 'directory');
  const receipt = { id: 'receipt-654321', version: 1, scope: SCOPE, cloudRoot: ROOT,
    stage: '.cloud-backup-owned-654321' };
  for (let index = 0; index < 128; index++) {
    const id = `receipt-${String(index).padStart(6, '0')}`;
    const directory = `${journal}/${id}`;
    port.put(directory, 'directory');
    port.put(`${directory}/receipt.json`, 'file', JSON.stringify({ ...receipt, id }));
  }
  assert.equal((await io.load()).length, 128);
  await assert.rejects(io.save(receipt), /STAGING_RECEIPT_LIMIT/);
  assert.equal((await io.load()).length, 128);
  noDestruction(port);
});

test('staging diagnostic calls and serialized output contain only fixed stages and numeric codes, never private input', async () => {
  const { port, staging, context, diagnosticCalls, lines } = setup();
  let unsafeReads = 0;
  const hostile = {
    get code() { return 13900025; },
    get message() { unsafeReads++; return CONTEXT_SECRET; },
    get stack() { unsafeReads++; return CONTENT; },
    toString() { unsafeReads++; return ROOT; },
    toJSON() { unsafeReads++; return SCOPE; },
  };
  port.failures.set('save', hostile);
  await assert.rejects(staging.create(CONTENT, context), failure => failure === hostile);
  port.failures.clear();
  const source = await staging.create(CONTENT, context);
  port.failures.set('move', hostile);
  await assert.rejects(staging.publish(source, FINAL, context), failure => failure === hostile);
  port.failures.set('unlink', hostile);
  assert.equal(await staging.discard(source, context), false);
  assert.equal(unsafeReads, 0);
  for (const call of diagnosticCalls) {
    assert.ok(['FS_STAGE', 'PUBLISH_END', 'TEMP_CLEANUP'].includes(call.args[1]));
    assert.equal(call.args[0], context);
    if (call.method === 'fail') {
      assert.equal(call.args.length, 4);
      assert.equal(call.args[2], 'FS');
      assert.equal(call.args[3], 13900025);
    } else {
      assert.equal(call.args.length, 3);
      assert.ok(['BEGIN', 'OK'].includes(call.args[2]));
    }
  }
  assert.ok(lines.length > 0);
  for (const line of lines) assert.ok(parseDiagnosticLine(`CloudBackupDiag: ${line}`), line);
  const emitted = JSON.stringify({ diagnosticCalls, lines });
  for (const privateValue of [ROOT, FILES, SCOPE, CONTENT, CONTEXT_SECRET, source, FINAL]) {
    assert.equal(emitted.includes(privateValue), false);
  }
});

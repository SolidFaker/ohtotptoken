import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

const root = new URL('../common/src/main/ets/utils/', import.meta.url);
async function transpile(name) {
  const source = await readFile(new URL(name, root), 'utf8');
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, '').replace(/^@Concurrent\r?\n/gm, ''),
    { mode: 'transform' }).replace(/\bexport\s+/g, '');
}
const taskSource = await transpile('CloudSyncTask.ets');
const metadataSource = await transpile('CloudBackupMetadata.ets');
const storageSource = await transpile('StoragePorts.ets');
const diagnosticsSource = await transpile('CloudBackupDiagnostics.ets');
const header = {
  version: 2, mode: 1, salt: Buffer.alloc(16, 1).toString('base64'), iv: Buffer.alloc(16, 2).toString('base64'),
  tokenCount: 1, size: 10, timestamp: 1745385600000, deviceId: 'synthetic-id', deviceName: 'Synthetic',
};
const encoded = Buffer.from(JSON.stringify(header)).toString('base64');
const valid = `${encoded}.cGF5bG9hZA==.signature`;

function setup(contents, location = 3, behavior = {}) {
  let opens = 0;
  let reads = 0;
  let closes = 0;
  let position = 0;
  const offsets = [];
  const bytes = Buffer.from(contents);
  const sdk = {
    CloudBackupMetadataStatus: { VALID: 'VALID', PENDING: 'PENDING', READ_FAILED: 'READ_FAILED', INVALID: 'INVALID' },
    CloudBackupIdentityStatus: { COMPLETE: 'COMPLETE', NAME_MISSING: 'NAME_MISSING', ID_MISSING: 'ID_MISSING' },
    CloudBackupCryptoMode: { NONE: 0, HUAWEI_ACCOUNT: 1 },
    DiagnosticStage: { READ_END: 'READ_END', HEADER_PARSE: 'HEADER_PARSE', HISTORY_END: 'HISTORY_END' },
    DiagnosticResult: { FAIL: 'FAIL' }, DiagnosticReason: { IO_ERROR: 'IO_ERROR', INVALID_FORMAT: 'INVALID_FORMAT' },
    appendDiagnosticSummary: (events, stage, result, details) => { if (events.length < 2) events.push({ stage, result, details }); },
    parseBackupTimestamp: name => Number(name.slice('otp_backup_'.length, -4)),
    formatRecordDate: () => 'Synthetic date', buffer: Buffer,
    util: { Base64Helper: class { decodeSync(value) {
      if (behavior.decodeThrows) throw new Error('SYNTHETIC_PRIVATE_DECODE');
      if (behavior.decodeEmpty) return new Uint8Array();
      return new Uint8Array(Buffer.from(value, 'base64'));
    } } },
    fs: {
      OpenMode: { READ_ONLY: 0 },
      listFileSync: () => ['otp_backup_1745385600000.enc'],
      // Residency is independent of native read success, including a location2 stat that stays unchanged.
      stat: async () => ({ size: bytes.length, location }),
      openSync: () => { opens++; position = 0; return { fd: 1 }; },
      readSync: (_fd, target, options = {}) => {
        reads++;
        if (behavior.readError) throw behavior.readError;
        if (behavior.readThrows) throw new Error('SYNTHETIC_PRIVATE_PATH');
        const offset = options.offset ?? position;
        offsets.push(offset);
        const length = Math.max(0, Math.min(bytes.length - offset, target.byteLength,
          options.length ?? target.byteLength, behavior.chunkSize ?? Infinity,
          (behavior.zeroAfter ?? Infinity) - offset));
        new Uint8Array(target).set(bytes.subarray(offset, offset + length));
        position = offset + length;
        return length;
      },
      closeSync: () => {
        closes++;
        if (behavior.closeThrows) throw new Error('SYNTHETIC_PRIVATE_CLOSE');
      },
    },
  };
  const api = runInNewContext(`${diagnosticsSource}\n${storageSource}\n${metadataSource}\n${taskSource}\n({loadBackupHistoryRecords});`, {
    ...sdk, process: { pid: 1, tid: 1 }, systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 0 },
    hilog: { info: () => {} },
  });
  return { run: (readBlocked = false) => api.loadBackupHistoryRecords('/synthetic/cloud', readBlocked),
    opens: () => opens, reads: () => reads, closes: () => closes, offsets: () => offsets };
}

function assertUnknown(record, status) {
  assert.equal(record.metadataStatus, status);
  assert.equal(record.tokenCountKnown, false);
  assert.equal(record.identityStatus, 'ID_MISSING');
  assert.equal(record.deviceId, '');
  assert.equal(record.deviceName, '');
}

function assertValid(record, location) {
  assert.equal(record.metadataStatus, 'VALID');
  assert.equal(record.tokenCountKnown, true);
  assert.equal(record.tokenCount, 1);
  assert.equal(record.deviceId, 'synthetic-id');
  assert.equal(record.deviceName, 'Synthetic');
  assert.equal(record.identityStatus, 'COMPLETE');
  assert.equal(record.location, location);
}

test('production TaskPool parser rejects empty payload or signature consistently', async () => {
  for (const content of [`${encoded}..`, `${encoded}.payload.`, `${encoded}..signature`]) {
    const fixture = setup(content);
    const result = await fixture.run();
    assertUnknown(result.records[0], 'INVALID');
    assert.equal(fixture.closes(), 1);
  }
});

test('native Base64 failure keeps readable backups retryable rather than invalid', async () => {
  for (const fault of ['decodeThrows', 'decodeEmpty']) {
    for (const location of [0, 1, 2, 3]) {
      const behavior = { [fault]: true };
      const fixture = setup(valid, location, behavior);
      const failed = await fixture.run();
      assertUnknown(failed.records[0], 'READ_FAILED');
      assert.equal(fixture.closes(), 1);
      assert.equal(failed.diagnostics[0].stage, 'HEADER_PARSE');
      assert.equal(failed.diagnostics[0].details.reason, 'DECRYPT_FAILED');
      assert.equal(JSON.stringify(failed.diagnostics).includes('SYNTHETIC_PRIVATE_DECODE'), false);
      behavior[fault] = false;
      assertValid((await fixture.run()).records[0], location);
    }
  }
});

test('invalid Base64 is format failure before unavailable native decoding', async () => {
  for (const encodedHeader of ['*invalid*', `${encoded}\n`, 'a===', 'abc']) {
    for (const location of [1, 2, 3]) {
      const fixture = setup(`${encodedHeader}.payload.signature`, location, { decodeThrows: true });
      const result = await fixture.run();
      assertUnknown(result.records[0], location === 2 ? 'PENDING' : 'INVALID');
      assert.equal(result.diagnostics[0].details.reason, 'INVALID_FORMAT');
    }
  }
});

test('native read of location2 restores metadata without rewriting residency', async () => {
  const fixture = setup(valid, 2);
  const result = await fixture.run();
  assert.equal(result.records.length, 1);
  assertValid(result.records[0], 2);
  assert.equal(fixture.opens(), 1);
  assert.equal(fixture.reads(), 1);
  assert.equal(fixture.closes(), 1);
});

test('safe read admission does not treat a previous cache failure as a stale per-file block', async () => {
  // Only outstanding native work blocks this API. A terminal cache error is represented by false,
  // not the old failed-prefetch filename list; fresh stat=3 and actual bytes remain authoritative.
  const fixture = setup(valid, 3);
  const result = await fixture.run(false);
  assertValid(result.records[0], 3);
  assert.equal(fixture.reads(), 1);
  assert.equal(fixture.closes(), 1);
});

test('unconfirmed cache work blocks opens and reads even for otherwise readable local bytes', async () => {
  for (const location of [0, 1, 2, 3]) {
    const fixture = setup(valid, location);
    const result = await fixture.run(true);
    assertUnknown(result.records[0], 'PENDING');
    assert.equal(fixture.opens(), 0);
    assert.equal(fixture.reads(), 0);
    assert.equal(fixture.closes(), 0);
  }
});

test('empty or malformed cloud-only bytes remain pending rather than confirmed corruption', async () => {
  for (const contents of ['', 'invalid-header']) {
    const fixture = setup(contents, 2);
    const result = await fixture.run();
    assertUnknown(result.records[0], 'PENDING');
    assert.equal(fixture.opens(), 1);
    if (contents.length > 0) assert.equal(fixture.reads(), 1);
    assert.equal(fixture.closes(), 1);
  }
});

test('unknown residency cannot turn an empty or malformed read into confirmed corruption', async () => {
  for (const contents of ['', 'invalid-header']) {
    assertUnknown((await setup(contents, 0).run()).records[0], 'READ_FAILED');
  }
});

test('known local empty or malformed content is invalid, but valid bytes expose known metadata', async () => {
  for (const location of [1, 3]) {
    for (const contents of ['', 'invalid-header']) {
      assertUnknown((await setup(contents, location).run()).records[0], 'INVALID');
    }
  }
  assertValid((await setup(valid).run()).records[0], 3);
});

test('actual read failure including location2 closes the descriptor without inventing metadata', async () => {
  for (const location of [2, 3]) {
    const fixture = setup(valid, location, { readThrows: true });
    const result = await fixture.run();
    assert.equal(fixture.reads(), 1);
    assert.equal(fixture.closes(), 1);
    assertUnknown(result.records[0], 'READ_FAILED');
    assert.equal(JSON.stringify(result.diagnostics).includes('SYNTHETIC_PRIVATE_PATH'), false);
  }
});

test('TaskPool carries only whitelisted numeric read errors without raw exception fields', async () => {
  let privateReads = 0;
  const error = { code: 13900005,
    get message() { privateReads++; return 'PRIVATE_HISTORY_MESSAGE'; },
    get stack() { privateReads++; return 'PRIVATE_HISTORY_STACK'; },
    toString() { privateReads++; return 'PRIVATE_HISTORY_STRING'; } };
  const result = await setup(valid, 2, { readError: error }).run();
  const event = result.diagnostics.find(item => item.stage === 'READ_END');
  assert.equal(event.details.errorDomain, 'FS');
  assert.equal(event.details.code, 13900005);
  assert.equal(privateReads, 0);
  assert.equal(JSON.stringify(result.diagnostics).includes('PRIVATE_'), false);
  const unknown = await setup(valid, 2, { readError: { code: 987654321 } }).run();
  assert.equal(unknown.diagnostics[0].details.code, 'UNKNOWN');
  assert.equal(JSON.stringify(unknown.diagnostics).includes('987654321'), false);
});

test('partial native reads assemble the entire file using advancing file offsets', async () => {
  const chunkSize = 7;
  const fixture = setup(valid, 2, { chunkSize });
  const result = await fixture.run();
  assertValid(result.records[0], 2);
  const expectedOffsets = Array.from({ length: Math.ceil(Buffer.byteLength(valid) / chunkSize) },
    (_, index) => index * chunkSize);
  assert.deepEqual(fixture.offsets(), expectedOffsets);
  assert.equal(fixture.reads(), expectedOffsets.length);
  assert.equal(fixture.closes(), 1);
});

test('zero-progress short read fails safely and closes without parsing a truncated prefix', async () => {
  const fixture = setup(valid, 2, { chunkSize: 7, zeroAfter: 7 });
  const result = await fixture.run();
  assertUnknown(result.records[0], 'READ_FAILED');
  assert.equal(fixture.reads(), 2);
  assert.equal(fixture.closes(), 1);
});

test('close failure cannot relabel already buffered bytes as valid metadata', async () => {
  const fixture = setup(valid, 2, { closeThrows: true });
  const result = await fixture.run();
  assertUnknown(result.records[0], 'READ_FAILED');
  assert.equal(fixture.reads(), 1);
  assert.equal(fixture.closes(), 1);
  assert.equal(JSON.stringify(result.diagnostics).includes('SYNTHETIC_PRIVATE_CLOSE'), false);
});

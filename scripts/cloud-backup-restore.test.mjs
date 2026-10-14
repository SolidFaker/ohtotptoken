import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createContext, runInContext } from 'node:vm';
import { createHash, createCipheriv, createDecipheriv, pbkdf2Sync } from 'node:crypto';

// 执行当前生产 Crypto/Metadata/Manager/Result/Gate/Diagnostics，不替换 decrypt 或恢复验证。
// 仅平台边界使用 Node AES-128-CBC/PKCS7 + PBKDF2-SHA256 和内存端口；不等同原生 SDK 验收。
const root = new URL('../common/src/main/ets/utils/', import.meta.url);
async function transpile(name) {
  const source = await readFile(new URL(name, root), 'utf8');
  const exports = [...source.matchAll(/^export\s+(?:async\s+)?(?:class|enum|function|const)\s+(\w+)/gm)].map(match => match[1]);
  return { exports, code: stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''), { mode: 'transform' })
    .replace(/\bexport\s+/g, '') };
}
// Each module gets its own lexical scope (Diagnostics and LastFailure both declare STAGES/REASONS).
const sources = await Promise.all(['CloudBackupDiagnostics.ets', 'CloudBackupMetadata.ets', 'CloudBackupCrypto.ets',
  'CloudBackupResult.ets', 'CloudSyncLastFailure.ets', 'CloudBackupOperationGate.ets', 'CloudBackupStaging.ets',
  'CloudBackupPublicationGuard.ets', 'CloudBackupManager.ets'].map(transpile));
const ID = 'otp_backup_1745385600000.enc';
const CLOUD = '/synthetic/cloud';
const KEY = 'SYNTHETIC_ACCOUNT_KEY';
const SENTINEL = 'SYNTHETIC_PRIVATE_EXCEPTION';
const sha256 = value => createHash('sha256').update(value, 'utf8').digest('hex');
const b64 = value => Buffer.from(value, 'utf8').toString('base64');
const seal = (header, payload) => {
  const data = `${b64(JSON.stringify(header))}.${payload}`;
  return `${data}.${sha256(data)}`;
};
const codec = {
  encodeText: b64,
  decodeText: value => Buffer.from(value, 'base64').toString('utf8'),
  encodeBytes: value => Buffer.from(value).toString('base64'),
  decodeBytes: value => new Uint8Array(Buffer.from(value, 'base64')),
};
function cipherBytes(plaintext, key, salt, iv) {
  const cipher = createCipheriv('aes-128-cbc', pbkdf2Sync(key, salt, 10000, 16, 'sha256'), iv);
  return Buffer.concat([cipher.update(plaintext), cipher.final()]);
}
function nativeError(code = 2) {
  // 名称、code 及消息均不应替代 instanceof 作为可信格式错误证据。
  const error = new Error(SENTINEL);
  error.name = 'CloudBackupTokenError';
  error.code = code;
  return error;
}
function engine() {
  return {
    round: 0, failHash: false, emptyHash: false, failDecrypt: false, emptyDecrypt: false,
    randomBytes(length) { return Uint8Array.from({ length }, (_, i) => (i * 13 + ++this.round) & 255); },
    async sha256Hex(value) {
      if (this.failHash) throw nativeError(1);
      return this.emptyHash ? '' : sha256(value);
    },
    async aesCbcEncrypt(plaintext, password, salt, iv) { return cipherBytes(plaintext, password, salt, iv); },
    async aesCbcDecrypt(ciphertext, password, salt, iv) {
      if (this.failDecrypt) throw nativeError();
      if (this.emptyDecrypt) return new Uint8Array();
      const decipher = createDecipheriv('aes-128-cbc', pbkdf2Sync(password, salt, 10000, 16, 'sha256'), iv);
      return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    },
  };
}
const token = (type = 0) => ({ TokenUUID: `synthetic-${type}`, TokenType: type, TokenSecret: 'SYNTHETIC_TOKEN_SECRET',
  TokenName: '合成名称', TokenIssuer: 'Synthetic', TokenAlgorithm: 'SHA1', TokenPeriod: 30,
  TokenDigits: type === 3 ? 5 : 6, TokenCounter: 0, RankScore: type });
const payload = () => ({ tokens: [0, 1, 2, 3].map(token), groups: [{ id: 'synthetic-group', name: '合成分组' }],
  enabledPacks: ['synthetic-pack'], packMeta: [] });

// 已对照 git 00a989c:entry/.../CloudBackupCrypto.ets 和 2b72261:common/.../CloudBackupCrypto.ets。
// 独立构造旧 wire 格式，避免只验证“新 writer 与新 reader 恰好一起改变”的回环。
function oldBackup(text, version = 2, mode = 1, omitIdentity = false) {
  const salt = Buffer.alloc(16, 7), iv = Buffer.alloc(16, 11);
  const header = { version, mode, salt: version === 1 ? 'mock_salt_1745385600000' : salt.toString('base64'),
    iv: version === 1 ? 'mock_iv_1745385600000' : iv.toString('base64'), tokenCount: 4,
    size: text.length, timestamp: 1745385600000 };
  if (!omitIdentity) Object.assign(header, { deviceId: 'synthetic-old-device', deviceName: 'Synthetic old device' });
  return seal(header, version === 1 ? b64(text) : cipherBytes(Buffer.from(text), KEY, salt, iv).toString('base64'));
}

export function setup() {
  const files = new Map(), lines = [], contexts = [], preferences = new Map();
  const captures = { tokens: [], attempts: 0, groups: [], packs: [], sync: 0, icons: 0,
    reads: 0, stats: 0, lists: 0, writes: 0, publishes: 0, deletes: 0 };
  const behavior = { failWrite: false, failRead: false, corruptRead: false, failPublish: false,
    failDelete: false, failSync: false, failTokenAt: -1, cleanup: false,
    formalReadFailure: false, formalOverride: undefined, collideFormal: false, deletedPaths: [] };
  const account = { login: true, key: KEY, isUserLogin() { return this.login; }, unionId() { return this.key; } };
  const fs = {
    async stat(path) {
      captures.stats++;
      if (path === CLOUD) return { isDirectory: true };
      if (!files.has(path)) { const error = new Error(SENTINEL); error.code = 13900002; throw error; }
      return { size: Buffer.byteLength(files.get(path)), location: 3, isDirectory: false };
    },
    async listFiles() { captures.lists++; return [...files.keys()].map(path => path.slice(CLOUD.length + 1)); },
    async readTextFile(path, context) {
      captures.reads++; contexts.push(context);
      if (behavior.failRead || (behavior.formalReadFailure && /\/otp_backup_-?\d+\.enc$/.test(path))) throw nativeError();
      return behavior.corruptRead ? '' : files.get(path);
    },
    async writeNewTextFile(path, content, context) {
      captures.writes++; contexts.push(context);
      if (behavior.failWrite || files.has(path)) throw nativeError();
      files.set(path, content);
    },
    async publishFile(source, destination, context) {
      captures.publishes++; contexts.push(context);
      if (behavior.collideFormal) files.set(destination, 'SYNTH_FOREIGN_BACKUP');
      if (behavior.failPublish || files.has(destination)) throw nativeError();
      files.set(destination, behavior.formalOverride ?? files.get(source)); files.delete(source);
    },
    async deleteFile(path) {
      captures.deletes++;
      if (behavior.failDelete) throw nativeError();
      behavior.deletedPaths.push(path);
      files.delete(path);
    },
  };
  const sdk = {
    // ArkTS Buffer.buffer 返回有效内容的精确副本；不能给其套 Node 的内存池偏移契约。
    buffer: { from(value, encoding) {
      const data = Buffer.from(value, encoding);
      return { buffer: Uint8Array.from(data).buffer, toString: encoding => data.toString(encoding) };
    } },
    process: { pid: 1, tid: 1 }, systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1 },
    hilog: { info: (_domain, _tag, _format, line) => lines.push(line) },
    AppStorage: { get: () => undefined }, FileIoFsGateway: class {},
    fileIoDiagnosticCode: error => typeof error?.code === 'number' ? error.code : undefined,
    AppPreference: { getPreference: key => preferences.get(key) ?? '', setPreference: (key, value) => preferences.set(key, value),
      saveEnabledPacks: packs => captures.packs.push(packs) },
    PREF_KEYS: { CLOUD_SYNC_LAST_TIME: 'last', CLOUD_SYNC_LAST_FAILURE: 'failure', APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE: 'enable' },
    SyncTimeHelper: { formatTimestamp: () => 'Synthetic date' },
    parseBackupTimestamp: name => Number(name.slice('otp_backup_'.length, -4)),
    BACKUP_FILE_PREFIX: 'otp_backup_', BACKUP_FILE_EXT: '.enc',
    TokenIconPacks: { enabled_packs: [], aegis_icon_packs: [] }, sanitizedTokenForBackup: value => value,
    prepareCloudFileRead: async cache => !cache.isCleanupPending(),
  };
  const api = {};
  const runtime = createContext(sdk);
  for (const source of sources) {
    const module = runInContext(`(() => { ${source.code}\nreturn {${source.exports.join(',')}}; })();`, runtime);
    Object.assign(api, module);
    Object.assign(sdk, module);
  }
  api.CloudBackupDiagnostics.enable();
  const cryptoEngine = engine();
  const crypto = api.CloudBackupCrypto.useEngineForTest(cryptoEngine, codec);
  const deps = {
    fs, account, device: { deviceId: () => 'synthetic-device', deviceName: () => 'Synthetic device' },
    tokens: { getTokens: async () => [], updateToken: async value => {
      if (captures.attempts++ === behavior.failTokenAt) throw nativeError();
      captures.tokens.push(value);
    } },
    groups: { currentGroups: () => [], merge: async groups => captures.groups.push(groups) },
    icons: { backupIconPacks: async () => { captures.icons++; return true; }, clearCloudBackup: async () => true },
    sync: { start: async () => { captures.sync++; if (behavior.failSync) throw nativeError(); } },
    cache: { isCleanupPending: () => behavior.cleanup }, cloudDir: CLOUD,
  };
  const publication = new api.MemoryCloudBackupPublicationPort(fs);
  deps.publication = publication;
  const manager = api.CloudBackupManager.getInstance();
  manager.useDepsForTest(deps);
  return { api, manager, crypto, cryptoEngine, captures, behavior, account, files, lines, contexts, deps,
    publication, preferences,
    put: content => files.set(`${CLOUD}/${ID}`, content),
    restore: () => manager.restoreFromBackupRecordResult(ID),
    async encrypted(text = JSON.stringify(payload())) {
      return crypto.encrypt(text, crypto.getMode(true), KEY, 4, 1745385600000, 'synthetic-device', '合成设备');
    },
  };
}
const events = fixture => fixture.lines.map(line => Object.fromEntries(line.split(' ').map(field => field.split('='))));
function hasEvent(fixture, stage, result, reason) {
  return events(fixture).some(event => event.stage === stage && event.result === result &&
    (reason === undefined || event.reason === reason));
}
function noMutation(fixture) {
  assert.equal(fixture.captures.attempts, 0);
  for (const field of ['tokens', 'groups', 'packs']) assert.equal(fixture.captures[field].length, 0);
  for (const field of ['writes', 'publishes', 'deletes', 'sync', 'icons']) assert.equal(fixture.captures[field], 0);
  assert.equal(fixture.manager.isBusy(), false);
}
function privateDiagnostics(fixture) {
  const output = fixture.lines.join('\n');
  for (const value of [SENTINEL, KEY, 'SYNTHETIC_TOKEN_SECRET', ID, CLOUD, 'synthetic-device', '合成设备']) {
    assert.equal(output.includes(value), false);
  }
}
function sameOperation(fixture) {
  const emitted = events(fixture);
  assert.ok(emitted.length > 0);
  assert.equal(new Set(emitted.map(event => event.op)).size, 1);
}

test('current production crypto and manager restore real AES data and share one diagnostic context', async () => {
  const fixture = setup();
  fixture.put(await fixture.encrypted());
  assert.equal((await fixture.restore()).success, true);
  assert.equal(fixture.captures.tokens.length, 4);
  assert.equal(fixture.captures.groups.length, 1);
  assert.equal(fixture.captures.packs.length, 1);
  for (const stage of ['RESTORE_DECRYPT', 'RESTORE_VALIDATE', 'RESTORE_END']) assert.ok(hasEvent(fixture, stage, 'OK'));
  assert.ok(hasEvent(fixture, 'RESTORE_BEGIN', 'BEGIN'));
  sameOperation(fixture);
  privateDiagnostics(fixture);
});

test('historical v1 NONE/account and v2 AES restore old arrays and grouped payloads', async () => {
  for (const [version, mode] of [[1, 0], [1, 1], [2, 1]]) {
    for (const oldArray of [false, true]) {
      for (const missingIdentity of [false, true]) {
        const fixture = setup();
        const data = payload();
        // 旧 token 无后加可选字段，不能变为拒绝条件。
        delete data.tokens[0].RankScore;
        const text = JSON.stringify(oldArray ? data.tokens : data);
        fixture.put(oldBackup(text, version, mode, missingIdentity));
        assert.equal((await fixture.restore()).success, true);
        assert.equal(fixture.captures.tokens.length, 4);
        assert.equal(fixture.captures.groups.length, oldArray ? 0 : 1);
        assert.equal(fixture.captures.packs.length, oldArray ? 0 : 1);
        privateDiagnostics(fixture);
      }
    }
  }
});

test('wrong account key is DECRYPT_FAILED without mutation and can retry the unchanged backup', async () => {
  const fixture = setup();
  const content = oldBackup(JSON.stringify(payload()));
  fixture.put(content);
  assert.equal(await fixture.crypto.verifyToken(content), true);
  assert.equal(fixture.crypto.parseTokenHeader(content).version, 2);
  fixture.account.key = 'SYNTHETIC_WRONG_ACCOUNT_KEY';
  const failed = await fixture.restore();
  assert.equal(failed.reason, 'DECRYPT_FAILED');
  assert.equal(failed.partialFailure, false);
  noMutation(fixture);
  assert.ok(hasEvent(fixture, 'RESTORE_DECRYPT', 'FAIL', 'DECRYPT_FAILED'));
  assert.equal(hasEvent(fixture, 'HEADER_VALIDATE', 'FAIL'), false);
  assert.equal(hasEvent(fixture, 'RESTORE_VALIDATE', 'FAIL'), false);
  fixture.account.key = KEY;
  assert.equal((await fixture.restore()).success, true);
  assert.equal(fixture.files.get(`${CLOUD}/${ID}`), content);
  privateDiagnostics(fixture);
});

test('padding-valid wrong key remains retryable without declaring corruption', async () => {
  const fixture = setup();
  const content = oldBackup(JSON.stringify(payload()), 2, 1);
  const wrongKey = 'SYNTHETIC_REVIEW_WRONG_ACCOUNT_145';
  fixture.put(content);
  assert.equal(await fixture.crypto.verifyToken(content), true);
  const wrongPlaintext = await fixture.crypto.decrypt(content, 1, wrongKey);
  assert.throws(() => JSON.parse(wrongPlaintext));

  fixture.account.key = wrongKey;
  const failed = await fixture.restore();
  assert.equal(failed.reason, 'DECRYPT_FAILED');
  assert.equal(failed.partialFailure, false);
  noMutation(fixture);
  assert.ok(hasEvent(fixture, 'RESTORE_DECRYPT', 'OK'));
  assert.ok(hasEvent(fixture, 'RESTORE_VALIDATE', 'FAIL', 'DECRYPT_FAILED'));
  assert.ok(hasEvent(fixture, 'RESTORE_END', 'FAIL', 'DECRYPT_FAILED'));

  fixture.account.key = KEY;
  assert.equal((await fixture.restore()).success, true);
  assert.equal(fixture.files.get(`${CLOUD}/${ID}`), content);
  privateDiagnostics(fixture);
});

test('native AES/SHA errors, unavailable digest, and missing key never imply corrupted data', async () => {
  for (const fault of ['failDecrypt', 'failHash', 'emptyHash', 'emptyDecrypt', 'emptyKey']) {
    const fixture = setup();
    fixture.put(await fixture.encrypted());
    if (fault === 'emptyKey') fixture.account.key = '';
    else fixture.cryptoEngine[fault] = true;
    const result = await fixture.restore();
    assert.equal(result.reason, 'DECRYPT_FAILED');
    noMutation(fixture);
    assert.ok(hasEvent(fixture, 'RESTORE_DECRYPT', 'FAIL', 'DECRYPT_FAILED'));
    assert.ok(hasEvent(fixture, 'RESTORE_END', 'FAIL', 'DECRYPT_FAILED'));
    assert.equal(hasEvent(fixture, 'RESTORE_VALIDATE', 'FAIL'), false);
    privateDiagnostics(fixture);
  }
});

test('SDK header decode failure is not recast as invalid header or file corruption', async () => {
  const fixture = setup();
  fixture.put(await fixture.encrypted());
  fixture.api.CloudBackupCrypto.useEngineForTest(fixture.cryptoEngine, {
    ...codec, decodeText() { throw nativeError(1); },
  });
  assert.equal((await fixture.restore()).reason, 'DECRYPT_FAILED');
  noMutation(fixture);
  assert.equal(hasEvent(fixture, 'HEADER_VALIDATE', 'FAIL', 'INVALID_FORMAT'), false);
  privateDiagnostics(fixture);
});

test('real token format and digest mismatch failures are FORMAT_INVALID without local writes', async () => {
  for (const corrupt of [() => 'invalid-token', content => `${content}.extra`,
    content => `${content.slice(0, content.lastIndexOf('.') + 1)}${'0'.repeat(64)}`,
    content => { const parts = content.split('.'); const header = JSON.parse(codec.decodeText(parts[0]));
      header.version = 99; return seal(header, parts[1]); }]) {
    const fixture = setup();
    fixture.put(corrupt(await fixture.encrypted()));
    assert.equal((await fixture.restore()).reason, 'FORMAT_INVALID');
    noMutation(fixture);
    assert.ok(hasEvent(fixture, 'RESTORE_DECRYPT', 'FAIL', 'INVALID_FORMAT'));
    assert.equal(hasEvent(fixture, 'RESTORE_VALIDATE', 'FAIL'), false);
    privateDiagnostics(fixture);
  }
});

test('decrypted JSON and payload errors fail RESTORE_VALIDATE before all local mutations', async () => {
  const data = payload();
  const badPayloads = ['invalid-json', 'null', '{"tokens":{}}',
    JSON.stringify({ ...data, groups: {} }), JSON.stringify({ ...data, enabledPacks: [false] }),
    JSON.stringify({ ...data, tokens: [token(0), token(4)] }),
    JSON.stringify([token(0), token(4)]), JSON.stringify([token(0), token(0)]),
    JSON.stringify({ ...data, groups: [{ id: 'g', name: '' }] })];
  for (const version of [1, 2]) {
    for (const text of badPayloads) {
      const fixture = setup();
      fixture.put(oldBackup(text, version, 1));
      const reason = version === 1 ? 'FORMAT_INVALID' : 'DECRYPT_FAILED';
      assert.equal((await fixture.restore()).reason, reason);
      noMutation(fixture);
      assert.ok(hasEvent(fixture, 'RESTORE_DECRYPT', 'OK'));
      assert.ok(hasEvent(fixture, 'RESTORE_VALIDATE', 'FAIL', version === 1 ? 'INVALID_FORMAT' : reason));
      assert.equal(hasEvent(fixture, 'HEADER_VALIDATE', 'FAIL'), false);
      privateDiagnostics(fixture);
    }
  }
});

test('a real write failure after validation remains WRITE_FAILED and partial, not format/decryption failure', async () => {
  const fixture = setup();
  fixture.put(await fixture.encrypted());
  fixture.behavior.failTokenAt = 1;
  const result = await fixture.restore();
  assert.equal(result.reason, 'WRITE_FAILED');
  assert.equal(result.partialFailure, true);
  assert.equal(result.localComplete, false);
  assert.equal(fixture.captures.attempts, 2);
  assert.equal(fixture.captures.tokens.length, 1);
  assert.equal(fixture.captures.groups.length, 1);
  assert.ok(hasEvent(fixture, 'RESTORE_VALIDATE', 'OK'));
  assert.ok(hasEvent(fixture, 'RESTORE_END', 'FAIL', 'IO_ERROR'));
  privateDiagnostics(fixture);
});

test('runAction, history and presence readiness refusals always emit their terminal reason', async () => {
  for (const reason of ['NOT_READY', 'NOT_SIGNED_IN']) {
    for (const action of ['restoreFromBackupRecordResult', 'listBackupHistoryResult', 'hasBackupRecords']) {
      const fixture = setup();
      if (reason === 'NOT_READY') {
        fixture.manager.resetForTest();
        fixture.manager.useDepsForTest({ ...fixture.deps, cloudDir: '' });
      } else fixture.account.login = false;
      await fixture.manager[action](ID);
      const terminal = action === 'restoreFromBackupRecordResult' ? 'RESTORE_END' : 'HISTORY_END';
      assert.ok(hasEvent(fixture, terminal, 'BLOCKED', reason));
      assert.equal(fixture.captures.reads + fixture.captures.lists, 0);
      noMutation(fixture);
    }
  }
});

test('gate BUSY and unresolved cleanup emit distinct terminal reasons for every manager entry', async () => {
  for (const cleanup of [false, true]) {
    for (const action of ['restoreFromBackupRecordResult', 'listBackupHistoryResult', 'hasBackupRecords']) {
      const fixture = setup();
      const owner = fixture.api.CloudBackupOperationGate.getInstance().tryEnter(fixture.api.CloudBackupOperationKind.BACKUP);
      fixture.behavior.cleanup = cleanup;
      try {
        await fixture.manager[action](ID);
        const terminal = action === 'restoreFromBackupRecordResult' ? 'RESTORE_END' : 'HISTORY_END';
        assert.ok(hasEvent(fixture, terminal, 'BLOCKED', cleanup ? 'INFLIGHT_UNCONFIRMED' : 'BUSY'));
        assert.equal(fixture.captures.reads + fixture.captures.lists + fixture.captures.writes, 0);
      } finally { owner.release(); }
    }
  }
});

test('RESTORE_BEGIN precedes unreadable content and invalid target refusals', async () => {
  for (const badTarget of [false, true]) {
    const fixture = setup();
    fixture.put(await fixture.encrypted());
    fixture.behavior.failRead = true;
    const result = await fixture.manager.restoreFromBackupRecordResult(badTarget ? '../invalid' : ID);
    assert.equal(result.reason, badTarget ? 'INVALID_TARGET' : 'READ_FAILED');
    assert.equal(events(fixture)[0].stage, 'RESTORE_BEGIN');
    assert.equal(hasEvent(fixture, 'RESTORE_DECRYPT', 'FAIL'), false);
    noMutation(fixture);
  }
});

test('backup failures attribute write, readback verification and publication to their actual stage', async () => {
  for (const [fault, stage, reason] of [['failWrite', 'WRITE_END', 'IO_ERROR'], ['failRead', 'FS_VERIFY', 'IO_ERROR'],
    ['corruptRead', 'FS_VERIFY', 'INVALID_FORMAT'], ['failPublish', 'PUBLISH_END', 'IO_ERROR']]) {
    const fixture = setup();
    fixture.behavior[fault] = true;
    const result = await fixture.manager.backupToCloudResult();
    assert.equal(result.reason, 'WRITE_FAILED');
    assert.ok(hasEvent(fixture, stage, 'FAIL', reason));
    if (fault !== 'failWrite') {
      assert.ok(hasEvent(fixture, 'WRITE_END', 'OK'));
      assert.equal(hasEvent(fixture, 'WRITE_END', 'FAIL'), false);
    }
    assert.ok(hasEvent(fixture, 'BACKUP_END', 'FAIL', 'IO_ERROR'));
    assert.equal(fixture.captures.sync, 0);
    assert.equal(fixture.files.size, 0);
    assert.ok(fixture.contexts.every(context => context === fixture.contexts[0]));
    sameOperation(fixture);
    privateDiagnostics(fixture);
  }
});

test('owned temporary cleanup failure is TEMP_CLEANUP rather than FS_CLOSE', async () => {
  const fixture = setup();
  fixture.behavior.failPublish = true;
  fixture.behavior.failDelete = true;
  assert.equal((await fixture.manager.backupToCloudResult()).reason, 'WRITE_FAILED');
  assert.ok(hasEvent(fixture, 'TEMP_CLEANUP', 'FAIL', 'IO_ERROR'));
  assert.equal(hasEvent(fixture, 'FS_CLOSE', 'FAIL'), false);
  assert.equal(fixture.files.size, 1);
  privateDiagnostics(fixture);
});

test('production success paths reuse their operation context without per-file diagnostic operations', async () => {
  const fixture = setup();
  assert.equal((await fixture.manager.backupToCloudResult()).success, true);
  for (const stage of ['CRYPTO_RESULT', 'WRITE_END', 'FS_VERIFY', 'PUBLISH_END', 'BACKUP_END']) {
    assert.ok(hasEvent(fixture, stage, 'OK'));
  }
  assert.ok(fixture.contexts.length >= 3);
  assert.ok(fixture.contexts.every(context => context === fixture.contexts[0]));
  sameOperation(fixture);
  privateDiagnostics(fixture);
});

export function withStaging(fixture) {
  const receipts = new Map(), directories = new Set(), events = [];
  let sequence = 0;
  const scope = 'a'.repeat(64);
  const port = {
    async createDirectory(prefix) {
      const path = prefix.replace('XXXXXX', String(++sequence).padStart(6, '0'));
      directories.add(path); events.push('create'); return path;
    },
    async inspect(path) {
      if (directories.has(path)) return { directory: true, regular: false, symbolic: false };
      if (fixture.files.has(path)) return { directory: false, regular: true, symbolic: false };
      return undefined;
    },
    async list(path) { return [...fixture.files.keys()].filter(key => key.startsWith(`${path}/`)).map(key => key.slice(path.length + 1)); },
    async save(receipt) {
      const id = `receipt-${String(sequence).padStart(6, '0')}`;
      receipts.set(id, { ...receipt, id }); events.push('save'); return id;
    },
    async load() { events.push('load'); return [...receipts.values()].map(value => ({ ...value })); },
    async forget(id) { receipts.delete(id); events.push('forget'); },
    async write(path, content, context) {
      events.push('write'); await fixture.deps.fs.writeNewTextFile(path, content, context);
    },
    async move(source, destination) { events.push('publish'); await fixture.deps.fs.publishFile(source, destination); },
    async unlink(path) { events.push('unlink'); await fixture.deps.fs.deleteFile(path); },
    async removeDirectory(path) { directories.delete(path); events.push('removeDirectory'); },
    async sync() { events.push('recoverySync'); return !fixture.behavior.failSync; },
  };
  const highLevelSync = fixture.deps.sync.start;
  fixture.deps.sync.start = async () => { events.push('operationSync'); await highLevelSync(); };
  const staging = new fixture.api.CloudBackupStaging(CLOUD, scope, port);
  fixture.deps.staging = staging;
  fixture.manager.useDepsForTest(fixture.deps);
  return { receipts, directories, events, scope, port, staging };
}

test('manager uses real staging lifecycle and forgets only after high-level sync acceptance', async () => {
  const fixture = setup();
  const stage = withStaging(fixture);
  const result = await fixture.manager.backupToCloudResult();
  assert.equal(result.success, true);
  assert.equal(stage.receipts.size, 0);
  assert.equal(stage.directories.size, 0);
  assert.equal(fixture.files.size, 1);
  assert.ok([...fixture.files.keys()][0].match(/\/otp_backup_-?\d+\.enc$/));
  for (const [before, after] of [['save', 'write'], ['write', 'publish'], ['publish', 'removeDirectory'],
    ['removeDirectory', 'operationSync'], ['operationSync', 'forget']]) {
    assert.ok(stage.events.indexOf(before) < stage.events.indexOf(after));
  }
  privateDiagnostics(fixture);
});

test('manager retains receipt on sync failure and history can recover it without deleting the formal backup', async () => {
  const fixture = setup();
  const stage = withStaging(fixture);
  fixture.behavior.failSync = true;
  const result = await fixture.manager.backupToCloudResult();
  assert.equal(result.success, false);
  assert.equal(result.localComplete, true);
  assert.equal(result.reason, 'SYNC_FAILED');
  assert.equal(stage.receipts.size, 1);
  assert.equal(stage.events.includes('forget'), false);
  const formal = [...fixture.files.entries()];
  fixture.behavior.failSync = false;
  assert.equal((await fixture.manager.listBackupHistoryResult()).records.length, 1);
  assert.equal(stage.receipts.size, 0);
  assert.deepEqual([...fixture.files.entries()], formal);
  assert.ok(stage.events.indexOf('recoverySync') < stage.events.indexOf('forget'));
  privateDiagnostics(fixture);
});

test('manager does not invoke staging during unresolved I/O or hide formal history when recovery is blocked', async () => {
  const blocked = setup();
  const blockedStage = withStaging(blocked);
  blocked.behavior.cleanup = true;
  assert.equal((await blocked.manager.backupToCloudResult()).reason, 'CLEANUP_PENDING');
  assert.equal(blockedStage.events.length, 0);
  assert.equal(blocked.manager.isBusy(), true);

  const fixture = setup();
  const stage = withStaging(fixture);
  fixture.put(oldBackup(JSON.stringify(payload())));
  const directory = `${CLOUD}/.cloud-backup-owned-123456`;
  stage.directories.add(directory);
  fixture.files.set(`${directory}/unknown-child`, 'SYNTH_FOREIGN');
  stage.receipts.set('receipt-123456', { id: 'receipt-123456', version: 1, scope: stage.scope,
    cloudRoot: CLOUD, stage: '.cloud-backup-owned-123456' });
  const history = await fixture.manager.listBackupHistoryResult();
  assert.equal(history.records.length, 1);
  assert.equal(history.records[0].metadataStatus, 'VALID');
  assert.equal(stage.receipts.size, 1);
  assert.equal(stage.events.includes('unlink'), false);
  assert.equal(stage.events.includes('forget'), false);
  privateDiagnostics(fixture);
});

test('localized decryption feedback does not claim key mismatch and both pages map the new reason', async () => {
  for (const locale of ['base', 'en_US', 'zh_CN', 'zh_TW']) {
    const resource = JSON.parse(await readFile(new URL(`../common/src/main/resources/${locale}/element/string.json`, import.meta.url), 'utf8'));
    const matches = resource.string.filter(item => item.name === 'cloud_backup_decrypt_failed');
    assert.equal(matches.length, 1);
    assert.ok(matches[0].value.length > 0);
    assert.equal(/key mismatch|密钥不匹配|金鑰不符/i.test(matches[0].value), false);
  }
  for (const page of ['ShowCloudBackupHistoryPage', 'ShowCloudSyncDetailsPage']) {
    const source = await readFile(new URL(`../entry/src/main/ets/pages/${page}.ets`, import.meta.url), 'utf8');
    assert.match(source, /case CloudBackupFailureReason\.DECRYPT_FAILED: return \$r\('app\.string\.cloud_backup_decrypt_failed'\)/);
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { parseDiagnosticLine } from './collect-cloud-backup-diagnostics.mjs';

// 只读离线回归：执行当前生产 IconPack/Storage/Gate/Diagnostics/Cache/Time 控制流，
// 同时执行原 ETS 定向 suite。仅系统边界使用内存端口，不复制恢复/发布算法。
// move fake 仅注入目标变更前失败；不证明原生移动中断、真机杀进程或云同步完成。
const root = new URL('../', import.meta.url);
async function executable(path) {
  const source = await readFile(new URL(path, root), 'utf8');
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, '')
    .replace(/export\s+default\s+/g, ''), { mode: 'transform' }).replace(/\bexport\s+/g, '');
}
const common = 'common/src/main/ets/utils/';
const production = await Promise.all(['CloudBackupDiagnostics.ets', 'StoragePorts.ets',
  'CloudBackupOperationGate.ets', 'CloudFileCacheLoader.ets', 'SyncTimeHelper.ets',
  'IconPackPublication.ets', 'IconPackCloudBackup.ets'].map(name => executable(common + name)));
const fakes = await Promise.all(['entry/src/test/fakes/BackupFakes.ets',
  'entry/src/test/fakes/CloudCacheFakes.ets'].map(executable));
const suite = await executable('entry/src/test/IconPackCloudBackup.test.ets');
const NOW = 1800000000000;
const OLD_TIME = '100';
const ZIP = '/cloud/icon_packs_backup.zip';
const CLOUD_META = '/cloud/icon_packs_sync_meta.json';
const STAGED_ZIP = '/cloud/.icon_packs_backup_pending.zip';
const LOCAL_ZIP = '/data/cache/icon_packs_backup.zip';
const RESTORE = '/data/cache/icon_pack_restore';
const VERIFY = '/data/cache/icon_pack_publish_verify';
const PRIVATE = 'SYNTHETIC_PRIVATE_PATH_UUID_MESSAGE';
class FixedDate extends Date { static now() { return NOW; } }

function fixture({ detailed = true, registerSuite = false } = {}) {
  const settings = new Map(), lines = [], marks = [], events = [], cases = [], nativeMoves = [], nativeUnlinks = [];
  const account = { userLogin: true };
  const appContext = { filesDir: '/data/files', cloudFileDir: '/cloud', cacheDir: '/data/cache', tempDir: '/data/cache',
    eventHub: { emit: name => events.push(name) } };
  const nativeFs = {
    async moveFile(source, destination, mode) {
      nativeMoves.push({ source, destination, mode });
      if (nativeFs.error) throw nativeFs.error;
    },
    async unlink(path) {
      nativeUnlinks.push(path);
      if (nativeFs.unlinkError) throw nativeFs.unlinkError;
    },
  };
  const sdk = {
    Date: FixedDate, setTimeout, clearTimeout,
    fs: nativeFs, buffer: { from: (value, encoding) => Buffer.from(value, encoding) },
    process: { pid: 1, tid: 1 }, systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1 },
    hilog: { info: (_domain, _tag, _format, line) => lines.push(line) },
    AppStorage: { get: () => appContext },
    AppPreference: {
      getPreference: key => settings.get(key) ?? '',
      setPreference: (key, value) => settings.set(key, value),
      saveEnabledPacks: packs => settings.set('enabled', JSON.stringify(packs)),
      loadEnabledPacks: () => JSON.parse(settings.get('enabled') || '[]'),
    },
    PREF_KEYS: { ICON_PACK_CLOUD_SYNC_TIME: 'time', APPEARANCE_ICON_PACK_ENABLED: 'enabled',
      APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE: 'enable' },
    EVENT_NAMES: { ICON_PACK_CHANGED: 'ICON_PACK_CHANGED' }, BUILTIN_DEFAULT_PACK_ID: '__builtin_default',
    HuaweiAccountManager: { getInstance: () => account }, padZero: value => String(value).padStart(2, '0'),
    AegisIconPack: class { uuid = ''; name = ''; version = 0; icons = []; on_device_path = ''; },
    describe: (_name, body) => body(), it: (name, _level, body) => cases.push({ name, body }),
    expect: actual => ({ assertEqual: expected => assert.equal(actual, expected),
      assertTrue: () => assert.equal(actual, true), assertFalse: () => assert.equal(actual, false) }),
  };
  const api = runInNewContext(`${production.join('\n')}\n${fakes.join('\n')}\n${suite}\n({
    IconPackCloudBackup, IconPackSyncState, CloudBackupOperationGate, CloudBackupDiagnostics,
    DiagnosticKind, DiagnosticStage, DiagnosticResult, FileIoFsGateway, MemoryFs, MemoryFsError,
    DownloadAwareFs, FakeFileCacher, FakeUnpackArchiver, FakeIconRegistry, FakeIconDevice, FakeIconSync,
    iconPackCloudBackupTest });`, sdk);
  const mark = api.CloudBackupDiagnostics.mark;
  api.CloudBackupDiagnostics.mark = (context, stage, result, details) => {
    marks.push({ context, stage, result, details });
    mark(context, stage, result, details);
  };
  if (detailed) api.CloudBackupDiagnostics.enable();
  if (registerSuite) api.iconPackCloudBackupTest();
  const fs = new api.DownloadAwareFs();
  const archiver = new api.FakeUnpackArchiver(fs);
  const registry = new api.FakeIconRegistry();
  const sync = new api.FakeIconSync();
  const icons = api.IconPackCloudBackup.getInstance();
  settings.set('time', OLD_TIME);
  settings.set('enable', true);
  const f = { api, icons, fs, archiver, registry, sync, settings, lines, marks, events,
    account, cases, nativeFs, nativeMoves, nativeUnlinks };
  f.bind = async () => {
    // 保持真实 prepareContext/init 路径和事件出口，不直接调用私有业务方法。
    await icons.init();
    icons.useDepsForTest({ fs, archiver, registry, sync, device: new api.FakeIconDevice(),
      cache: new api.FakeFileCacher(fs) });
  };
  f.assertReleased = () => {
    assert.equal(icons.getState(), api.IconPackSyncState.IDLE);
    assert.equal(api.CloudBackupOperationGate.getInstance().isBusy(), false);
  };
  return f;
}
function seedBackup(f, meta = '{"packs":[],"enabledPacks":[]}') {
  f.fs.files.set('/data/files/icon_packs/pack.json', '{}');
  f.fs.files.set(LOCAL_ZIP, 'new-zip');
  f.fs.files.set(ZIP, 'old-good-zip');
  f.fs.files.set(CLOUD_META, '{"timestamp":100}');
  if (meta !== undefined) f.archiver.contents.set('icon_packs_meta.json', meta);
}
function seedRestore(f, { meta = true, twoFiles = false } = {}) {
  f.fs.files.set(ZIP, 'same-cloud-zip');
  f.fs.files.set(CLOUD_META, '{"timestamp":9000}');
  f.archiver.contents.set('user_icons/a.svg', 'a');
  if (twoFiles) f.archiver.contents.set('user_icons/b.svg', 'b');
  if (meta) f.archiver.contents.set('icon_packs_meta.json', JSON.stringify({
    timestamp: 9000, enabledPacks: ['cloud'], deletedPacks: [], packs: [],
  }));
}
function partialOnly(f) {
  assert.ok(f.marks.some(m => m.stage === 'ICON_IO' && m.result === 'FAIL' &&
    m.details?.reason === 'PARTIAL_FAILURE'));
  assert.equal(f.marks.some(m => m.stage === 'ICON_IO' && m.result === 'OK'), false);
  assert.equal(f.settings.get('time'), OLD_TIME);
  f.assertReleased();
}
function assertSafeLines(f, detailed) {
  assert.ok(f.lines.length > 0);
  for (const line of f.lines) {
    assert.ok(parseDiagnosticLine(`CloudBackupDiag: ${line}`), 'Every emitted line must pass the existing collector allowlist');
    assert.equal(/SYNTHETIC_PRIVATE|\/cloud|\/data|rawError|message=|count=|uuid=/i.test(line), false);
    if (!detailed) assert.equal(/\b(?:op|item|elapsed|code)=/.test(line), false);
  }
}

for (const failure of ['copy', 'verify', 'sync']) {
  test(`production ${failure} failure preserves old data in pre-mutation fake without formal copy, time or sync`, async () => {
    const f = fixture(); await f.bind(); seedBackup(f);
    if (failure === 'copy') f.fs.failCopyFor.add(LOCAL_ZIP);
    if (failure === 'verify') f.archiver.contents.clear();
    if (failure === 'sync') f.fs.failSyncFor.add('/cloud/.icon_packs_generations/generation-000001/icon_packs_backup.zip');
    assert.equal(await f.icons.backupIconPacks(), false);
    assert.equal(f.fs.files.get(ZIP), 'old-good-zip');
    assert.equal(f.fs.files.get(CLOUD_META), '{"timestamp":100}');
    assert.equal(f.fs.copiedPairs.some(pair => pair.endsWith(`->${ZIP}`)), false);
    assert.equal(f.fs.replaceAttempts.length, 0);
    assert.equal(f.fs.publishAttempts.length, 0);
    assert.equal(f.fs.replacedPairs.length, 0);
    assert.equal(f.fs.written.has(CLOUD_META), false);
    assert.equal(f.fs.files.has(STAGED_ZIP), false);
    assert.equal(f.settings.get('time'), OLD_TIME);
    assert.equal(f.sync.calls, 0);
    assert.equal(f.marks.some(m => m.stage === 'ICON_IO' && m.result === 'OK'), false);
    assertSafeLines(f, true); f.assertReleased();
  });
}

test('production success publishes immutable generation without mutating legacy backup', async () => {
  const f = fixture(); await f.bind(); seedBackup(f);
  assert.equal(await f.icons.backupIconPacks(), true);
  const generation = '/cloud/.icon_packs_generations/generation-000001';
  assert.equal(f.fs.files.get(generation + '/icon_packs_backup.zip'), 'new-zip');
  assert.ok(f.fs.files.has(generation + '/icon_packs_sync_meta.json'));
  assert.ok(f.fs.files.has(generation + '/committed.json'));
  assert.equal(f.fs.files.get(ZIP), 'old-good-zip');
  assert.equal(f.fs.files.get(CLOUD_META), '{"timestamp":100}');
  assert.equal(f.fs.publishAttempts.length, 0);
  assert.equal(f.fs.replaceAttempts.length, 0);
  assert.equal(f.settings.get('time'), String(NOW));
  assert.equal(f.sync.calls, 1); f.assertReleased();
});

test('production companion metadata staging failure preserves old zip/meta, no time or sync, and cleans only owned temporaries', async () => {
  const f = fixture(); await f.bind(); seedBackup(f);
  f.fs.files.set('/cloud/.icon_packs_backup_pending_foreign.zip', 'foreign');
  f.fs.files.set('/data/files/user_icons/existing.svg', 'existing');
  const write = f.fs.writeTextFile.bind(f.fs);
  let metaAttempts = 0;
  f.fs.writeTextFile = async (path, content) => {
    if (path.endsWith('/icon_packs_sync_meta.json') && path.includes('/.icon_packs_generations/')) {
      metaAttempts++;
      assert.equal(f.fs.files.get(ZIP), 'old-good-zip');
      throw new f.api.MemoryFsError(13900012);
    }
    return write(path, content);
  };
  assert.equal(await f.icons.backupIconPacks(), false);
  assert.equal(metaAttempts, 1);
  assert.equal(f.fs.files.get(ZIP), 'old-good-zip');
  assert.equal(f.fs.files.get(CLOUD_META), '{"timestamp":100}');
  assert.equal(f.fs.replacedPairs.length, 0);
  assert.equal(f.fs.copiedPairs.some(pair => pair.endsWith(`->${ZIP}`)), false);
  assert.equal(f.settings.get('time'), OLD_TIME);
  assert.equal(f.sync.calls, 0);
  assert.equal(f.marks.some(m => m.stage === 'ICON_IO' && m.result === 'OK'), false);
  assert.equal(f.fs.files.has(LOCAL_ZIP), false);
  assert.equal(f.fs.files.has(STAGED_ZIP), false);
  assert.equal([...f.fs.files.keys()].some(path => path.startsWith('/data/cache/icon_pack_staging/')), false);
  assert.equal([...f.fs.files.keys()].some(path => path.startsWith(`${VERIFY}/`)), false);
  assert.equal(f.fs.files.get('/cloud/.icon_packs_backup_pending_foreign.zip'), 'foreign');
  assert.equal(f.fs.files.get('/data/files/user_icons/existing.svg'), 'existing');
  assert.equal(f.fs.deleteAttempts.includes('/cloud/.icon_packs_backup_pending_foreign.zip'), false);
  assert.equal(f.fs.deleteAttempts.some(path => path.startsWith('/data/files/')), false);
  assertSafeLines(f, true); f.assertReleased();
});

test('production adapter unlinks stale target then moves without replace; absent target tolerated, real unlink error aborts', async () => {
  const f = fixture();
  const gateway = new f.api.FileIoFsGateway();
  const error = new f.api.MemoryFsError(13900012);
  f.nativeFs.error = error;
  await assert.rejects(gateway.moveFileToReplace(STAGED_ZIP, ZIP), candidate => candidate === error);
  assert.deepEqual(f.nativeUnlinks, [ZIP]);
  assert.deepEqual(f.nativeMoves, [{ source: STAGED_ZIP, destination: ZIP, mode: 1 }]);
  // 首次备份：目标缺失时删除抛 ENOENT 视为目标本就不存在，继续移动。
  f.nativeFs.error = undefined;
  f.nativeFs.unlinkError = new f.api.MemoryFsError(13900002);
  await gateway.moveFileToReplace(STAGED_ZIP, ZIP);
  assert.equal(f.nativeMoves.length, 2);
  // 删除的其他失败如实传播，绝不进入移动。
  const unlinkFailure = new f.api.MemoryFsError(13900012);
  f.nativeFs.unlinkError = unlinkFailure;
  await assert.rejects(gateway.moveFileToReplace(STAGED_ZIP, ZIP), candidate => candidate === unlinkFailure);
  assert.equal(f.nativeMoves.length, 2);
  // 同目录与同路径守卫保持原样，且不触发任何原生调用。
  const callsBefore = f.nativeUnlinks.length;
  await assert.rejects(gateway.moveFileToReplace('/other/stage.zip', ZIP));
  await assert.rejects(gateway.moveFileToReplace(ZIP, ZIP));
  assert.equal(f.nativeUnlinks.length, callsBefore);
});

for (const detailed of [false, true]) {
  test(`partial auto restore refreshes actual files, returns false and retries unchanged timestamp (detailed=${detailed})`, async () => {
    const f = fixture({ detailed }); await f.bind(); seedRestore(f, { twoFiles: true });
    f.fs.failCopyFor.add(`${RESTORE}/user_icons/b.svg`);
    assert.equal(await f.icons.checkAndAutoRestore(), false);
    assert.equal(f.fs.files.get('/data/files/user_icons/a.svg'), 'a');
    assert.equal(f.fs.files.has('/data/files/user_icons/b.svg'), false);
    assert.deepEqual(f.events, ['ICON_PACK_CHANGED']);
    partialOnly(f); assertSafeLines(f, detailed);
    // 只解除故障：不重置服务/账号/偏好、云文件或时间戳。
    f.fs.failCopyFor.clear();
    assert.equal(await f.icons.checkAndAutoRestore(), true);
    assert.equal(f.archiver.decompressCalls, 2);
    assert.equal(f.fs.files.get('/data/files/user_icons/b.svg'), 'b');
    assert.equal(f.settings.get('time'), '9000');
    assert.deepEqual(f.events, ['ICON_PACK_CHANGED', 'ICON_PACK_CHANGED']);
    f.assertReleased();
  });
}

for (const failure of ['load-user', 'add-pack', 'remove-pack', 'reload-enabled', 'list-local', 'set-enabled']) {
  test(`production registry ${failure} failure reports partial and does not suppress same-timestamp retry`, async () => {
    const f = fixture(); await f.bind(); seedRestore(f);
    const metadata = JSON.parse(f.archiver.contents.get('icon_packs_meta.json'));
    if (failure === 'load-user') f.registry.failLoadUserIcons = true;
    if (failure === 'add-pack') {
      f.archiver.contents.set('icon_packs/new/pack.json', '{}');
      f.registry.failAddFor.add('/data/files/icon_packs/new');
    }
    if (failure === 'remove-pack') {
      f.registry.packs.push({ uuid: 'deleted', on_device_path: '/data/files/icon_packs/deleted' });
      metadata.deletedPacks = ['deleted']; f.registry.failRemoveFor.add('deleted');
    }
    if (failure === 'reload-enabled') f.registry.failReloadEnabledPacks = true;
    const list = f.fs.listFiles.bind(f.fs);
    if (failure === 'list-local') f.fs.listFiles = async path => {
      if (path === '/data/files/icon_packs') throw new f.api.MemoryFsError(13900012);
      return list(path);
    };
    const set = f.registry.setEnabledPacks.bind(f.registry);
    if (failure === 'set-enabled') f.registry.setEnabledPacks = () => { throw new Error(PRIVATE); };
    f.archiver.contents.set('icon_packs_meta.json', JSON.stringify(metadata));
    const result = await f.icons.restoreIconPacks();
    assert.equal(result.failedFiles, 1);
    assert.ok(result.restoredFiles > 0); partialOnly(f);
    f.registry.failLoadUserIcons = false; f.registry.failAddFor.clear(); f.registry.failRemoveFor.clear();
    f.registry.failReloadEnabledPacks = false; f.fs.listFiles = list; f.registry.setEnabledPacks = set;
    assert.equal((await f.icons.restoreIconPacks()).failedFiles, 0);
    assert.equal(f.settings.get('time'), '9000'); f.assertReleased();
  });
}

test('legacy zip without metadata copies files without format rejection or registry rewrite', async () => {
  const f = fixture(); await f.bind(); seedRestore(f, { meta: false });
  const result = await f.icons.restoreIconPacks();
  assert.equal(result.failedFiles, 0); assert.equal(result.restoredFiles, 1);
  assert.equal(f.registry.reloadEnabledPacksCalls, 0);
  assert.equal(f.registry.lastAppliedPacks.length, 0);
  assert.equal(f.settings.get('time'), OLD_TIME); f.assertReleased();
});

for (const failure of ['read-meta', 'invalid-json', 'zip-read']) {
  test(`production restore ${failure} does not advance time or report OK`, async () => {
    const f = fixture(); await f.bind(); seedRestore(f);
    if (failure === 'read-meta') f.fs.failReadFor.add(`${RESTORE}/icon_packs_meta.json`);
    if (failure === 'invalid-json') f.archiver.contents.set('icon_packs_meta.json', '{');
    const unpack = f.archiver.decompress.bind(f.archiver);
    if (failure === 'zip-read') f.archiver.decompress = async () => { throw new Error(PRIVATE); };
    const result = await f.icons.restoreIconPacks();
    assert.equal(result.failedFiles, 1);
    assert.equal(result.restoredFiles, failure === 'zip-read' ? 0 : 1); partialOnly(f);
    f.fs.failReadFor.clear(); f.archiver.decompress = unpack;
    seedRestore(f);
    assert.equal((await f.icons.restoreIconPacks()).failedFiles, 0);
    assert.equal(f.settings.get('time'), '9000');
  });
}

for (const phase of ['verify', 'local-zip', 'staging-dir']) {
  test(`production backup ${phase} cleanup failure reports partial, no time or sync, and leaves foreign data untouched`, async () => {
    const f = fixture(); await f.bind(); seedBackup(f);
    const failingPath = { verify: `${VERIFY}/icon_packs_meta.json`, 'local-zip': LOCAL_ZIP,
      'staging-dir': '/data/cache/icon_pack_staging', 'cloud-stage': STAGED_ZIP }[phase];
    if (phase === 'staging-dir') {
      f.fs.failRemoveDirFor.add(failingPath);
    } else f.fs.failDeleteFor.add(failingPath);
    if (phase === 'cloud-stage') f.fs.failPublish = true;
    f.fs.files.set('/cloud/.icon_packs_backup_pending_foreign.zip', 'foreign');
    f.fs.files.set('/data/files/user_icons/existing.svg', 'existing');
    assert.equal(await f.icons.backupIconPacks(), false);
    assert.equal(f.sync.calls, 0); partialOnly(f);
    assert.equal(f.fs.files.get('/cloud/.icon_packs_backup_pending_foreign.zip'), 'foreign');
    assert.equal(f.fs.files.get('/data/files/user_icons/existing.svg'), 'existing');
    assert.equal(f.fs.deleteAttempts.some(path => path.startsWith('/data/files/')), false);
    assert.equal(f.fs.deleteAttempts.includes('/cloud/.icon_packs_backup_pending_foreign.zip'), false);
    assertSafeLines(f, true);
  });
}

test('production initial restore cleanup failure is counted once and retried only by the next operation', async () => {
  const f = fixture(); await f.bind(); seedRestore(f);
  const residual = `${RESTORE}/residual.svg`;
  f.fs.dirs.add(RESTORE);
  f.fs.files.set(residual, 'residual');
  f.fs.failDeleteFor.add(residual);
  const result = await f.icons.restoreIconPacks();
  assert.equal(result.failedFiles, 1);
  assert.equal(result.restoredFiles, 0);
  assert.equal(f.archiver.decompressCalls, 0);
  assert.equal(f.fs.deleteAttempts.filter(path => path === residual).length, 1);
  partialOnly(f);
  f.fs.failDeleteFor.clear();
  assert.equal((await f.icons.restoreIconPacks()).failedFiles, 0);
  assert.equal(f.archiver.decompressCalls, 1);
  assert.equal(f.settings.get('time'), '9000'); f.assertReleased();
});

test('production cloud-only committed generation caches before verification and is recoverable', async () => {
  const f = fixture(); await f.bind(); seedRestore(f);
  const metadata = JSON.stringify({ version: 1, timestamp: 9000, deviceId: 'd', deviceName: 'M',
    enabledPacks: ['cloud'], deletedPacks: [], packs: [] });
  f.fs.files.set(CLOUD_META, metadata);
  f.archiver.contents.set('icon_packs_meta.json', JSON.stringify({ version: 1, timestamp: 9000,
    enabledPacks: ['cloud'], deletedPacks: [], packs: [] }));
  const dir = '/cloud/.icon_packs_generations/generation-AAAAAA';
  f.fs.dirs.add('/cloud/.icon_packs_generations'); f.fs.dirs.add(dir);
  const committed = dir + '/committed.json';
  f.fs.files.set(dir + '/icon_packs_backup.zip', 'same-cloud-zip');
  f.fs.files.set(dir + '/icon_packs_sync_meta.json', metadata);
  f.fs.files.set(committed, JSON.stringify({ version: 1, id: 'generation-AAAAAA', timestamp: 9000, metadata }));
  for (const path of [dir + '/icon_packs_backup.zip', dir + '/icon_packs_sync_meta.json', committed]) f.fs.locationOverride.set(path, 2);
  const unpack = f.archiver.decompress.bind(f.archiver);
  f.archiver.decompress = async (path, dir) => { await f.fs.readTextFile(path); return unpack(path, dir); };
  const result = await f.icons.restoreIconPacks();
  assert.equal(result.failedFiles, 0);
  assert.ok(result.restoredFiles > 0);
  assert.equal(f.fs.files.has(committed), true);
  assert.equal(f.settings.get('time'), '9000');
  f.assertReleased();
});

test('production corrupt publication status is unresolved rather than never-backed-up and explicit clear unblocks', async () => {
  const f = fixture(); await f.bind(); seedBackup(f);
  const dir = '/cloud/.icon_packs_generations/generation-AAAAAA';
  f.fs.dirs.add('/cloud/.icon_packs_generations'); f.fs.dirs.add(dir);
  f.fs.files.set(dir + '/committed.json', '{');
  f.fs.files.delete(ZIP); f.fs.files.delete(CLOUD_META);
  const status = await f.icons.getCloudBackupStatus();
  assert.equal(status.publicationUnresolved, true);
  assert.equal(status.metadataAbsent, false);
  assert.equal(status.metadataKnown, false);
  assert.equal(await f.icons.clearCloudBackup(), true);
  assert.equal(f.fs.files.has(dir + '/committed.json'), false);
  assert.equal((await f.icons.getCloudBackupStatus()).publicationUnresolved, false);
  f.assertReleased();
});

test('production scoped generation clear submits sync even when legacy belongs to another device', async () => {
  const f = fixture(); await f.bind();
  const dir = '/cloud/.icon_packs_generations/generation-AAAAAA';
  f.fs.dirs.add('/cloud/.icon_packs_generations'); f.fs.dirs.add(dir);
  f.fs.files.set(dir + '/icon_packs_backup.zip', 'new');
  f.fs.files.set(dir + '/icon_packs_sync_meta.json', '{"deviceId":"same"}');
  f.fs.files.set(dir + '/committed.json', '{}');
  f.fs.files.set(ZIP, 'other-legacy'); f.fs.files.set(CLOUD_META, '{"deviceId":"other"}');
  assert.equal(await f.icons.clearCloudBackupForDevices(['same'], undefined, false), true);
  assert.equal(f.fs.files.has(dir + '/icon_packs_backup.zip'), false);
  assert.equal(f.fs.files.get(ZIP), 'other-legacy');
  assert.equal(f.sync.calls, 1); f.assertReleased();
});

test('production temp directory reclamation before publish leaves old cloud generation intact', async () => {
  const f = fixture(); await f.bind(); seedBackup(f);
  const compress = f.archiver.compress.bind(f.archiver);
  f.archiver.compress = async (dir, path) => { await compress(dir, path); f.fs.files.delete(path); };
  assert.equal(await f.icons.backupIconPacks(), false);
  assert.equal(f.fs.files.get(ZIP), 'old-good-zip');
  assert.equal(f.fs.files.get(CLOUD_META), '{"timestamp":100}');
  assert.equal(f.fs.publishAttempts.length, 0);
  f.assertReleased();
});

test('production restore cleanup failure keeps result and old time; residual cleanup is exact and retryable', async () => {
  const f = fixture(); await f.bind(); seedRestore(f);
  f.fs.failDeleteFor.add(`${RESTORE}/user_icons/a.svg`);
  f.fs.files.set('/data/files/user_icons/existing.svg', 'existing');
  const result = await f.icons.restoreIconPacks();
  assert.equal(result.restoredFiles, 1); assert.equal(result.failedFiles, 1); partialOnly(f);
  assert.equal(f.fs.files.get('/data/files/user_icons/existing.svg'), 'existing');
  f.fs.failDeleteFor.clear();
  assert.equal((await f.icons.restoreIconPacks()).failedFiles, 0);
  assert.equal(f.settings.get('time'), '9000'); f.assertReleased();
});

for (const detailed of [false, true]) {
  test(`production errors use numeric allowlist only without reading sensitive text (detailed=${detailed})`, async () => {
    const f = fixture({ detailed }); await f.bind(); seedBackup(f);
    let sensitiveReads = 0;
    const error = { code: 13900012 };
    for (const field of ['message', 'stack', 'cause', 'toString', 'toJSON']) {
      Object.defineProperty(error, field, { get() { sensitiveReads++; throw new Error(PRIVATE); } });
    }
    f.fs.syncFile = async () => { throw error; };
    assert.equal(await f.icons.backupIconPacks(), false);
    assert.equal(sensitiveReads, 0); assertSafeLines(f, detailed);
    if (detailed) assert.ok(f.lines.some(line => line.includes('code=13900012')));
    f.assertReleased();
  });
}

// 运行既有 ETS suite（包括新回归），不调用 hvigor、不写 .test 产物、不碰设备。
const suiteFixture = fixture({ registerSuite: true });
for (const { name, body } of suiteFixture.cases) {
  test(`existing ETS icon suite: ${name}`, body);
}

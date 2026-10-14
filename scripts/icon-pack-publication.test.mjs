import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

const root = new URL('../', import.meta.url);
async function executable(path) {
  const source = await readFile(new URL(path, root), 'utf8');
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, '')
    .replace(/export\s+default\s+/g, ''), { mode: 'transform' }).replace(/\bexport\s+/g, '');
}
const files = ['common/src/main/ets/utils/CloudBackupDiagnostics.ets',
  'common/src/main/ets/utils/StoragePorts.ets', 'common/src/main/ets/utils/IconPackPublication.ets',
  'entry/src/test/fakes/BackupFakes.ets', 'entry/src/test/IconPackPublication.test.ets'];
const sources = await Promise.all(files.map(executable));
const cases = [];
const api = runInNewContext(sources.join('\n') + '\niconPackPublicationTest();\n({ MemoryFs, IconPackPublication, CloudBackupDiagnostics, DiagnosticKind });', {
  fs: {}, buffer: { from: (s, enc) => Buffer.from(s, enc) },
  hilog: { info() {} }, process: { pid: 1, tid: 1 },
  systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1 },
  describe: (_name, body) => body(), it: (name, _level, body) => cases.push({ name, body }),
  expect: actual => ({ assertEqual: expected => assert.equal(actual, expected),
    assertTrue: () => assert.equal(actual, true), assertFalse: () => assert.equal(actual, false) }),
});
for (const { name, body } of cases) test('production publication: ' + name, body);

// 两实例交错时，过期 GC 只操作全序更旧的独占代，不能删除后来发布代。
test('two publishers interleave stale cleanup without destroying the newest recoverable generation', async () => {
  const fs = new api.MemoryFs();
  const root = '/cloud/.icon_packs_generations';
  fs.dirs.add(root);
  const meta = timestamp => JSON.stringify({ version: 1, timestamp, deviceId: 'fixture', packs: [] });
  for (const [id, timestamp] of [['generation-AAAAAA', 1], ['generation-BBBBBB', 2]]) {
    const directory = root + '/' + id;
    fs.dirs.add(directory);
    fs.files.set(directory + '/icon_packs_backup.zip', 'old-' + timestamp);
    fs.files.set(directory + '/icon_packs_sync_meta.json', meta(timestamp));
    fs.files.set(directory + '/committed.json', JSON.stringify({ version: 1, id, timestamp, metadata: meta(timestamp) }));
  }
  fs.files.set('/temp/a.zip', 'A'); fs.files.set('/temp/b.zip', 'B');
  const publication = () => new api.IconPackPublication(fs, '/cloud',
    api.CloudBackupDiagnostics.begin(api.DiagnosticKind.ICON), async path => fs.files.has(path));
  let release, arrived;
  const paused = new Promise(resolve => { arrived = resolve; });
  const wait = new Promise(resolve => { release = resolve; });
  const remove = fs.deleteFile.bind(fs);
  let once = false;
  fs.deleteFile = async path => {
    if (!once && path === root + '/generation-AAAAAA/icon_packs_backup.zip') {
      once = true; arrived(); await wait;
    }
    return remove(path);
  };
  const a = publication().publish('/temp/a.zip', meta(3));
  await paused;
  assert.equal(await publication().publish('/temp/b.zip', meta(4)), true);
  release();
  assert.equal(await a, true);
  const snapshot = await publication().snapshot();
  assert.equal(fs.files.get(snapshot.zipPath), 'B');
  assert.ok(fs.files.has(root + '/generation-000001/icon_packs_backup.zip'));
  assert.ok(fs.files.has(root + '/generation-000002/icon_packs_backup.zip'));
});

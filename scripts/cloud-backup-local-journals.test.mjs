import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

// 本安装所有权凭据 journal（staging receipt 与 publication receipt）必须被系统备份/迁移
// 精确排除（docs §13 先例、openspec guard-against-zero-byte-orphan design D8）。
// 本测试回归两条契约：
// 1. backup_config.json 对每个 journal 目录给出 el1/el2/el5 × base/files、base/haps/*/files
//    的六种精确排除；禁止整 filesDir 排除（includes 不得被粗粒度排除替代）。
// 2. journal 目录名与生产代码常量一一对应：由真实转译的生产端口在合成 filesDir 上
//    计算出的 journal 路径必须等于 `<filesDir>/<配置的目录名>`，且非常规根拒绝构造。

async function executable(name) {
  const source = await readFile(new URL(`../common/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''), { mode: 'transform' })
    .replace(/\bexport\s+/g, '');
}

const [stagingCode, guardCode, storageCode, diagnosticCode] = await Promise.all([
  executable('CloudBackupStaging'), executable('CloudBackupPublicationGuard'),
  executable('StoragePorts'), executable('CloudBackupDiagnostics'),
]);

// 构造函数不触碰 fileIo；提供满足模块引用的最小全局即可实例化生产端口。
const sdk = {
  fs: { OpenMode: { READ_ONLY: 0o40000000, WRITE_ONLY: 0o20000000, CREATE: 0o1000, TRUNC: 0o100 } },
  buffer: { from: text => ({ length: text.length, readUInt8: () => 0 }) },
  console,
};
const api = runInNewContext(
  `${diagnosticCode}\n${storageCode}\n${stagingCode}\n${guardCode}
   ({NativeCloudBackupStagingPort, NativeCloudBackupPublicationPort,
     CLOUD_STAGE_JOURNAL, CLOUD_PUBLICATION_JOURNAL});`, sdk);

const FILES = '/synthetic/local/journal/files';
const stagingPort = new api.NativeCloudBackupStagingPort(FILES);
const publicationPort = new api.NativeCloudBackupPublicationPort(FILES);
const JOURNALS = new Map([
  ['staging receipt', api.CLOUD_STAGE_JOURNAL],
  ['publication receipt', api.CLOUD_PUBLICATION_JOURNAL],
]);

// 生产端口计算的 journal 路径（运行时事实来源）与导出常量一一对应。
assert.equal(stagingPort.journal, `${FILES}/${api.CLOUD_STAGE_JOURNAL}`);
assert.equal(publicationPort.journal, `${FILES}/${api.CLOUD_PUBLICATION_JOURNAL}`);

const LEVELS = ['el1', 'el2', 'el5'];
const SUBDIRS = ['files', 'haps/*/files'];
const configText = await readFile(
  new URL('../entry/src/main/resources/base/profile/backup_config.json', import.meta.url), 'utf8');
const config = JSON.parse(configText);

test('backup_config enables backup/restore and excludes exactly each local journal per level and subtree', () => {
  assert.equal(config.allowToBackupRestore, true);
  assert.ok(Array.isArray(config.includes) && config.includes.length > 0);
  assert.ok(Array.isArray(config.excludes) && config.excludes.length > 0);
  for (const [kind, journal] of JOURNALS) {
    assert.match(journal, /^\.cloud-backup-[a-z]+$/, `${kind} journal 必须是沙箱内点前缀专用目录`);
    for (const level of LEVELS) {
      for (const sub of SUBDIRS) {
        const expected = `data/storage/${level}/base/${sub}/${journal}/`;
        assert.ok(config.excludes.includes(expected),
          `缺少 ${kind} journal 的系统备份排除项: ${expected}`);
      }
    }
  }
});

test('excludes stay precise: journal-scoped only, unique, never whole filesDir or parent dirs', () => {
  const journalNames = [...JOURNALS.values()];
  const seen = new Set();
  for (const entry of config.excludes) {
    assert.equal(seen.has(entry), false, `excludes 存在重复项: ${entry}`);
    seen.add(entry);
    assert.match(entry, /^data\/storage\/el[1-5]\/base\/(?:files|haps\/\*\/files)\/\.cloud-backup-[a-z]+\/$/,
      `排除项必须是 el1/el2/el5 下 journal 专用目录，不得整目录排除: ${entry}`);
    assert.ok(journalNames.some(journal => entry.endsWith(`/${journal}/`)),
      `排除项不属于任何本地凭据 journal: ${entry}`);
  }
});

test('excludes only carve out directories that includes actually cover', () => {
  for (const entry of config.excludes) {
    const withoutJournal = entry.slice(0, entry.indexOf('/.cloud-backup-') + 1);
    assert.ok(config.includes.includes(withoutJournal),
      `排除父目录必须被 includes 覆盖，否则排除项形同虚设或越界: ${entry} -> ${withoutJournal}`);
  }
  assert.ok(config.includes.includes('data/storage/el2/base/files/'),
    'filesDir 本体必须保持包含（本测试禁止以整 filesDir 排除代替精确排除）');
});

test('native ports reject non-canonical journal roots (fail-closed) and pin configured names', () => {
  assert.throws(() => new api.NativeCloudBackupStagingPort('relative/path'), /INVALID_JOURNAL_ROOT/);
  assert.throws(() => new api.NativeCloudBackupPublicationPort('/bad\\path'), /INVALID_PUBLICATION_JOURNAL_ROOT/);
  assert.equal(stagingPort.journal.endsWith(`/${api.CLOUD_STAGE_JOURNAL}`), true);
  assert.equal(publicationPort.journal.endsWith(`/${api.CLOUD_PUBLICATION_JOURNAL}`), true);
});

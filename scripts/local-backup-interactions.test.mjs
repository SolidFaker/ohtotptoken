import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import test from 'node:test';

const root = '../';
const load = path => readFileSync(new URL(root + path, import.meta.url), 'utf8');
const common = 'common/src/main/ets/utils/';
const entry = 'entry/src/main/ets/';
const executable = text => stripTypeScriptTypes(text.replace(/^import\s[\s\S]*?;\r?\n/gm, '')
  .replace(/\bexport\s+/g, ''), { mode: 'transform' });

function nativeIo({ closeFails = false, readFails = false, shortWrite = 5 } = {}) {
  const calls = { closes: 0, writes: [], opens: 0, reads: 0 };
  const text = Buffer.from('合成🙂跨块内容'.repeat(50));
  let offset = 0;
  const sensitive = 'SYNTHETIC_PASSWORD_PATH_PLAIN_CIPHER';
  const fs = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    async open() { calls.opens++; return { fd: 5 }; },
    async read(fd, output) {
      assert.equal(fd, 5); calls.reads++;
      if (readFails) throw new Error(sensitive);
      const size = Math.min(2, text.length - offset);
      new Uint8Array(output).set(text.subarray(offset, offset + size));
      offset += size;
      return size;
    },
    async write(fd, bytes) {
      assert.equal(fd, 5);
      const count = Math.min(shortWrite, bytes.byteLength);
      calls.writes.push(...new Uint8Array(bytes, 0, count));
      return count;
    },
    async close(fd) { assert.equal(fd, 5); calls.closes++; if (closeFails) throw new Error(sensitive); },
  };
  const nativeBuffer = {
    from(value, encoding) {
      if (typeof value !== 'string') return Buffer.from(value);
      const encoded = Buffer.from(value, encoding);
      return { length: encoded.length, readUInt8: i => encoded.readUInt8(i),
        get buffer() { throw new Error('Do not assume backing-buffer layout'); },
        get byteOffset() { throw new Error('Do not assume pool offset'); } };
    }
  };
  const { LocalBackupFileIo } = runInNewContext(executable(load(common + 'LocalBackupFormat.ets')) +
    executable(load(common + 'LocalBackupFileIo.ets')) + '\n({ LocalBackupFileIo });', { fs, buffer: nativeBuffer });
  return { io: new LocalBackupFileIo(), calls, text: text.toString(), sensitive };
}

test('production local adapter uses exact UTF-8 bytes and completes short writes', async () => {
  const f = nativeIo();
  const text = '中文🙂\0'.repeat(12000);
  await f.io.writeText('synthetic', text);
  assert.deepEqual(Buffer.from(f.calls.writes), Buffer.from(text));
  assert.equal(f.calls.closes, 1);
});

test('production local adapter decodes only after full multi-byte read and successful close', async () => {
  const f = nativeIo();
  assert.equal(await f.io.readText('synthetic'), f.text);
  assert.equal(f.calls.closes, 1);
});

for (const mode of ['read', 'write']) {
  test(`${mode} close failure is fixed, private and closes exactly once`, async () => {
    const f = nativeIo({ closeFails: true });
    await assert.rejects(mode === 'read' ? f.io.readText(f.sensitive) : f.io.writeText(f.sensitive, f.sensitive), error => {
      assert.equal(error.message.includes(f.sensitive), false);
      assert.equal(error.cause, undefined);
      return true;
    });
    assert.equal(f.calls.closes, 1);
  });
}

test('local backup path contains no raw logs, hash helpers, clipboard or automatic deletion', () => {
  for (const name of ['LocalBackupFormat.ets', 'LocalBackupFileIo.ets', 'TokenBackup.ets']) {
    const text = load(common + name);
    assert.doesNotMatch(text, /hilog\.|console\.|\.message\b|\.stack\b|\.cause\b|copyText\(|pasteboard|unlink\(|writeFileContentCheckHashEqual/);
  }
  const page = load(entry + 'pages/setting/BackupAndMigrationSheet.ets');
  assert.doesNotMatch(page, /\.message\b|\.stack\b|\.cause\b|hilog\.|backup_select_uri|writeFileContent\(|importBackupWithProgress\(/);
  assert.match(page, /readLocalBackupSource\(/);
  assert.match(page, /commitPreparedBackup\(prepared, this.backupReload, report\)/);
  assert.match(page, /UriImportSheet, null\)/);
  assert.match(page, /\.bindSheet\(\$\$this.cloudDetailsVisible, this.CloudDetailsContent\(\), cloudBackupDetailsSheetOptions\(\)\)/);
  assert.doesNotMatch(page, /pushPathByName\(ROUTE_NAMES.ShowCloudSyncDetailsPage/);
});

test('two cloud pages share explicit safe default and three background layers without changing scaffold', () => {
  for (const name of ['ShowCloudSyncDetailsPage', 'ShowCloudBackupHistoryPage']) {
    const text = load(entry + `pages/${name}.ets`);
    assert.match(text, /@Param inMaterialSheet: boolean = false/);
    assert.match(text, /PageScaffold\(\{ bgColor: this.pageBackground\(\) \}\)/);
    assert.equal((text.match(/\.backgroundColor\(this.pageBackground\(\)\)/g) ?? []).length, 2);
    assert.match(text, /this.inMaterialSheet \? MaterialTheme.surfaceBackground/);
  }
  assert.match(load(entry + 'components/PageScaffold.ets'), /@Param bgColor: ResourceColor = \$r\('app.color.window_background'\)/);
  assert.match(load(entry + 'shell/SheetCoordinator.ets'), /options.backgroundColor = \$r\('app.color.window_background'\)/);
  assert.match(load(entry + 'pages/ShowCloudBackupHistoryPage.ets'), /options.backgroundColor = \$r\('app.color.window_background'\)/);
});

test('cloud details uses a bottom sheet with an isolated history stack and root close', () => {
  const sheet = load(entry + 'pages/setting/CloudBackupDetailsSheet.ets');
  assert.match(sheet, /MaterialSheetStyle.options\(\)/);
  assert.match(sheet, /private pageInfos: NavPathStack = new NavPathStack\(\)/);
  assert.match(sheet, /pushPathByName\(ROUTE_NAMES.ShowCloudSyncDetailsPage, null, false\)/);
  assert.match(sheet, /hideNavBar\(true\)/);
  assert.match(sheet, /sheetRoot: true/);
  assert.match(sheet, /ShowCloudBackupHistoryPage\(\{ scrollEffectType: this.scrollEffectType, inMaterialSheet: true \}\)/);
  assert.match(sheet, /this.pageInfos.clear\(\)/);
  const detail = load(entry + 'pages/ShowCloudSyncDetailsPage.ets');
  assert.match(detail, /@Param sheetRoot: boolean = false/);
  assert.match(detail, /if \(!this.sheetRoot\) \{ return false; \}\s*this.onCloseSheet\(\);\s*return true;/);
  assert.match(detail, /pushPathByName\(ROUTE_NAMES.ShowCloudBackupHistoryPage, null\)/);
  assert.match(load(entry + 'components/MaterialSheetStyle.ets'), /preferType: SheetType.BOTTOM/);
});

test('new resources are translated consistently with matching placeholders', () => {
  let expected;
  for (const locale of ['base', 'en_US', 'zh_CN', 'zh_TW']) {
    const strings = JSON.parse(load(`common/src/main/resources/${locale}/element/string.json`)).string
      .filter(item => item.name.startsWith('local_backup_'));
    const signatures = strings.map(item => [item.name, item.value.match(/%[ds]/g) ?? []]);
    if (expected) assert.deepEqual(signatures, expected); else expected = signatures;
    assert.equal(new Set(strings.map(item => item.name)).size, strings.length);
    assert.ok(strings.every(item => item.value.length > 0));
  }
});

test('menu cancellation classifier accepts only verified cancel and never forwards hostile errors', () => {
  const source = load(entry + 'utils/LocalBackupFlow.ets').replace(/@ObservedV2\s*/g, '').replace(/@Trace\s+/g, '');
  const { isLocalBackupMenuCancellation } = runInNewContext(executable(source) + '\n({ isLocalBackupMenuCancellation });');
  assert.equal(isLocalBackupMenuCancellation(new Error('cancel')), true);
  for (const code of [100001, '100001', 401, '401']) {
    assert.equal(isLocalBackupMenuCancellation({ code, message: 'SYNTHETIC_PRIVATE' }), false);
  }
  assert.equal(isLocalBackupMenuCancellation({ get code() { throw new Error('SYNTHETIC_PRIVATE'); } }), false);
  assert.equal(isLocalBackupMenuCancellation({ get message() { throw new Error('SYNTHETIC_PRIVATE'); } }), false);
  assert.doesNotMatch(source, /hilog\.|console\.|showSnackBar\(|pasteboard\.|AppStorage(?:V2)?\./);
});

test('password has no new import length restriction and retains explicit async submit buttons', () => {
  const text = load(entry + 'dialogs/EncryptionPassWordDialog.ets');
  assert.doesNotMatch(text, /\.maxLength\(|buttons:/);
  assert.match(text, /await this.submit\(password\)/);
  assert.match(text, /this.showConfirmPassword && this.textValue.length === 0/);
  assert.match(text, /local-backup-password-submit/);
  assert.match(text, /minHeight: 48/);
  const page = load(entry + 'pages/setting/BackupAndMigrationSheet.ets');
  assert.match(page, /accepted: \(\) => \{\s*this.afterPasswordClosed =/);
  assert.match(page, /onDidDisappear: \(\) => \{\s*const next = this.afterPasswordClosed;/);
  assert.match(page, /this.afterPasswordClosed = undefined;\s*next\?\.\(\);/);
  assert.match(page, /cancel: \(\) => \{\s*this.cancel\(generation\);\s*this.closePasswordDialog\(\);/);
});

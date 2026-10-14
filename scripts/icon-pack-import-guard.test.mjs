import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { createRequire } from 'node:module';
import zlib from 'node:zlib';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseDiagnosticLine } from './collect-cloud-backup-diagnostics.mjs';

// 只读离线回归：执行真实 IconPackZipReader / IconPackZipGate / IconPackImportDiag /
// SubItemIconManager.importIconPackFile 生产控制流（真实 jszip 库）。仅系统边界用内存端口。
// importIconPackFile 中的动态 import 在 vm 内以 __loadReader 解析到真实 reader 模块命名空间，
// 方法体其余逐字未改。

const jszipRoot = process.env.ICON_PACK_JSZIP_LIB
  ? pathToFileURL(resolve(process.env.ICON_PACK_JSZIP_LIB) + '/')
  : new URL('../entry/oh_modules/@ohos/jszip/src/main/core/jszip-master/', import.meta.url);
try {
  await readFile(new URL('lib/index.js', jszipRoot));
} catch (_) {
  throw new Error('Production JSZip core missing: install OH dependencies or run scripts/prepare-icon-pack-jszip.mjs and set ICON_PACK_JSZIP_LIB.');
}
const require2 = createRequire(jszipRoot);
const Module = await import('node:module');
const origLoad = Module.default._load;
let inflatedTotal = 0;
Module.default._load = function (request, parent, isMain) {
  if (request === 'setimmediate') { return (cb) => setTimeout(cb, 0); }
  if (request === 'pako') {
    class Inflate {
      constructor() { this.pending = []; this.produced = 0; this.onData = null; }
      push(data, end) {
        if (data && data.length) { this.pending.push(Buffer.from(data)); }
        if (!this.onData) { return; }
        const all = Buffer.concat(this.pending);
        let out;
        try {
          out = zlib.inflateRawSync(all, { finishFlush: zlib.constants.Z_SYNC_FLUSH });
        } catch (_) { return; }
        if (out.length > this.produced) {
          const fresh = out.subarray(this.produced);
          this.produced = out.length;
          inflatedTotal += fresh.length;
          this.onData(fresh);
        }
      }
    }
    class Deflate {
      constructor() { this.parts = []; this.onData = null; }
      push(data, end) { if (data && data.length) this.parts.push(Buffer.from(data)); if (end) this.onData(zlib.deflateRawSync(Buffer.concat(this.parts))); }
    }
    return { Inflate, Deflate };
  }
  return origLoad.call(this, request, parent, isMain);
};
const JSZip = require2('./lib/index.js');

const root = new URL('../', import.meta.url);
async function executable(path) {
  const source = await readFile(new URL(path, root), 'utf8');
  return stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, '')
    .replace(/export\s+default\s+/g, '').replace(/\bexport\s+/g, ''), { mode: 'transform' });
}
const diagSrc = await executable('common/src/main/ets/utils/CloudBackupDiagnostics.ets');
const gateSrc = await executable('common/src/main/ets/utils/IconPackZipGate.ets');
const diagHelperSrc = await executable('entry/src/main/ets/utils/IconPackImportDiag.ets');
const readerSrc = await executable('entry/src/main/ets/components/IconPackZipReader.ts');
const manager = await readFile(new URL('entry/src/main/ets/components/SubItemIconManager.ets', root), 'utf8');
const start = manager.indexOf('private installedPackInfos');
const end = manager.indexOf('private async rematchAndShowProgress');
const methods = manager.slice(start, end)
  .replaceAll('private ', '')
  .replace("await import('./IconPackZipReader')", 'await __loadReader()');
const componentJs = stripTypeScriptTypes(
  'class Impl {\n  constructor(icon_pack_dir) { this.icon_pack_dir = icon_pack_dir; }\n' +
  '  syncFromTokenIconPacks() {}\n' + methods + '\n}\n', { mode: 'transform' });

const PRIVATE = 'SYNTHETIC_PRIVATE_IMPORT_TEXT';
const ZIP_LIMITS = { maxMeta: 1024 * 1024 };

function crc32(buf) {
  let c, t = [];
  for (let n = 0; n < 256; n++) { c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c; }
  let r = 0xFFFFFFFF;
  for (const b of buf) r = t[(r ^ b) & 0xFF] ^ (r >>> 8);
  return (r ^ 0xFFFFFFFF) >>> 0;
}
const u16 = v => Buffer.from([v & 255, (v >> 8) & 255]);
const u32 = v => Buffer.from([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
// entries: [{ name(原始字节名), content, isDir, declared(谎报 uncompressedSize, 缺省=真实) }]
function buildZip(entries) {
  const locals = [], centrals = [];
  let off = 0;
  for (const e of entries) {
    const content = e.content ?? Buffer.alloc(0);
    const comp = e.isDir ? Buffer.alloc(0) : zlib.deflateRawSync(content);
    const crc = crc32(content);
    const declared = e.declared ?? content.length;
    const nb = Buffer.from(e.name, 'latin1');
    const dirBit = e.isDir ? 0x10 : 0;
    locals.push(Buffer.concat([
      Buffer.from('PK\x03\x04'), u16(20), u16(0), u16(8), u16(0), u16(0), u32(crc), u32(comp.length), u32(declared),
      u16(nb.length), u16(0), nb, comp]));
    centrals.push(Buffer.concat([
      Buffer.from('PK\x01\x02'), u16(20), u16(20), u16(0), u16(8), u16(0), u16(0), u32(crc), u32(comp.length),
      u32(declared), u16(nb.length), u16(0), u16(0), u16(0), u16(0), u32(dirBit << 24), u32(off), nb]));
    off += locals[locals.length - 1].length;
  }
  const cd = Buffer.concat(centrals);
  return Buffer.concat([...locals, cd, Buffer.from('PK\x05\x06'), u16(0), u16(0),
    u16(entries.length), u16(entries.length), u32(cd.length), u32(off), u16(0)]);
}

function makeWorld() {
  const files = new Map(), dirs = new Set(), fdTable = new Map(), zips = new Map();
  let nextFd = 1;
  const unlinks = [];
  const parent = p => p.slice(0, p.lastIndexOf('/'));
  const ensureParents = p => { let cur = p; const stack = []; while (cur && cur !== '/icon_packs') { stack.push(cur); cur = parent(cur); } for (const d of stack.reverse()) dirs.add(d); };
  const err = code => { const e = new Error('fs ' + code); e.code = code; return e; };
  let decompressCalls = 0;
  let decompressDelay = 0;
  const fs = {
    async stat(path) {
      if (files.has(path)) return { size: files.get(path).length, isDirectory: () => false };
      if (dirs.has(path)) return { size: 0, isDirectory: () => true };
      throw err(13900002);
    },
    readSync(fd, chunk, opts) {
      const data = files.get(fdTable.get(fd).path);
      const src = data.subarray(opts.offset, opts.offset + opts.length);
      new Uint8Array(chunk, 0, src.length).set(src);
      return src.length;
    },
    async mkdir(path) { if (dirs.has(path) || files.has(path)) throw err(13900015); dirs.add(path); },
    closeSync() {},
    async listFile(dir) {
      const names = new Set();
      for (const p of files.keys()) { if (p.startsWith(dir + '/')) { const rest = p.slice(dir.length + 1); if (rest) names.add(rest.split('/')[0]); } }
      for (const d of dirs) { if (d.startsWith(dir + '/') && d !== dir) names.add(d.slice(dir.length + 1).split('/')[0]); }
      if (!names.size && !dirs.has(dir)) throw err(13900002);
      return [...names];
    },
    async lstat(path) {
      if (files.has(path)) return { isDirectory: () => false, isSymbolicLink: () => false, size: files.get(path).length };
      if (dirs.has(path)) return { isDirectory: () => true, isSymbolicLink: () => false, size: 0 };
      throw err(13900002);
    },
    async unlink(path) { unlinks.push(path); if (!files.delete(path)) throw err(13900002); },
    async rmdir(path) {
      const hasContent = [...files.keys()].some(p => p.startsWith(path + '/')) || [...dirs].some(d => d.startsWith(path + '/') && d !== path);
      if (hasContent) throw err(13900032);
      dirs.delete(path);
    },
    async open(path) { if (!files.has(path)) throw err(13900002); const fd = nextFd++; fdTable.set(fd, { path }); return { fd, path }; },
  };
  const zlib = {
    async getOriginalSize(path) { return zips.get(path).reduce((a, e) => a + (e.declared ?? (e.content ?? Buffer.alloc(0)).length), 0); },
    async decompressFile(path, outDir) {
      decompressCalls++;
      if (decompressDelay > 0) { await new Promise(r => setTimeout(r, decompressDelay)); }
      for (const e of zips.get(path)) {
        if (e.isDir) { continue; }
        const target = outDir + '/' + e.name;
        ensureParents(target);
        files.set(target, e.content ?? Buffer.alloc(0));
      }
    },
  };
  // TokenIconPacks shim：注册语义逐行镜像 TokenUtils.ets:464-497（仅按 on_device_path 去重）。
  const TokenIconPacks = {
    aegis_icon_packs: [],
    async addAegisIconPack(path) {
      if (!files.has(path + '/pack.json')) {
        TokenIconPacks.aegis_icon_packs.push({ invalid: true, on_device_path: path, name: '', version: 0, icons: [] });
        return;
      }
      if (TokenIconPacks.aegis_icon_packs.some(p => p.on_device_path === path)) return;
      const tmp = JSON.parse(files.get(path + '/pack.json').toString());
      TokenIconPacks.aegis_icon_packs.push({ uuid: String(tmp.uuid ?? (tmp.name + '_' + path.split('/').pop())),
        name: tmp.name, version: tmp.version ?? 0, icons: [], invalid: false, on_device_path: path });
    },
    notifyChanged() {},
  };
  return { fs, zlib, TokenIconPacks, files, dirs, zips, unlinks, fdTable,
    stats: { get decompressCalls() { return decompressCalls; }, set delay(v) { decompressDelay = v; } } };
}

const PACK_JSON = name => JSON.stringify({ name, version: '1', icons: [] });
const snackbarCalls = [];
const hilogLines = [];

function baseSandbox(world) {
  return {
    JSZip, Promise, console, ArrayBuffer, Uint8Array, Object, Error, JSON,
    setTimeout, clearTimeout,
    process: { pid: 1, tid: 1 },
    systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1000 },
    hilog: {
      info: (_d, tag, _f, line) => hilogLines.push({ tag, line }),
      error: (_d, tag, _f, line) => hilogLines.push({ tag, line, isError: true }),
    },
    showSnackBar: msg => snackbarCalls.push(String(msg)),
    SnackBarNotifyType: { ERROR: 'ERROR' },
    $r: token => token,
    fs: world.fs, zlib: world.zlib, TokenIconPacks: world.TokenIconPacks,
    Date,
  };
}

function makeApi(world) {
  const sb = baseSandbox(world);
  const api = runInNewContext(
    [diagSrc, gateSrc, diagHelperSrc, readerSrc, componentJs,
      '(0,{ Impl, CloudBackupDiagnostics, IconPackGateRejectError, IconPackZipGateReject, IconPackImportMutex, readZipIndex })'].join('\n'),
    sb);
  api.CloudBackupDiagnostics.enable();
  const readerNs = Object.create(null);
  readerNs.readZipIndex = api.readZipIndex;
  sb.__loadReader = () => readerNs;
  const impl = new api.Impl('/icon_packs');
  impl.syncFromTokenIconPacks = () => {};
  return { api, impl, readerNs };
}

function assertDiagPrivacy(lines) {
  for (const { line, tag } of lines) {
    assert.equal(tag, 'CloudBackupDiag');
    assert.ok(parseDiagnosticLine('CloudBackupDiag: ' + line), 'line must pass collector allowlist: ' + line);
    assert.equal(/SYNTHETIC_PRIVATE|\/picker|\/icon_packs|rawError|\.svg|pack\.json/i.test(line), false, 'no raw paths/text: ' + line);
  }
}

function resetObservations() {
  snackbarCalls.length = 0;
  hilogLines.length = 0;
  inflatedTotal = 0;
}

function seed(world, filename, entries) {
  const zipBytes = buildZip(entries);
  world.files.set('/picker/' + filename, zipBytes);
  world.zips.set('/picker/' + filename, entries);
  world.dirs.add('/icon_packs');
}

async function importViaPicker(world, impl, filename) {
  const fd = await world.fs.open('/picker/' + filename);
  await impl.importIconPackFile(fd);
}

test('honest legacy pack with nested dirs imports and diag lines stay allowlisted', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  const entries = [{ name: 'pack.json', content: Buffer.from(PACK_JSON('aegis-legacy')) }];
  for (let i = 0; i < 20; i++) { entries.push({ name: `icons/set${i}/icon.svg`, content: Buffer.from(`<svg>${i}</svg>`) }); }
  seed(world, 'aegis-legacy.zip', entries);
  await importViaPicker(world, impl, 'aegis-legacy.zip');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 1);
  assert.equal(world.TokenIconPacks.aegis_icon_packs[0].name, 'aegis-legacy');
  assert.equal(snackbarCalls.length, 0);
  assert.equal(hilogLines.some(l => l.line.includes('result=FAIL')), false, 'success must not emit failure lines');
  assertDiagPrivacy(hilogLines);
});

test('raw parent traversal in FILE entry rejected before any write', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl, api } = makeApi(world);
  seed(world, 'smug.zip', [
    { name: 'x/../pack.json', content: Buffer.from(PACK_JSON('Smuggled')) },
    { name: 'icon.svg', content: Buffer.from('x') },
  ]);
  await importViaPicker(world, impl, 'smug.zip');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 0);
  assert.equal([...world.dirs].some(d => d.includes('/icon_packs/smug.zip')), false, 'no directory created');
  assert.equal(world.stats.decompressCalls, 0, 'zero extraction');
  assert.equal(snackbarCalls[0], 'app.string.icon_pack_import_reject_unsafe_path');
  assert.ok(!api.IconPackImportMutex.isHeld());
  assertDiagPrivacy(hilogLines);
});

test('raw parent traversal in DIRECTORY entry rejected (unsafeOriginalName does not cover dirs)', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  seed(world, 'dirsmug.zip', [
    { name: 'pack.json', content: Buffer.from(PACK_JSON('Good')) },
    { name: '../evil/', isDir: true },
    { name: 'icon.svg', content: Buffer.from('x') },
  ]);
  await importViaPicker(world, impl, 'dirsmug.zip');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 0);
  assert.equal(world.stats.decompressCalls, 0);
  assert.equal(snackbarCalls[0], 'app.string.icon_pack_import_reject_unsafe_path');
  assertDiagPrivacy(hilogLines);
});

test('honest oversize declared pack.json rejected with zero inflation', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  seed(world, 'bigmeta.zip', [
    { name: 'pack.json', content: Buffer.alloc(4 * 1024 * 1024, 0x41) },
  ]);
  await importViaPicker(world, impl, 'bigmeta.zip');
  assert.equal(snackbarCalls[0], 'app.string.icon_pack_import_reject_file_too_large');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 0);
  assert.equal(inflatedTotal, 0, 'declared-stage rejection must inflate nothing');
  assertDiagPrivacy(hilogLines);
});

test('lying declared pack.json is stopped mid-inflation below the actual size', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  // 实际 4MB 伪随机内容（压缩后 ~2MB，非紧炸弹）：中央目录谎报 uncompressedSize=10。
  const actual = Buffer.alloc(4 * 1024 * 1024);
  let state = 12345;
  for (let i = 0; i < actual.length; i++) { state = (state * 1103515245 + 12345) & 0x7fffffff; actual[i] = state & 0xff; }
  seed(world, 'lyingmeta.zip', [
    { name: 'pack.json', content: actual, declared: 10 },
  ]);
  await importViaPicker(world, impl, 'lyingmeta.zip');
  assert.equal(snackbarCalls[0], 'app.string.icon_pack_import_reject_file_too_large');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 0);
  assert.ok(inflatedTotal > 0, 'some inflation happened before the abort');
  assert.ok(inflatedTotal < actual.length, `abort before full expansion: ${inflatedTotal} < ${actual.length}`);
  assert.ok(inflatedTotal < ZIP_LIMITS.maxMeta + 512 * 1024, `abort near the 1MB hard limit: ${inflatedTotal}`);
  assertDiagPrivacy(hilogLines);
});

test('concurrent duplicate imports serialize via process mutex', async () => {
  resetObservations();
  const world = makeWorld();
  world.stats.delay = 30;
  const { impl } = makeApi(world);
  seed(world, 'a.zip', [
    { name: 'pack.json', content: Buffer.from(PACK_JSON('Same')) },
    { name: 'a.svg', content: Buffer.from('a') },
  ]);
  seed(world, 'b.zip', [
    { name: 'pack.json', content: Buffer.from(PACK_JSON('Same')) },
    { name: 'b.svg', content: Buffer.from('b') },
  ]);
  const run = name => world.fs.open('/picker/' + name).then(fd => impl.importIconPackFile(fd));
  const first = run('a.zip');
  const second = run('b.zip');
  await Promise.all([first, second]);
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 1, 'only the mutex holder registers');
  assert.equal(world.stats.decompressCalls, 1, 'busy import never starts extracting');
  assert.ok(snackbarCalls.some(m => m === 'app.string.cloud_backup_operation_busy'), 'busy snackbar shown');
  // 释放后可继续导入不同版本。
  seed(world, 'v2.zip', [
    { name: 'pack.json', content: Buffer.from(JSON.stringify({ name: 'Same', version: '2', icons: [] })) },
  ]);
  await importViaPicker(world, impl, 'v2.zip');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 2);
  assertDiagPrivacy(hilogLines);
});

test('sequential same-version reimport rejected, other version allowed', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  seed(world, 'one.zip', [{ name: 'pack.json', content: Buffer.from(PACK_JSON('P')) }]);
  seed(world, 'two.zip', [{ name: 'pack.json', content: Buffer.from(PACK_JSON('P')) }]);
  seed(world, 'three.zip', [{ name: 'pack.json', content: Buffer.from(JSON.stringify({ name: 'P', version: '2', icons: [] })) }]);
  await importViaPicker(world, impl, 'one.zip');
  await importViaPicker(world, impl, 'two.zip');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 1);
  assert.equal(snackbarCalls.at(-1), 'app.string.icon_pack_import_reject_duplicate');
  await importViaPicker(world, impl, 'three.zip');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 2);
  assertDiagPrivacy(hilogLines);
});

test('createdDir ownership: leftover dir blocks import and is never deleted', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  seed(world, 'leftover.zip', [{ name: 'pack.json', content: Buffer.from(PACK_JSON('X')) }]);
  world.dirs.add('/icon_packs/leftover.zip');
  world.files.set('/icon_packs/leftover.zip/SENTINEL', Buffer.from('keep'));
  const dirsBefore = world.dirs.size;
  await importViaPicker(world, impl, 'leftover.zip');
  assert.equal(world.dirs.size, dirsBefore, 'leftover dir untouched');
  assert.equal(world.files.get('/icon_packs/leftover.zip/SENTINEL')?.toString(), 'keep');
  assert.equal(world.unlinks.filter(p => p.startsWith('/icon_packs/leftover.zip')).length, 0, 'no deletions inside foreign dir');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 0);
  assertDiagPrivacy(hilogLines);
});

test('privacy sentinel: hostile error objects are never read beyond numeric code', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  let sensitiveReads = 0;
  world.fs.stat = async () => {
    const error = { code: 13900012 };
    for (const field of ['message', 'stack', 'cause', 'toString', 'toJSON']) {
      Object.defineProperty(error, field, { get() { sensitiveReads++; throw new Error(PRIVATE); } });
    }
    throw error;
  };
  seed(world, 'hostile.zip', [{ name: 'pack.json', content: Buffer.from(PACK_JSON('H')) }]);
  await importViaPicker(world, impl, 'hostile.zip');
  assert.equal(sensitiveReads, 0, 'no sensitive member reads');
  assert.equal(snackbarCalls[0], 'app.string.icon_pack_import_reject_io', 'unknown failure uses fixed IO_ERROR copy');
  assert.equal(world.TokenIconPacks.aegis_icon_packs.length, 0);
  const failLines = hilogLines.filter(l => l.line.includes('result=FAIL'));
  assert.ok(failLines.some(l => l.line.includes('code=13900012')), 'numeric code surfaced: ' + JSON.stringify(failLines.map(l => l.line)));
  assertDiagPrivacy(hilogLines);
});

test('gate rejection reason reaches diagnostics as fixed enum mapping', async () => {
  resetObservations();
  const world = makeWorld();
  const { impl } = makeApi(world);
  seed(world, 'nometa.zip', [{ name: 'icon.svg', content: Buffer.from('x') }]);
  await importViaPicker(world, impl, 'nometa.zip');
  assert.equal(snackbarCalls[0], 'app.string.icon_pack_import_reject_missing_meta');
  assert.ok(hilogLines.some(l => l.line.includes('result=FAIL') && l.line.includes('reason=INVALID_FORMAT')),
    'INVALID_FORMAT expected, got: ' + JSON.stringify(hilogLines.map(l => l.line)));
  assertDiagPrivacy(hilogLines);
});

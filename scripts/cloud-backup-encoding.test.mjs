import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';

const source = await readFile(new URL('../common/src/main/ets/utils/StoragePorts.ets', import.meta.url), 'utf8');
const executable = stripTypeScriptTypes(source.replace(/^import\s[\s\S]*?;\r?\n/gm, ''), { mode: 'transform' })
  .replace(/\bexport\s+/g, '');

function setup(layout, options = {}) {
  let offset = options.initialOffset ?? 8;
  let copiedBufferReads = 0;
  let offsetReads = 0;
  const writes = [];
  const closes = [];
  const files = new Map();
  const moves = [];
  const native = {
    from(text, encoding) {
      assert.equal(typeof text, 'string');
      const bytes = Buffer.from(text, encoding);
      const poolOffset = offset;
      offset += Math.ceil(Math.max(bytes.length, 1) / 8) * 8;
      const backing = new Uint8Array(poolOffset + bytes.length + 8);
      backing.fill(0xf7);
      backing.set(bytes, poolOffset);
      return {
        length: bytes.length,
        readUInt8(index) { return bytes.readUInt8(index); },
        get byteOffset() {
          offsetReads++;
          if (options.forbidViewProperties) throw new Error('POOL_OFFSET_NOT_A_CONTENT_OFFSET');
          return poolOffset;
        },
        get buffer() {
          copiedBufferReads++;
          if (options.forbidViewProperties) throw new Error('BACKING_SEMANTICS_MUST_NOT_BE_ASSUMED');
          // ArkTS from(string) may copy only logical bytes while byteOffset still names the pool.
          return layout === 'copied' ? Uint8Array.from(bytes).buffer : backing.buffer;
        },
      };
    },
  };
  const fs = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    openSync(path) { files.set(path, []); return { fd: 1 }; },
    writeSync(fd, bytes) {
      assert.equal(fd, 1);
      const snapshot = Array.from(new Uint8Array(bytes));
      writes.push(snapshot);
      return bytes.byteLength;
    },
    closeSync(fd) { closes.push(fd); },
    async mkdtemp() { return '/synthetic/cloud/owned-stage'; },
    async moveFile(from, to, mode) { moves.push({ mode }); },
    async unlink() {},
    async rmdir() {},
  };
  const api = runInNewContext(`${executable}\n({ NativeFileIoWritePort, FileIoFsGateway });`, { buffer: native, fs });
  return { writer: new api.NativeFileIoWritePort(), gateway: new api.FileIoFsGateway(),
    writes, closes, moves, copiedBufferReads: () => copiedBufferReads, offsetReads: () => offsetReads };
}

for (const layout of ['copied', 'shared']) {
  test(`production encoder copies logical bytes for ${layout} backing with a nonzero pool offset`, () => {
    const fixture = setup(layout);
    for (const text of ['probe', 'A中é🔒', '', 'second pooled string']) {
      assert.deepEqual(Array.from(fixture.writer.encodeText(text)), Array.from(Buffer.from(text, 'utf8')));
    }
  });
}

test('production encoder never reads incompatible Buffer view properties', () => {
  const fixture = setup('copied', { forbidViewProperties: true });
  assert.deepEqual(Array.from(fixture.writer.encodeText('fixture')), Array.from(Buffer.from('fixture')));
  assert.equal(fixture.copiedBufferReads(), 0);
  assert.equal(fixture.offsetReads(), 0);
});

test('production encoder handles repeated allocations, NUL, surrogate replacement and large text', () => {
  const fixture = setup('copied', { initialOffset: 0 });
  for (const text of ['seed', 'next', '\0inside\0', '\ud800', '\udc00', '合成🧪'.repeat(12000)]) {
    assert.deepEqual(Array.from(fixture.writer.encodeText(text)), Array.from(Buffer.from(text, 'utf8')));
  }
});

test('production gateway reaches native open and writes exact UTF-8 bytes after pooled encoding', async () => {
  const fixture = setup('copied');
  const text = 'synthetic encrypted-envelope text';
  await fixture.gateway.writeTextFile('/synthetic/cloud/pending.tmp', text);
  assert.deepEqual(fixture.writes.flat(), Array.from(Buffer.from(text)));
  assert.deepEqual(fixture.closes, [1]);
});

test('production staging path is no longer blocked by pooled Buffer conversion', async () => {
  const fixture = setup('copied');
  const text = 'synthetic.header.payload';
  await fixture.gateway.writeNewTextFile('/synthetic/cloud/pending.tmp', text);
  assert.deepEqual(fixture.writes.flat(), Array.from(Buffer.from(text)));
  assert.deepEqual(fixture.moves, [{ mode: 1 }]);
  assert.deepEqual(fixture.closes, [1]);
});

import JSZip from '@ohos/jszip';

const META_LIMIT = 1024 * 1024;

function randomBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  let state = 123456789;
  for (let i = 0; i < length; i++) {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    bytes[i] = state >>> 24;
  }
  return bytes;
}

function readU32(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16 | bytes[offset + 3] << 24) >>> 0;
}

function writeU32(bytes: Uint8Array, offset: number, value: number): void {
  for (let i = 0; i < 4; i++) bytes[offset + i] = value >>> (8 * i) & 255;
}

/** 合成单条目 ZIP：只修改声明长度，压缩流保留真实输出，供流式上限验收。 */
function understateMetadata(bytes: ArrayBuffer): ArrayBuffer {
  const data = new Uint8Array(bytes);
  if (readU32(data, 0) !== 0x04034b50) throw new Error('IMPORT_FIXTURE_HEADER_INVALID');
  writeU32(data, 22, 16);
  const eocd = data.length - 22;
  if (readU32(data, eocd) !== 0x06054b50) throw new Error('IMPORT_FIXTURE_HEADER_INVALID');
  const central = readU32(data, eocd + 16);
  if (readU32(data, central) !== 0x02014b50) throw new Error('IMPORT_FIXTURE_HEADER_INVALID');
  writeU32(data, central + 24, 16);
  return bytes;
}

export async function makeImportFixture(kind: string): Promise<ArrayBuffer> {
  const zip = new JSZip();
  const meta = JSON.stringify({ name: 'Synthetic Import Fixture', version: '1', icons: [] });
  switch (kind) {
    case 'valid':
      zip.file('pack.json', meta, { createFolders: false });
      zip.file('icons/fixture.svg', '<svg xmlns="http://www.w3.org/2000/svg"><text>synthetic</text></svg>');
      break;
    case 'file-path':
      zip.file('x/../pack.json', meta, { createFolders: false });
      break;
    case 'directory-path':
      zip.file('pack.json', meta, { createFolders: false });
      zip.file('../foreign/', null, { dir: true, createFolders: false });
      break;
    case 'declared-meta':
      zip.file('pack.json', randomBytes(META_LIMIT + 128 * 1024), { createFolders: false });
      break;
    case 'actual-meta':
      zip.file('pack.json', randomBytes(2 * META_LIMIT), { createFolders: false });
      break;
    default:
      throw new Error('IMPORT_FIXTURE_KIND_INVALID');
  }
  const bytes = await zip.generateAsync({ type: 'arraybuffer', compression: 'DEFLATE' });
  return kind === 'actual-meta' ? understateMetadata(bytes) : bytes;
}

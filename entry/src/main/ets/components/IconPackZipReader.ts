import JSZip from '@ohos/jszip';

/**
 * jszip（@ohos/jszip）互操作薄封装。放在 entry 模块的 .ts 是刻意的：jszip 类型宽松（条目大小在
 * 私有 _data 上），且 TS 文件不能导入 ArkTS 模块，故此处自带条目/索引结构定义，由调用方
 * （SubItemIconManager.ets）映射到 common 的门控入参；common 导出链不含 jszip，LocalUnit
 * 不加载其运行时。
 *
 * 除 jszip 归一化索引外，本封装还直接解析原始中央目录（ZIP64 兼容，解析失败一律抛错 fail-closed）：
 * jszip 的归一化 map 会消解 `..`/`.` 段，且 unsafeOriginalName 只对文件条目保留（load.js 对目录
 * 条目不赋值），同名归一化还会互相覆盖——`x/../pack.json`、`../evil/` 这类原始路径只能在这里看到。
 * pack.json 内容读取改为 jszip internalStream 流式读取：累计真实输出字节超过上限即 pause 整条
 * worker 链（GenericWorker.pause 递归暂停到 DataWorker 源头）并拒绝——不再 async 全量展开后拒。
 */

export interface ZipIndexEntry {
  relativePath: string;
  sizeBytes: number;
  isDirectory: boolean;
}

/** 原始中央目录条目：文件与目录都保留原始字节路径，供 common 门控做原始路径审计。 */
export interface ZipRawIndexEntry {
  rawName: string;
  sizeBytes: number;
  isDirectory: boolean;
}

export interface ZipIndex {
  /** 全部条目（文件 + 目录），路径为 jszip 归一化后的名称——只用于限额/根级 pack.json 判定。 */
  entries: ZipIndexEntry[];
  /** 原始中央目录条目（含目录条目的原始路径），供 gateZipRawEntries 审计。 */
  rawEntries: ZipRawIndexEntry[];
  /** 根级 pack.json 的文本内容；不存在时为 null。 */
  packJsonContent: string | null;
}

/** jszip 未公开的压缩元数据（中央目录声明值，含 uncompressedSize）。 */
interface ZipPrivateData {
  _data?: {
    uncompressedSize?: number;
  };
}

interface JsZipObjectLike {
  internalStream: (type: string) => StreamHelperLike;
}

interface StreamHelperLike {
  on: (event: string, listener: (payload: never) => void) => StreamHelperLike;
  pause: () => void;
  resume: () => void;
}

/** pack.json 文本读取上限：合法 Aegis 包的 pack.json 为 KB 级；上限既拦诚实声明（零膨胀快速拒绝），也由流式真实字节硬限兜住谎报声明。 */
const MAX_META_BYTES = 1024 * 1024;
/** EOCD 定位扫描窗口：固定 22 字节 + 注释上限 65535。 */
const EOCD_SCAN_BYTES = 22 + 65535;
const EOCD_MIN_BYTES = 22;
const ZIP64_LOCATOR_BYTES = 20;
const CENTRAL_HEADER_BYTES = 46;
const U16_MAX = 0xFFFF;
const U32_MAX = 0xFFFFFFFF;

function u16At(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function u32At(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0);
}

function u64At(bytes: Uint8Array, offset: number): number {
  return u32At(bytes, offset) + u32At(bytes, offset + 4) * 0x100000000;
}

function matchSig(bytes: Uint8Array, offset: number, a: number, b: number, c: number, d: number): boolean {
  return bytes[offset] === a && bytes[offset + 1] === b && bytes[offset + 2] === c && bytes[offset + 3] === d;
}

/** 非法序列以 U+FFFD 替换：路径审计是结构级检查（/ . \ NUL 的 ASCII 字节在任何编码下不变），UTF-8 解码只需保真 ASCII 骨架。 */
function decodeUtf8Bytes(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length;) {
    const lead = bytes[i];
    if (lead < 0x80) { out += String.fromCharCode(lead); i += 1; continue; }
    let codePoint = 0;
    let extra = 0;
    if (lead >= 0xC2 && lead <= 0xDF) { codePoint = lead & 0x1F; extra = 1; }
    else if (lead >= 0xE0 && lead <= 0xEF) { codePoint = lead & 0x0F; extra = 2; }
    else if (lead >= 0xF0 && lead <= 0xF4) { codePoint = lead & 0x07; extra = 3; }
    else { out += String.fromCharCode(0xFFFD); i += 1; continue; }
    let valid = i + extra < bytes.length;
    for (let k = 1; k <= extra; k++) {
      const cont = bytes[i + k];
      if ((cont & 0xC0) !== 0x80) { valid = false; break; }
      codePoint = (codePoint << 6) | (cont & 0x3F);
    }
    if (!valid) { out += String.fromCharCode(0xFFFD); i += 1; continue; }
    if (codePoint > 0xFFFF) {
      const rest = codePoint - 0x10000;
      out += String.fromCharCode(0xD800 + (rest >> 10), 0xDC00 + (rest & 0x3FF));
    } else {
      out += String.fromCharCode(codePoint);
    }
    i += extra + 1;
  }
  return out;
}

/**
 * 条目名字节解码：UTF-8 标志位走 UTF-8；否则按 latin1 逐字节保真。
 * latin1 视图下 UTF-8 多字节序列呈现为高位乱码字符，但 / . \ NUL 的 ASCII 字节不受影响，
 * 对 `..`/反斜杠/NUL/绝对路径的结构审计而言比猜测编码更保真。
 */
function decodeNameBytes(nameBytes: Uint8Array, utf8Flag: boolean): string {
  if (!utf8Flag) {
    let out = '';
    for (let i = 0; i < nameBytes.length; i++) {
      out += String.fromCharCode(nameBytes[i]);
    }
    return out;
  }
  return decodeUtf8Bytes(nameBytes);
}

/**
 * 直接解析原始中央目录（EOCD → [ZIP64 EOCD] → 中央记录序列）。
 * 任何不一致（签名缺失、越界、ZIP64 无法定位）一律抛错由调用方按损坏 zip 归类：合法 Aegis 包
 * 从不触发这些分支；审计数据不可得时门控宁拒不漏。
 */
function parseRawCentralDirectory(bytes: Uint8Array): ZipRawIndexEntry[] {
  const scanStart = Math.max(0, bytes.length - EOCD_SCAN_BYTES);
  let eocd = -1;
  for (let i = bytes.length - EOCD_MIN_BYTES; i >= scanStart; i--) {
    if (matchSig(bytes, i, 0x50, 0x4b, 0x05, 0x06)) { eocd = i; break; }
  }
  if (eocd < 0) { throw new Error('ICON_PACK_ZIP_INDEX_UNREADABLE'); }
  let entryCount = u16At(bytes, eocd + 10);
  let cdOffset = u32At(bytes, eocd + 16);
  if (cdOffset === U32_MAX || entryCount === U16_MAX) {
    const locator = eocd - ZIP64_LOCATOR_BYTES;
    if (locator < 0 || !matchSig(bytes, locator, 0x50, 0x4b, 0x06, 0x07)) {
      throw new Error('ICON_PACK_ZIP_INDEX_UNREADABLE');
    }
    const z64Offset = u64At(bytes, locator + 8);
    if (z64Offset + 56 > bytes.length || !matchSig(bytes, z64Offset, 0x50, 0x4b, 0x06, 0x06)) {
      throw new Error('ICON_PACK_ZIP_INDEX_UNREADABLE');
    }
    entryCount = u64At(bytes, z64Offset + 32);
    cdOffset = u64At(bytes, z64Offset + 48);
  }
  const rawEntries: ZipRawIndexEntry[] = [];
  let pos = cdOffset;
  for (let index = 0; index < entryCount; index++) {
    if (pos + CENTRAL_HEADER_BYTES > bytes.length || !matchSig(bytes, pos, 0x50, 0x4b, 0x01, 0x02)) {
      throw new Error('ICON_PACK_ZIP_INDEX_UNREADABLE');
    }
    const flags = u16At(bytes, pos + 8);
    const uncompressedSize = u32At(bytes, pos + 24);
    const nameLen = u16At(bytes, pos + 28);
    const extraLen = u16At(bytes, pos + 30);
    const commentLen = u16At(bytes, pos + 32);
    const externalAttrs = u32At(bytes, pos + 38);
    const nameStart = pos + CENTRAL_HEADER_BYTES;
    if (nameStart + nameLen > bytes.length) { throw new Error('ICON_PACK_ZIP_INDEX_UNREADABLE'); }
    const rawName = decodeNameBytes(bytes.subarray(nameStart, nameStart + nameLen), (flags & 0x0800) !== 0);
    const isDirectory = rawName.charAt(rawName.length - 1) === '/' || (externalAttrs & 0x10) !== 0;
    const item: ZipRawIndexEntry = { rawName: rawName, sizeBytes: uncompressedSize, isDirectory: isDirectory };
    rawEntries.push(item);
    pos = nameStart + nameLen + extraLen + commentLen;
  }
  return rawEntries;
}

function concatBytes(chunks: Uint8Array[], total: number): Uint8Array {
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

/** 固定 token 错误（字面量逐处构造：调用方只读 error.name 分类，不读异常文本）。 */
function metaTooLargeError(): Error {
  const error = new Error('ICON_PACK_META_TOO_LARGE');
  error.name = 'ICON_PACK_META_TOO_LARGE';
  return error;
}

/**
 * 流式读取条目并按真实输出字节硬限：超过上限立即 pause 整条 worker 链
 * （GenericWorker.pause 递归到 DataWorker 源头，不再产生后续输出）并拒绝。
 * 与 `entry.async('string')` 的本质区别：jszip 的声明长度校验只在 end 阶段比较，
 * 谎报小声明的条目会被全量展开后再拒；本函数在展开途中按真实字节截停。
 */
function readEntryBounded(entry: JSZip.JSZipObject, maxBytes: number): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve: (value: Uint8Array) => void, reject: (reason: Error) => void) => {
    const chunks: Uint8Array[] = [];
    let total = 0;
    let settled = false;
    const helper: StreamHelperLike = (entry as unknown as JsZipObjectLike).internalStream('uint8array');
    helper.on('data', (chunk: Uint8Array) => {
      if (settled) { return; }
      total += chunk.length;
      if (total > maxBytes) {
        settled = true;
        helper.pause();
        reject(metaTooLargeError());
        return;
      }
      chunks.push(chunk);
    });
    helper.on('error', (error: Error) => {
      if (!settled) { settled = true; reject(error); }
    });
    helper.on('end', () => {
      if (!settled) { settled = true; resolve(concatBytes(chunks, total)); }
    });
    helper.resume();
  });
}

/** 读取 zip 索引。非 ZIP/损坏/原始中央目录不可解析时按 JSZip/解析异常原样抛出（调用方归 NOT_ZIP_OR_DAMAGED）。 */
export async function readZipIndex(bytes: ArrayBuffer): Promise<ZipIndex> {
  const rawEntries = parseRawCentralDirectory(new Uint8Array(bytes));
  const zip = await JSZip.loadAsync(bytes);
  const entries: ZipIndexEntry[] = [];
  let packEntry: JSZip.JSZipObject | null = null;
  zip.forEach((relativePath: string, file: JSZip.JSZipObject) => {
    const sizeBytes = file.dir ? 0 : ((file as unknown as ZipPrivateData)._data?.uncompressedSize ?? 0);
    const entry: ZipIndexEntry = { relativePath: relativePath, sizeBytes: sizeBytes, isDirectory: file.dir };
    entries.push(entry);
    if (!file.dir && relativePath === 'pack.json') {
      packEntry = file;
    }
  });
  let packJsonContent: string | null = null;
  if (packEntry !== null) {
    const target = packEntry as JSZip.JSZipObject;
    // 诚实声明超限：零膨胀快速拒绝；谎报声明由 readEntryBounded 的真实字节硬限截停。
    const declared = (target as unknown as ZipPrivateData)._data?.uncompressedSize ?? 0;
    if (declared > MAX_META_BYTES) {
      throw metaTooLargeError();
    }
    packJsonContent = decodeUtf8Bytes(await readEntryBounded(target, MAX_META_BYTES));
  }
  const index: ZipIndex = { entries: entries, rawEntries: rawEntries, packJsonContent: packJsonContent };
  return index;
}

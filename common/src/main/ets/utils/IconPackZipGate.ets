import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 图标包 zip 导入门控（2026-10-13 真机发现：无 pack.json 的 zip 导入会静默注册
 * invalid 条目并把解压产物永久残留于 icon_packs，见 docs/testing/cloud-backup-diagnostics.md）。
 *
 * 四段门控：
 * 1. 解压前·格式与总体积：`zlib.getOriginalSize`（API 12）校验 ZIP 有效性与未压缩总体积，
 *    损坏/非 ZIP 抛 900003——零写入；
 * 2. 解压前·原始中央目录：readZipIndex 直接解析原始字节（文件与目录都保留原始路径），
 *    `..`/反斜杠/NUL/绝对路径/深度在原始路径层拦截——jszip 归一化不可见、目录条目无
 *    unsafeOriginalName，均零写入；
 * 3. 解压前·归一化中央目录（@ohos/jszip，经 IconPackZipReader.ts 薄封装读取）：pack.json
 *    存在并可解析、文件数/单文件/总体积限额、同名同版本重复导入拒绝——仍零写入；
 *    pack.json 读取为流式真实字节硬限（超限即 pause 整条 worker 链），谎报小声明的
 *    条目在展开途中截停而非全量展开后拒；
 * 4. 解压后·落盘校验：对解压目标目录复扫（符号链接、真实落地内容）作为纵深防御。
 * 任何一段不过都不进入注册表，且失败只回收本操作创建的目录。
 * 条目级 zip-slip 由平台 decompressFile 的 "../" 拦截（错误 900003）兜底。
 */

export enum IconPackZipGateReject {
  UNKNOWN = 'UNKNOWN',
  NOT_ZIP_OR_DAMAGED = 'NOT_ZIP_OR_DAMAGED',
  TOO_LARGE_TOTAL = 'TOO_LARGE_TOTAL',
  MISSING_PACK_META = 'MISSING_PACK_META',
  INVALID_PACK_META = 'INVALID_PACK_META',
  DUPLICATE_NAME_VERSION = 'DUPLICATE_NAME_VERSION',
  ENTRY_OVERFLOW = 'ENTRY_OVERFLOW',
  FILE_TOO_LARGE = 'FILE_TOO_LARGE',
  UNSAFE_ENTRY_PATH = 'UNSAFE_ENTRY_PATH',
  IO_ERROR = 'IO_ERROR'
}

export interface IconPackZipGateVerdict {
  ok: boolean;
  reject: IconPackZipGateReject;
}

export interface IconPackZipEntryInfo {
  relativePath: string;
  sizeBytes: number;
  isDirectory: boolean;
}

/** 已安装图标包的身份摘要（用于同名同版本重复导入判定）。 */
export interface InstalledPackInfo {
  name: string;
  version: string;
}

/** 拦截阈值：aegis 图标包实测约 1MB/千文件，阈值放宽一个数量级以上，只拦滥用与解压炸弹。 */
export class IconPackZipGateLimits {
  static readonly MAX_TOTAL_UNCOMPRESSED_BYTES = 64 * 1024 * 1024;
  static readonly MAX_COMPRESSED_BYTES = 32 * 1024 * 1024;
  static readonly MAX_EXTRACTED_FILE_COUNT = 4096;
  static readonly MAX_SINGLE_FILE_BYTES = 8 * 1024 * 1024;
  static readonly REQUIRED_META_NAME = 'pack.json';
  static readonly MAX_ENTRY_DEPTH = 16;
}

function allow(): IconPackZipGateVerdict {
  const verdict: IconPackZipGateVerdict = { ok: true, reject: IconPackZipGateReject.UNKNOWN };
  return verdict;
}

function reject(reason: IconPackZipGateReject): IconPackZipGateVerdict {
  const verdict: IconPackZipGateVerdict = { ok: false, reject: reason };
  return verdict;
}

/** 门控拒绝异常：携带机器可读原因，由 UI 层映射为用户文案后提示。 */
export class IconPackGateRejectError extends Error {
  readonly reason: IconPackZipGateReject;
  constructor(reason: IconPackZipGateReject) {
    super(reason);
    this.reason = reason;
  }
}

/** 门控拒绝原因 → 用户文案（common 四语言资源）。 */
export function iconPackGateRejectText(reason: IconPackZipGateReject): Resource {
  switch (reason) {
    case IconPackZipGateReject.NOT_ZIP_OR_DAMAGED:
      return $r('app.string.icon_pack_import_reject_not_zip');
    case IconPackZipGateReject.TOO_LARGE_TOTAL:
      return $r('app.string.icon_pack_import_reject_too_large');
    case IconPackZipGateReject.MISSING_PACK_META:
      return $r('app.string.icon_pack_import_reject_missing_meta');
    case IconPackZipGateReject.INVALID_PACK_META:
      return $r('app.string.icon_pack_import_reject_invalid_meta');
    case IconPackZipGateReject.DUPLICATE_NAME_VERSION:
      return $r('app.string.icon_pack_import_reject_duplicate');
    case IconPackZipGateReject.ENTRY_OVERFLOW:
      return $r('app.string.icon_pack_import_reject_entry_overflow');
    case IconPackZipGateReject.FILE_TOO_LARGE:
      return $r('app.string.icon_pack_import_reject_file_too_large');
    case IconPackZipGateReject.UNSAFE_ENTRY_PATH:
      return $r('app.string.icon_pack_import_reject_unsafe_path');
    case IconPackZipGateReject.IO_ERROR:
    default:
      return $r('app.string.icon_pack_import_reject_io');
  }
}

/**
 * 解压前门：getOriginalSize 返回的未压缩总字节数必须在阈值内。
 * 非法输入（负数/非有限值）按 IO_ERROR 处理，不静默放行。
 */
export function gateZipTotalSize(totalBytes: number): IconPackZipGateVerdict {
  if (!Number.isFinite(totalBytes) || totalBytes < 0) {
    return reject(IconPackZipGateReject.IO_ERROR);
  }
  if (totalBytes > IconPackZipGateLimits.MAX_TOTAL_UNCOMPRESSED_BYTES) {
    return reject(IconPackZipGateReject.TOO_LARGE_TOTAL);
  }
  return allow();
}

/** getOriginalSize 的 SDK 错误映射：损坏/非 ZIP 归专用拒绝，其余归 IO。 */
export function mapGetOriginalSizeError(error: BusinessError): IconPackZipGateReject {
  if (error !== null && error !== undefined && (error.code === 900003 || error.code === 900001)) {
    return IconPackZipGateReject.NOT_ZIP_OR_DAMAGED;
  }
  return IconPackZipGateReject.IO_ERROR;
}

function isUnsafeEntryPath(relativePath: string): boolean {
  if (relativePath.length === 0 || relativePath.indexOf('\u0000') >= 0 || relativePath.indexOf('\\') >= 0) {
    return true;
  }
  if (relativePath.startsWith('/')) {
    return true;
  }
  const segments = relativePath.split('/');
  if (segments.some((segment: string): boolean => segment === '..')) {
    return true;
  }
  return segments.length > IconPackZipGateLimits.MAX_ENTRY_DEPTH;
}

/**
 * 解压后门（纯函数，LocalUnit 可测）：条目必须含根级 pack.json，数量/单文件/总体积
 * 在限内且路径无逃逸。条目仅含文件（目录只作为路径前缀出现）。
 */
export function gateExtractedPackEntries(entries: IconPackZipEntryInfo[]): IconPackZipGateVerdict {
  let hasMeta = false;
  let totalBytes = 0;
  for (const entry of entries) {
    if (isUnsafeEntryPath(entry.relativePath)) {
      return reject(IconPackZipGateReject.UNSAFE_ENTRY_PATH);
    }
    if (entry.sizeBytes < 0 || !Number.isFinite(entry.sizeBytes)) {
      return reject(IconPackZipGateReject.IO_ERROR);
    }
    if (entry.sizeBytes > IconPackZipGateLimits.MAX_SINGLE_FILE_BYTES) {
      return reject(IconPackZipGateReject.FILE_TOO_LARGE);
    }
    if (entry.relativePath === IconPackZipGateLimits.REQUIRED_META_NAME) {
      hasMeta = true;
    }
    totalBytes += entry.sizeBytes;
  }
  if (!hasMeta) {
    return reject(IconPackZipGateReject.MISSING_PACK_META);
  }
  if (entries.length > IconPackZipGateLimits.MAX_EXTRACTED_FILE_COUNT) {
    return reject(IconPackZipGateReject.ENTRY_OVERFLOW);
  }
  if (totalBytes > IconPackZipGateLimits.MAX_TOTAL_UNCOMPRESSED_BYTES) {
    return reject(IconPackZipGateReject.TOO_LARGE_TOTAL);
  }
  return allow();
}

/**
 * 原始中央目录条目（readZipIndex 直接解析原始字节获得；文件与目录都保留原始路径）。
 */
export interface ZipRawEntryInfo {
  rawName: string;
  sizeBytes: number;
  isDirectory: boolean;
}

/**
 * 原始中央目录门（纯函数，LocalUnit 可测；数据来自 readZipIndex 的 rawEntries，解压前生效）：
 * 对文件与目录条目的原始路径做同一合法性检查。jszip 的归一化 map 会消解 `..`/`.` 段，
 * 且 unsafeOriginalName 只对文件条目保留（目录条目不赋值、同名归一化互相覆盖），
 * 因此 `x/../pack.json`、`../evil/` 这类原始路径只能由本门在解压前拦截。
 */
export function gateZipRawEntries(entries: ZipRawEntryInfo[]): IconPackZipGateVerdict {
  for (const entry of entries) {
    if (isUnsafeEntryPath(entry.rawName)) {
      return reject(IconPackZipGateReject.UNSAFE_ENTRY_PATH);
    }
  }
  return allow();
}

/**
 * 中央目录门（纯函数，LocalUnit 可测；数据来自 @ohos/jszip 的 readZipIndex，解压前生效）：
 * 对文件与目录条目都做路径合法性检查。原始 `..`/`.` 段已由 gateZipRawEntries 在原始字节层
 * 拦截，本检查对 jszip 归一化数据是纯函数层纵深；真实的解压逃逸防线 = 原始中央目录门 +
 * 平台 decompressFile 的 "../" 拒绝（900003）+ 本门的反斜杠/NUL/绝对路径/深度检查，
 * 全部 fail-closed。
 * pack.json 必须作为根级文件存在且可解析、同名同版本已安装拒绝，数量/单文件/总体积限额
 * 同解压后门。entries 含目录条目（isDirectory=true），目录不计数不计体积。
 */
export function gateZipCentralIndex(entries: IconPackZipEntryInfo[], packJsonContent: string | null,
  installed: InstalledPackInfo[]): IconPackZipGateVerdict {
  let fileCount = 0;
  let totalBytes = 0;
  for (const entry of entries) {
    if (isUnsafeEntryPath(entry.relativePath.replace(/\/$/, ''))) {
      return reject(IconPackZipGateReject.UNSAFE_ENTRY_PATH);
    }
    if (entry.isDirectory) {
      continue;
    }
    if (entry.sizeBytes < 0 || !Number.isFinite(entry.sizeBytes)) {
      return reject(IconPackZipGateReject.IO_ERROR);
    }
    if (entry.sizeBytes > IconPackZipGateLimits.MAX_SINGLE_FILE_BYTES) {
      return reject(IconPackZipGateReject.FILE_TOO_LARGE);
    }
    fileCount++;
    totalBytes += entry.sizeBytes;
  }
  if (packJsonContent === null) {
    return reject(IconPackZipGateReject.MISSING_PACK_META);
  }
  const identity = gatePackIdentity(packJsonContent, installed);
  if (!identity.ok) {
    return identity;
  }
  if (fileCount > IconPackZipGateLimits.MAX_EXTRACTED_FILE_COUNT) {
    return reject(IconPackZipGateReject.ENTRY_OVERFLOW);
  }
  if (totalBytes > IconPackZipGateLimits.MAX_TOTAL_UNCOMPRESSED_BYTES) {
    return reject(IconPackZipGateReject.TOO_LARGE_TOTAL);
  }
  return allow();
}

/**
 * 身份门（纯函数）：pack.json 可解析且含 name，且与已安装包（name+version 归一为字符串比较）
 * 重复时拒绝。version 缺失按 '0' 归一，与 addAegisIconPack 的 fallback 语义一致。
 */
export function gatePackIdentity(packJsonContent: string, installed: InstalledPackInfo[]): IconPackZipGateVerdict {
  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(packJsonContent) as Object;
  } catch (error) {
    return reject(IconPackZipGateReject.INVALID_PACK_META);
  }
  if (parsed === null || typeof parsed !== 'object') {
    return reject(IconPackZipGateReject.INVALID_PACK_META);
  }
  const record = parsed as Record<string, Object>;
  const nameValue = record['name'];
  const versionValue = record['version'];
  if (typeof nameValue !== 'string' || nameValue.length === 0) {
    return reject(IconPackZipGateReject.INVALID_PACK_META);
  }
  // 归一与 TokenUtils.addAegisIconPack 的 `tmp.version ?? 0` 落库语义对齐：
  // number/string/boolean 原样字符串化，其余（缺失/对象等）按 '0'，两侧同值同判。
  const version = typeof versionValue === 'number' || typeof versionValue === 'string'
    || typeof versionValue === 'boolean' ? String(versionValue) : '0';
  for (const pack of installed) {
    if (pack.name === nameValue && pack.version === version) {
      return reject(IconPackZipGateReject.DUPLICATE_NAME_VERSION);
    }
  }
  return allow();
}

/**
 * 递归收集解压目录的文件条目（相对路径 + 字节大小），供解压后门使用。
 * 使用 lstat 且符号链接一律拒绝（UNSAFE_ENTRY_PATH）：不跟进、不计数——合法 Aegis 包不含链接。
 * listFile/lstat 失败按门控拒绝（IO_ERROR）抛出，不吞错——门控宁拒不漏。
 */
export async function collectIconPackDirEntries(rootDir: string): Promise<IconPackZipEntryInfo[]> {
  const entries: IconPackZipEntryInfo[] = [];
  const walk = async (dir: string, prefix: string): Promise<void> => {
    let names: string[] = [];
    try {
      names = await fs.listFile(dir);
    } catch (error) {
      throw new IconPackGateRejectError(IconPackZipGateReject.IO_ERROR);
    }
    for (const name of names) {
      const relativePath = prefix.length > 0 ? `${prefix}/${name}` : name;
      const absolutePath = `${dir}/${name}`;
      let stat: fs.Stat;
      try {
        stat = await fs.lstat(absolutePath);
      } catch (error) {
        throw new IconPackGateRejectError(IconPackZipGateReject.IO_ERROR);
      }
      if (stat.isSymbolicLink()) {
        throw new IconPackGateRejectError(IconPackZipGateReject.UNSAFE_ENTRY_PATH);
      }
      const isDirectory = stat.isDirectory();
      if (isDirectory) {
        await walk(absolutePath, relativePath);
      } else {
        const entry: IconPackZipEntryInfo = { relativePath: relativePath, sizeBytes: stat.size, isDirectory: isDirectory };
        entries.push(entry);
      }
    }
  };
  await walk(rootDir, '');
  return entries;
}

/**
 * 递归删除目录（导入失败/门控拒绝后的回收路径）。SDK d.ts 声明 fs.rmdir "递归删除目录及全部
 * 子目录与文件"，但同一签名又列出 13900032（目录非空）——契约自相矛盾，故手工先清内容再
 * rmdir，两种语义下都正确。lstat 遇符号链接只删链接本身不跟进；ENOENT 宽容（目录本就不存在），
 * 其余错误如实抛出由调用方记录。
 */
export async function removeIconPackDirBestEffort(dir: string): Promise<void> {
  let names: string[] = [];
  try {
    names = await fs.listFile(dir);
  } catch (error) {
    if ((error as BusinessError).code === 13900002) {
      return;
    }
    throw error as Error;
  }
  for (const name of names) {
    const absolutePath = `${dir}/${name}`;
    let stat: fs.Stat;
    try {
      stat = await fs.lstat(absolutePath);
    } catch (error) {
      if ((error as BusinessError).code === 13900002) {
        continue;
      }
      throw error as Error;
    }
    if (stat.isDirectory() && !stat.isSymbolicLink()) {
      await removeIconPackDirBestEffort(absolutePath);
    } else {
      try {
        await fs.unlink(absolutePath);
      } catch (error) {
        if ((error as BusinessError).code !== 13900002) {
          throw error as Error;
        }
      }
    }
  }
  try {
    await fs.rmdir(dir);
  } catch (error) {
    if ((error as BusinessError).code !== 13900002) {
      throw error as Error;
    }
  }
}

/**
 * 进程内图标包导入互斥：多次点击、多个面板实例共享同一把静态锁。
 * try-acquire 忙碌即拒（无时钟去重、无排队——导入临界区短，忙碌提示即可），
 * 持有方必须在 finally 调用 release，失败路径也不例外。
 */
export class IconPackImportMutex {
  private static held: boolean = false;

  static tryAcquire(): boolean {
    if (IconPackImportMutex.held) {
      return false;
    }
    IconPackImportMutex.held = true;
    return true;
  }

  static release(): void {
    IconPackImportMutex.held = false;
  }

  static isHeld(): boolean {
    return IconPackImportMutex.held;
  }
}

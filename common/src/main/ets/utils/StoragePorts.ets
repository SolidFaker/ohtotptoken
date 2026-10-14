import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { TokenConfig } from './TokenConfig';
import { TokenBatchProgressCallback } from './TokenBatchProgress';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticErrorDomain, DiagnosticMode,
  DiagnosticReason, DiagnosticResult, DiagnosticStage
} from './CloudBackupDiagnostics';

/**
 * 分组目录 KV 后端接口（历史名，Phase 1 引入；Phase 2 并入本文件端口族）。
 * TokenGroupStore 与 TokenKvStore 共享此标称祖先：
 * TokenStore 加载时用同一后端驱动 TokenGroupStore，测试注入一个实现即可覆盖两者。
 */
export interface TokenGroupKvBackend {
  getValue<T>(key: string): Promise<T | null>;
  setValue<T>(key: string, value: T): Promise<void>;
}

/**
 * Phase 2 存储与密钥解耦端口（docs/TEST_PLAN.md 第 4 节）。
 *
 * 四个核心端口家族：
 * - {@link KeyValueStore} / {@link TokenKvStore}：键值与令牌主存储（生产 KvManager/PreferenceManager）
 * - {@link SecretStore} / {@link NamedSecretStore}：TEE 密钥读写（生产 AssetSecretStore）
 * - {@link CryptoEngine}：密码学引擎（生产 cryptoFramework，LocalUnit 不可用）
 * - {@link FsGateway}：文件系统网关（生产 fileIo/cloudSync，LocalUnit 不可用）
 *
 * 业务层（TokenStore/CloudBackupManager/CryptoUtils 等）只依赖端口，
 * 测试注入内存/确定性假实现，真机行为由生产适配器保证。
 *
 * 注：UTF-8 字节长度工具使用 SteamAuth.utf8ByteLength（避免 common/Index 的
 * star-export 命名冲突），本文件不再重复导出。
 */

/**
 * 通用键值存储端口。
 * 生产实现：KvManager（加密 KV）、PreferenceManager（preferences）。
 */
export interface KeyValueStore {
  getValue<T>(key: string): Promise<T | null>;
  setValue<T>(key: string, value: T): Promise<void>;
  deleteValue(key: string): Promise<void>;
}

/** 批量条目：值统一为 JSON 字符串（与加密 KV 的存储形态一致）。 */
export interface KvBatchEntry {
  key: string;
  value: string;
}

/**
 * 令牌主存储端口（分组目录后端 + 令牌数组/事务批量）。
 * 生产实现为 KvManager；TokenStore 仅依赖本端口。
 */
export interface TokenKvStore extends TokenGroupKvBackend {
  /** 初始化底层存储（生产 KvManager.initKvManager，测试为 no-op） */
  init(): Promise<void>;
  getTokenArray(prefix: string): Promise<TokenConfig[]>;
  saveTokenBatch(prefix: string, tokens: TokenConfig[], deletedUuids?: string[],
    onProgress?: TokenBatchProgressCallback): Promise<void>;
}

/** 分布式 KV 事务原语端口（供分块提交/回滚编排使用）。 */
export interface TransactionalKv {
  startTransaction(): Promise<void>;
  putBatch(entries: KvBatchEntry[]): Promise<void>;
  deleteBatch(keys: string[]): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

/** 旧版本令牌键迁移所需的最小 KV 读写端口。 */
export interface LegacyTokenKv {
  getRawEntries(prefix: string): Promise<KvBatchEntry[]>;
  getString(key: string): Promise<string | null>;
  setString(key: string, value: string): Promise<void>;
  deleteValue(key: string): Promise<void>;
}

/**
 * 任意别名密钥存储端口（ASSET 语义）。
 * Steam 分片凭证（SteamSecretStore）依赖本端口而非具体 AssetSecretStore。
 */
export interface NamedSecretStore {
  upsertNamedSecret(alias: string, secret: string): Promise<boolean>;
  queryNamedSecret(alias: string): Promise<string | null>;
  removeNamedSecret(alias: string): Promise<void>;
}

/**
 * 令牌密钥存储端口（生产实现为 AssetSecretStore / TEE 硬件保护）。
 * TokenStore 的迁移三重验证、降级判断只依赖本端口。
 */
export interface SecretStore extends NamedSecretStore {
  /** Secret 的 UTF-8 字节长度是否在存储限制内（≤900 字节） */
  isSecretSizeValid(secret: string): boolean;
  upsertSecret(tokenUUID: string, secret: string): Promise<boolean>;
  querySecret(tokenUUID: string): Promise<string | null>;
  removeSecret(tokenUUID: string): Promise<void>;
  batchQuerySecrets(tokenUUIDs: string[]): Promise<Map<string, string>>;
}

/** GCM 加封结果：密文与认证标签分离返回。 */
export class CryptoSealedBytes {
  ciphertext: Uint8Array = new Uint8Array(0);
  tag: Uint8Array = new Uint8Array(0);
}

/**
 * 密码学引擎端口：屏蔽 cryptoFramework（LocalUnit 下静默失效）。
 * CryptoUtils 的格式/协议逻辑（魔数、salt/iv 布局、legacy 兼容分支）只依赖本端口，
 * 数值正确性（AES/PBKDF2/GCM 向量）由真机 ohosTest 与生产实现保证。
 */
export interface CryptoEngine {
  randomBytes(length: number): Uint8Array;
  utf8Encode(text: string): Uint8Array;
  utf8Decode(data: Uint8Array): string;
  /** PBKDF2-SHA256 派生对称密钥字节 */
  pbkdf2Derive(password: string, salt: Uint8Array, iterations: number, keySize: number): Promise<Uint8Array>;
  sha256(data: Uint8Array): Promise<Uint8Array>;
  /** AES-CBC-PKCS7 加密；key 为原始密钥字节（AES-128） */
  aesCbcEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array>;
  /** AES-CBC-PKCS7 解密；填充非法时抛异常 */
  aesCbcDecrypt(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array>;
  /** AES-256-GCM 加密，返回密文与 16 字节认证标签 */
  aesGcmSeal(plain: Uint8Array, key: Uint8Array, iv: Uint8Array, aad: Uint8Array): Promise<CryptoSealedBytes>;
  /** AES-256-GCM 解密；认证失败抛异常 */
  aesGcmOpen(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array, aad: Uint8Array, tag: Uint8Array): Promise<Uint8Array>;
}

/** 文件状态（location: 1=仅本地 2=仅云端（本地仅元数据桩） 3=本地+云端双份）。 */
export class FsStatInfo {
  size: number = 0;
  location: number = 0;
  isDirectory: boolean = false;
}

/**
 * 文件系统网关端口：屏蔽 @kit.CoreFileKit 的 fileIo/cloudSync。
 * 覆盖云备份编排所需的最小面（stat/list/read/write/mkdir/unlink/copy）。
 */
export interface FsGateway {
  stat(path: string): Promise<FsStatInfo>;
  listFiles(dir: string): Promise<string[]>;
  readTextFile(path: string, context?: DiagnosticContext): Promise<string>;
  writeTextFile(path: string, content: string, context?: DiagnosticContext): Promise<void>;
  writeBinaryFile(path: string, data: Uint8Array, context?: DiagnosticContext): Promise<void>;
  /** 新建文件，目标存在时失败；调用方只传密文。失败不获得目标所有权。 */
  writeNewTextFile(path: string, content: string, context?: DiagnosticContext): Promise<void>;
  /** 对已关闭的精确文件提交 fsync；发布保旧凭据必须在破坏性动作前落盘。 */
  syncFile(path: string): Promise<void>;
  /** 同目录、不覆盖发布；调用方先关闭、读回并校验源文件。 */
  publishFile(source: string, destination: string, context?: DiagnosticContext): Promise<void>;
  /** 同目录覆盖式移动；调用方先校验暂存产物，移动异常向上传播，不承诺原子性或失败保旧。 */
  moveFileToReplace(source: string, destination: string): Promise<void>;
  makeDir(path: string): Promise<void>;
  makeTempDir(prefix: string): Promise<string>;
  /** 递归删除目录及其内容（fs.rmdir 语义）；调用方必须确认目录所有权。 */
  removeDir(path: string): Promise<void>;
  deleteFile(path: string): Promise<void>;
  copyFile(src: string, dest: string): Promise<void>;
}

/** 本地备份文本端口；成功必须等待全部字节写入及 close，失败不得吞掉。 */
export interface BackupTextIo {
  readText(uri: string): Promise<string>;
  writeText(uri: string, content: string): Promise<void>;
}

/**
 * 原生文件错误的窄适配器：只读取一次数值 code，阶段白名单仍由诊断器验证。
 * 不读取 message/stack/cause，不进行字符串转换；恶意 getter 的异常被隔离。
 */
export function fileIoDiagnosticCode(error: Object | undefined | null): number | undefined {
  try {
    if (error === undefined || error === null || typeof error !== 'object') {
      return undefined;
    }
    const code = (error as BusinessError).code;
    return typeof code === 'number' ? code : undefined;
  } catch (_) {
    return undefined;
  }
}

/** 写入原语注入点：LocalUnit 只替换原生边界，仍执行生产的短写/关闭/发布逻辑。 */
export interface FileIoWritePort {
  encodeText(content: string): Uint8Array;
  openFile(path: string): number;
  writeSync(fd: number, bytes: ArrayBuffer): number;
  closeFile(fd: number): void;
  makeTempDir(prefix: string): Promise<string>;
  moveFileNoReplace(source: string, destination: string): Promise<void>;
  deleteFile(path: string): Promise<void>;
  removeDir(path: string): Promise<void>;
}

class NativeFileIoWritePort implements FileIoWritePort {
  encodeText(content: string): Uint8Array {
    const encoded = buffer.from(content, 'utf-8');
    // Buffer.byteOffset 属于原内存池，不保证相对于 buffer 返回的内容副本。
    const bytes = new Uint8Array(encoded.length);
    for (let index = 0; index < bytes.length; index++) {
      bytes[index] = encoded.readUInt8(index);
    }
    return bytes;
  }

  openFile(path: string): number {
    return fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;
  }

  writeSync(fd: number, bytes: ArrayBuffer): number {
    // SDK WriteOptions.offset 是文件偏移，不是 bytes 的源偏移；使用描述符当前位置。
    return fs.writeSync(fd, bytes);
  }

  closeFile(fd: number): void {
    fs.closeSync(fd);
  }

  async makeTempDir(prefix: string): Promise<string> {
    return fs.mkdtemp(prefix);
  }

  async moveFileNoReplace(source: string, destination: string): Promise<void> {
    // SDK API9：mode=1 在目标存在时抛出异常。不是 stat + rename，也不承诺原子性。
    await fs.moveFile(source, destination, 1);
  }

  async deleteFile(path: string): Promise<void> {
    await fs.unlink(path);
  }

  async removeDir(path: string): Promise<void> {
    await fs.rmdir(path);
  }
}

/** 只接受规范的沙箱绝对文件路径，避免别名路径绕过同目录约束。 */
function publicationParent(path: string): string {
  const parts = path.split('/');
  if (!path.startsWith('/') || parts.length < 3 ||
    parts.slice(1).some((part: string): boolean => part.length === 0 || part === '.' || part === '..') ||
    path.indexOf('\\') >= 0 || path.indexOf('\u0000') >= 0) {
    throw new Error('Invalid publication path');
  }
  return path.substring(0, path.lastIndexOf('/'));
}

/** 仅文件不存在（ENOENT 13900002）视为替换目标本就缺失；其余删除失败如实传播。 */
function isFileAbsentError(error: BusinessError): boolean {
  try {
    return error.code === 13900002;
  } catch (_) {
    // code 读取失败按非 ENOENT 处理：宁可让备份如实失败，不进入删除后移动。
    return false;
  }
}

/** {@link FsGateway} 的生产实现：包装 @kit.CoreFileKit fileIo。 */
export class FileIoFsGateway implements FsGateway {
  private readonly writer: FileIoWritePort;

  constructor(writer?: FileIoWritePort) {
    this.writer = writer !== undefined ? writer : new NativeFileIoWritePort();
  }
  async stat(path: string): Promise<FsStatInfo> {
    const raw = await fs.stat(path);
    const info = new FsStatInfo();
    info.size = raw.size;
    info.location = raw.location;
    info.isDirectory = raw.isDirectory();
    return info;
  }

  async listFiles(dir: string): Promise<string[]> {
    return fs.listFileSync(dir);
  }

  async readTextFile(path: string, context?: DiagnosticContext): Promise<string> {
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const info = await fs.stat(file.fd);
      const bytes = new Uint8Array(info.size);
      let offset = 0;
      while (offset < bytes.length) {
        const chunk = new ArrayBuffer(Math.min(bytes.length - offset, 65536));
        const readLength = await fs.read(file.fd, chunk);
        if (!Number.isInteger(readLength) || readLength <= 0 || readLength > chunk.byteLength) {
          throw new Error('Incomplete file read');
        }
        bytes.set(new Uint8Array(chunk, 0, readLength), offset);
        offset += readLength;
      }
      if (context !== undefined) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_VERIFY, DiagnosticResult.OK,
          { contentNonEmpty: bytes.length > 0 });
      }
      return buffer.from(bytes).toString('utf-8');
    } finally {
      await fs.close(file);
    }
  }

  async writeTextFile(path: string, content: string, context?: DiagnosticContext): Promise<void> {
    let bytes: Uint8Array;
    try {
      bytes = this.writer.encodeText(content);
    } catch (error) {
      if (context !== undefined) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_ENCODE, DiagnosticResult.FAIL,
          { errorDomain: DiagnosticErrorDomain.APP, reason: DiagnosticReason.ENCODING_FAILED });
      }
      throw error as Error;
    }
    await this.writeBinaryFile(path, bytes, context);
  }

  async writeBinaryFile(path: string, data: Uint8Array, context?: DiagnosticContext): Promise<void> {
    let fd: number;
    try {
      fd = this.writer.openFile(path);
      if (context !== undefined) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_OPEN, DiagnosticResult.OK);
      }
    } catch (error) {
      if (context !== undefined) {
        CloudBackupDiagnostics.fail(context, DiagnosticStage.FS_OPEN, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
      }
      throw error as Error;
    }
    let invalidProgress = false;
    let writeFailed = false;
    try {
      let offset = 0;
      while (offset < data.byteLength) {
        const length = Math.min(data.byteLength - offset, 65536);
        // slice 同时处理共享大 buffer 和非零 byteOffset，只把有效视图交给 SDK。
        const chunk = data.buffer.slice(data.byteOffset + offset, data.byteOffset + offset + length);
        const written = this.writer.writeSync(fd, chunk);
        if (!Number.isInteger(written) || written <= 0 || written > length) {
          invalidProgress = true;
          throw new Error('File write made no valid progress');
        }
        offset += written;
      }
      if (context !== undefined) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_WRITE, DiagnosticResult.OK,
          { mode: DiagnosticMode.ARRAY_BUFFER, writeComplete: true, contentNonEmpty: data.byteLength > 0 });
      }
    } catch (error) {
      writeFailed = true;
      if (context !== undefined) {
        if (invalidProgress) {
          CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_WRITE, DiagnosticResult.FAIL,
            { reason: DiagnosticReason.SHORT_WRITE, mode: DiagnosticMode.ARRAY_BUFFER, writeComplete: false });
        } else {
          CloudBackupDiagnostics.fail(context, DiagnosticStage.FS_WRITE, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
        }
      }
      throw error as Error;
    } finally {
      try {
        this.writer.closeFile(fd);
        if (context !== undefined) {
          CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_CLOSE, DiagnosticResult.OK);
        }
      } catch (error) {
        if (context !== undefined) {
          CloudBackupDiagnostics.fail(context, DiagnosticStage.FS_CLOSE, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
        }
        if (!writeFailed) throw error as Error;
      }
    }
  }

  async writeNewTextFile(path: string, content: string, context?: DiagnosticContext): Promise<void> {
    let parent: string;
    try { parent = publicationParent(path); } catch (error) {
      if (context !== undefined) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_PREPARE, DiagnosticResult.FAIL,
          { errorDomain: DiagnosticErrorDomain.APP, reason: DiagnosticReason.INVALID_ARGUMENT });
      }
      throw error as Error;
    }
    // 通用接口仅有进程内所有权；云备份生产路径由 CloudBackupStaging 持久登记密文产物。
    let directory: string;
    try { directory = await this.writer.makeTempDir(parent + '/.cloud-backup-stage-XXXXXX'); } catch (error) {
      if (context !== undefined) {
        CloudBackupDiagnostics.fail(context, DiagnosticStage.FS_STAGE, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
      }
      throw error as Error;
    }
    const staged = directory + '/content.tmp';
    let moved = false;
    try {
      await this.writeTextFile(staged, content, context);
      try { await this.writer.moveFileNoReplace(staged, path); } catch (error) {
        if (context !== undefined) {
          CloudBackupDiagnostics.fail(context, DiagnosticStage.FS_STAGE_MOVE, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
        }
        throw error as Error;
      }
      moved = true;
    } finally {
      if (!moved) {
        try {
          await this.writer.deleteFile(staged);
        } catch (_) {
          // 仅限本操作拥有的路径；不扫描或删除目标/历史记录。
        }
      }
      try {
        await this.writer.removeDir(directory);
      } catch (error) {
        if (context !== undefined) {
          CloudBackupDiagnostics.fail(context, DiagnosticStage.TEMP_CLEANUP, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
        }
      }
    }
  }

  async syncFile(path: string): Promise<void> {
    const file = await fs.open(path, fs.OpenMode.READ_WRITE);
    let failed = false;
    try {
      await fs.fsync(file.fd);
    } catch (error) {
      failed = true;
      throw error as Error;
    } finally {
      try {
        await fs.close(file);
      } catch (error) {
        if (!failed) throw error as Error;
      }
    }
  }

  async publishFile(source: string, destination: string, context?: DiagnosticContext): Promise<void> {
    try {
      if (source === destination || publicationParent(source) !== publicationParent(destination)) {
        throw new Error('Publication requires distinct files in the same directory');
      }
      // 同目录保持同一文件系统，不主动降级为覆盖写；API 的冲突检查不是跨进程原子锁。
      await this.writer.moveFileNoReplace(source, destination);
    } catch (error) {
      if (context !== undefined) {
        CloudBackupDiagnostics.fail(context, DiagnosticStage.PUBLISH_END, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
      }
      throw error as Error;
    }
  }

  async moveFileToReplace(source: string, destination: string): Promise<void> {
    if (source === destination || publicationParent(source) !== publicationParent(destination)) {
      throw new Error('Replace requires distinct files in the same directory');
    }
    // 真机云目录已验证：目标已存在时 SDK fs.moveFile(mode=0) 抛 EINVAL(13900020)，覆盖移动不可用。
    // 改为精确删除旧目标（仅 ENOENT 宽容）后 moveFile(mode=1)；mode=1 在删除与移动之间出现
    // 同名目标时拒绝而非静默覆盖。中断窗口：删除后、移动完成前进程终止会失去旧正式文件，
    // 下次完整备份可重建；SDK 无原子替换原语，此窗口只能收窄为相邻两个原生调用。
    try {
      await this.writer.deleteFile(destination);
    } catch (error) {
      if (!isFileAbsentError(error as BusinessError)) {
        throw error as Error;
      }
    }
    await this.writer.moveFileNoReplace(source, destination);
  }

  async makeTempDir(prefix: string): Promise<string> {
    return this.writer.makeTempDir(prefix);
  }

  async makeDir(path: string): Promise<void> {
    await fs.mkdir(path);
  }

  async removeDir(path: string): Promise<void> {
    await fs.rmdir(path);
  }

  async deleteFile(path: string): Promise<void> {
    await fs.unlink(path);
  }

  async copyFile(src: string, dest: string): Promise<void> {
    await fs.copyFile(src, dest);
  }
}

import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticStage, DiagnosticResult,
  DiagnosticErrorDomain
} from './CloudBackupDiagnostics';
import { CloudBackupSyncService } from './CloudBackupSyncService';
import { FileIoFsGateway, fileIoDiagnosticCode } from './StoragePorts';

export const CLOUD_STAGE_JOURNAL = '.cloud-backup-journal';

export interface CloudStageReceipt {
  id: string;
  version: number;
  scope: string;
  cloudRoot: string;
  stage: string;
}

export interface CloudStageStat {
  directory: boolean;
  regular: boolean;
  symbolic: boolean;
}

export interface CloudBackupStagingPort {
  createDirectory(prefix: string): Promise<string>;
  inspect(path: string): Promise<CloudStageStat | undefined>;
  list(path: string): Promise<string[]>;
  save(receipt: CloudStageReceipt): Promise<string>;
  load(): Promise<CloudStageReceipt[]>;
  forget(id: string): Promise<void>;
  write(path: string, content: string, context?: DiagnosticContext): Promise<void>;
  move(source: string, destination: string): Promise<void>;
  unlink(path: string): Promise<void>;
  removeDirectory(path: string): Promise<void>;
  sync(context?: DiagnosticContext): Promise<boolean>;
}

function canonicalRoot(path: string): boolean {
  return path.startsWith('/') && !path.includes('\\') && !/[\u0000-\u001f\u007f]/.test(path) &&
    path.split('/').slice(1).every((part: string): boolean => part.length > 0 && part !== '.' && part !== '..');
}

function validReceipt(receipt: CloudStageReceipt): boolean {
  return receipt !== null && typeof receipt === 'object' && receipt.version === 1 &&
    typeof receipt.id === 'string' && /^receipt-[A-Za-z0-9]{6}(?![\s\S])/.test(receipt.id) &&
    typeof receipt.scope === 'string' && /^[a-f0-9]{64}(?![\s\S])/.test(receipt.scope) &&
    typeof receipt.cloudRoot === 'string' && canonicalRoot(receipt.cloudRoot) &&
    typeof receipt.stage === 'string' && /^\.cloud-backup-owned-[A-Za-z0-9]{6}(?![\s\S])/.test(receipt.stage);
}

/** 本地 receipt 不迁移、不上云；其存在证明该安装曾成功创建精确 stage，而非按云端前缀认领。 */
export class CloudBackupStaging {
  private readonly root: string;
  private readonly scope: string;
  private readonly port: CloudBackupStagingPort;
  private active: Map<string, CloudStageReceipt> = new Map();
  private cleaned: Set<string> = new Set();

  constructor(root: string, scope: string, port: CloudBackupStagingPort) {
    if (!canonicalRoot(root) || !/^[a-f0-9]{64}(?![\s\S])/.test(scope)) throw new Error('INVALID_STAGING_SCOPE');
    this.root = root;
    this.scope = scope;
    this.port = port;
  }

  static async production(root: string, filesDir: string, account: string): Promise<CloudBackupStaging> {
    if (account.length === 0) throw new Error('STAGING_ACCOUNT_UNAVAILABLE');
    const encoded = buffer.from(account, 'utf-8');
    const bytes = new Uint8Array(encoded.length);
    for (let index = 0; index < bytes.length; index++) bytes[index] = encoded.readUInt8(index);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest = await md.digest();
    let scope = '';
    for (const value of digest.data) scope += value.toString(16).padStart(2, '0');
    return new CloudBackupStaging(root, scope, new NativeCloudBackupStagingPort(filesDir));
  }

  private fail(context: DiagnosticContext, stage: DiagnosticStage, error: Object): void {
    CloudBackupDiagnostics.fail(context, stage, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
  }

  /** 只能在持有全局云操作许可且无未知在途 I/O 时调用；不清理其他账号或无凭据的旧残留。 */
  async recover(context: DiagnosticContext): Promise<boolean> {
    try {
      const receipts = await this.port.load();
      let complete = true;
      for (const receipt of receipts) {
        if (!validReceipt(receipt)) throw new Error('INVALID_STAGING_RECEIPT');
        if (receipt.scope !== this.scope || receipt.cloudRoot !== this.root) continue;
        const source = this.root + '/' + receipt.stage + '/content.tmp';
        if (this.active.has(source)) continue;
        if (!await this.clean(receipt, context)) complete = false;
      }
      if (this.cleaned.size > 0) {
        if (await this.port.sync(context)) await this.acknowledgeSync(context);
        else complete = false;
      }
      return complete;
    } catch (error) {
      this.fail(context, DiagnosticStage.TEMP_CLEANUP, error);
      return false;
    }
  }

  async create(content: string, context: DiagnosticContext): Promise<string> {
    if (!await this.recover(context)) throw new Error('STAGING_RECOVERY_FAILED');
    CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_STAGE, DiagnosticResult.BEGIN);
    let directory: string;
    try {
      directory = await this.port.createDirectory(this.root + '/.cloud-backup-owned-XXXXXX');
    } catch (error) {
      this.fail(context, DiagnosticStage.FS_STAGE, error);
      throw error as Error;
    }
    const receipt: CloudStageReceipt = {
      id: 'receipt-000000', version: 1, scope: this.scope, cloudRoot: this.root,
      stage: directory.substring(this.root.length + 1)
    };
    if (directory !== this.root + '/' + receipt.stage || !validReceipt(receipt)) throw new Error('INVALID_STAGING_DIRECTORY');
    // receipt 完整写入、fsync、关闭后才能写密文。此前进程死亡最多留下未认领的空目录。
    try {
      receipt.id = await this.port.save(receipt);
      if (!validReceipt(receipt)) throw new Error('INVALID_STAGING_RECEIPT');
    } catch (error) {
      this.fail(context, DiagnosticStage.FS_STAGE, error);
      throw error as Error;
    }
    const source = directory + '/content.tmp';
    this.active.set(source, receipt);
    CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_STAGE, DiagnosticResult.OK);
    try {
      await this.port.write(source, content, context);
      return source;
    } catch (error) {
      await this.discard(source, context);
      throw error as Error;
    }
  }

  /** 仅允许已登记 stage/content.tmp 发布到同一 cloudRoot 的正式文件，不放宽通用同目录发布接口。 */
  async publish(source: string, destination: string, context: DiagnosticContext): Promise<void> {
    const receipt = this.active.get(source);
    const name = destination.substring(this.root.length + 1);
    if (receipt === undefined || destination !== this.root + '/' + name ||
      !/^otp_backup_-?\d+\.enc(?![\s\S])/.test(name) ||
      !Number.isSafeInteger(Number(name.substring(11, name.length - 4)))) throw new Error('INVALID_STAGING_PUBLICATION');
    const state = await this.port.inspect(source);
    if (state === undefined || state.symbolic || !state.regular) throw new Error('INVALID_STAGING_CONTENT');
    try {
      await this.port.move(source, destination);
    } catch (error) {
      this.fail(context, DiagnosticStage.PUBLISH_END, error);
      throw error as Error;
    }
  }

  async discard(source: string, context: DiagnosticContext): Promise<boolean> {
    const receipt = this.active.get(source);
    if (receipt === undefined) return false;
    this.active.delete(source);
    return this.clean(receipt, context);
  }

  private async clean(receipt: CloudStageReceipt, context: DiagnosticContext): Promise<boolean> {
    this.cleaned.delete(receipt.id);
    try {
      const directory = this.root + '/' + receipt.stage;
      const state = await this.port.inspect(directory);
      if (state !== undefined) {
        if (state.symbolic || !state.directory) throw new Error('STAGING_DIRECTORY_CHANGED');
        const children = await this.port.list(directory);
        if (children.some((name: string): boolean => name !== 'content.tmp')) throw new Error('STAGING_HAS_UNKNOWN_CONTENT');
        const path = directory + '/content.tmp';
        const content = await this.port.inspect(path);
        if (content !== undefined) {
          if (content.symbolic || !content.regular) throw new Error('STAGING_CONTENT_CHANGED');
          try { await this.port.unlink(path); } catch (error) {
            if (fileIoDiagnosticCode(error) !== 13900002) throw error as Error;
          }
        }
        if ((await this.port.list(directory)).length !== 0) throw new Error('STAGING_HAS_UNKNOWN_CONTENT');
        // rmdir 会递归：仅用于本安装创建、无其他写者的专用随机子树；列表检查不是跨进程原子锁。
        try { await this.port.removeDirectory(directory); } catch (error) {
          if (fileIoDiagnosticCode(error) !== 13900002) throw error as Error;
        }
      }
      this.cleaned.add(receipt.id);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.TEMP_CLEANUP, DiagnosticResult.OK);
      return true;
    } catch (error) {
      this.fail(context, DiagnosticStage.TEMP_CLEANUP, error);
      return false;
    }
  }

  /** 仅在清理已完成且同步请求被接受后删本地凭据；不把接受等同远端删除完成。 */
  async acknowledgeSync(context: DiagnosticContext): Promise<void> {
    for (const id of this.cleaned) {
      try {
        await this.port.forget(id);
        this.cleaned.delete(id);
      } catch (error) {
        this.fail(context, DiagnosticStage.TEMP_CLEANUP, error);
      }
    }
  }
}

export class NativeCloudBackupStagingPort implements CloudBackupStagingPort {
  private readonly journal: string;
  private readonly gateway: FileIoFsGateway = new FileIoFsGateway();

  constructor(filesDir: string) {
    if (!canonicalRoot(filesDir)) throw new Error('INVALID_JOURNAL_ROOT');
    this.journal = filesDir + '/' + CLOUD_STAGE_JOURNAL;
  }

  private async ensureJournal(): Promise<void> {
    let stat = await this.inspect(this.journal);
    if (stat === undefined) {
      await fs.mkdir(this.journal);
      stat = await this.inspect(this.journal);
    }
    if (stat === undefined || !stat.directory || stat.symbolic) throw new Error('INVALID_JOURNAL_DIRECTORY');
  }

  async createDirectory(prefix: string): Promise<string> { return fs.mkdtemp(prefix); }
  async inspect(path: string): Promise<CloudStageStat | undefined> {
    try {
      const stat = await fs.lstat(path);
      return { directory: stat.isDirectory(), regular: stat.isFile(), symbolic: stat.isSymbolicLink() };
    } catch (error) {
      if (fileIoDiagnosticCode(error) === 13900002) return undefined;
      throw error as Error;
    }
  }
  async list(path: string): Promise<string[]> { return fs.listFile(path); }

  async save(receipt: CloudStageReceipt): Promise<string> {
    // 配额只统计可用凭据；中断残片不应永久耗尽登记空间。
    if ((await this.load()).length >= 128) throw new Error('STAGING_RECEIPT_LIMIT');
    const directory = await fs.mkdtemp(this.journal + '/receipt-XXXXXX');
    const id = directory.substring(this.journal.length + 1);
    if (directory !== this.journal + '/' + id || !/^receipt-[A-Za-z0-9]{6}(?![\s\S])/.test(id)) {
      throw new Error('INVALID_STAGING_RECEIPT');
    }
    try {
      const saved: CloudStageReceipt = { id: id, version: 1, scope: receipt.scope, cloudRoot: receipt.cloudRoot, stage: receipt.stage };
      if (!validReceipt(saved)) throw new Error('INVALID_STAGING_RECEIPT');
      const json = JSON.stringify(saved);
      const bytes = new Uint8Array(json.length);
      // 登记字段均经ASCII路径/散列校验；正式沙箱路径不是用户文件名。
      for (let index = 0; index < json.length; index++) {
        if (json.charCodeAt(index) > 127) throw new Error('INVALID_STAGING_RECEIPT');
        bytes[index] = json.charCodeAt(index);
      }
      const file = await fs.open(directory + '/receipt.json', fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        let offset = 0;
        while (offset < bytes.length) {
          const length = await fs.write(file.fd, bytes.buffer.slice(offset));
          if (!Number.isInteger(length) || length <= 0 || length > bytes.length - offset) throw new Error('INCOMPLETE_STAGING_RECEIPT');
          offset += length;
        }
        await fs.fsync(file.fd);
      } finally { await fs.close(file); }
      return id;
    } catch (error) {
      // save 尚未返回，云密文尚未打开；只回收本次本地目录，不据失败凭据操作云端。
      await this.discardInvalidLocalReceipt(id);
      throw error as Error;
    }
  }

  private async discardInvalidLocalReceipt(id: string): Promise<void> {
    // 仅移除形态已知的本地残片；未知子项/符号链接保留，但不计入可用凭据配额。
    try { await this.forget(id); } catch (_) {}
  }

  async load(): Promise<CloudStageReceipt[]> {
    await this.ensureJournal();
    const names = await this.list(this.journal);
    const receipts: CloudStageReceipt[] = [];
    for (const name of names) {
      if (!/^receipt-[A-Za-z0-9]{6}(?![\s\S])/.test(name)) continue;
      const directory = this.journal + '/' + name;
      const dirState = await this.inspect(directory);
      if (dirState === undefined || !dirState.directory || dirState.symbolic) continue;
      const file = directory + '/receipt.json';
      const fileState = await this.inspect(file);
      if (fileState === undefined) {
        await this.discardInvalidLocalReceipt(name);
        continue;
      }
      if (!fileState.regular || fileState.symbolic) continue;
      const size = (await fs.stat(file)).size;
      if (!Number.isSafeInteger(size) || size < 0 || size > 4096) continue;
      // I/O 不可用不等于凭据损坏，读取异常向上报告并保留，不触发本地回收。
      const text = await this.gateway.readTextFile(file);
      let parsed: CloudStageReceipt;
      try { parsed = JSON.parse(text) as CloudStageReceipt; }
      catch (_) {
        await this.discardInvalidLocalReceipt(name);
        continue;
      }
      if (!validReceipt(parsed) || parsed.id !== name) continue;
      receipts.push(parsed);
    }
    return receipts;
  }

  async forget(id: string): Promise<void> {
    if (!/^receipt-[A-Za-z0-9]{6}(?![\s\S])/.test(id)) throw new Error('INVALID_STAGING_RECEIPT');
    const directory = this.journal + '/' + id;
    const state = await this.inspect(directory);
    if (state === undefined) return;
    if (!state.directory || state.symbolic || (await this.list(directory)).some((name: string): boolean => name !== 'receipt.json')) {
      throw new Error('INVALID_STAGING_RECEIPT');
    }
    await fs.rmdir(directory);
  }
  async write(path: string, content: string, context?: DiagnosticContext): Promise<void> {
    await this.gateway.writeTextFile(path, content, context);
  }
  async move(source: string, destination: string): Promise<void> { await fs.moveFile(source, destination, 1); }
  async unlink(path: string): Promise<void> { await fs.unlink(path); }
  async removeDirectory(path: string): Promise<void> { await fs.rmdir(path); }
  async sync(context?: DiagnosticContext): Promise<boolean> { return CloudBackupSyncService.getInstance().start(context); }
}

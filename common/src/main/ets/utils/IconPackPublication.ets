import { FsGateway, fileIoDiagnosticCode } from './StoragePorts';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticErrorDomain, DiagnosticStage,
} from './CloudBackupDiagnostics';

export const ICON_PACK_ZIP = 'icon_packs_backup.zip';
export const ICON_PACK_META = 'icon_packs_sync_meta.json';
export const ICON_PACK_GENERATIONS = '.icon_packs_generations';
const GENERATION_COMMIT = 'committed.json';
const MAX_METADATA_BYTES = 1024 * 1024;
const MAX_GENERATIONS = 128;
const RETAIN_GENERATIONS = 2;

export interface IconPackCloudSnapshot {
  zipPath: string;
  metaPath: string;
}

interface IconPackGeneration {
  version: number;
  id: string;
  timestamp: number;
  metadata: string;
}

export type IconPackPublishedValidator = (zipPath: string, metadata: string) => Promise<boolean>;

/** 每代独占目录，commit 之后不可改写；不用共享 pointer／previous 槽模拟跨设备事务。 */
export class IconPackPublication {
  private readonly fs: FsGateway;
  private readonly cloudDir: string;
  private readonly context: DiagnosticContext;
  private readonly validate: IconPackPublishedValidator;
  private readonly prepareRead: ((path: string) => Promise<void>) | undefined;

  constructor(fs: FsGateway, cloudDir: string, context: DiagnosticContext,
    validate: IconPackPublishedValidator, prepareRead?: (path: string) => Promise<void>) {
    this.fs = fs;
    this.cloudDir = cloudDir;
    this.context = context;
    this.validate = validate;
    this.prepareRead = prepareRead;
  }

  root(): string {
    return this.cloudDir + '/' + ICON_PACK_GENERATIONS;
  }

  private directory(id: string): string {
    if (!/^generation-[A-Za-z0-9]{6}$/.test(id)) throw new Error('ICON_GENERATION_ID_INVALID');
    return this.root() + '/' + id;
  }

  private async read(path: string): Promise<string> {
    const stat = await this.fs.stat(path);
    if (stat.isDirectory || stat.size <= 0 || stat.size > MAX_METADATA_BYTES) {
      throw new Error('ICON_GENERATION_METADATA_INVALID');
    }
    if (this.prepareRead !== undefined) await this.prepareRead(path);
    return this.fs.readTextFile(path);
  }

  private report(error: Object): void {
    CloudBackupDiagnostics.fail(this.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.FS,
      fileIoDiagnosticCode(error));
  }

  private async exists(path: string): Promise<boolean> {
    try {
      return !(await this.fs.stat(path)).isDirectory;
    } catch (error) {
      if (fileIoDiagnosticCode(error) === 13900002) return false;
      throw error as Error;
    }
  }

  private async generation(id: string): Promise<IconPackGeneration | undefined> {
    const dir = this.directory(id);
    if (!await this.exists(dir + '/' + GENERATION_COMMIT)) return undefined;
    const record = JSON.parse(await this.read(dir + '/' + GENERATION_COMMIT)) as IconPackGeneration;
    if (record === null || typeof record !== 'object' || record.version !== 1 || record.id !== id ||
      typeof record.timestamp !== 'number' || !Number.isFinite(record.timestamp) || record.timestamp < 0 ||
      typeof record.metadata !== 'string' || record.metadata.length === 0) {
      throw new Error('ICON_GENERATION_COMMIT_INVALID');
    }
    const meta = JSON.parse(record.metadata) as Record<string, Object>;
    if (meta === null || typeof meta !== 'object' || meta['version'] !== 1 ||
      meta['timestamp'] !== record.timestamp || !Array.isArray(meta['packs'])) {
      throw new Error('ICON_GENERATION_COMMIT_INVALID');
    }
    if (!await this.exists(dir + '/' + ICON_PACK_ZIP) ||
      await this.read(dir + '/' + ICON_PACK_META) !== record.metadata) return undefined;
    return record;
  }

  private async ids(): Promise<string[]> {
    try {
      const names = await this.fs.listFiles(this.root());
      return names.filter((name: string): boolean => /^generation-[A-Za-z0-9]{6}$/.test(name));
    } catch (error) {
      if (fileIoDiagnosticCode(error) === 13900002) return [];
      throw error as Error;
    }
  }

  private compare(left: IconPackGeneration, right: IconPackGeneration): number {
    if (left.timestamp !== right.timestamp) return left.timestamp < right.timestamp ? -1 : 1;
    return left.id === right.id ? 0 : left.id < right.id ? -1 : 1;
  }

  private async generations(): Promise<IconPackGeneration[]> {
    const records: IconPackGeneration[] = [];
    for (const id of await this.ids()) {
      try {
        const record = await this.generation(id);
        if (record !== undefined) records.push(record);
      } catch (error) {
        // 云同步可能先送达 commit；该代不可读不能阻塞另一完整代，也不能授予自动删除资格。
        this.report(error);
      }
    }
    return records.sort((left: IconPackGeneration, right: IconPackGeneration): number => this.compare(right, left));
  }

  /** 精确拥有的一代只含三个协议文件；陌生内容拒绝递归删除，不按目录名前缀认领。 */
  private async removeGeneration(id: string): Promise<void> {
    const dir = this.directory(id);
    const names = await this.fs.listFiles(dir);
    if (names.some((name: string): boolean => ![ICON_PACK_ZIP, ICON_PACK_META, GENERATION_COMMIT].includes(name))) {
      throw new Error('ICON_GENERATION_FOREIGN_CONTENT');
    }
    // 归属 sidecar 最后删除；任一前置删除失败保留原范围重试依据。
    for (const name of [ICON_PACK_ZIP, GENERATION_COMMIT, ICON_PACK_META]) {
      if (!names.includes(name)) continue;
      try {
        await this.fs.deleteFile(dir + '/' + name);
      } catch (error) {
        if (fileIoDiagnosticCode(error) !== 13900002) throw error as Error;
      }
    }
    try {
      await this.fs.removeDir(dir);
    } catch (error) {
      if (fileIoDiagnosticCode(error) !== 13900002) throw error as Error;
    }
  }

  /** 只收集严格早于本次已校验提交代的旧代；过期 GC 不能删后来者或自身代。 */
  private async prune(own: IconPackGeneration): Promise<void> {
    const records = await this.generations();
    for (const record of records.slice(RETAIN_GENERATIONS)) {
      if (this.compare(record, own) >= 0) continue;
      const dir = this.directory(own.id);
      if (!await this.exists(dir + '/' + ICON_PACK_ZIP) ||
        await this.read(dir + '/' + ICON_PACK_META) !== own.metadata ||
        !await this.validate(dir + '/' + ICON_PACK_ZIP, own.metadata)) {
        throw new Error('ICON_GENERATION_RETENTION_GUARD');
      }
      await this.removeGeneration(record.id);
    }
  }

  async publish(tempZipPath: string, metadata: string): Promise<boolean> {
    let id = '';
    let committed = false;
    try {
      const parsed = JSON.parse(metadata) as Record<string, Object>;
      const timestamp = parsed['timestamp'];
      if (parsed['version'] !== 1 || typeof timestamp !== 'number' || !Number.isFinite(timestamp) ||
        timestamp < 0 || !Array.isArray(parsed['packs']) || metadata.length > MAX_METADATA_BYTES / 2) {
        throw new Error('ICON_GENERATION_METADATA_INVALID');
      }
      try {
        await this.fs.makeDir(this.root());
      } catch (error) {
        if (!(await this.fs.stat(this.root())).isDirectory) throw error as Error;
      }
      if ((await this.ids()).length >= MAX_GENERATIONS) throw new Error('ICON_GENERATION_LIMIT');
      const dir = await this.fs.makeTempDir(this.root() + '/generation-XXXXXX');
      id = dir.substring(dir.lastIndexOf('/') + 1);
      if (this.directory(id) !== dir) throw new Error('ICON_GENERATION_ID_INVALID');
      await this.fs.copyFile(tempZipPath, dir + '/' + ICON_PACK_ZIP);
      await this.fs.writeTextFile(dir + '/' + ICON_PACK_META, metadata, this.context);
      await this.fs.syncFile(dir + '/' + ICON_PACK_ZIP);
      await this.fs.syncFile(dir + '/' + ICON_PACK_META);
      if (!await this.validate(dir + '/' + ICON_PACK_ZIP, metadata)) throw new Error('ICON_GENERATION_VERIFY_FAILED');
      const record: IconPackGeneration = { version: 1, id, timestamp, metadata };
      // write/close 抛错也可能已让 commit 可见；一旦开始提交便不再把本代当临时产物删除。
      committed = true;
      await this.fs.writeTextFile(dir + '/' + GENERATION_COMMIT, JSON.stringify(record), this.context);
      // 读取仍须复核 ZIP 与 metadata，撕裂 commit 不授予恢复或自动删除资格。
      await this.fs.syncFile(dir + '/' + GENERATION_COMMIT);
      if (await this.read(dir + '/' + ICON_PACK_META) !== metadata ||
        !await this.validate(dir + '/' + ICON_PACK_ZIP, metadata)) throw new Error('ICON_GENERATION_VERIFY_FAILED');
      await this.prune(record);
      return true;
    } catch (error) {
      this.report(error);
      if (id.length > 0 && !committed) {
        try { await this.removeGeneration(id); } catch (cleanupError) { this.report(cleanupError); }
      }
      return false;
    }
  }

  async snapshot(): Promise<IconPackCloudSnapshot | undefined> {
    try {
      for (const record of await this.generations()) {
        const dir = this.directory(record.id);
        try {
          if (await this.validate(dir + '/' + ICON_PACK_ZIP, record.metadata)) {
            return { zipPath: dir + '/' + ICON_PACK_ZIP, metaPath: dir + '/' + ICON_PACK_META };
          }
        } catch (error) { this.report(error); }
      }
      // 旧 fixed-name 备份只读兼容；本协议绝不移动、覆盖或自动回收它。
      const zip = this.cloudDir + '/' + ICON_PACK_ZIP;
      const meta = this.cloudDir + '/' + ICON_PACK_META;
      if (await this.exists(zip) || await this.exists(meta) || (await this.ids()).length === 0) {
        return { zipPath: zip, metaPath: meta };
      }
      return undefined;
    } catch (error) {
      this.report(error);
      return undefined;
    }
  }

  /** 明确清理仅接收有效 generation id；设备范围按该代自己的元数据判断，无 ZIP 下载。 */
  async clear(deviceIds?: string[]): Promise<boolean> {
    let success = true;
    try {
      for (const id of await this.ids()) {
        try {
          if (deviceIds !== undefined) {
            const remaining = await this.fs.listFiles(this.directory(id));
            // 空目录已无任何业务文件，回收不删除备份且允许 rmdir 失败后的原范围重试。
            if (remaining.length > 0) {
              const metadata = JSON.parse(await this.read(this.directory(id) + '/' + ICON_PACK_META)) as Record<string, Object>;
              const deviceId = metadata['deviceId'];
              if (typeof deviceId !== 'string' || deviceId.length === 0 || deviceId === 'unknown_odid') {
                throw new Error('ICON_GENERATION_IDENTITY_UNAVAILABLE');
              }
              if (!deviceIds.includes(deviceId)) continue;
            }
          }
          await this.removeGeneration(id);
        } catch (error) { success = false; this.report(error); }
      }
      return success;
    } catch (error) {
      this.report(error);
      return false;
    }
  }
}

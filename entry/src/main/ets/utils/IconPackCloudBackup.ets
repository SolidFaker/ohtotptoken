import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs, cloudSync, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { buffer } from '@kit.ArkTS';
import { AppPreference, PREF_KEYS, BUILTIN_DEFAULT_PACK_ID, EVENT_NAMES } from './AppPreference';
import { TokenIconPacks } from './TokenUtils';
import { SyncTimeHelper } from './SyncTimeHelper';
import { HuaweiAccountManager } from './HuaweiAccountManager';
import { DeviceInfoHelper } from './DeviceInfoHelper';

const TAG = 'IconPackCloudBackup';
const DOMAIN = 0xFF00;
const ICON_PACK_BACKUP_ZIP = 'icon_packs_backup.zip';
const META_JSON_NAME = 'icon_packs_meta.json';
/**
 * 云端伴生元数据文件名（放在 cloudDir，与 zip 同级）。
 * 仅 ~1-2KB，包含时间戳、设备信息、图标包列表。
 * checkCloudBackupNewer 只读取此文件而不用解压整个 zip，大幅降低冷启动开销。
 */
const SYNC_META_FILE = 'icon_packs_sync_meta.json';

/**
 * 图标包云备份同步状态机
 *
 * 状态转换图：
 *   IDLE ──→ BACKING_UP ──→ IDLE   (备份图标包到云端)
 *   IDLE ──→ RESTORING   ──→ IDLE   (从云端恢复图标包)
 *   IDLE ──→ CLEARING    ──→ IDLE   (清除云端图标包备份)
 *   IDLE ──→ CHECKING    ──→ IDLE   (检查云端备份是否较新)
 *
 * 规则：只有 IDLE 状态才能转换到其他状态，任何操作结束后（无论成功/失败）均回到 IDLE。
 * 这确保了备份、恢复、清理、检查四类操作互斥，不会同时操作同一组文件。
 *
 * 生命周期：纯内存态（实例变量），不持久化。
 * - 应用重启后 singleton 重建，状态自动重置为 IDLE，不会出现永久锁死。
 * - 进程被系统回收同理。
 */
export enum IconPackSyncState {
  IDLE = 0,
  BACKING_UP = 1,
  RESTORING = 2,
  CLEARING = 3,
  CHECKING = 4,
}

export class IconPackRestoreResult {
  restoredCount: number = 0;
  restoredFiles: number = 0;
}

export class IconPackBackupStatus {
  exists: boolean = false;
  packCount: number = 0;
  size: number = 0;
  lastTime: string = '';
  sourceDeviceName: string = '';
  sourceDeviceId: string = '';
  packs: PackMetaEntry[] = [];
}

export class PackMetaEntry {
  uuid: string = '';
  name: string = '';
  version: number = 0;
  iconCount: number = 0;
}

/**
 * 备份 zip 内的元数据记录，包含时间戳、启用的图标包列表、已删除的图标包列表等。
 */
class IconPackMetaRecord {
  version: number = 0;
  timestamp: number = 0;
  enabledPacks: string[] = [];
  deletedPacks: string[] = [];
  packs: PackMetaEntry[] = [];
}

/**
 * 云端伴生元数据文件的结构（SYNC_META_FILE）。
 * 与 zip 同级存放，供 checkCloudBackupNewer 直接读取，避免解压整个 zip。
 * 含设备信息便于 UI 展示"此备份来自 xxx 设备"。
 */
class SyncMetaRecord {
  version: number = 0;
  timestamp: number = 0;
  deviceId: string = '';
  deviceName: string = '';
  enabledPacks: string[] = [];
  deletedPacks: string[] = [];
  packs: PackMetaEntry[] = [];
}

/**
 * 图标包云备份/恢复管理器（单例）
 *
 * 职责：
 * 1. 将 icon_packs/ 和 user_icons/ 目录打包为 zip，通过 FileSync 上传到华为云
 * 2. 从云端下载 zip，解压并合并到本地 filesDir
 * 3. 管理 enabledPacks 列表的云端同步（随 token 备份一起序列化）
 *
 * 线程安全：ArkTS 单线程事件循环，通过 IconPackSyncState 状态机保证操作互斥，
 * 不需要真正的锁。所有公开异步方法在入口处 tryTransition，在 finally 中回到 IDLE。
 *
 * 状态机生命周期：纯内存态，不持久化。应用重启后 singleton 重建，自动恢复 IDLE。
 */
export class IconPackCloudBackup {
  private static instance: IconPackCloudBackup | null = null;
  private context: common.UIAbilityContext | undefined = undefined;
  private cloudDir: string = '';
  private filesDir: string = '';
  private cacheDir: string = '';
  private fileSync: cloudSync.FileSync | null = null;
  /** 状态机当前状态，纯内存态，重启自动重置 */
  private syncState: IconPackSyncState = IconPackSyncState.IDLE;

  private constructor() {
  }

  static getInstance(): IconPackCloudBackup {
    if (!IconPackCloudBackup.instance) {
      IconPackCloudBackup.instance = new IconPackCloudBackup();
    }
    return IconPackCloudBackup.instance;
  }

  async init(): Promise<void> {
    if (this.context) {
      return;
    }
    this.context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'init: failed to get appContext');
      return;
    }
    this.filesDir = this.context.filesDir;
    this.cloudDir = this.context.cloudFileDir;
    this.cacheDir = this.context.cacheDir;
  }

  /**
   * 冷启动自动恢复入口（Index.ets deferredInit 调用）
   *
   * 流程：IDLE→RESTORING → 前置条件检查 → 检查云端时间戳 → 恢复 → 合并 enabledPacks → 发事件 → IDLE
   * 直接调用 doCheckCloudBackupNewer/doRestoreIconPacks（私有方法，不经过状态检查），
   * 因为整个 check+restore 已在 RESTORING 状态保护下作为原子操作执行。
   */
  async checkAndAutoRestore(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) return false;

    if (!this.tryTransition(IconPackSyncState.RESTORING)) {
      hilog.warn(DOMAIN, TAG, `checkAndAutoRestore: state=${this.syncState}, skip`);
      return false;
    }
    try {
      const enabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
      if (!enabled) return false;
      if (!HuaweiAccountManager.getInstance().userLogin) return false;

      if (!await this.doCheckCloudBackupNewer()) return false;

      const result = await this.doRestoreIconPacks();
      if (result.restoredCount > 0 || result.restoredFiles > 0) {
        this.context.eventHub?.emit(EVENT_NAMES.ICON_PACK_CHANGED);
      }
      return result.restoredCount > 0 || result.restoredFiles > 0;
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /**
   * 备份图标包到云端（由 CloudBackupManager.backupToCloud 在 token 备份成功后 fire-and-forget 调用）
   *
   * 流程：IDLE→BACKING_UP → 检查本地是否有图标包 → 拷贝到 staging → 压缩 zip →
   *       复制到 cloudDir → FileSync.start() → IDLE
   */
  async backupIconPacks(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return false;
    }
    if (!this.tryTransition(IconPackSyncState.BACKING_UP)) {
      hilog.warn(DOMAIN, TAG, `backupIconPacks: state=${this.syncState}, skip`);
      return false;
    }
    try {
      return await this.doBackupIconPacks();
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 实际备份逻辑：staging 目录构建 → zip 压缩 → 复制到 cloudDir → 触发同步 */
  private async doBackupIconPacks(): Promise<boolean> {
    const iconPackDir = this.filesDir + '/icon_packs';
    const userIconDir = this.filesDir + '/user_icons';
    let hasContent = false;

    try {
      const packFiles = fs.listFileSync(iconPackDir);
      if (packFiles.length > 0) hasContent = true;
    } catch (_) {}

    try {
      const userFiles = fs.listFileSync(userIconDir);
      if (userFiles.length > 0) hasContent = true;
    } catch (_) {}

    if (!hasContent) {
      hilog.info(DOMAIN, TAG, 'backupIconPacks: no icon packs to backup, skip');
      return true;
    }

    const now = Date.now();
    const packEntries: PackMetaEntry[] = [];
    for (const p of TokenIconPacks.aegis_icon_packs) {
      const entry = new PackMetaEntry();
      entry.uuid = p.uuid;
      entry.name = p.name;
      entry.version = p.version;
      entry.iconCount = p.icons.length;
      packEntries.push(entry);
    }
    const meta = new IconPackMetaRecord();
    meta.version = 1;
    meta.timestamp = now;
    meta.enabledPacks = TokenIconPacks.enabled_packs;
    meta.deletedPacks = [];
    meta.packs = packEntries;

    const stagingDir = this.cacheDir + '/icon_pack_staging';
    const metaPath = stagingDir + '/' + META_JSON_NAME;
    const tempZipPath = this.cacheDir + '/' + ICON_PACK_BACKUP_ZIP;

    try {
      // 1. 创建 staging 目录
      try {
        await fs.mkdir(stagingDir);
      } catch (_) {}

      // 2. 写入元数据文件
      const metaFile = fs.openSync(metaPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(metaFile.fd, JSON.stringify(meta));
      fs.closeSync(metaFile);

      // 3. 递归拷贝 icon_packs 和 user_icons 到 staging（必须用 copyDirRecursive，fs.copyFile 不支持目录）
      try {
        const destIconDir = stagingDir + '/icon_packs';
        await fs.mkdir(destIconDir);
        await this.copyDirRecursive(iconPackDir, destIconDir);
      } catch (_) {}
      try {
        const destUserDir = stagingDir + '/user_icons';
        await fs.mkdir(destUserDir);
        await this.copyDirRecursive(userIconDir, destUserDir);
      } catch (_) {}

      // 4. 压缩 staging 目录为 zip
      const options: zlib.Options = {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
      };
      await zlib.compressFile(stagingDir, tempZipPath, options);

      // 5. 将 zip 复制到 cloudDir
      const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
      await fs.copyFile(tempZipPath, cloudZipPath);

      // 6. 写入伴生元数据文件（~1-2KB，含设备信息、时间戳、图标包列表）
      const syncMeta = new SyncMetaRecord();
      syncMeta.version = 1;
      syncMeta.timestamp = now;
      syncMeta.deviceId = DeviceInfoHelper.getInstance().getDeviceId();
      syncMeta.deviceName = DeviceInfoHelper.getInstance().getDeviceName();
      syncMeta.enabledPacks = TokenIconPacks.enabled_packs;
      syncMeta.deletedPacks = [];
      syncMeta.packs = packEntries;
      const syncMetaPath = this.cloudDir + '/' + SYNC_META_FILE;
      const syncMetaFile = fs.openSync(syncMetaPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(syncMetaFile.fd, JSON.stringify(syncMeta));
      fs.closeSync(syncMetaFile);

      // 7. 触发云端同步（zip + 伴生文件一起上传）
      await this.syncToCloud();

      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${now}`);
      hilog.info(DOMAIN, TAG, `backupIconPacks: completed, timestamp=${now}`);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `backupIconPacks: error=${JSON.stringify(e)}`);
      return false;
    } finally {
      await this.removeDirRecursive(stagingDir);
      try {
        await fs.unlink(tempZipPath);
      } catch (_) {}
    }
  }

  /**
   * 检查云端备份是否比本地更新（公开入口，外部可独立调用）
   * 内部先做 5 分钟去抖，再读取伴生元数据文件比较时间戳（不解压 zip）。
   */
  async checkCloudBackupNewer(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return false;
    }
    if (!this.tryTransition(IconPackSyncState.CHECKING)) {
      hilog.warn(DOMAIN, TAG, `checkCloudBackupNewer: state=${this.syncState}, skip`);
      return false;
    }
    try {
      return await this.doCheckCloudBackupNewer();
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 读取云端伴生元数据文件比较 timestamp，无需下载/解压 zip */
  private async doCheckCloudBackupNewer(): Promise<boolean> {
    const lastRestoreStr = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
    const lastRestoreTs = SyncTimeHelper.parseStoredTimestamp(lastRestoreStr);
    if (lastRestoreTs > 0 && SyncTimeHelper.isWithinMinutes(lastRestoreTs, 5)) {
      hilog.info(DOMAIN, TAG, 'checkCloudBackupNewer: restored within 5 min, skip');
      return false;
    }

    const syncMetaPath = this.cloudDir + '/' + SYNC_META_FILE;
    try {
      const stat = await fs.stat(syncMetaPath);
      if (stat.location === 2) {
        await this.cacheFile(syncMetaPath);
      }

      const content = await this.readFileContent(syncMetaPath);
      const meta = JSON.parse(content) as SyncMetaRecord;
      const cloudTs = meta.timestamp || 0;
      hilog.info(DOMAIN, TAG, `checkCloudBackupNewer: cloudTs=${cloudTs}, localTs=${lastRestoreTs}, device=${meta.deviceName}`);
      return cloudTs > lastRestoreTs;
    } catch (e) {
      hilog.info(DOMAIN, TAG, `checkCloudBackupNewer: no sync meta or error=${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 从云端恢复图标包（公开入口，checkAndAutoRestore 内部直接调用 doRestoreIconPacks）
   *
   * 流程：IDLE→RESTORING → 下载解压 → 拷贝到 filesDir → 处理 deletedPacks →
   *       刷新内存状态 → 合并 enabledPacks → IDLE
   */
  async restoreIconPacks(): Promise<IconPackRestoreResult> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return new IconPackRestoreResult();
    }
    if (!this.tryTransition(IconPackSyncState.RESTORING)) {
      hilog.warn(DOMAIN, TAG, `restoreIconPacks: state=${this.syncState}, skip`);
      return new IconPackRestoreResult();
    }
    try {
      return await this.doRestoreIconPacks();
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 实际恢复逻辑：解压 → 拷贝文件 → 处理已删除包 → 刷新内存 → 合并启用列表 */
  private async doRestoreIconPacks(): Promise<IconPackRestoreResult> {
    const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
    try {
      // 若文件仍在云端（location=2），先缓存到本地
      const stat = await fs.stat(cloudZipPath);
      if (stat.location === 2) {
        await this.cacheFile(cloudZipPath);
      }

      // 解压到临时目录（cacheDir，不直接写 filesDir）
      const tempDir = this.cacheDir + '/icon_pack_restore';
      try {
        await fs.mkdir(tempDir);
      } catch (_) {}

      await zlib.decompressFile(cloudZipPath, tempDir);

      // 确保目标目录存在
      const iconPackDir = this.filesDir + '/icon_packs';
      const userIconDir = this.filesDir + '/user_icons';
      try {
        fs.mkdirSync(iconPackDir);
      } catch (_) {}
      try {
        fs.mkdirSync(userIconDir);
      } catch (_) {}

      // 选择性拷贝：只还原 icon_packs 和 user_icons 子目录
      const tempIconPacks = tempDir + '/icon_packs';
      const tempUserIcons = tempDir + '/user_icons';
      try {
        await this.copyDirRecursive(tempIconPacks, iconPackDir);
      } catch (_) {}
      try {
        await this.copyDirRecursive(tempUserIcons, userIconDir);
      } catch (_) {}

      // 读取元数据
      let meta: IconPackMetaRecord | null = null;
      try {
        const metaContent = await this.readFileContent(tempDir + '/' + META_JSON_NAME);
        meta = JSON.parse(metaContent) as IconPackMetaRecord;
      } catch (_) {}

      // 清理临时目录
      await this.removeDirRecursive(tempDir);

      if (meta) {
        // 处理云端标记为已删除的图标包
        if (meta.deletedPacks && meta.deletedPacks.length > 0) {
          for (const deletedUuid of meta.deletedPacks) {
            const pack = TokenIconPacks.aegis_icon_packs.find(p => p.uuid === deletedUuid);
            if (pack) {
              try {
                await TokenIconPacks.removeAegisIconPack(pack);
              } catch (e) {
                hilog.warn(DOMAIN, TAG, `restoreIconPacks: failed to delete pack ${deletedUuid}: ${JSON.stringify(e)}`);
              }
            }
          }
        }

        // 在 merge 前重新从磁盘加载图标包，使 TokenIconPacks 内存状态包含新拷贝的文件
        await this.refreshIconPackState();

        // 合并策略：以云端 enabledPacks 为基础，追加本地独有的包（不丢失本地新增包）
        const basePacks = meta.enabledPacks && meta.enabledPacks.length > 0
          ? meta.enabledPacks
          : [BUILTIN_DEFAULT_PACK_ID];
        let merged = [...basePacks];
        const localPacks = TokenIconPacks.aegis_icon_packs.map(p => p.uuid);
        for (const localUuid of localPacks) {
          if (!merged.includes(localUuid)) {
            merged.push(localUuid);
          }
        }

        TokenIconPacks.enabled_packs = merged;
        AppPreference.saveEnabledPacks(merged);
        AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${meta.timestamp}`);

        hilog.info(DOMAIN, TAG, `restoreIconPacks: merged enabledPacks=${JSON.stringify(merged)}`);
      }

      const result = new IconPackRestoreResult();
      result.restoredCount = meta?.packs?.length ?? 0;
      result.restoredFiles = 1;
      return result;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `restoreIconPacks: error=${JSON.stringify(e)}`);
      return new IconPackRestoreResult();
    }
  }

  /**
   * 从磁盘重新加载图标包到 TokenIconPacks 内存（在 merge enabledPacks 前调用）
   * 包含：user_icons 目录 + icon_packs 下所有子目录 + enabled_packs 偏好
   */
  private async refreshIconPackState(): Promise<void> {
    const iconPackDir = this.filesDir + '/icon_packs';
    const userIconDir = this.filesDir + '/user_icons';

    await TokenIconPacks.addUserIconPack(userIconDir);
    try {
      const paths = await fs.listFile(iconPackDir);
      for (const path of paths) {
        try {
          await TokenIconPacks.addAegisIconPack(iconPackDir + '/' + path);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, `refreshIconPackState: failed to load pack ${path}: ${JSON.stringify(err)}`);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, `refreshIconPackState: failed to list ${iconPackDir}: ${JSON.stringify(err)}`);
    }
    TokenIconPacks.enabled_packs = AppPreference.loadEnabledPacks();
  }

  /** 查询云端图标包备份状态（是否存在、包数量、大小、来源设备等），供 UI 展示 */
  async getCloudBackupStatus(): Promise<IconPackBackupStatus> {
    await this.init();
    const result = new IconPackBackupStatus();

    const lastTimeStr = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
    const lastTs = SyncTimeHelper.parseStoredTimestamp(lastTimeStr);
    result.lastTime = SyncTimeHelper.formatTimestamp(lastTs);

    if (!this.context || !this.cloudDir) {
      return result;
    }

    const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
    try {
      const stat = await fs.stat(cloudZipPath);
      result.exists = true;
      result.size = stat.size;
    } catch (_) {}

    // 从伴生元数据文件读取详细信息（包列表、来源设备等）
    const syncMetaPath = this.cloudDir + '/' + SYNC_META_FILE;
    try {
      const smStat = await fs.stat(syncMetaPath);
      if (smStat.location === 2) {
        await this.cacheFile(syncMetaPath);
      }
      const content = await this.readFileContent(syncMetaPath);
      const meta = JSON.parse(content) as SyncMetaRecord;
      result.packCount = meta.packs?.length ?? 0;
      result.sourceDeviceId = meta.deviceId ?? '';
      result.sourceDeviceName = meta.deviceName ?? '';
      result.packs = meta.packs ?? [];
    } catch (_) {
      // 伴生文件不存在（旧版本备份），回退到本地内存
      result.packCount = TokenIconPacks.aegis_icon_packs.length;
    }

    return result;
  }

  /** 删除云端图标包备份 zip（由 CloudBackupManager 的三个 clear 方法调用） */
  async clearCloudBackup(): Promise<boolean> {
    await this.init();
    if (!this.context || !this.cloudDir) {
      return false;
    }
    if (!this.tryTransition(IconPackSyncState.CLEARING)) {
      hilog.warn(DOMAIN, TAG, `clearCloudBackup: state=${this.syncState}, skip`);
      return false;
    }
    try {
      const cloudZipPath = this.cloudDir + '/' + ICON_PACK_BACKUP_ZIP;
      await fs.unlink(cloudZipPath);
      // 同步删除伴生元数据文件
      try {
        await fs.unlink(this.cloudDir + '/' + SYNC_META_FILE);
      } catch (_) {}
      await this.syncToCloud();
      hilog.info(DOMAIN, TAG, 'clearCloudBackup: completed');
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearCloudBackup: error=${JSON.stringify(e)}`);
      return false;
    } finally {
      this.syncState = IconPackSyncState.IDLE;
    }
  }

  /** 状态机原子转换：仅 IDLE→target 允许，其他状态拒绝（返回 false） */
  private tryTransition(target: IconPackSyncState): boolean {
    if (this.syncState !== IconPackSyncState.IDLE) {
      return false;
    }
    this.syncState = target;
    return true;
  }

  /** 暴露当前状态机状态，供 UI 层查询同步进度 */
  getState(): IconPackSyncState {
    return this.syncState;
  }

  /** 触发 FileSync.start() 将 cloudDir 变更同步到云端（复用实例避免重复创建） */
  private async syncToCloud(): Promise<void> {
    if (!this.fileSync) {
      this.fileSync = new cloudSync.FileSync();
    }
    try {
      await this.fileSync.start();
      hilog.info(DOMAIN, TAG, 'syncToCloud: started');
    } catch (e) {
      hilog.error(DOMAIN, TAG, `syncToCloud: error=${JSON.stringify(e)}`);
    }
  }

  /** 将云端文件（location=2）缓存到本地，以便读取内容 */
  private async cacheFile(filePath: string): Promise<void> {
    const uri = fileUri.getUriFromPath(filePath);
    const cache = new cloudSync.CloudFileCache();
    try {
      await cache.start(uri);
      hilog.info(DOMAIN, TAG, `cacheFile: cached ${filePath}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `cacheFile: error=${JSON.stringify(e)}`);
    }
  }

  private async readFileContent(filePath: string): Promise<string> {
    const stat = await fs.stat(filePath);
    const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    const bufferArray = new ArrayBuffer(stat.size);
    const readLen = fs.readSync(file.fd, bufferArray);
    fs.closeSync(file);
    const uint8Array = new Uint8Array(bufferArray.slice(0, readLen));
    return buffer.from(uint8Array).toString('utf-8');
  }

  private async removeDirRecursive(dirPath: string): Promise<void> {
    try {
      const files = await fs.listFile(dirPath);
      for (const file of files) {
        const fullPath = dirPath + '/' + file;
        try {
          const stat = await fs.stat(fullPath);
          if (stat.isDirectory()) {
            await this.removeDirRecursive(fullPath);
          } else {
            await fs.unlink(fullPath);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `removeDirRecursive: failed to remove ${fullPath}: ${JSON.stringify(e)}`);
        }
      }
      await fs.rmdir(dirPath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `removeDirRecursive: failed to process ${dirPath}: ${JSON.stringify(e)}`);
    }
  }

  private async copyDirRecursive(srcDir: string, destDir: string): Promise<void> {
    try {
      const files = await fs.listFile(srcDir);
      for (const file of files) {
        const srcPath = srcDir + '/' + file;
        const destPath = destDir + '/' + file;
        try {
          const stat = await fs.stat(srcPath);
          if (stat.isDirectory()) {
            try {
              await fs.mkdir(destPath);
            } catch (_) {}
            await this.copyDirRecursive(srcPath, destPath);
          } else {
            await fs.copyFile(srcPath, destPath);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `copyDirRecursive: failed to copy ${srcPath}: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `copyDirRecursive: failed to read ${srcDir}: ${JSON.stringify(e)}`);
    }
  }
}

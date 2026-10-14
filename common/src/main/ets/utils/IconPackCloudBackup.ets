import { common } from '@kit.AbilityKit';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { CloudFileCacher, CloudFileCacheLoader, prepareCloudFileRead } from './CloudFileCacheLoader';
import { CloudBackupOperationGate, CloudBackupOperationKind, CloudBackupOperationLease } from './CloudBackupOperationGate';
import { CloudBackupSyncService } from './CloudBackupSyncService';
import {
  CloudBackupDiagnostics, DiagnosticArtifact, DiagnosticContext, DiagnosticErrorDomain,
  DiagnosticKind, DiagnosticReason, DiagnosticResult, DiagnosticStage,
} from './CloudBackupDiagnostics';
import { AppPreference, PREF_KEYS, BUILTIN_DEFAULT_PACK_ID, EVENT_NAMES } from './AppPreference';
import { TokenIconPacks, AegisIconPack } from './TokenUtils';
import { SyncTimeHelper } from './SyncTimeHelper';
import { HuaweiAccountManager } from './HuaweiAccountManager';
import { DeviceInfoHelper } from './DeviceInfoHelper';
import { FsGateway, FileIoFsGateway, FsStatInfo } from './StoragePorts';
import { IconPackPublication, IconPackCloudSnapshot } from './IconPackPublication';

const ICON_PACK_BACKUP_ZIP = 'icon_packs_backup.zip';
const META_JSON_NAME = 'icon_packs_meta.json';
/**
 * 云端伴生元数据文件名（放在 cloudDir，与 zip 同级）。
 * 仅 ~1-2KB，包含时间戳、设备信息、图标包列表。
 * checkCloudBackupNewer 只读取此文件而不用解压整个 zip，大幅降低冷启动开销。
 */
const SYNC_META_FILE = 'icon_packs_sync_meta.json';

/** zip 压缩/解压端口（生产：zlib，LocalUnit 不可用）。 */
export interface IconPackArchiver {
  compress(srcDir: string, destZip: string): Promise<void>;
  decompress(zipPath: string, destDir: string): Promise<void>;
}

class ZlibIconPackArchiver implements IconPackArchiver {
  async compress(srcDir: string, destZip: string): Promise<void> {
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
    };
    await zlib.compressFile(srcDir, destZip, options);
  }

  async decompress(zipPath: string, destDir: string): Promise<void> {
    await zlib.decompressFile(zipPath, destDir);
  }
}

/**
 * 恢复时的启用列表合并策略（纯函数）：
 * 以云端 enabledPacks 为基础（为空则回退内置默认包），追加本地独有的包（不丢失本地新增包）。
 */
export function mergeEnabledPacks(cloudEnabledPacks: string[], localPackUuids: string[]): string[] {
  const basePacks = cloudEnabledPacks && cloudEnabledPacks.length > 0
    ? cloudEnabledPacks
    : [BUILTIN_DEFAULT_PACK_ID];
  const merged = [...basePacks];
  for (const localUuid of localPackUuids) {
    if (!merged.includes(localUuid)) {
      merged.push(localUuid);
    }
  }
  return merged;
}

/** 设备标识端口（生产：DeviceInfoHelper，LocalUnit 不可用）。 */
export interface IconPackDevicePort {
  deviceId(): string;
  deviceName(): string;
}

class DeviceInfoAdapter implements IconPackDevicePort {
  deviceId(): string {
    return DeviceInfoHelper.getInstance().getDeviceId();
  }

  deviceName(): string {
    return DeviceInfoHelper.getInstance().getDeviceName();
  }
}

/**
 * 图标包注册表端口（Phase 3，docs/TEST_PLAN.md 第 4 节）。
 * 恢复成功链路（deletedPacks 清理 → 磁盘重载 → enabledPacks 合并应用）经此端口
 * 访问 TokenIconPacks 静态状态，LocalUnit 注入内存假实现全测；
 * 生产适配器保证真机行为不变（磁盘加载/偏好读写归 TokenIconPacks/AppPreference）。
 */
export interface IconPackRegistry {
  /** 当前已加载的自定义图标包（含无效包） */
  listPacks(): AegisIconPack[];
  /** 从 user_icons 目录重载用户图标 */
  loadUserIcons(userIconDir: string): Promise<void>;
  /** 从设备目录加载图标包（pack.json 解析 + 磁盘读取） */
  addPackFromDevice(path: string): Promise<void>;
  /** 删除图标包（清理预览缓存、enabledPacks 过滤、磁盘目录删除） */
  removePack(pack: AegisIconPack): Promise<void>;
  getEnabledPacks(): string[];
  setEnabledPacks(packs: string[]): void;
  /** 从偏好重新加载 enabledPacks 到内存（恢复前的干净基线） */
  reloadEnabledPacksFromPreference(): void;
}

/** {@link IconPackRegistry} 生产实现：委托 TokenIconPacks 静态接口。 */
class TokenIconPacksRegistry implements IconPackRegistry {
  listPacks(): AegisIconPack[] {
    return TokenIconPacks.aegis_icon_packs;
  }

  async loadUserIcons(userIconDir: string): Promise<void> {
    await TokenIconPacks.addUserIconPack(userIconDir);
  }

  async addPackFromDevice(path: string): Promise<void> {
    await TokenIconPacks.addAegisIconPack(path);
  }

  async removePack(pack: AegisIconPack): Promise<void> {
    await TokenIconPacks.removeAegisIconPack(pack);
  }

  getEnabledPacks(): string[] {
    return TokenIconPacks.enabled_packs;
  }

  setEnabledPacks(packs: string[]): void {
    TokenIconPacks.enabled_packs = packs;
  }

  reloadEnabledPacksFromPreference(): void {
    TokenIconPacks.enabled_packs = AppPreference.loadEnabledPacks();
  }
}

/** LocalUnit 测试注入项（目录就绪时跳过 init() 的 AppStorage 依赖）。 */
export interface IconPackSyncStarter {
  /** 仅表示同步提交被接受，不表示远端已经完成。 */
  start(): Promise<boolean>;
}

export interface IconPackBackupTestDeps {
  fs?: FsGateway;
  cache?: CloudFileCacher;
  sync?: IconPackSyncStarter;
  archiver?: IconPackArchiver;
  device?: IconPackDevicePort;
  registry?: IconPackRegistry;
  filesDir?: string;
  cloudDir?: string;
  cacheDir?: string;
  tempDir?: string;
}

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
  /** 实际拷贝落地的文件数（不再硬编码）。 */
  restoredFiles: number = 0;
  /** 文件拷贝失败数；注册表加载/删除、元数据读取或临时清理失败各记一次。
   * 非 0 表示恢复不完整，不得推进同步水位或被调用方当作完整成功。 */
  failedFiles: number = 0;
}

/** 目录递归拷贝的结果计数；failed > 0 表示收集不完整，不得宣称完整备份。 */
class IconPackDirCopyResult {
  copied: number = 0;
  failed: number = 0;
}

export class IconPackBackupStatus {
  exists: boolean = false;
  /** 为 false 时 packCount 的默认值不是已知的远端数量。 */
  metadataKnown: boolean = false;
  /** 发布记录未收敛或无法验证；不得显示为“从未备份”。 */
  publicationUnresolved: boolean = false;
  /** 伴生元数据文件确定不存在（无内容短路从未写出），是确定状态而非读取失败。 */
  metadataAbsent: boolean = false;
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

/** 显式传递上下文，不使用可变的全局“当前操作”。 */
class IconPackOperation {
  lease: CloudBackupOperationLease;
  ownLease: boolean;
  context: DiagnosticContext;
  ownContext: boolean;
  unknownIo: boolean = false;

  constructor(lease: CloudBackupOperationLease, ownLease: boolean,
    context: DiagnosticContext, ownContext: boolean) {
    this.lease = lease;
    this.ownLease = ownLease;
    this.context = context;
    this.ownContext = ownContext;
  }
}

/**
 * 图标包云备份/恢复管理器（单例）
 *
 * 职责：
 * 1. 将 icon_packs/ 和 user_icons/ 目录打包为 zip，通过 FileSync 上传到华为云
 * 2. 从云端下载 zip，解压并合并到本地 filesDir
 * 3. 管理 enabledPacks 列表的云端同步（随 token 备份一起序列化）
 *
 * 线程安全：共享 gate 覆盖令牌与图标 I/O，本地 IconPackSyncState 防止同许可重入。
 * 独立入口取得许可后才初始化；嵌套入口复用合法所有者，finally 不释放外层许可。
 * 取消未确认时状态回到 IDLE 结束 loading，但 gate 保留至原所有者显式排空。
 *
 * 状态机生命周期：纯内存态，不持久化。应用重启后 singleton 重建，自动恢复 IDLE。
 *
 * ## Phase 2 解耦
 * 文件系统经 {@link FsGateway} 端口、压缩经 {@link IconPackArchiver} 端口访问，
 * 状态机/去抖/合并决策在 LocalUnit 下可测（见 docs/TEST_PLAN.md 第 4 节）。
 */
export class IconPackCloudBackup {
  private static instance: IconPackCloudBackup | null = null;
  private context: common.UIAbilityContext | undefined = undefined;
  private cloudDir: string = '';
  private filesDir: string = '';
  private cacheDir: string = '';
  private tempDir: string = '';
  private pendingCleanupLease: CloudBackupOperationLease | undefined = undefined;
  private cleanupRetryRunning: boolean = false;
  /** 状态机当前状态，纯内存态，重启自动重置 */
  private syncState: IconPackSyncState = IconPackSyncState.IDLE;
  private testDeps: IconPackBackupTestDeps | null = null;
  private readonly productionFs: FsGateway = new FileIoFsGateway();
  private readonly productionRegistry: IconPackRegistry = new TokenIconPacksRegistry();

  private constructor() {
  }

  static getInstance(): IconPackCloudBackup {
    if (!IconPackCloudBackup.instance) {
      IconPackCloudBackup.instance = new IconPackCloudBackup();
    }
    return IconPackCloudBackup.instance;
  }

  /** 测试注入：LocalUnit 下 fileIo/zlib 不可用，替换文件系统/压缩端口与目录。 */
  useDepsForTest(deps: IconPackBackupTestDeps): void {
    this.testDeps = deps;
    if (deps.cloudDir !== undefined || deps.filesDir !== undefined || deps.cacheDir !== undefined) {
      // 语义上 context 已就绪：init() 直接短路，不再读 AppStorage
      this.context = new Object() as common.UIAbilityContext;
      this.cloudDir = deps.cloudDir !== undefined ? deps.cloudDir : this.cloudDir;
      this.filesDir = deps.filesDir !== undefined ? deps.filesDir : this.filesDir;
      this.cacheDir = deps.cacheDir !== undefined ? deps.cacheDir : this.cacheDir;
      this.tempDir = deps.tempDir !== undefined ? deps.tempDir : this.cacheDir;
    }
  }

  /** 重置测试注入（恢复生产端口与未初始化状态）。 */
  resetForTest(): void {
    if (this.testDeps !== null && this.pendingCleanupLease !== undefined) {
      this.pendingCleanupLease.resolveUnknownIo();
      this.pendingCleanupLease.release();
    }
    this.pendingCleanupLease = undefined;
    this.cleanupRetryRunning = false;
    this.testDeps = null;
    this.context = undefined;
    this.cloudDir = '';
    this.filesDir = '';
    this.cacheDir = '';
    this.tempDir = '';
    this.syncState = IconPackSyncState.IDLE;
  }

  private get fs(): FsGateway {
    if (this.testDeps === null) return this.productionFs;
    if (this.testDeps.fs === undefined) throw new Error('Icon file dependency unavailable');
    return this.testDeps.fs;
  }

  private get archiver(): IconPackArchiver {
    if (this.testDeps === null) return new ZlibIconPackArchiver();
    if (this.testDeps.archiver === undefined) throw new Error('Icon archive dependency unavailable');
    return this.testDeps.archiver;
  }

  private get devicePort(): IconPackDevicePort {
    if (this.testDeps === null) return new DeviceInfoAdapter();
    if (this.testDeps.device === undefined) throw new Error('Icon device dependency unavailable');
    return this.testDeps.device;
  }

  private get registry(): IconPackRegistry {
    if (this.testDeps === null) return this.productionRegistry;
    if (this.testDeps.registry === undefined) throw new Error('Icon registry dependency unavailable');
    return this.testDeps.registry;
  }

  async init(): Promise<void> {
    if (this.context || this.testDeps !== null) {
      return;
    }
    this.context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (!this.context) {
      return;
    }
    this.filesDir = this.context.filesDir;
    this.cloudDir = this.context.cloudFileDir;
    this.cacheDir = this.context.cacheDir;
    this.tempDir = this.context.tempDir;
  }

  /**
   * 冷启动自动恢复入口（Index.ets deferredInit 调用）
   *
   * 流程：IDLE→RESTORING → 前置条件检查 → 检查云端时间戳 → 恢复 → 合并 enabledPacks → 发事件 → IDLE
   * 直接调用 doCheckCloudBackupNewer/doRestoreIconPacks（私有方法，不经过状态检查），
   * 因为整个 check+restore 已在 RESTORING 状态保护下作为原子操作执行。
   */
  async checkAndAutoRestore(owner?: CloudBackupOperationLease, ctx?: DiagnosticContext): Promise<boolean> {
    const operation = this.beginOperation(IconPackSyncState.RESTORING, owner, ctx);
    if (operation === undefined) return false;
    try {
      if (!await this.prepareContext(operation.context)) return false;
      const enabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
      if (!enabled) return false;
      if (!HuaweiAccountManager.getInstance().userLogin) return false;

      if (!await this.doCheckCloudBackupNewer(operation)) return false;

      const result = await this.doRestoreIconPacks(operation);
      if (result.restoredCount > 0 || result.restoredFiles > 0) {
        this.context?.eventHub?.emit(EVENT_NAMES.ICON_PACK_CHANGED);
      }
      // 部分落地仍可刷新图标，但失败必须被消费，不能误报完整恢复并阻断同版本重试。
      if (result.failedFiles > 0) return false;
      return result.restoredCount > 0 || result.restoredFiles > 0;
    } catch (error) {
      CloudBackupDiagnostics.fail(operation.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.APP, error);
      return false;
    } finally {
      this.finishOperation(operation);
    }
  }

  /**
   * 备份图标包到云端；管理器等待图标操作完成，复用许可并在最后统一提交同步。
   *
   * 流程：IDLE→BACKING_UP → 检查本地是否有图标包 → 拷贝到 staging → 压缩 zip →
   *       复制到 cloudDir → FileSync.start() → IDLE
   */
  async backupIconPacks(owner?: CloudBackupOperationLease, deferSync: boolean = false,
    ctx?: DiagnosticContext): Promise<boolean> {
    const operation = this.beginOperation(IconPackSyncState.BACKING_UP, owner, ctx);
    if (operation === undefined) return false;
    try {
      if (!await this.prepareContext(operation.context)) return false;
      return await this.doBackupIconPacks(operation, deferSync);
    } catch (error) {
      CloudBackupDiagnostics.fail(operation.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.APP, error);
      return false;
    } finally {
      this.finishOperation(operation);
    }
  }

  /** tempDir 收集／压缩，云端独占新代校验并提交；不移动或覆盖任何现有云备份。 */
  private async doBackupIconPacks(operation: IconPackOperation, deferSync: boolean): Promise<boolean> {
    const iconPackDir = this.filesDir + '/icon_packs';
    const userIconDir = this.filesDir + '/user_icons';
    let hasContent = false;
    let listingFailed = false;

    try {
      const packFiles = await this.fs.listFiles(iconPackDir);
      if (packFiles.length > 0) hasContent = true;
    } catch (error) {
      // 目录确实不存在视为无内容；其他列举失败不得当作"无内容"跳过——那是假成功。
      if (!this.isMissingFile(error)) listingFailed = true;
    }

    try {
      const userFiles = await this.fs.listFiles(userIconDir);
      if (userFiles.length > 0) hasContent = true;
    } catch (error) {
      if (!this.isMissingFile(error)) listingFailed = true;
    }

    if (listingFailed) {
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
        { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.IO_ERROR });
      return false;
    }

    if (!hasContent) {
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.OK,
        { artifact: DiagnosticArtifact.ICON });
      return true;
    }

    const publication = this.publication(operation);

    const now = Date.now();
    const packEntries: PackMetaEntry[] = [];
    for (const p of this.registry.listPacks()) {
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
    meta.enabledPacks = this.registry.getEnabledPacks();
    meta.deletedPacks = [];
    meta.packs = packEntries;

    const stagingDir = this.tempDir + '/icon_pack_staging';
    const metaPath = stagingDir + '/' + META_JSON_NAME;
    const tempZipPath = this.tempDir + '/' + ICON_PACK_BACKUP_ZIP;
    let completed = false;
    try {
      // 1. 清理并创建专用 cache staging 目录；清理失败不能混入旧产物继续发布。
      if (!await this.removeDirRecursive(stagingDir, operation.context)) return false;
      try {
        await this.fs.makeDir(stagingDir);
      } catch (_) {}

      // 2. 写入元数据文件
      await this.fs.writeTextFile(metaPath, JSON.stringify(meta));

      // 3. 递归拷贝 icon_packs 和 user_icons 到 staging（fs.copyFile 不支持目录）；
      //    任一文件失败都使本次备份失败，不得缺文件仍宣称成功。
      const iconCopy = await this.copyDirInto(iconPackDir, stagingDir + '/icon_packs', operation.context);
      const userCopy = await this.copyDirInto(userIconDir, stagingDir + '/user_icons', operation.context);
      if (iconCopy.failed + userCopy.failed > 0) {
        CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
          { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.PARTIAL_FAILURE });
        return false;
      }

      // 4. 压缩 staging 目录为 zip
      await this.archiver.compress(stagingDir, tempZipPath);

      const syncMeta = new SyncMetaRecord();
      syncMeta.version = 1;
      syncMeta.timestamp = now;
      syncMeta.deviceId = this.devicePort.deviceId();
      syncMeta.deviceName = this.devicePort.deviceName();
      syncMeta.enabledPacks = meta.enabledPacks;
      syncMeta.deletedPacks = meta.deletedPacks;
      syncMeta.packs = packEntries;
      const syncMetadata = JSON.stringify(syncMeta);

      // tempDir 中的可再生产物丢失只让本次失败；旧代的保留不依赖系统临时目录。
      if (!await this.verifyStagedZip(tempZipPath, operation, syncMetadata)) return false;
      if (!await publication.publish(tempZipPath, syncMetadata)) return false;
      completed = true;
    } catch (error) {
      this.reportFsFailure(operation.context, DiagnosticStage.ICON_IO, error);
    } finally {
      const stagingCleaned = await this.removeDirRecursive(stagingDir, operation.context);
      const tempCleaned = await this.removeTemporaryFile(tempZipPath, operation.context);
      // 已提交云端代不属于临时产物；失败／同步拒绝不从 finally 删除任何已提交代。
      if (!stagingCleaned || !tempCleaned) completed = false;
    }
    if (!completed) return false;

    // 临时产物清理也必须成功，之后才提交同步及推进成功水位。
    if (!deferSync && !await this.syncToCloud(operation.context)) return false;
    AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${now}`);
    CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.OK,
      { artifact: DiagnosticArtifact.ICON });
    return true;
  }

  /** makeDir + 递归拷贝的组合步骤；目标父目录创建失败由逐文件失败计数兜底。 */
  private async copyDirInto(srcDir: string, destDir: string,
    ctx: DiagnosticContext): Promise<IconPackDirCopyResult> {
    try {
      await this.fs.makeDir(destDir);
    } catch (_) {}
    return this.copyDirRecursive(srcDir, destDir, ctx);
  }

  private publication(operation: IconPackOperation): IconPackPublication {
    return new IconPackPublication(this.fs, this.cloudDir, operation.context,
      async (path: string, metadata: string): Promise<boolean> => {
        const stat = await this.fs.stat(path);
        if (stat.location === 2) await this.cacheFile(path, operation);
        return this.verifyStagedZip(path, operation, metadata);
      },
      async (path: string): Promise<void> => {
        const stat = await this.fs.stat(path);
        if (stat.location === 2) await this.cacheFile(path, operation);
      });
  }

  private async readableSnapshot(operation: IconPackOperation): Promise<IconPackCloudSnapshot | undefined> {
    return this.publication(operation).snapshot();
  }

  /** 完整试读并核对内部元数据与同代伴生元数据；tempDir 可被回收，异常即失败。 */
  private async verifyStagedZip(stagedZipPath: string, operation: IconPackOperation,
    expectedMetadata: string): Promise<boolean> {
    const verifyDir = this.tempDir + '/icon_pack_publish_verify';
    let verified = false;
    try {
      if (!await this.removeDirRecursive(verifyDir, operation.context)) return false;
      try {
        await this.fs.makeDir(verifyDir);
      } catch (_) {}
      await this.archiver.decompress(stagedZipPath, verifyDir);
      const metaContent = await this.fs.readTextFile(verifyDir + '/' + META_JSON_NAME);
      const meta = JSON.parse(metaContent) as IconPackMetaRecord;
      const expected = JSON.parse(expectedMetadata) as SyncMetaRecord;
      if (meta === null || typeof meta !== 'object' || meta.version !== 1 ||
        meta.timestamp !== expected.timestamp || JSON.stringify(meta.packs) !== JSON.stringify(expected.packs) ||
        JSON.stringify(meta.enabledPacks) !== JSON.stringify(expected.enabledPacks) ||
        JSON.stringify(meta.deletedPacks) !== JSON.stringify(expected.deletedPacks)) {
        throw new Error('ICON_PACK_META_INVALID');
      }
      verified = true;
    } catch (error) {
      this.reportFsFailure(operation.context, DiagnosticStage.ICON_IO, error);
    } finally {
      if (!await this.removeDirRecursive(verifyDir, operation.context)) verified = false;
    }
    return verified;
  }

  /**
   * 检查云端备份是否比本地更新（公开入口，外部可独立调用）
   * 内部先做 5 分钟去抖，再读取伴生元数据文件比较时间戳（不解压 zip）。
   */
  async checkCloudBackupNewer(owner?: CloudBackupOperationLease, ctx?: DiagnosticContext): Promise<boolean> {
    const operation = this.beginOperation(IconPackSyncState.CHECKING, owner, ctx);
    if (operation === undefined) return false;
    try {
      if (!await this.prepareContext(operation.context)) return false;
      return await this.doCheckCloudBackupNewer(operation);
    } catch (error) {
      CloudBackupDiagnostics.fail(operation.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.APP, error);
      return false;
    } finally {
      this.finishOperation(operation);
    }
  }

  /** 读取云端伴生元数据文件比较 timestamp，无需下载/解压 zip */
  private async doCheckCloudBackupNewer(operation: IconPackOperation): Promise<boolean> {
    const lastRestoreStr = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
    const lastRestoreTs = SyncTimeHelper.parseStoredTimestamp(lastRestoreStr);
    if (lastRestoreTs > 0 && SyncTimeHelper.isWithinMinutes(lastRestoreTs, 5)) {
      return false;
    }

    const snapshot = await this.readableSnapshot(operation);
    if (snapshot === undefined || snapshot.metaPath.length === 0) return false;
    const syncMetaPath = snapshot.metaPath;
    try {
      const stat = await this.fs.stat(syncMetaPath);
      if (stat.location === 2) {
        await this.cacheFile(syncMetaPath, operation);
      }

      const content = await this.fs.readTextFile(syncMetaPath);
      const meta = JSON.parse(content) as SyncMetaRecord;
      const cloudTs = meta.timestamp || 0;
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.READ_END, DiagnosticResult.OK,
        { headerParsed: true });
      return cloudTs > lastRestoreTs;
    } catch (error) {
      this.reportFsFailure(operation.context, DiagnosticStage.READ_END, error);
      return false;
    }
  }

  /**
   * 从云端恢复图标包（公开入口，checkAndAutoRestore 内部直接调用 doRestoreIconPacks）
   *
   * 流程：IDLE→RESTORING → 下载解压 → 拷贝到 filesDir → 处理 deletedPacks →
   *       刷新内存状态 → 合并 enabledPacks → IDLE
   */
  async restoreIconPacks(owner?: CloudBackupOperationLease, ctx?: DiagnosticContext): Promise<IconPackRestoreResult> {
    const operation = this.beginOperation(IconPackSyncState.RESTORING, owner, ctx);
    if (operation === undefined) return new IconPackRestoreResult();
    try {
      if (!await this.prepareContext(operation.context)) return new IconPackRestoreResult();
      return await this.doRestoreIconPacks(operation);
    } catch (error) {
      CloudBackupDiagnostics.fail(operation.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.APP, error);
      return new IconPackRestoreResult();
    } finally {
      this.finishOperation(operation);
    }
  }

  /** 实际恢复逻辑：解压 → 拷贝文件 → 处理已删除包 → 刷新内存 → 合并启用列表 */
  private async doRestoreIconPacks(operation: IconPackOperation): Promise<IconPackRestoreResult> {
    const result = new IconPackRestoreResult();
    const snapshot = await this.readableSnapshot(operation);
    if (snapshot === undefined) {
      result.failedFiles++;
      return result;
    }
    const cloudZipPath = snapshot.zipPath;
    const tempDir = this.tempDir + '/icon_pack_restore';
    let restoreDirUsed = false;
    let meta: IconPackMetaRecord | null = null;
    try {
      // 云端文件可选预缓存；确认无在途任务后仍须由解压读取验证实际可用性。
      const stat = await this.fs.stat(cloudZipPath);
      if (stat.location === 2) {
        await this.cacheFile(cloudZipPath, operation);
      }

      // 仅清理专用 cache 临时目录，不把上次解压残留当作当前 zip 的内容。
      if (!await this.removeDirRecursive(tempDir, operation.context)) {
        // 本次尚未解压，失败只记一项；finally 不重复清理/计数，下次操作可重试。
        result.failedFiles++;
        return result;
      }
      restoreDirUsed = true;
      try {
        await this.fs.makeDir(tempDir);
      } catch (_) {}
      await this.archiver.decompress(cloudZipPath, tempDir);

      // 选择性拷贝：缺少整个可选子目录仍兼容旧 zip；逐文件失败必须保留在结果内。
      const iconPackDir = this.filesDir + '/icon_packs';
      const userIconDir = this.filesDir + '/user_icons';
      const iconCopy = await this.copyDirInto(tempDir + '/icon_packs', iconPackDir, operation.context);
      const userCopy = await this.copyDirInto(tempDir + '/user_icons', userIconDir, operation.context);
      result.restoredFiles = iconCopy.copied + userCopy.copied;
      result.failedFiles += iconCopy.failed + userCopy.failed;

      // 旧 zip 确定无 meta 仍允许文件恢复，不新增格式拒绝；真实读取/解析失败不假成功。
      try {
        const metaContent = await this.fs.readTextFile(tempDir + '/' + META_JSON_NAME);
        meta = JSON.parse(metaContent) as IconPackMetaRecord;
      } catch (error) {
        if (!this.isMissingFile(error)) {
          result.failedFiles++;
          this.reportFsFailure(operation.context, DiagnosticStage.ICON_IO, error);
        }
      }

      if (meta) {
        result.restoredCount = meta.packs?.length ?? 0;
        if (meta.deletedPacks && meta.deletedPacks.length > 0) {
          for (const deletedUuid of meta.deletedPacks) {
            const pack = this.registry.listPacks().find(p => p.uuid === deletedUuid);
            if (pack) {
              try {
                await this.registry.removePack(pack);
              } catch (error) {
                result.failedFiles++;
                this.reportFsFailure(operation.context, DiagnosticStage.ICON_IO, error);
              }
            }
          }
        }

        // 重载/删除失败会影响完整性；继续刷新已成功的文件，但不得推进成功水位。
        result.failedFiles += await this.refreshIconPackState(operation.context);
        const localPacks = this.registry.listPacks().map(p => p.uuid);
        const merged = mergeEnabledPacks(meta.enabledPacks, localPacks);
        this.registry.setEnabledPacks(merged);
        AppPreference.saveEnabledPacks(merged);
      }
    } catch (error) {
      // 保存已经成功落地的文件计数，供自动入口发事件；异常不再返回伪空成功结果。
      result.failedFiles++;
      this.reportFsFailure(operation.context, DiagnosticStage.ICON_IO, error);
    } finally {
      if (restoreDirUsed && !await this.removeDirRecursive(tempDir, operation.context)) result.failedFiles++;
    }

    if (result.failedFiles > 0) {
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
        { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.PARTIAL_FAILURE });
    } else {
      // 必须在文件/注册表/清理全部成功之后推进；失败去掉后同 timestamp 的 zip 仍可重试。
      if (meta) AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${meta.timestamp}`);
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.OK,
        { artifact: DiagnosticArtifact.ICON });
    }
    return result;
  }

  /**
   * 从磁盘重新加载图标包到注册表内存（在 merge enabledPacks 前调用）
   * 包含：user_icons 目录 + icon_packs 下所有子目录 + enabled_packs 偏好
   */
  private async refreshIconPackState(ctx: DiagnosticContext): Promise<number> {
    const iconPackDir = this.filesDir + '/icon_packs';
    const userIconDir = this.filesDir + '/user_icons';
    let failed = 0;
    try {
      await this.registry.loadUserIcons(userIconDir);
    } catch (error) {
      failed++;
      this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
    }
    try {
      const paths = await this.fs.listFiles(iconPackDir);
      for (const path of paths) {
        const fullPath = iconPackDir + '/' + path;
        if (this.registry.listPacks().some(pack => pack.on_device_path === fullPath)) {
          continue;
        }
        try {
          await this.registry.addPackFromDevice(fullPath);
        } catch (error) {
          failed++;
          this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
        }
      }
    } catch (error) {
      failed++;
      this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
    }
    try {
      this.registry.reloadEnabledPacksFromPreference();
    } catch (error) {
      failed++;
      this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
    }
    return failed;
  }

  /** 查询云端图标包备份状态（是否存在、包数量、大小、来源设备等），供 UI 展示 */
  async getCloudBackupStatus(owner?: CloudBackupOperationLease, ctx?: DiagnosticContext): Promise<IconPackBackupStatus> {
    const operation = this.beginOperation(IconPackSyncState.CHECKING, owner, ctx);
    if (operation === undefined) return new IconPackBackupStatus();
    try {
      if (!await this.prepareContext(operation.context)) return new IconPackBackupStatus();
      return await this.doGetCloudBackupStatus(operation);
    } catch (error) {
      this.reportFsFailure(operation.context, DiagnosticStage.READ_END, error);
      return new IconPackBackupStatus();
    } finally {
      this.finishOperation(operation);
    }
  }

  private async doGetCloudBackupStatus(operation: IconPackOperation): Promise<IconPackBackupStatus> {
    const result = new IconPackBackupStatus();
    const lastTimeStr = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
    const lastTs = SyncTimeHelper.parseStoredTimestamp(lastTimeStr);
    result.lastTime = SyncTimeHelper.formatTimestamp(lastTs);

    if (!this.context || !this.cloudDir) {
      return result;
    }

    const snapshot = await this.readableSnapshot(operation);
    if (snapshot === undefined) {
      result.publicationUnresolved = true;
      return result;
    }
    const cloudZipPath = snapshot.zipPath;
    try {
      const stat = await this.fs.stat(cloudZipPath);
      result.exists = true;
      result.size = stat.size;
    } catch (_) {}

    // 从伴生元数据文件读取详细信息（包列表、来源设备等）
    if (snapshot.metaPath.length === 0) {
      result.metadataAbsent = true;
      return result;
    }
    const syncMetaPath = snapshot.metaPath;
    // stat 单独判定“确定不存在”：读取/缓存阶段的 ENOENT（如 TOCTOU 被并发删除）仍归未知态。
    let smStat: FsStatInfo;
    try {
      smStat = await this.fs.stat(syncMetaPath);
    } catch (error) {
      if (this.isMissingFile(error)) {
        // 文件确定不存在：备份流程对无图标包内容按设计跳过、从不写出该文件，
        // 与“文件在但读不了/校验不过”的未知态不同，是可展示的确定“未备份”。
        // 诊断侧不产生任何行：ICON 批次类只让失败事件可见，成功与确定缺失同为零输出，
        // 无法仅凭该操作的诊断流区分“已运行且确定缺失”与“未触发”。
        result.metadataAbsent = true;
        return result;
      }
      this.reportFsFailure(operation.context, DiagnosticStage.READ_END, error);
      return result;
    }
    try {
      if (smStat.location === 2) {
        await this.cacheFile(syncMetaPath, operation);
      }
      const content = await this.fs.readTextFile(syncMetaPath);
      const meta = JSON.parse(content) as SyncMetaRecord;
      if (!this.isValidStatusMeta(meta)) {
        CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.READ_END, DiagnosticResult.FAIL,
          { reason: DiagnosticReason.INVALID_FORMAT, headerParsed: false });
        return result;
      }
      result.metadataKnown = true;
      result.packCount = meta.packs.length;
      result.sourceDeviceId = typeof meta.deviceId === 'string' ? meta.deviceId : '';
      result.sourceDeviceName = typeof meta.deviceName === 'string' ? meta.deviceName : '';
      result.packs = meta.packs;
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.READ_END, DiagnosticResult.OK,
        { headerParsed: true });
    } catch (error) {
      // 远端内容未知不能用本地注册表数量/设备身份替代。
      this.reportFsFailure(operation.context, DiagnosticStage.READ_END, error);
    }

    return result;
  }

  private isValidStatusMeta(meta: SyncMetaRecord | null): boolean {
    if (meta === null || typeof meta !== 'object' || !Array.isArray(meta.packs) ||
      (meta.deviceId !== undefined && typeof meta.deviceId !== 'string') ||
      (meta.deviceName !== undefined && typeof meta.deviceName !== 'string') ||
      (meta.timestamp !== undefined && (typeof meta.timestamp !== 'number' || !Number.isFinite(meta.timestamp) ||
        meta.timestamp < 0))) return false;
    for (const pack of meta.packs) {
      if (pack === null || typeof pack !== 'object' || typeof pack.uuid !== 'string' ||
        typeof pack.name !== 'string' || !Number.isInteger(pack.version) || pack.version < 0 ||
        !Number.isInteger(pack.iconCount) || pack.iconCount < 0) return false;
    }
    return true;
  }

  /** 全部范围无需解析归属，也不为删除创建下载；外层可延后统一同步。 */
  async clearCloudBackup(owner?: CloudBackupOperationLease, deferSync: boolean = false,
    ctx?: DiagnosticContext): Promise<boolean> {
    return this.clearWithScope(undefined, owner, deferSync, ctx);
  }

  /** 设备范围只删除归属已确认的共享图标文件，失败时保留伴生归属证据。 */
  async clearCloudBackupForDevices(deviceIds: string[], owner?: CloudBackupOperationLease,
    deferSync: boolean = true, ctx?: DiagnosticContext): Promise<boolean> {
    return this.clearWithScope(deviceIds, owner, deferSync, ctx);
  }

  private async clearWithScope(deviceIds: string[] | undefined, owner: CloudBackupOperationLease | undefined,
    deferSync: boolean, ctx: DiagnosticContext | undefined): Promise<boolean> {
    const operation = this.beginOperation(IconPackSyncState.CLEARING, owner, ctx);
    if (operation === undefined) return false;
    try {
      if (!await this.prepareContext(operation.context)) return false;
      const files = await this.fs.listFiles(this.cloudDir);
      // 旧 fixed-name 备份仍按原归属规则清理；新代只在用户明确清理范围时独立逐代删除。
      const generationCleared = await new IconPackPublication(this.fs, this.cloudDir, operation.context,
        async (): Promise<boolean> => false).clear(deviceIds);
      const publicationFiles = [ICON_PACK_BACKUP_ZIP, SYNC_META_FILE];
      const hasArtifacts = publicationFiles.some((name: string): boolean => files.includes(name));
      let legacySelected = true;
      let identityFailed = false;
      if (deviceIds !== undefined && hasArtifacts) {
        const sourceId = await this.readSourceDeviceId(operation);
        identityFailed = sourceId === undefined;
        legacySelected = sourceId !== undefined && deviceIds.includes(sourceId);
      }

      let failed = !generationCleared || identityFailed;
      let removed = false;
      for (const name of publicationFiles) {
        if (!legacySelected) break;
        if (!files.includes(name)) continue;
        // zip 失败或底层未确认结束时，设备范围不能删除最后的归属证据。
        if (operation.unknownIo || (deviceIds !== undefined && failed)) break;
        const deleted = await this.deleteIconFile(`${this.cloudDir}/${name}`, operation);
        failed = failed || !deleted;
        removed = removed || deleted;
      }
      if (operation.unknownIo || this.cacheCleanupPending()) {
        this.retainCleanup(operation);
        // 同步已完成的删除不启动新文件 I/O；未知缓存任务仍由原许可保护。
        if (removed && !deferSync) await this.syncToCloud(operation.context);
        return false;
      }
      // 有已成功的删除时，即使另一文件失败也提交；deferSync 由管理器统一一次提交。
      const syncStarted = deferSync || await this.syncToCloud(operation.context);
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_CLEAR,
        failed || !syncStarted ? DiagnosticResult.FAIL : DiagnosticResult.OK,
        { artifact: DiagnosticArtifact.ICON, partialFailure: failed && removed });
      if (failed || !syncStarted) return false;
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '0');
      return true;
    } catch (error) {
      this.reportFsFailure(operation.context, DiagnosticStage.ICON_CLEAR, error);
      return false;
    } finally {
      this.finishOperation(operation);
    }
  }

  private async readSourceDeviceId(operation: IconPackOperation): Promise<string | undefined> {
    const path = `${this.cloudDir}/${SYNC_META_FILE}`;
    try {
      const stat = await this.fs.stat(path);
      if (stat.location === 2) await this.cacheFile(path, operation);
      const meta = JSON.parse(await this.fs.readTextFile(path)) as SyncMetaRecord | null;
      if (meta === null || typeof meta !== 'object' || typeof meta.deviceId !== 'string' ||
        meta.deviceId.trim().length === 0 || meta.deviceId === 'unknown_odid') {
        CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_CLEAR, DiagnosticResult.BLOCKED,
          { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.INVALID_FORMAT, headerParsed: false });
        return undefined;
      }
      CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.READ_END, DiagnosticResult.OK,
        { headerParsed: true });
      return meta.deviceId;
    } catch (error) {
      this.reportFsFailure(operation.context, DiagnosticStage.READ_END, error);
      return undefined;
    }
  }

  private async deleteIconFile(path: string, operation: IconPackOperation): Promise<boolean> {
    if (!await this.prepareForDelete(path, operation)) return false;
    CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_CLEAR, DiagnosticResult.BEGIN,
      { artifact: DiagnosticArtifact.ICON, unlinkAttempted: true });
    try {
      await this.fs.deleteFile(path);
      return true;
    } catch (error) {
      // 只认 SDK 的明确 ENOENT，不能把任意 stat/unlink 异常当作已不存在。
      if (this.isMissingFile(error)) {
        CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_CLEAR, DiagnosticResult.OK,
          { artifact: DiagnosticArtifact.ICON, unlinkAttempted: true, alreadyAbsent: true });
        return true;
      }
      this.reportFsFailure(operation.context, DiagnosticStage.ICON_CLEAR, error);
      return false;
    }
  }

  /** 只提取 SDK 数字码，白名单映射仍由诊断模块负责；不访问异常文本。 */
  private reportFsFailure(ctx: DiagnosticContext, stage: DiagnosticStage, error: Object): void {
    let code: number | undefined = undefined;
    try {
      const candidate = (error as BusinessError).code;
      if (typeof candidate === 'number') code = candidate;
    } catch (_) {}
    CloudBackupDiagnostics.fail(ctx, stage, DiagnosticErrorDomain.FS, code);
  }

  private isMissingFile(error: Object): boolean {
    try {
      return (error as BusinessError).code === 13900002;
    } catch (_) {
      return false;
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

  private beginOperation(state: IconPackSyncState, owner?: CloudBackupOperationLease,
    ctx?: DiagnosticContext): IconPackOperation | undefined {
    const context = ctx ?? CloudBackupDiagnostics.begin(DiagnosticKind.ICON);
    const gate = CloudBackupOperationGate.getInstance();
    const validOwner = owner === undefined || gate.canUse(owner);
    const lease = validOwner && this.syncState === IconPackSyncState.IDLE
      ? (owner ?? gate.tryEnter(CloudBackupOperationKind.ICONS)) : undefined;
    if (lease === undefined) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.ICON_IO, DiagnosticResult.BLOCKED,
        { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.BUSY });
      if (ctx === undefined) CloudBackupDiagnostics.end(context);
      return undefined;
    }
    const operation = new IconPackOperation(lease, owner === undefined, context, ctx === undefined);
    this.tryTransition(state);
    if (this.cacheCleanupPending()) {
      this.retainCleanup(operation);
      this.finishOperation(operation);
      return undefined;
    }
    CloudBackupDiagnostics.mark(context,
      state === IconPackSyncState.CLEARING ? DiagnosticStage.ICON_CLEAR : DiagnosticStage.ICON_IO,
      DiagnosticResult.BEGIN, { artifact: DiagnosticArtifact.ICON });
    return operation;
  }

  private async prepareContext(ctx: DiagnosticContext): Promise<boolean> {
    await this.init();
    if (this.context && this.cloudDir) return true;
    CloudBackupDiagnostics.mark(ctx, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
      { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.UNAVAILABLE });
    return false;
  }

  private finishOperation(operation: IconPackOperation): void {
    if (operation.unknownIo || operation.lease.isCleanupPending() || this.cacheCleanupPending()) {
      this.retainCleanup(operation);
    } else if (operation.ownLease) {
      operation.lease.release();
    }
    this.syncState = IconPackSyncState.IDLE;
    if (operation.ownContext) CloudBackupDiagnostics.end(operation.context);
  }

  private get cacher(): CloudFileCacher | undefined {
    // 注入模式绝不回退到原生缓存单例。
    return this.testDeps !== null ? this.testDeps.cache : CloudFileCacheLoader.getInstance();
  }

  private cacheCleanupPending(): boolean {
    try {
      return this.cacher?.isCleanupPending?.() ?? false;
    } catch (_) {
      // 无法确认状态时保持屏障，不能因状态查询异常提前释放许可。
      return true;
    }
  }

  private retainCleanup(operation: IconPackOperation): void {
    operation.unknownIo = true;
    operation.lease.retainUnknownIo();
    if (operation.ownLease) this.pendingCleanupLease = operation.lease;
    CloudBackupDiagnostics.mark(operation.context, DiagnosticStage.ICON_IO, DiagnosticResult.BLOCKED,
      { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.INFLIGHT_UNCONFIRMED, drained: false });
  }

  isCleanupPending(): boolean {
    return this.pendingCleanupLease !== undefined || this.cacheCleanupPending();
  }

  /** 只由独立图标操作的原所有者重试排空；不重新抢 gate，不重放删除或下载。 */
  async retryPendingCleanup(): Promise<boolean> {
    const lease = this.pendingCleanupLease;
    if (lease === undefined) return true;
    if (this.cleanupRetryRunning || !CloudBackupOperationGate.getInstance().owns(lease)) return false;
    this.cleanupRetryRunning = true;
    const ctx = CloudBackupDiagnostics.begin(DiagnosticKind.ICON);
    try {
      const cache = this.cacher;
      if (cache?.retryCleanup === undefined || !await cache.retryCleanup() || this.cacheCleanupPending()) {
        CloudBackupDiagnostics.mark(ctx, DiagnosticStage.ICON_IO, DiagnosticResult.BLOCKED,
          { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.INFLIGHT_UNCONFIRMED, drained: false });
        return false;
      }
      lease.resolveUnknownIo();
      if (!lease.release()) return false;
      if (this.pendingCleanupLease === lease) this.pendingCleanupLease = undefined;
      CloudBackupDiagnostics.mark(ctx, DiagnosticStage.ICON_IO, DiagnosticResult.OK,
        { artifact: DiagnosticArtifact.ICON, drained: true });
      return true;
    } catch (error) {
      CloudBackupDiagnostics.fail(ctx, DiagnosticStage.CACHE_END, DiagnosticErrorDomain.APP, error);
      return false;
    } finally {
      this.cleanupRetryRunning = false;
      CloudBackupDiagnostics.end(ctx);
    }
  }

  /** 删除只结束已有缓存工作，不因位置或 unlink 失败发起下载。 */
  private async prepareForDelete(path: string, operation: IconPackOperation): Promise<boolean> {
    try {
      const cache = this.cacher;
      const drained = cache?.prepareForDelete === undefined || await cache.prepareForDelete(path, operation.context);
      if (!drained || this.cacheCleanupPending()) {
        this.retainCleanup(operation);
        return false;
      }
      return true;
    } catch (error) {
      this.retainCleanup(operation);
      CloudBackupDiagnostics.fail(operation.context, DiagnosticStage.CACHE_END, DiagnosticErrorDomain.APP, error);
      return false;
    }
  }

  /** 统一服务持有原生实例；true 仅表示 start 被接受，不是远端完成。 */
  private async syncToCloud(ctx: DiagnosticContext): Promise<boolean> {
    try {
      if (this.testDeps === null) return await CloudBackupSyncService.getInstance().start(ctx);
      const accepted = this.testDeps.sync === undefined || await this.testDeps.sync.start();
      CloudBackupDiagnostics.mark(ctx, DiagnosticStage.SYNC_START,
        accepted ? DiagnosticResult.OK : DiagnosticResult.FAIL, { syncStartAccepted: accepted });
      return accepted;
    } catch (error) {
      CloudBackupDiagnostics.fail(ctx, DiagnosticStage.SYNC_START, DiagnosticErrorDomain.SYNC, error);
      return false;
    }
  }

  /** 可选预缓存失败不等于普通读取失败；未确认结束的 I/O 仍阻止读取并保留许可。 */
  private async cacheFile(filePath: string, operation: IconPackOperation): Promise<void> {
    if (!await prepareCloudFileRead(this.cacher, filePath, 2, operation.context)) {
      this.retainCleanup(operation);
      throw new Error('CLOUD_CACHE_CLEANUP_PENDING');
    }
  }

  /** 仅供上述专用 cache 临时目录清理；不用于 filesDir 用户内容或 cloudDir 枚举。 */
  private async removeDirRecursive(dirPath: string, ctx: DiagnosticContext): Promise<boolean> {
    let failed = false;
    try {
      const files = await this.fs.listFiles(dirPath);
      for (const file of files) {
        const fullPath = dirPath + '/' + file;
        try {
          const stat = await this.fs.stat(fullPath);
          const removed = stat.isDirectory
            ? await this.removeDirRecursive(fullPath, ctx)
            : await this.removeTemporaryFile(fullPath, ctx);
          if (!removed) failed = true;
        } catch (error) {
          if (!this.isMissingFile(error)) {
            failed = true;
            this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
          }
        }
      }
      // 不用 rmdir 的递归语义掩盖逐项失败；保留残片给同一专用路径下次重试。
      if (!failed) await this.fs.removeDir(dirPath);
    } catch (error) {
      if (!this.isMissingFile(error)) {
        failed = true;
        this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
      }
    }
    if (failed) {
      CloudBackupDiagnostics.mark(ctx, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
        { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.PARTIAL_FAILURE });
    }
    return !failed;
  }

  /** 精确临时文件清理：只有明确 ENOENT 幂等，其他错误如实传播结果并输出白名单诊断。 */
  private async removeTemporaryFile(path: string, ctx: DiagnosticContext): Promise<boolean> {
    try {
      await this.fs.deleteFile(path);
      return true;
    } catch (error) {
      if (this.isMissingFile(error)) return true;
      this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
      CloudBackupDiagnostics.mark(ctx, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
        { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.PARTIAL_FAILURE });
      return false;
    }
  }

  /** 逐文件拷贝并计数：失败不静默，由调用方决定整体成败（备份失败/恢复部分上报）。 */
  private async copyDirRecursive(srcDir: string, destDir: string, ctx: DiagnosticContext):
    Promise<IconPackDirCopyResult> {
    const result = new IconPackDirCopyResult();
    let files: string[];
    try {
      files = await this.fs.listFiles(srcDir);
    } catch (error) {
      // 源目录不存在视为空目录（兼容无 user_icons 的旧 zip/新装机）；其他列举失败计入失败。
      if (!this.isMissingFile(error)) {
        this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
        result.failed++;
      }
      return result;
    }
    for (const file of files) {
      const srcPath = srcDir + '/' + file;
      const destPath = destDir + '/' + file;
      try {
        const stat = await this.fs.stat(srcPath);
        if (stat.isDirectory) {
          try {
            await this.fs.makeDir(destPath);
          } catch (_) {}
          const nested = await this.copyDirRecursive(srcPath, destPath, ctx);
          result.copied += nested.copied;
          result.failed += nested.failed;
        } else {
          await this.fs.copyFile(srcPath, destPath);
          result.copied++;
        }
      } catch (error) {
        this.reportFsFailure(ctx, DiagnosticStage.ICON_IO, error);
        result.failed++;
      }
    }
    return result;
  }
}

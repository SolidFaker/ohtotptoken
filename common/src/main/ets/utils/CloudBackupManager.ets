import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreference, PREF_KEYS } from './AppPreference';
import {
  CloudBackupCrypto, CloudBackupRecord, CloudBackupMetadataStatus, CloudBackupIdentityStatus, CloudBackupTokenError,
} from './CloudBackupCrypto';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticKind, DiagnosticStage, DiagnosticResult,
  DiagnosticReason, DiagnosticErrorDomain, DiagnosticScope,
} from './CloudBackupDiagnostics';
import { normalizeCloudBackupDeviceId } from './CloudBackupMetadata';
import { CloudBackupOperationGate, CloudBackupOperationKind, CloudBackupOperationLease } from './CloudBackupOperationGate';
import {
  CloudBackupActionResult, CloudBackupFailureReason, CloudBackupHistoryResult, cloudBackupFailure,
} from './CloudBackupResult';
import { CloudBackupSyncService } from './CloudBackupSyncService';
import { CloudBackupStaging } from './CloudBackupStaging';
import {
  CloudBackupPublicationGuard, CloudBackupPublicationPort, MemoryCloudBackupPublicationPort,
  applyCloudPublicationIsolation,
} from './CloudBackupPublicationGuard';
import { CloudSyncFailureStage, CloudSyncFailureState } from './CloudSyncLastFailure';
import { CloudFileCacher, CloudFileCacheLoader, prepareCloudFileRead } from './CloudFileCacheLoader';
import { CloudBackupTaskHistory, loadBackupHistoryRecords, checkCloudBackupRecords } from './CloudSyncTask';
import { TokenStore } from './TokenStore';
import { TokenConfig, sanitizedTokenForBackup } from './TokenConfig';
import { TokenGroup, TokenGroupStore } from './TokenGroupStore';
import { DeviceInfoHelper } from './DeviceInfoHelper';
import { HuaweiAccountManager } from './HuaweiAccountManager';
import { SyncTimeHelper } from './SyncTimeHelper';
import { TokenIconPacks } from './TokenUtils';
import { IconPackCloudBackup, PackMetaEntry } from './IconPackCloudBackup';
import { FsGateway, FileIoFsGateway, fileIoDiagnosticCode } from './StoragePorts';
import { BACKUP_FILE_EXT, BACKUP_FILE_PREFIX, parseBackupTimestamp } from './CommonUtils';

const MAX_BACKUP_COUNT = 5;

export interface CloudBackupAccountPort {
  isUserLogin(): boolean;
  unionId(): string;
}

export interface CloudBackupDevicePort {
  deviceId(): string;
  deviceName(): string;
}

export interface CloudBackupTokenPort {
  getTokens(): Promise<TokenConfig[]>;
  updateToken(token: TokenConfig): Promise<void>;
}

export interface CloudBackupGroupPort {
  currentGroups(): TokenGroup[];
  merge(groups: TokenGroup[] | undefined): Promise<void>;
}

export interface CloudBackupIconPort {
  backupIconPacks(owner?: CloudBackupOperationLease, deferSync?: boolean, context?: DiagnosticContext): Promise<boolean>;
  clearCloudBackup(owner?: CloudBackupOperationLease, deferSync?: boolean, context?: DiagnosticContext): Promise<boolean>;
  clearCloudBackupForDevices?(deviceIds: string[], owner?: CloudBackupOperationLease,
    deferSync?: boolean, context?: DiagnosticContext): Promise<boolean>;
}

export interface CloudSyncStarter {
  start(): Promise<void>;
}

export interface CloudBackupTestDeps {
  fs?: FsGateway;
  account?: CloudBackupAccountPort;
  device?: CloudBackupDevicePort;
  tokens?: CloudBackupTokenPort;
  groups?: CloudBackupGroupPort;
  icons?: CloudBackupIconPort;
  sync?: CloudSyncStarter;
  cache?: CloudFileCacher;
  cloudDir?: string;
  staging?: CloudBackupStaging;
  publication?: CloudBackupPublicationPort;
  /** Test the production TaskPool branch without calling native filesystem APIs. */
  historyTask?: (root: string, context: DiagnosticContext) => Promise<CloudBackupTaskHistory>;
}

class HuaweiAccountAdapter implements CloudBackupAccountPort {
  isUserLogin(): boolean { return HuaweiAccountManager.getInstance().userLogin; }
  unionId(): string { return HuaweiAccountManager.getInstance().userAccount.unionId; }
}

class DeviceInfoAdapter implements CloudBackupDevicePort {
  deviceId(): string { return DeviceInfoHelper.getInstance().getDeviceId(); }
  deviceName(): string { return DeviceInfoHelper.getInstance().getDeviceName(); }
}

class TokenStoreAdapter implements CloudBackupTokenPort {
  getTokens(): Promise<TokenConfig[]> { return TokenStore.getInstance().getTokens(); }
  updateToken(token: TokenConfig): Promise<void> { return TokenStore.getInstance().updateToken(token); }
}

class TokenGroupStoreAdapter implements CloudBackupGroupPort {
  currentGroups(): TokenGroup[] { return TokenGroupStore.getInstance().state.groups; }
  merge(groups: TokenGroup[] | undefined): Promise<void> { return TokenGroupStore.getInstance().merge(groups); }
}

class IconPackCloudBackupAdapter implements CloudBackupIconPort {
  backupIconPacks(owner?: CloudBackupOperationLease, deferSync?: boolean, context?: DiagnosticContext): Promise<boolean> {
    return IconPackCloudBackup.getInstance().backupIconPacks(owner, deferSync, context);
  }
  clearCloudBackup(owner?: CloudBackupOperationLease, deferSync?: boolean, context?: DiagnosticContext): Promise<boolean> {
    return IconPackCloudBackup.getInstance().clearCloudBackup(owner, deferSync, context);
  }
  clearCloudBackupForDevices(ids: string[], owner?: CloudBackupOperationLease,
    deferSync?: boolean, context?: DiagnosticContext): Promise<boolean> {
    return IconPackCloudBackup.getInstance().clearCloudBackupForDevices(ids, owner, deferSync, context);
  }
}

class CloudBackupPayload {
  tokens: TokenConfig[] = [];
  groups: TokenGroup[] = [];
  enabledPacks: string[] = [];
  packMeta: PackMetaEntry[] = [];
}

interface CloudBackupRestorePayload {
  tokens: TokenConfig[];
  groups?: TokenGroup[];
  enabledPacks: string[];
}

class BackupScanResult {
  records: CloudBackupRecord[] = [];
  complete: boolean = true;
  blocked: boolean = false;
}

class PublicationCleanupResult {
  drained: boolean = true;
  syncAttempted: boolean = false;
  syncStartAccepted: boolean = false;
}

/** 文件名是目录枚举的边界，不接受路径、额外后缀或部分可解析的时间戳。 */
export function isSafeCloudBackupId(id: string): boolean {
  return /^otp_backup_-?\d+\.enc(?![\s\S])/.test(id) && Number.isSafeInteger(parseBackupTimestamp(id));
}

function isFileAbsent(error: Object): boolean {
  try { return (error as BusinessError).code === 13900002; } catch (_) { return false; }
}

export class CloudBackupManager {
  private static instance: CloudBackupManager | null = null;
  private context: common.UIAbilityContext | undefined = undefined;
  private cloudDir: string = '';
  private testDeps: CloudBackupTestDeps | null = null;
  private readonly productionFs: FsGateway = new FileIoFsGateway();
  private pendingCleanupLease: CloudBackupOperationLease | undefined = undefined;
  private lastFileTimestamp: number = -1;
  private testPublication: MemoryCloudBackupPublicationPort | undefined = undefined;
  private publicationGuard: CloudBackupPublicationGuard | undefined = undefined;
  private publicationAccount: string = '';
  private publicationRoot: string = '';
  private publicationUnavailable: boolean = false;
  private publicationPending: boolean = false;

  private constructor() {}

  static getInstance(): CloudBackupManager {
    if (!CloudBackupManager.instance) CloudBackupManager.instance = new CloudBackupManager();
    return CloudBackupManager.instance;
  }

  useDepsForTest(deps: CloudBackupTestDeps): void {
    if (this.testDeps?.fs !== deps.fs || this.testDeps?.publication !== deps.publication) {
      this.testPublication = deps.publication === undefined && deps.fs !== undefined ?
        new MemoryCloudBackupPublicationPort(deps.fs) : undefined;
    }
    this.publicationGuard = undefined;
    this.testDeps = deps;
    if (deps.cloudDir !== undefined && deps.cloudDir.length > 0) {
      this.context = new Object() as common.UIAbilityContext;
      this.cloudDir = deps.cloudDir;
    }
  }

  resetForTest(): void {
    if (this.pendingCleanupLease !== undefined) {
      this.pendingCleanupLease.resolveUnknownIo();
      this.pendingCleanupLease.release();
    }
    this.pendingCleanupLease = undefined;
    this.testDeps = null;
    this.context = undefined;
    this.cloudDir = '';
    this.lastFileTimestamp = -1;
    this.testPublication = undefined;
    this.publicationGuard = undefined;
    this.publicationAccount = '';
    this.publicationRoot = '';
    this.publicationUnavailable = false;
    this.publicationPending = false;
  }

  private get fsPort(): FsGateway { return this.testDeps?.fs ?? this.productionFs; }
  private get accountPort(): CloudBackupAccountPort { return this.testDeps?.account ?? new HuaweiAccountAdapter(); }
  private get devicePort(): CloudBackupDevicePort { return this.testDeps?.device ?? new DeviceInfoAdapter(); }
  private get tokenPort(): CloudBackupTokenPort { return this.testDeps?.tokens ?? new TokenStoreAdapter(); }
  private get groupPort(): CloudBackupGroupPort { return this.testDeps?.groups ?? new TokenGroupStoreAdapter(); }
  private get iconPort(): CloudBackupIconPort { return this.testDeps?.icons ?? new IconPackCloudBackupAdapter(); }
  private get crypto(): CloudBackupCrypto { return CloudBackupCrypto.getInstance(); }
  private async staging(): Promise<CloudBackupStaging | undefined> {
    if (this.testDeps !== null) return this.testDeps.staging;
    if (this.context === undefined) throw new Error('STAGING_CONTEXT_UNAVAILABLE');
    return CloudBackupStaging.production(this.cloudDir, this.context.filesDir, this.accountPort.unionId());
  }
  private async publication(): Promise<CloudBackupPublicationGuard> {
    const account = this.accountPort.unionId();
    if (!account && this.testDeps === null) throw new Error('PUBLICATION_ACCOUNT_UNAVAILABLE');
    if (this.publicationGuard !== undefined && this.publicationAccount === account &&
      this.publicationRoot === this.cloudDir) return this.publicationGuard;
    const port = this.testDeps?.publication ?? this.testPublication;
    const guard = this.testDeps !== null ?
      new CloudBackupPublicationGuard(this.cloudDir, account || 'test-no-account', port!) :
      await CloudBackupPublicationGuard.production(this.cloudDir, this.context!.filesDir, account);
    if (this.testDeps !== null && port === undefined) throw new Error('PUBLICATION_PORT_UNAVAILABLE');
    this.publicationGuard = guard;
    this.publicationAccount = account;
    this.publicationRoot = this.cloudDir;
    return guard;
  }

  /** Must precede staging.create/recover: staging cleanup would destroy non-publication evidence. */
  private async preparePublication(context: DiagnosticContext): Promise<boolean> {
    if (this.cacher?.isCleanupPending?.()) return false;
    try {
      const guard = await this.publication();
      if (!await guard.recover(context)) {
        this.publicationUnavailable = true;
        return false;
      }
      this.publicationUnavailable = false;
      this.publicationPending = guard.hasRejectedCleanup();
      return true;
    } catch (error) {
      this.publicationUnavailable = true;
      CloudBackupDiagnostics.fail(context, DiagnosticStage.PUBLICATION_GUARD,
        DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
      return false;
    }
  }

  /** Only a durable confirmed-move REJECTED receipt authorizes automatic unlink. */
  private async cleanupPublications(context: DiagnosticContext): Promise<PublicationCleanupResult> {
    const result = new PublicationCleanupResult();
    try {
      const guard = await this.publication();
      const cleaned: string[] = [];
      for (const receipt of guard.rejected()) {
        const deletion = await this.deleteBackupFile(receipt.fileName, context);
        if (deletion.success) cleaned.push(receipt.id);
        else result.drained = false;
      }
      // Never acknowledge failed unlinks merely because unrelated sync was accepted.
      if (cleaned.length > 0) {
        result.syncAttempted = true;
        result.syncStartAccepted = await this.syncToCloud(context);
        if (result.syncStartAccepted) {
          for (const id of cleaned) await guard.acknowledgeRejected(id, context);
        } else result.drained = false;
      }
      this.publicationPending = guard.hasRejectedCleanup();
      result.drained = result.drained && !this.publicationPending;
    } catch (error) {
      result.drained = false;
      this.publicationUnavailable = true;
      CloudBackupDiagnostics.fail(context, DiagnosticStage.PUBLICATION_CLEANUP,
        DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
    }
    CloudBackupDiagnostics.mark(context, DiagnosticStage.PUBLICATION_CLEANUP,
      result.drained ? DiagnosticResult.OK : DiagnosticResult.FAIL,
      { drained: result.drained, partialFailure: !result.drained, syncStartAccepted: result.syncStartAccepted,
        reason: result.drained ? DiagnosticReason.NONE : DiagnosticReason.IO_ERROR });
    return result;
  }

  private get cacher(): CloudFileCacher | undefined {
    return this.testDeps !== null ? this.testDeps.cache : CloudFileCacheLoader.getInstance();
  }

  async init(): Promise<void> {
    if (this.context && this.cloudDir) return;
    const context = AppStorage.get<common.UIAbilityContext>('appContext');
    if (!context) return;
    try {
      const dir = context.cloudFileDir;
      if (!dir) return;
      try {
        const stat = await this.fsPort.stat(dir);
        if (!stat.isDirectory) return;
      } catch (error) {
        if (!isFileAbsent(error)) return;
        await this.fsPort.makeDir(dir);
      }
      this.context = context;
      this.cloudDir = dir;
    } catch (_) {
      this.context = undefined;
      this.cloudDir = '';
    }
  }

  isBusy(): boolean { return CloudBackupOperationGate.getInstance().isBusy(); }

  isCleanupPending(): boolean {
    return this.publicationUnavailable ||
      this.cacher?.isCleanupPending?.() === true || this.pendingCleanupLease !== undefined ||
      (this.testDeps === null && IconPackCloudBackup.getInstance().isCleanupPending());
  }

  async retryPendingCleanup(): Promise<boolean> {
    const cache = this.cacher;
    const context = CloudBackupDiagnostics.begin(DiagnosticKind.CACHE);
    let recoveryOwner: CloudBackupOperationLease | undefined = this.pendingCleanupLease;
    if (recoveryOwner === undefined) recoveryOwner = CloudBackupOperationGate.getInstance().tryEnter(CloudBackupOperationKind.HISTORY);
    if (recoveryOwner === undefined) {
      CloudBackupDiagnostics.end(context);
      return false;
    }
    try {
      if (cache?.isCleanupPending?.()) {
        if (cache.retryCleanup === undefined || !await cache.retryCleanup()) return false;
      }
      if (this.testDeps === null && !await IconPackCloudBackup.getInstance().retryPendingCleanup()) return false;
      recoveryOwner.resolveUnknownIo();
      this.pendingCleanupLease = undefined;
      if (await this.ready() !== CloudBackupFailureReason.NONE || !await this.preparePublication(context)) return false;
      const cleanup = await this.cleanupPublications(context);
      if (!(await this.publication()).isAvailable()) return false;
      const staged = await this.staging();
      const stageCleaned = staged === undefined || await staged.recover(context);
      if (!cleanup.drained || !stageCleaned) return false;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.CACHE_DRAIN, DiagnosticResult.OK, { drained: true });
      return true;
    } catch (_) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.CACHE_DRAIN, DiagnosticResult.FAIL,
        { reason: DiagnosticReason.INFLIGHT_UNCONFIRMED, drained: false });
      return false;
    } finally {
      this.finishLease(recoveryOwner);
      CloudBackupDiagnostics.end(context);
    }
  }

  private finishLease(owner: CloudBackupOperationLease): void {
    if (owner.isCleanupPending() || this.cacher?.isCleanupPending?.()) {
      owner.retainUnknownIo();
      this.pendingCleanupLease = owner;
    } else {
      owner.release();
    }
  }

  private async ready(): Promise<CloudBackupFailureReason> {
    await this.init();
    if (!this.context || !this.cloudDir) return CloudBackupFailureReason.NOT_READY;
    if (!this.accountPort.isUserLogin()) return CloudBackupFailureReason.NOT_SIGNED_IN;
    return CloudBackupFailureReason.NONE;
  }

  private diagnosticReason(reason: CloudBackupFailureReason): DiagnosticReason {
    switch (reason) {
      case CloudBackupFailureReason.NONE: return DiagnosticReason.NONE;
      case CloudBackupFailureReason.NOT_READY: return DiagnosticReason.NOT_READY;
      case CloudBackupFailureReason.NOT_SIGNED_IN: return DiagnosticReason.NOT_SIGNED_IN;
      case CloudBackupFailureReason.BUSY: return DiagnosticReason.BUSY;
      case CloudBackupFailureReason.CLEANUP_PENDING: return DiagnosticReason.INFLIGHT_UNCONFIRMED;
      case CloudBackupFailureReason.IDENTITY_UNAVAILABLE: return DiagnosticReason.IDENTITY_UNAVAILABLE;
      case CloudBackupFailureReason.INVALID_TARGET: return DiagnosticReason.INVALID_ARGUMENT;
      case CloudBackupFailureReason.FORMAT_INVALID: return DiagnosticReason.INVALID_FORMAT;
      case CloudBackupFailureReason.DECRYPT_FAILED: return DiagnosticReason.DECRYPT_FAILED;
      case CloudBackupFailureReason.READ_FAILED:
      case CloudBackupFailureReason.WRITE_FAILED:
      case CloudBackupFailureReason.DELETE_FAILED: return DiagnosticReason.IO_ERROR;
      case CloudBackupFailureReason.SYNC_FAILED: return DiagnosticReason.SYNC_REJECTED;
      case CloudBackupFailureReason.ICON_FAILED: return DiagnosticReason.UNAVAILABLE;
      case CloudBackupFailureReason.POST_VERIFY_FAILED: return DiagnosticReason.MISMATCH;
      default: return DiagnosticReason.UNKNOWN;
    }
  }

  private blockedReason(): CloudBackupFailureReason {
    return this.isCleanupPending() ? CloudBackupFailureReason.CLEANUP_PENDING : CloudBackupFailureReason.BUSY;
  }

  private async runAction(kind: CloudBackupOperationKind, diagnosticKind: DiagnosticKind,
    terminal: DiagnosticStage,
    action: (owner: CloudBackupOperationLease, context: DiagnosticContext) => Promise<CloudBackupActionResult>):
    Promise<CloudBackupActionResult> {
    const context = CloudBackupDiagnostics.begin(diagnosticKind);
    // 在门禁、初始化或读取失败之前也能定位恢复请求，且整次动作共用一个上下文。
    if (kind === CloudBackupOperationKind.RESTORE) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.RESTORE_BEGIN, DiagnosticResult.BEGIN);
    }
    const owner = CloudBackupOperationGate.getInstance().tryEnter(kind);
    if (owner === undefined) {
      const reason = this.blockedReason();
      CloudBackupDiagnostics.mark(context, terminal, DiagnosticResult.BLOCKED, { reason: this.diagnosticReason(reason) });
      CloudBackupDiagnostics.end(context);
      return cloudBackupFailure(reason);
    }
    try {
      const readiness = await this.ready();
      if (readiness !== CloudBackupFailureReason.NONE) {
        CloudBackupDiagnostics.mark(context, terminal, DiagnosticResult.BLOCKED, { reason: this.diagnosticReason(readiness) });
        return cloudBackupFailure(readiness);
      }
      if (!await this.preparePublication(context)) {
        if (this.cacher?.isCleanupPending?.()) owner.retainUnknownIo();
        CloudBackupDiagnostics.mark(context, terminal, DiagnosticResult.BLOCKED,
          { reason: DiagnosticReason.UNAVAILABLE });
        return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
      }
      const result = await action(owner, context);
      if (owner.isCleanupPending() || this.cacher?.isCleanupPending?.()) {
        result.success = false;
        result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
      }
      CloudBackupDiagnostics.mark(context, terminal, result.success ? DiagnosticResult.OK : DiagnosticResult.FAIL,
        { reason: this.diagnosticReason(result.reason), partialFailure: result.partialFailure,
          syncStartAccepted: result.syncStartAccepted });
      return result;
    } catch (_) {
      CloudBackupDiagnostics.mark(context, terminal, DiagnosticResult.FAIL, { reason: DiagnosticReason.UNKNOWN });
      return cloudBackupFailure(CloudBackupFailureReason.UNKNOWN);
    } finally {
      this.finishLease(owner);
      CloudBackupDiagnostics.end(context);
    }
  }

  async backupToCloud(): Promise<boolean> { return (await this.backupToCloudResult()).success; }

  async backupToCloudResult(): Promise<CloudBackupActionResult> {
    return this.runAction(CloudBackupOperationKind.BACKUP, DiagnosticKind.BACKUP, DiagnosticStage.BACKUP_END,
      async (owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        return this.performBackupToCloud(owner, context);
      });
  }

  /** 失败阶段 → 持久化失败状态键的阶段枚举映射。 */
  private backupFailureStageOfPhase(phase: DiagnosticStage): CloudSyncFailureStage {
    switch (phase) {
      case DiagnosticStage.WRITE_END: return CloudSyncFailureStage.WRITE;
      case DiagnosticStage.FS_VERIFY: return CloudSyncFailureStage.STAGED_VERIFY;
      case DiagnosticStage.PUBLISH_END:
      case DiagnosticStage.PUBLICATION_GUARD: return CloudSyncFailureStage.PUBLISH;
      default: return CloudSyncFailureStage.UNKNOWN;
    }
  }

  /** 汇总阶段原因 → 失败状态键的阶段枚举映射（轮换/图标/同步在发布之后收口）。 */
  private backupFailureStageOfReason(reason: CloudBackupFailureReason): CloudSyncFailureStage {
    switch (reason) {
      case CloudBackupFailureReason.ICON_FAILED: return CloudSyncFailureStage.ICON;
      case CloudBackupFailureReason.SYNC_FAILED: return CloudSyncFailureStage.SYNC;
      case CloudBackupFailureReason.DELETE_FAILED:
      case CloudBackupFailureReason.CLEANUP_PENDING: return CloudSyncFailureStage.ROTATE;
      default: return CloudSyncFailureStage.UNKNOWN;
    }
  }

  /**
   * 单次备份尝试的完整管线。写入链路错误零容忍：失败出口都先落
   * CLOUD_SYNC_LAST_FAILURE 失败状态键（详情页持久展示），再返回整体失败。
   * 例外：管线开工前的环境阻断（cacher cleanup-pending 早退）与被门禁/登录态
   * 阻断的尝试一样不落键——避免用环境状态覆盖既有真实失败记录。
   */
  private async performBackupToCloud(owner: CloudBackupOperationLease,
    context: DiagnosticContext): Promise<CloudBackupActionResult> {
    CloudBackupDiagnostics.mark(context, DiagnosticStage.BACKUP_BEGIN, DiagnosticResult.BEGIN);
    const guard = await this.publication();
    await this.cleanupPublications(context);
    if (!guard.isAvailable()) return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
    if (this.testDeps?.device === undefined) DeviceInfoHelper.getInstance().refreshRequiredInfo();
    const deviceId = normalizeCloudBackupDeviceId(this.devicePort.deviceId());
    const deviceName = this.devicePort.deviceName().trim();
    CloudBackupDiagnostics.mark(context, DiagnosticStage.DEVICE_INFO, DiagnosticResult.OK,
      { identityAvailable: deviceId.length > 0, nameAvailable: deviceName.length > 0 });
    if (!deviceId) {
      CloudSyncFailureState.record(CloudSyncFailureStage.DEVICE_INFO, CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
      return cloudBackupFailure(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
    }
    // 令牌/分组快照读取失败同样是备份失败，不向用户抛未处理异常。
    const payload = new CloudBackupPayload();
    let snapshotCount = 0;
    try {
      const tokens = await this.tokenPort.getTokens();
      snapshotCount = tokens.length;
      payload.tokens = tokens.map((token: TokenConfig): TokenConfig => sanitizedTokenForBackup(token));
      payload.groups = [...this.groupPort.currentGroups()];
      payload.enabledPacks = [...TokenIconPacks.enabled_packs];
      for (const pack of TokenIconPacks.aegis_icon_packs) {
        const meta = new PackMetaEntry();
        meta.uuid = pack.uuid;
        meta.name = pack.name;
        meta.version = pack.version;
        meta.iconCount = pack.icons.length;
        payload.packMeta.push(meta);
      }
    } catch (_) {
      CloudSyncFailureState.record(CloudSyncFailureStage.SNAPSHOT, CloudBackupFailureReason.READ_FAILED);
      return cloudBackupFailure(CloudBackupFailureReason.READ_FAILED);
    }
    const now = Math.max(Date.now(), this.lastFileTimestamp + 1);
    this.lastFileTimestamp = now;
    let content: string;
    try {
      content = await this.crypto.encrypt(JSON.stringify(payload), this.crypto.getMode(true),
        this.accountPort.unionId(), snapshotCount, now, deviceId, deviceName, context);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.ENCRYPT_END, DiagnosticResult.OK);
    } catch (_) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.ENCRYPT_END, DiagnosticResult.FAIL);
      CloudSyncFailureState.record(CloudSyncFailureStage.ENCRYPT, CloudBackupFailureReason.FORMAT_INVALID);
      return cloudBackupFailure(CloudBackupFailureReason.FORMAT_INVALID);
    }
    const fileName = `${BACKUP_FILE_PREFIX}${now}${BACKUP_FILE_EXT}`;
    let tempPath = `${this.cloudDir}/.otp_backup_pending_${now}.tmp`;
    let tempOwned = false;
    let staged: CloudBackupStaging | undefined = undefined;
    let published = false;
    let candidate = '';
    let preserveSource = false;
    let cleanupFailed = false;
    let phase = DiagnosticStage.WRITE_END;
    let failureReason = DiagnosticReason.IO_ERROR;
    try {
      if (this.cacher?.isCleanupPending?.()) return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
      staged = await this.staging();
      // 生产密文先登记本地凭据；测试旧端口仍只有成功返回后才获得精确目标所有权。
      if (staged !== undefined) tempPath = await staged.create(content, context);
      else await this.fsPort.writeNewTextFile(tempPath, content, context);
      tempOwned = true;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.WRITE_END, DiagnosticResult.OK,
        { contentNonEmpty: content.length > 0, writeComplete: true });
      phase = DiagnosticStage.FS_VERIFY;
      const actual = await this.fsPort.readTextFile(tempPath, context);
      failureReason = DiagnosticReason.INVALID_FORMAT;
      if (actual !== content || actual.length === 0) throw new Error('BACKUP_VERIFY_FAILED');
      this.crypto.parseTokenHeader(actual, context);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.FS_VERIFY, DiagnosticResult.OK,
        { contentNonEmpty: true, writeComplete: true, headerParsed: true });
      phase = DiagnosticStage.PUBLICATION_GUARD;
      failureReason = DiagnosticReason.IO_ERROR;
      // Durable candidate precedes the formal move, so process death is fail-closed.
      preserveSource = true;
      candidate = await guard.register(tempPath, fileName, context);
      preserveSource = false;
      phase = DiagnosticStage.PUBLISH_END;
      if (staged !== undefined) await staged.publish(tempPath, `${this.cloudDir}/${fileName}`, context);
      else await this.fsPort.publishFile(tempPath, `${this.cloudDir}/${fileName}`, context);
      published = true;
      if (staged === undefined) tempOwned = false;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.PUBLISH_END, DiagnosticResult.OK);
      phase = DiagnosticStage.PUBLICATION_GUARD;
      await guard.published(candidate, context);
    } catch (_) {
      // 原生详细错误由 StoragePorts 报告；此处只补准确阶段，不重复原始异常。
      CloudBackupDiagnostics.mark(context, phase, DiagnosticResult.FAIL, { reason: failureReason });
      if (!published && candidate !== '') {
        // A collision must be cancelled while the source still proves no publication.
        try { await guard.cancelUnpublished(candidate, context); } catch (_) { preserveSource = true; }
      }
      this.publicationUnavailable = !guard.isAvailable();
      this.publicationPending = guard.hasRejectedCleanup();
      CloudSyncFailureState.record(this.backupFailureStageOfPhase(phase), CloudBackupFailureReason.WRITE_FAILED);
      const failed = cloudBackupFailure(CloudBackupFailureReason.WRITE_FAILED);
      failed.partialFailure = published || preserveSource;
      return failed;
    } finally {
      if (tempOwned && !preserveSource) {
        if (staged !== undefined) cleanupFailed = !await staged.discard(tempPath, context);
        else {
          try { await this.fsPort.deleteFile(tempPath); } catch (_) {
            CloudBackupDiagnostics.mark(context, DiagnosticStage.TEMP_CLEANUP, DiagnosticResult.FAIL,
              { reason: DiagnosticReason.IO_ERROR });
          }
        }
      }
      if (!published && !preserveSource && staged !== undefined) await staged.recover(context);
    }
    // 发布后一致性校验（守护核心）：以发起备份时的快照（令牌数量 + 写入 header 的
    // deviceId）对正式文件重读比对；不动摇既有的暂存回读，也不新增抢闸。
    if (!await this.verifyPublishedBackup(fileName, snapshotCount, deviceId, context)) {
      // Rejection proof is durable before unlink. Failure leaves the candidate isolated, never auto-deleted.
      let cleanup = new PublicationCleanupResult();
      cleanup.drained = false;
      try {
        await guard.reject(candidate, context);
        cleanup = await this.cleanupPublications(context);
        if (cleanup.syncStartAccepted && staged !== undefined) await staged.acknowledgeSync(context);
      } catch (_) { this.publicationUnavailable = true; }
      this.publicationPending = guard.hasRejectedCleanup();
      CloudSyncFailureState.record(CloudSyncFailureStage.POST_PUBLISH_VERIFY, CloudBackupFailureReason.POST_VERIFY_FAILED);
      const failed = cloudBackupFailure(CloudBackupFailureReason.POST_VERIFY_FAILED);
      failed.syncStartAccepted = cleanup.syncStartAccepted;
      failed.partialFailure = !cleanup.drained || cleanupFailed;
      return failed;
    }
    try {
      // Postverify success alone is insufficient: durable release must also succeed.
      await guard.verified(candidate, context);
      this.publicationPending = guard.hasRejectedCleanup();
    } catch (_) {
      this.publicationUnavailable = true;
      CloudSyncFailureState.record(CloudSyncFailureStage.PUBLISH, CloudBackupFailureReason.WRITE_FAILED);
      const failed = cloudBackupFailure(CloudBackupFailureReason.WRITE_FAILED);
      failed.partialFailure = true;
      return failed;
    }
    const result = new CloudBackupActionResult();
    result.localComplete = true;
    if (cleanupFailed) {
      result.partialFailure = true;
      result.reason = CloudBackupFailureReason.DELETE_FAILED;
    }
    const scan = await this.listBackupRecords(context, owner);
    if (scan.blocked) {
      result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
      result.partialFailure = true;
      CloudSyncFailureState.record(CloudSyncFailureStage.ROTATE, CloudBackupFailureReason.CLEANUP_PENDING);
      return result;
    }
    // 轮换剪除仅统计归属本机且 header 通过的记录；无归属/他机记录不入选也不被剪除。
    const owned = scan.records.filter((record: CloudBackupRecord): boolean =>
      record.metadataStatus === CloudBackupMetadataStatus.VALID && record.tokenCountKnown === true && record.deviceId === deviceId);
    if (owned.length > MAX_BACKUP_COUNT) {
      const prune = await this.deleteBackupFile(owned[owned.length - 1].id, context);
      if (!prune.success) { result.partialFailure = true; result.reason = prune.reason; }
    }
    try {
      if (!await this.iconPort.backupIconPacks(owner, true, context)) {
        result.partialFailure = true;
        result.reason = CloudBackupFailureReason.ICON_FAILED;
      }
    } catch (_) {
      result.partialFailure = true;
      result.reason = CloudBackupFailureReason.ICON_FAILED;
    }
    result.syncStartAccepted = await this.syncToCloud(context);
    if (result.syncStartAccepted && staged !== undefined) await staged.acknowledgeSync(context);
    if (!result.syncStartAccepted) result.reason = CloudBackupFailureReason.SYNC_FAILED;
    result.success = !result.partialFailure && result.syncStartAccepted;
    if (result.success) {
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${now}`);
      CloudSyncFailureState.clear();
    } else {
      CloudSyncFailureState.record(this.backupFailureStageOfReason(result.reason), result.reason);
    }
    return result;
  }

  /**
   * 发布后快速一致性校验：重读正式文件并只解析 header 的令牌数量与设备标识，
   * 与发起备份时的快照比对。不解密正文、不展开令牌列表。
   * 重读抛错、文件缺失、header 非法三种情况都收敛为校验失败，不向用户抛未处理异常。
   */
  private async verifyPublishedBackup(fileName: string, expectedCount: number, expectedDeviceId: string,
    context: DiagnosticContext): Promise<boolean> {
    try {
      const content = await this.fsPort.readTextFile(`${this.cloudDir}/${fileName}`, context);
      const header = this.crypto.parseTokenHeader(content, context);
      if (header.tokenCount !== expectedCount ||
        normalizeCloudBackupDeviceId(header.deviceId) !== expectedDeviceId) {
        // 只记比对结论，不输出数量、文件名或路径。
        CloudBackupDiagnostics.mark(context, DiagnosticStage.POST_PUBLISH_VERIFY, DiagnosticResult.FAIL,
          { reason: DiagnosticReason.MISMATCH, headerParsed: true });
        return false;
      }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.POST_PUBLISH_VERIFY, DiagnosticResult.OK,
        { headerParsed: true });
      return true;
    } catch (error) {
      // code 1/2 为可信格式/完整性失败；code 3（Base64/JSON 解码不可用）归解密类，其余读取异常归 IO。
      const tokenError = error instanceof CloudBackupTokenError ? error.code : 0;
      const invalid = tokenError === 1 || tokenError === 2;
      const undecodable = tokenError === 3;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.POST_PUBLISH_VERIFY, DiagnosticResult.FAIL,
        { reason: invalid ? DiagnosticReason.INVALID_FORMAT :
          undecodable ? DiagnosticReason.DECRYPT_FAILED : DiagnosticReason.IO_ERROR });
      return false;
    }
  }

  async restoreFromCloud(): Promise<boolean> {
    const result = await this.runAction(CloudBackupOperationKind.RESTORE, DiagnosticKind.RESTORE,
      DiagnosticStage.RESTORE_END,
      async (owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        const scan = await this.listBackupRecords(context, owner);
        if (scan.blocked) return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
        const restorable = scan.records.filter((record: CloudBackupRecord): boolean =>
          record.metadataStatus === CloudBackupMetadataStatus.VALID);
        if (restorable.length === 0) return cloudBackupFailure(CloudBackupFailureReason.READ_FAILED);
        return this.restoreRecord(restorable[0].id, context, owner);
      });
    return result.success;
  }

  async restoreFromBackupRecord(id: string): Promise<boolean> {
    return (await this.restoreFromBackupRecordResult(id)).success;
  }

  async restoreFromBackupRecordResult(id: string): Promise<CloudBackupActionResult> {
    return this.runAction(CloudBackupOperationKind.RESTORE, DiagnosticKind.RESTORE, DiagnosticStage.RESTORE_END,
      async (owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        return this.restoreRecord(id, context, owner);
      });
  }

  private async restoreRecord(id: string, context: DiagnosticContext,
    owner: CloudBackupOperationLease): Promise<CloudBackupActionResult> {
    if (!isSafeCloudBackupId(id)) return cloudBackupFailure(CloudBackupFailureReason.INVALID_TARGET);
    const guard = await this.publication();
    if (!guard.isAvailable()) return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
    if (guard.isolatedFileNames().includes(id)) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.PUBLICATION_GUARD, DiagnosticResult.BLOCKED,
        { reason: DiagnosticReason.MISMATCH });
      return cloudBackupFailure(CloudBackupFailureReason.POST_VERIFY_FAILED);
    }
    let content: string;
    try {
      const path = `${this.cloudDir}/${id}`;
      const stat = await this.fsPort.stat(path);
      if (!await this.prepareRead(path, stat.location, context)) {
        owner.retainUnknownIo();
        return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
      }
      content = await this.fsPort.readTextFile(path, context);
    } catch (error) {
      this.logFileError(context, DiagnosticStage.READ_END, error);
      return cloudBackupFailure(CloudBackupFailureReason.READ_FAILED);
    }
    let decrypted: string;
    try {
      decrypted = await this.crypto.decrypt(content, this.crypto.getMode(true), this.accountPort.unionId(), context);
    } catch (error) {
      // 只有可信的格式/完整性错误可判坏；不能按原生 code、名称或 message 猜测密钥原因。
      const invalid = error instanceof CloudBackupTokenError && (error.code === 1 || error.code === 2);
      return cloudBackupFailure(invalid ? CloudBackupFailureReason.FORMAT_INVALID : CloudBackupFailureReason.DECRYPT_FAILED);
    }
    let payload: CloudBackupRestorePayload;
    try {
      payload = this.parseRestorePayload(decrypted);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.RESTORE_VALIDATE, DiagnosticResult.OK);
    } catch (_) {
      // CBC 的有效填充及非密钥摘要不能证明密钥正确；只有明文 mock 可确认为载荷格式错误。
      const invalid = this.crypto.isMockFormat(content);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.RESTORE_VALIDATE, DiagnosticResult.FAIL,
        { reason: invalid ? DiagnosticReason.INVALID_FORMAT : DiagnosticReason.DECRYPT_FAILED });
      return cloudBackupFailure(invalid ? CloudBackupFailureReason.FORMAT_INVALID : CloudBackupFailureReason.DECRYPT_FAILED);
    }
    try {
      if (payload.groups !== undefined) await this.groupPort.merge(payload.groups);
      if (payload.enabledPacks.length > 0) AppPreference.saveEnabledPacks(payload.enabledPacks);
      for (const token of payload.tokens) await this.tokenPort.updateToken(token);
      const result = new CloudBackupActionResult();
      result.success = true;
      result.localComplete = true;
      return result;
    } catch (_) {
      const result = cloudBackupFailure(CloudBackupFailureReason.WRITE_FAILED);
      result.partialFailure = true;
      return result;
    }
  }

  /** 在任何本地持久化之前完整校验；旧数组没有 groups，不能额外触发分组合并。 */
  private parseRestorePayload(decrypted: string): CloudBackupRestorePayload {
    let tokens: TokenConfig[];
    let groups: TokenGroup[] | undefined = undefined;
    let enabledPacks: string[] = [];
    const parsed = JSON.parse(decrypted) as CloudBackupPayload;
    if (Array.isArray(parsed)) {
      tokens = parsed as TokenConfig[];
    } else {
      if (!parsed || !Array.isArray(parsed.tokens) ||
        (parsed.groups !== undefined && !Array.isArray(parsed.groups)) ||
        (parsed.enabledPacks !== undefined && !Array.isArray(parsed.enabledPacks))) {
        throw new Error('BACKUP_PAYLOAD_INVALID');
      }
      tokens = parsed.tokens;
      groups = parsed.groups;
      enabledPacks = parsed.enabledPacks ?? [];
    }
    const ids = new Set<string>();
    for (const token of tokens) {
      // NFC(type=4) 本就不允许持久化，不能放宽或静默跳过使非法备份看似恢复成功。
      if (!token || typeof token !== 'object' || Array.isArray(token) ||
        typeof token.TokenUUID !== 'string' || token.TokenUUID.trim().length === 0 || ids.has(token.TokenUUID) ||
        typeof token.TokenSecret !== 'string' || token.TokenSecret.length === 0 ||
        !Number.isInteger(token.TokenType) || token.TokenType < 0 || token.TokenType > 3 ||
        (token.TokenName !== undefined && typeof token.TokenName !== 'string') ||
        (token.TokenIssuer !== undefined && typeof token.TokenIssuer !== 'string') ||
        (token.TokenAlgorithm !== undefined && typeof token.TokenAlgorithm !== 'string') ||
        (token.TokenGroupId !== undefined && typeof token.TokenGroupId !== 'string') ||
        (token.TokenFavorite !== undefined && typeof token.TokenFavorite !== 'boolean') ||
        (token.TokenPeriod !== undefined && (!Number.isFinite(token.TokenPeriod) || token.TokenPeriod <= 0)) ||
        (token.TokenDigits !== undefined && (!Number.isInteger(token.TokenDigits) || token.TokenDigits <= 0)) ||
        (token.TokenCounter !== undefined && (!Number.isSafeInteger(token.TokenCounter) || token.TokenCounter < 0)) ||
        (token.RankScore !== undefined && !Number.isFinite(token.RankScore))) {
        throw new Error('BACKUP_PAYLOAD_INVALID');
      }
      ids.add(token.TokenUUID);
    }
    const groupIds = new Set<string>();
    if (groups !== undefined) {
      for (const group of groups) {
        if (!group || typeof group !== 'object' || Array.isArray(group) || typeof group.id !== 'string' ||
          group.id.trim().length === 0 || groupIds.has(group.id) || typeof group.name !== 'string' ||
          group.name.trim().length === 0) throw new Error('BACKUP_PAYLOAD_INVALID');
        groupIds.add(group.id);
      }
    }
    if (enabledPacks.some((pack: string): boolean => typeof pack !== 'string' || pack.length === 0)) {
      throw new Error('BACKUP_PAYLOAD_INVALID');
    }
    return { tokens: tokens, groups: groups, enabledPacks: enabledPacks };
  }

  async clearCloudStorage(): Promise<boolean> { return (await this.clearCloudStorageResult()).success; }
  async clearDeviceCloudStorage(): Promise<boolean> { return (await this.clearDeviceCloudStorageResult()).success; }
  async clearDeviceNameCloudStorage(): Promise<boolean> { return (await this.clearDeviceNameCloudStorageResult()).success; }
  clearCloudStorageResult(): Promise<CloudBackupActionResult> { return this.clearResult(DiagnosticScope.ALL); }
  clearDeviceCloudStorageResult(): Promise<CloudBackupActionResult> { return this.clearResult(DiagnosticScope.DEVICE); }
  clearDeviceNameCloudStorageResult(): Promise<CloudBackupActionResult> { return this.clearResult(DiagnosticScope.SAME_NAME); }

  private clearResult(scope: DiagnosticScope): Promise<CloudBackupActionResult> {
    return this.runAction(CloudBackupOperationKind.CLEAR, DiagnosticKind.CLEAR, DiagnosticStage.CLEAR_END,
      async (owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.CLEAR_BEGIN, DiagnosticResult.BEGIN, { scope: scope });
        const result = new CloudBackupActionResult();
        let targets: string[] = [];
        let devices: string[] = [];
        try {
          if (scope === DiagnosticScope.ALL) {
            targets = (await this.fsPort.listFiles(this.cloudDir)).filter(isSafeCloudBackupId);
          } else {
            const id = normalizeCloudBackupDeviceId(this.devicePort.deviceId());
            const name = this.devicePort.deviceName().trim();
            if (!id || (scope === DiagnosticScope.SAME_NAME && !name)) {
              return cloudBackupFailure(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
            }
            const scan = await this.listBackupRecords(context, owner);
            if (scan.blocked) return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
            if (!scan.complete) return cloudBackupFailure(CloudBackupFailureReason.READ_FAILED);
            // 无归属（deviceId 缺失）或同名范围无法确认的记录：跳过并计数上报，
            // 不再阻断设备级清理，也绝不自动认领（归错设备的删除不可逆）。
            for (const record of scan.records) {
              if (!record.deviceId || (scope === DiagnosticScope.SAME_NAME && !record.deviceName)) {
                result.skippedUnowned++;
                continue;
              }
              const matched = scope === DiagnosticScope.DEVICE ? record.deviceId === id :
                record.deviceId !== id && record.deviceName === name;
              if (matched) {
                targets.push(record.id);
                devices.push(record.deviceId);
              }
            }
            if (scope === DiagnosticScope.DEVICE && !devices.includes(id)) devices.push(id);
          }
        } catch (error) {
          this.logFileError(context, DiagnosticStage.READ_END, error);
          return cloudBackupFailure(CloudBackupFailureReason.READ_FAILED);
        }
        let iconsOk = true;
        // 设备范围须先保留归属证据，图标无法确认清理时不能先删除这些令牌文件。
        if (scope !== DiagnosticScope.ALL && devices.length > 0) {
          iconsOk = await this.clearIcons(owner, context, devices);
          if (!iconsOk) {
            result.reason = CloudBackupFailureReason.ICON_FAILED;
            result.partialFailure = true;
            result.syncStartAccepted = await this.syncToCloud(context);
            return result;
          }
        }
        let deletedAny = false;
        const deletedTargets: string[] = [];
        for (const target of targets) {
          const deletion = await this.deleteBackupFile(target, context);
          if (deletion.success) {
            deletedAny = true;
            deletedTargets.push(target);
            result.deletedCount++;
          } else { result.reason = deletion.reason; result.partialFailure = true; }
        }
        if (scope === DiagnosticScope.ALL) {
          iconsOk = await this.clearIcons(owner, context);
          if (!iconsOk) { result.partialFailure = true; result.reason = CloudBackupFailureReason.ICON_FAILED; }
        }
        result.localComplete = !result.partialFailure && iconsOk;
        result.syncStartAccepted = await this.syncToCloud(context);
        if (result.syncStartAccepted) {
          try {
            const guard = await this.publication();
            for (const target of deletedTargets) await guard.acknowledgeExplicitDeletion(target, context);
            this.publicationPending = guard.hasRejectedCleanup();
          } catch (_) {
            this.publicationUnavailable = true;
            result.partialFailure = true;
            result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
          }
        }
        if (!result.syncStartAccepted && result.reason === CloudBackupFailureReason.NONE) {
          result.reason = CloudBackupFailureReason.SYNC_FAILED;
        }
        result.success = result.localComplete && result.syncStartAccepted && !result.partialFailure;
        if (result.success && scope !== DiagnosticScope.SAME_NAME) {
          AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
        }
        if (!result.success && deletedAny) result.partialFailure = true;
        return result;
      });
  }

  private async clearIcons(owner: CloudBackupOperationLease, context: DiagnosticContext, ids?: string[]): Promise<boolean> {
    try {
      const icons = this.iconPort;
      if (ids !== undefined && icons.clearCloudBackupForDevices !== undefined) {
        return await icons.clearCloudBackupForDevices(ids, owner, true, context);
      }
      return await icons.clearCloudBackup(owner, true, context);
    } catch (_) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.ICON_CLEAR, DiagnosticResult.FAIL);
      return false;
    }
  }

  async deleteBackupRecord(id: string): Promise<boolean> { return (await this.deleteBackupRecordResult(id)).success; }

  deleteBackupRecordResult(id: string): Promise<CloudBackupActionResult> {
    return this.runAction(CloudBackupOperationKind.CLEAR, DiagnosticKind.DELETE, DiagnosticStage.DELETE_END,
      async (_owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        const result = await this.deleteBackupFile(id, context);
        if (!result.success) return result;
        result.syncStartAccepted = await this.syncToCloud(context);
        result.success = result.syncStartAccepted;
        if (!result.success) result.reason = CloudBackupFailureReason.SYNC_FAILED;
        else {
          try {
            const guard = await this.publication();
            await guard.acknowledgeExplicitDeletion(id, context);
            this.publicationPending = guard.hasRejectedCleanup();
          } catch (_) {
            this.publicationUnavailable = true;
            result.success = false;
            result.partialFailure = true;
            result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
          }
        }
        return result;
      });
  }

  private async deleteBackupFile(id: string, context: DiagnosticContext): Promise<CloudBackupActionResult> {
    if (!isSafeCloudBackupId(id)) return cloudBackupFailure(CloudBackupFailureReason.INVALID_TARGET);
    const path = `${this.cloudDir}/${id}`;
    try {
      const cache = this.cacher;
      if (cache?.prepareForDelete !== undefined && !await cache.prepareForDelete(path, context)) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.DELETE_GUARD, DiagnosticResult.BLOCKED,
          { reason: DiagnosticReason.INFLIGHT_UNCONFIRMED, unlinkAttempted: false });
        return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
      }
      try {
        await this.fsPort.stat(path);
      } catch (error) {
        if (!isFileAbsent(error)) throw error as Error;
        const absent = new CloudBackupActionResult();
        absent.success = true;
        absent.localComplete = true;
        CloudBackupDiagnostics.mark(context, DiagnosticStage.UNLINK_END, DiagnosticResult.OK,
          { alreadyAbsent: true, unlinkAttempted: false });
        return absent;
      }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.UNLINK_BEGIN, DiagnosticResult.BEGIN, { unlinkAttempted: true });
      try { await this.fsPort.deleteFile(path); } catch (error) { if (!isFileAbsent(error)) throw error as Error; }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.UNLINK_END, DiagnosticResult.OK, { unlinkAttempted: true });
      const result = new CloudBackupActionResult();
      result.success = true;
      result.localComplete = true;
      return result;
    } catch (error) {
      this.logFileError(context, DiagnosticStage.UNLINK_END, error);
      return cloudBackupFailure(CloudBackupFailureReason.DELETE_FAILED);
    }
  }

  async listBackupHistory(): Promise<CloudBackupRecord[]> { return (await this.listBackupHistoryResult()).records; }

  async listBackupHistoryResult(): Promise<CloudBackupHistoryResult> {
    const result = new CloudBackupHistoryResult();
    const context = CloudBackupDiagnostics.begin(DiagnosticKind.HISTORY);
    const owner = CloudBackupOperationGate.getInstance().tryEnter(CloudBackupOperationKind.HISTORY);
    if (owner === undefined) {
      result.reason = this.blockedReason();
      CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, DiagnosticResult.BLOCKED,
        { reason: this.diagnosticReason(result.reason) });
      CloudBackupDiagnostics.end(context);
      return result;
    }
    try {
      result.reason = await this.ready();
      if (result.reason !== CloudBackupFailureReason.NONE) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, DiagnosticResult.BLOCKED,
          { reason: this.diagnosticReason(result.reason) });
        return result;
      }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_BEGIN, DiagnosticResult.BEGIN);
      if (!await this.preparePublication(context)) {
        if (this.cacher?.isCleanupPending?.()) owner.retainUnknownIo();
        result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
        return result;
      }
      // Startup/history retries only durable confirmed-and-rejected publication ownership.
      await this.cleanupPublications(context);
      if (!(await this.publication()).isAvailable()) {
        result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
        return result;
      }
      if (this.cacher?.isCleanupPending?.()) {
        owner.retainUnknownIo();
        result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
        return result;
      }
      // Guard source inspection must finish before staging recovery removes any source evidence.
      // 当前许可排除本进程写入；仅恢复本安装登记产物，失败不隐藏仍可读的正式历史。
      if (!this.cacher?.isCleanupPending?.()) {
        try { await (await this.staging())?.recover(context); } catch (_) {
          CloudBackupDiagnostics.mark(context, DiagnosticStage.TEMP_CLEANUP, DiagnosticResult.FAIL,
            { reason: DiagnosticReason.UNAVAILABLE });
        }
      }
      if (this.testDeps !== null && this.testDeps.historyTask === undefined) {
        const scan = await this.listBackupRecords(context, owner);
        result.records = scan.records;
        result.success = scan.complete;
      } else {
        if (!await this.precache(context)) {
          owner.retainUnknownIo();
          result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
          CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, DiagnosticResult.BLOCKED,
            { reason: DiagnosticReason.INFLIGHT_UNCONFIRMED });
          return result;
        }
        const task = this.testDeps?.historyTask !== undefined ? await this.testDeps.historyTask(this.cloudDir, context) :
          await taskpool.execute(loadBackupHistoryRecords, this.cloudDir, false, context) as CloudBackupTaskHistory;
        result.records = task.records;
        result.success = task.complete;
        CloudBackupDiagnostics.replay(context, task.diagnostics);
      }
      applyCloudPublicationIsolation(result.records, (await this.publication()).isolatedFileNames());
      if (!result.success) result.reason = CloudBackupFailureReason.READ_FAILED;
      if (owner.isCleanupPending() || this.cacher?.isCleanupPending?.()) {
        result.success = false;
        result.reason = CloudBackupFailureReason.CLEANUP_PENDING;
      }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, result.success ? DiagnosticResult.OK : DiagnosticResult.FAIL,
        { reason: this.diagnosticReason(result.reason) });
      return result;
    } catch (error) {
      this.logFileError(context, DiagnosticStage.HISTORY_END, error);
      result.reason = CloudBackupFailureReason.READ_FAILED;
      return result;
    } finally {
      this.finishLease(owner);
      CloudBackupDiagnostics.end(context);
    }
  }

  async cacheCloudOnlyBackups(): Promise<void> {
    await this.runAction(CloudBackupOperationKind.HISTORY, DiagnosticKind.HISTORY, DiagnosticStage.HISTORY_END,
      async (owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        if (!await this.precache(context)) {
          owner.retainUnknownIo();
          return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
        }
        const result = new CloudBackupActionResult();
        result.success = true;
        return result;
      });
  }

  private async precache(context: DiagnosticContext): Promise<boolean> {
    const isolated = (await this.publication()).isolatedFileNames();
    const files = await this.fsPort.listFiles(this.cloudDir);
    for (const name of files) {
      if (!isSafeCloudBackupId(name) || isolated.includes(name)) continue;
      try {
        const path = `${this.cloudDir}/${name}`;
        const stat = await this.fsPort.stat(path);
        if (!await this.prepareRead(path, stat.location, context)) return false;
      } catch (error) {
        // 单次 stat 错误不构成持久黑名单；后台重新枚举并按实际读取结果展示。
        this.logFileError(context, DiagnosticStage.READ_END, error);
      }
    }
    return this.cacher?.isCleanupPending?.() !== true;
  }

  private async listBackupRecords(context: DiagnosticContext, owner: CloudBackupOperationLease): Promise<BackupScanResult> {
    const result = new BackupScanResult();
    const guard = await this.publication();
    if (!guard.isAvailable()) { result.blocked = true; result.complete = false; return result; }
    const isolated = guard.isolatedFileNames();
    let files: string[];
    try { files = await this.fsPort.listFiles(this.cloudDir); } catch (error) {
      this.logFileError(context, DiagnosticStage.READ_END, error);
      result.complete = false;
      return result;
    }
    for (const name of files) {
      if (!isSafeCloudBackupId(name)) continue;
      const path = `${this.cloudDir}/${name}`;
      try {
        const stat = await this.fsPort.stat(path);
        const timestamp = parseBackupTimestamp(name);
        const record: CloudBackupRecord = {
          id: name, date: SyncTimeHelper.formatTimestamp(timestamp), timestamp: timestamp,
          tokenCount: 0, size: stat.size, encrypted: true, deviceId: '', deviceName: '', location: stat.location,
          metadataStatus: stat.location === 2 ? CloudBackupMetadataStatus.PENDING : CloudBackupMetadataStatus.READ_FAILED,
          identityStatus: CloudBackupIdentityStatus.ID_MISSING, tokenCountKnown: false,
        };
        if (isolated.includes(name)) {
          applyCloudPublicationIsolation([record], isolated);
          result.records.push(record);
          continue;
        }
        let content: string | undefined = undefined;
        if (!await this.prepareRead(path, stat.location, context)) {
          owner.retainUnknownIo();
          result.blocked = true;
          result.complete = false;
          result.records.push(record);
          break;
        }
        try {
          content = await this.fsPort.readTextFile(path, context);
        } catch (error) {
          record.metadataStatus = CloudBackupMetadataStatus.READ_FAILED;
          this.logFileError(context, DiagnosticStage.READ_END, error);
        }
        if (content !== undefined) {
          try {
            const header = this.crypto.parseTokenHeader(content);
            record.tokenCount = header.tokenCount;
            record.size = header.size;
            record.deviceId = normalizeCloudBackupDeviceId(header.deviceId);
            record.deviceName = header.deviceName.trim();
            record.metadataStatus = CloudBackupMetadataStatus.VALID;
            record.identityStatus = !record.deviceId ? CloudBackupIdentityStatus.ID_MISSING :
              !record.deviceName ? CloudBackupIdentityStatus.NAME_MISSING : CloudBackupIdentityStatus.COMPLETE;
            record.tokenCountKnown = true;
          } catch (error) {
            const invalid = error instanceof CloudBackupTokenError && error.code === 1;
            record.metadataStatus = !invalid ? CloudBackupMetadataStatus.READ_FAILED : stat.location === 2 ? CloudBackupMetadataStatus.PENDING :
              stat.location === 1 || stat.location === 3 ? CloudBackupMetadataStatus.INVALID : CloudBackupMetadataStatus.READ_FAILED;
            CloudBackupDiagnostics.mark(context, DiagnosticStage.HEADER_PARSE, DiagnosticResult.FAIL,
              { reason: invalid ? DiagnosticReason.INVALID_FORMAT : DiagnosticReason.DECRYPT_FAILED,
                contentNonEmpty: content.length > 0, headerParsed: false });
          }
        }
        result.records.push(record);
      } catch (error) {
        result.complete = false;
        this.logFileError(context, DiagnosticStage.READ_END, error);
      }
    }
    result.records.sort((left: CloudBackupRecord, right: CloudBackupRecord): number => right.timestamp - left.timestamp);
    return result;
  }

  async hasBackupRecords(): Promise<boolean | undefined> {
    const context = CloudBackupDiagnostics.begin(DiagnosticKind.HISTORY);
    const owner = CloudBackupOperationGate.getInstance().tryEnter(CloudBackupOperationKind.HISTORY);
    if (owner === undefined) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, DiagnosticResult.BLOCKED,
        { reason: this.diagnosticReason(this.blockedReason()) });
      CloudBackupDiagnostics.end(context);
      return undefined;
    }
    try {
      const readiness = await this.ready();
      if (readiness !== CloudBackupFailureReason.NONE) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, DiagnosticResult.BLOCKED,
          { reason: this.diagnosticReason(readiness) });
        return undefined;
      }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_BEGIN, DiagnosticResult.BEGIN);
      if (!await this.preparePublication(context)) {
        if (this.cacher?.isCleanupPending?.()) owner.retainUnknownIo();
        return undefined;
      }
      const count = this.testDeps !== null ? ((await this.fsPort.listFiles(this.cloudDir)).some(isSafeCloudBackupId) ? 1 : 0)
        : await taskpool.execute(checkCloudBackupRecords, this.cloudDir) as number;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.HISTORY_END, count < 0 ? DiagnosticResult.FAIL : DiagnosticResult.OK,
        { reason: count < 0 ? DiagnosticReason.IO_ERROR : DiagnosticReason.NONE });
      return count < 0 ? undefined : count > 0;
    } catch (error) {
      this.logFileError(context, DiagnosticStage.HISTORY_END, error);
      return undefined;
    } finally {
      this.finishLease(owner);
      CloudBackupDiagnostics.end(context);
    }
  }

  async retrySync(): Promise<boolean> {
    const result = await this.runAction(CloudBackupOperationKind.HISTORY, DiagnosticKind.SYNC, DiagnosticStage.SYNC_START,
      async (_owner: CloudBackupOperationLease, context: DiagnosticContext): Promise<CloudBackupActionResult> => {
        const result = new CloudBackupActionResult();
        const cleanup = await this.cleanupPublications(context);
        if (!(await this.publication()).isAvailable()) return cloudBackupFailure(CloudBackupFailureReason.CLEANUP_PENDING);
        result.syncStartAccepted = cleanup.syncAttempted ? cleanup.syncStartAccepted : await this.syncToCloud(context);
        result.success = cleanup.drained && result.syncStartAccepted;
        result.partialFailure = !cleanup.drained;
        result.reason = !cleanup.drained ? CloudBackupFailureReason.CLEANUP_PENDING :
          result.success ? CloudBackupFailureReason.NONE : CloudBackupFailureReason.SYNC_FAILED;
        return result;
      });
    return result.success;
  }

  private async syncToCloud(context: DiagnosticContext): Promise<boolean> {
    try {
      let started: boolean;
      if (this.testDeps?.sync !== undefined) {
        await this.testDeps.sync.start();
        started = true;
      } else {
        started = await CloudBackupSyncService.getInstance().start(context);
      }
      CloudBackupDiagnostics.mark(context, DiagnosticStage.SYNC_START, started ? DiagnosticResult.OK : DiagnosticResult.FAIL,
        { syncStartAccepted: started });
      return started;
    } catch (_) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.SYNC_START, DiagnosticResult.FAIL,
        { reason: DiagnosticReason.SYNC_REJECTED, syncStartAccepted: false });
      return false;
    }
  }

  private prepareRead(path: string, location: number, context: DiagnosticContext): Promise<boolean> {
    return prepareCloudFileRead(this.cacher, path, location, context);
  }

  private logFileError(context: DiagnosticContext, stage: DiagnosticStage, error: Object): void {
    let code: number | undefined = undefined;
    try { code = (error as BusinessError).code; } catch (_) {}
    CloudBackupDiagnostics.mark(context, stage, DiagnosticResult.FAIL,
      { errorDomain: DiagnosticErrorDomain.FS, code: code, reason: DiagnosticReason.IO_ERROR });
  }

  async checkAndAutoBackup(): Promise<void> {
    if (!AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) || !this.accountPort.isUserLogin()) return;
    const last = SyncTimeHelper.parseStoredTimestamp(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string);
    if (last > 0 && SyncTimeHelper.isToday(last)) return;
    await this.backupToCloudResult();
  }

  get maxBackupCount(): number { return MAX_BACKUP_COUNT; }
}

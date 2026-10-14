import { cloudSync } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticDetails, DiagnosticErrorDomain, DiagnosticKind, DiagnosticReason,
  DiagnosticResult, DiagnosticStage, DiagnosticState,
} from './CloudBackupDiagnostics';

export enum CloudBackupSyncState {
  UNKNOWN = -1,
  UPLOADING = 0,
  UPLOAD_FAILED = 1,
  DOWNLOADING = 2,
  DOWNLOAD_FAILED = 3,
  COMPLETED = 4,
  STOPPED = 5,
}

export enum CloudBackupSyncError {
  UNKNOWN = -1,
  NO_ERROR = 0,
  NETWORK_UNAVAILABLE = 1,
  WIFI_UNAVAILABLE = 2,
  BATTERY_LEVEL_LOW = 3,
  BATTERY_LEVEL_WARNING = 4,
  CLOUD_STORAGE_FULL = 5,
  LOCAL_STORAGE_FULL = 6,
  DEVICE_TEMPERATURE_TOO_HIGH = 7,
  REMOTE_SERVER_ABNORMAL = 8,
}

/** 仅表示全局同步状态；没有本次备份/删除完成的关联凭据。 */
export interface CloudBackupSyncSnapshot {
  state: CloudBackupSyncState;
  error: CloudBackupSyncError;
}

export type CloudBackupSyncListener = (snapshot: CloudBackupSyncSnapshot) => void;

export interface CloudBackupSyncProgress {
  state: number;
  error: number;
}

export type CloudBackupSyncProgressListener = (progress: CloudBackupSyncProgress) => void;

export interface CloudBackupSyncClient {
  onProgress(listener: CloudBackupSyncProgressListener): void;
  offProgress(listener: CloudBackupSyncProgressListener): void;
  start(): Promise<void>;
}

export interface CloudBackupSyncFactory {
  create(): CloudBackupSyncClient;
}

export interface CloudBackupSyncTimer {
  schedule(callback: () => void, milliseconds: number): number;
  cancel(id: number): void;
}

export interface CloudBackupSyncDiagnostics {
  begin(kind: DiagnosticKind): DiagnosticContext;
  mark(context: DiagnosticContext, stage: DiagnosticStage, result: DiagnosticResult, details?: DiagnosticDetails): void;
  end(context: DiagnosticContext): void;
}

class NativeCloudBackupSyncDiagnostics implements CloudBackupSyncDiagnostics {
  begin(kind: DiagnosticKind): DiagnosticContext { return CloudBackupDiagnostics.begin(kind); }
  mark(context: DiagnosticContext, stage: DiagnosticStage, result: DiagnosticResult, details?: DiagnosticDetails): void {
    CloudBackupDiagnostics.mark(context, stage, result, details);
  }
  end(context: DiagnosticContext): void { CloudBackupDiagnostics.end(context); }
}

class NativeCloudBackupSyncClient implements CloudBackupSyncClient {
  private client: cloudSync.FileSync = new cloudSync.FileSync();
  private callback: ((progress: cloudSync.SyncProgress) => void) | undefined = undefined;

  onProgress(listener: CloudBackupSyncProgressListener): void {
    this.callback = (progress: cloudSync.SyncProgress): void => {
      // SDK SyncProgress 只有 state/error；不保留任何原生对象。
      listener({ state: progress.state, error: progress.error });
    };
    this.client.on('progress', this.callback);
  }

  offProgress(_listener: CloudBackupSyncProgressListener): void {
    if (this.callback !== undefined) {
      this.client.off('progress', this.callback);
      this.callback = undefined;
    }
  }

  start(): Promise<void> {
    return this.client.start();
  }
}

class NativeCloudBackupSyncFactory implements CloudBackupSyncFactory {
  create(): CloudBackupSyncClient {
    return new NativeCloudBackupSyncClient();
  }
}

class SystemCloudBackupSyncTimer implements CloudBackupSyncTimer {
  schedule(callback: () => void, milliseconds: number): number {
    return setTimeout(callback, milliseconds);
  }

  cancel(id: number): void {
    clearTimeout(id);
  }
}

function normalizeSyncState(state: number): CloudBackupSyncState {
  switch (state) {
    case 0: return CloudBackupSyncState.UPLOADING;
    case 1: return CloudBackupSyncState.UPLOAD_FAILED;
    case 2: return CloudBackupSyncState.DOWNLOADING;
    case 3: return CloudBackupSyncState.DOWNLOAD_FAILED;
    case 4: return CloudBackupSyncState.COMPLETED;
    case 5: return CloudBackupSyncState.STOPPED;
    default: return CloudBackupSyncState.UNKNOWN;
  }
}

function normalizeSyncError(error: number): CloudBackupSyncError {
  switch (error) {
    case 0: return CloudBackupSyncError.NO_ERROR;
    case 1: return CloudBackupSyncError.NETWORK_UNAVAILABLE;
    case 2: return CloudBackupSyncError.WIFI_UNAVAILABLE;
    case 3: return CloudBackupSyncError.BATTERY_LEVEL_LOW;
    case 4: return CloudBackupSyncError.BATTERY_LEVEL_WARNING;
    case 5: return CloudBackupSyncError.CLOUD_STORAGE_FULL;
    case 6: return CloudBackupSyncError.LOCAL_STORAGE_FULL;
    case 7: return CloudBackupSyncError.DEVICE_TEMPERATURE_TOO_HIGH;
    case 8: return CloudBackupSyncError.REMOTE_SERVER_ABNORMAL;
    default: return CloudBackupSyncError.UNKNOWN;
  }
}

function syncDiagnosticState(state: CloudBackupSyncState): DiagnosticState {
  switch (state) {
    case CloudBackupSyncState.UPLOADING:
    case CloudBackupSyncState.DOWNLOADING: return DiagnosticState.RUNNING;
    case CloudBackupSyncState.UPLOAD_FAILED:
    case CloudBackupSyncState.DOWNLOAD_FAILED: return DiagnosticState.FAILED;
    case CloudBackupSyncState.COMPLETED: return DiagnosticState.COMPLETED;
    case CloudBackupSyncState.STOPPED: return DiagnosticState.STOPPED;
    default: return DiagnosticState.UNKNOWN;
  }
}

function syncFailure(diagnostics: CloudBackupSyncDiagnostics, context: DiagnosticContext,
  stage: DiagnosticStage, error: Object): void {
  let code: number = -1;
  try {
    code = (error as BusinessError).code;
  } catch (_) {
    // 不读取 message/stack/cause，不调用外部字符串转换。
  }
  diagnostics.mark(context, stage, DiagnosticResult.FAIL,
    { errorDomain: DiagnosticErrorDomain.SYNC, code: code, reason: DiagnosticReason.SYNC_REJECTED });
}

/** 页面订阅和 start 共享同一 SDK 实例；start 返回只代表请求被接受。 */
export class CloudBackupSyncService {
  private static instance: CloudBackupSyncService | undefined = undefined;
  private client: CloudBackupSyncClient | undefined = undefined;
  private callback: CloudBackupSyncProgressListener | undefined = undefined;
  private callbackGeneration: number = 0;
  private subscriptionContext: DiagnosticContext | undefined = undefined;
  private ownsSubscriptionContext: boolean = false;
  private listeners: Set<CloudBackupSyncListener> = new Set();
  private snapshot: CloudBackupSyncSnapshot = {
    state: CloudBackupSyncState.UNKNOWN, error: CloudBackupSyncError.NO_ERROR,
  };
  private startPending: boolean = false;
  private attached: boolean = false;

  private factory: CloudBackupSyncFactory;
  private timer: CloudBackupSyncTimer;
  private timeoutMs: number;
  private diagnostics: CloudBackupSyncDiagnostics;

  constructor(factory: CloudBackupSyncFactory = new NativeCloudBackupSyncFactory(),
    timer: CloudBackupSyncTimer = new SystemCloudBackupSyncTimer(), timeoutMs: number = 60000,
    diagnostics: CloudBackupSyncDiagnostics = new NativeCloudBackupSyncDiagnostics()) {
    this.factory = factory;
    this.timer = timer;
    this.timeoutMs = timeoutMs;
    this.diagnostics = diagnostics;
  }

  static getInstance(): CloudBackupSyncService {
    if (CloudBackupSyncService.instance === undefined) {
      CloudBackupSyncService.instance = new CloudBackupSyncService();
    }
    return CloudBackupSyncService.instance;
  }

  getSnapshot(): CloudBackupSyncSnapshot {
    return { state: this.snapshot.state, error: this.snapshot.error };
  }

  subscribe(listener: CloudBackupSyncListener): () => void {
    this.listeners.add(listener);
    this.attach();
    this.notify(listener);
    let removed = false;
    return (): void => {
      if (!removed) {
        removed = true;
        this.listeners.delete(listener);
        this.detachIfIdle();
      }
    };
  }

  start(context?: DiagnosticContext): Promise<boolean> {
    const trace = context === undefined ? this.diagnostics.begin(DiagnosticKind.SYNC) : context;
    const ownsTrace = context === undefined;
    if (this.startPending) {
      this.diagnostics.mark(trace, DiagnosticStage.SYNC_START, DiagnosticResult.BLOCKED,
        { reason: DiagnosticReason.BUSY, syncStartAccepted: false });
      if (ownsTrace) {
        this.diagnostics.end(trace);
      }
      return Promise.resolve(false);
    }
    // on() 可以同步回调；在订阅前防重入，不排队自动补发旧请求。
    this.startPending = true;
    return new Promise<boolean>((resolve: (accepted: boolean) => void) => {
      let settled = false;
      let timerId = -1;
      const finish = (accepted: boolean, timedOut: boolean = false): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId >= 0) {
          try { this.timer.cancel(timerId); } catch (_) {}
        }
        this.diagnostics.mark(trace, DiagnosticStage.SYNC_START,
          accepted ? DiagnosticResult.OK : DiagnosticResult.FAIL,
          { syncStartAccepted: accepted, reason: timedOut ? DiagnosticReason.TIMEOUT :
            (accepted ? DiagnosticReason.UNKNOWN : DiagnosticReason.SYNC_REJECTED) });
        if (ownsTrace) {
          this.diagnostics.end(trace);
        }
        resolve(accepted);
      };
      const nativeSettled = (): void => {
        this.startPending = false;
        this.detachIfIdle();
      };
      try {
        if (!this.attach(trace) || this.client === undefined) {
          finish(false);
          nativeSettled();
          return;
        }
        timerId = this.timer.schedule(() => {
          // UI 可结束等待，但保留原 start 屏障，未知任务不能通过新实例绕过。
          finish(false, true);
        }, this.timeoutMs);
        this.client.start().then(() => {
          finish(true);
          nativeSettled();
        }, (error: Object) => {
          if (!settled) {
            syncFailure(this.diagnostics, trace, DiagnosticStage.SYNC_START, error);
          }
          finish(false);
          nativeSettled();
        });
      } catch (error) {
        syncFailure(this.diagnostics, trace, DiagnosticStage.SYNC_START, error as Object);
        finish(false);
        nativeSettled();
      }
    });
  }

  private attach(context?: DiagnosticContext): boolean {
    if (this.attached) {
      return true;
    }
    const trace = context === undefined ? this.diagnostics.begin(DiagnosticKind.SYNC) : context;
    this.subscriptionContext = trace;
    this.ownsSubscriptionContext = context === undefined;
    try {
      if (this.client === undefined) {
        this.client = this.factory.create();
      }
      // off 失败时保存同一回调，下一次只重试 off，不重复注册。
      if (this.callback !== undefined) {
        this.client.offProgress(this.callback);
        this.callback = undefined;
      }
      const generation = ++this.callbackGeneration;
      this.callback = (progress: CloudBackupSyncProgress): void => {
        if (!this.attached || this.callbackGeneration !== generation) {
          return;
        }
        const next: CloudBackupSyncSnapshot = {
          state: normalizeSyncState(progress.state), error: normalizeSyncError(progress.error),
        };
        if (next.state === this.snapshot.state && next.error === this.snapshot.error) {
          return;
        }
        this.snapshot = next;
        this.diagnostics.mark(trace, DiagnosticStage.SYNC_STATE, DiagnosticResult.PENDING,
          { state: syncDiagnosticState(next.state), errorDomain: DiagnosticErrorDomain.SYNC, code: next.error });
        for (const listener of Array.from(this.listeners)) {
          this.notify(listener);
        }
      };
      this.attached = true;
      this.client.onProgress(this.callback);
      return true;
    } catch (error) {
      syncFailure(this.diagnostics, trace, DiagnosticStage.SYNC_STATE, error as Object);
      this.detach();
      return false;
    }
  }

  private notify(listener: CloudBackupSyncListener): void {
    try {
      listener(this.getSnapshot());
    } catch (_) {
      // 一个页面回调失败不影响其他订阅者或 SDK start 的接受结果。
    }
  }

  private detachIfIdle(): void {
    if (!this.startPending && this.listeners.size === 0) {
      this.detach();
    }
  }

  private detach(): void {
    this.attached = false;
    this.callbackGeneration++;
    if (this.subscriptionContext !== undefined) {
      if (this.ownsSubscriptionContext) {
        this.diagnostics.end(this.subscriptionContext);
      }
      this.subscriptionContext = undefined;
      this.ownsSubscriptionContext = false;
    }
    if (this.client !== undefined && this.callback !== undefined) {
      try {
        this.client.offProgress(this.callback);
        this.callback = undefined;
      } catch (_) {
        // 保留回调以便显式再订阅时重试注销；迟到回调由 generation 隔离。
      }
    }
  }
}

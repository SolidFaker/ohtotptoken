import { cloudSync, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticErrorDomain, DiagnosticKind, DiagnosticReason,
  DiagnosticResult, DiagnosticStage, DiagnosticState,
} from './CloudBackupDiagnostics';

export enum CloudCacheState {
  RUNNING = 0,
  COMPLETED = 1,
  FAILED = 2,
  STOPPED = 3,
}

export interface CloudCacheProgress {
  uri: string;
  state: CloudCacheState;
  error: number;
}

export type CloudCacheListener = (progress: CloudCacheProgress) => void;

export interface CloudCacheClient {
  onProgress(listener: CloudCacheListener): void;
  offProgress(): void;
  start(uri: string): Promise<void>;
  stop(uri: string): Promise<void>;
}

export interface CloudCacheFactory {
  create(): CloudCacheClient;
  toUri(filePath: string): string;
}

export interface CloudCacheTimer {
  schedule(callback: () => void, milliseconds: number): number;
  cancel(id: number): void;
}

/** 可选方法保持旧 fake/调用方兼容；生产共享 loader 提供真实清理屏障。 */
export interface CloudFileCacher {
  cache(filePath: string, context?: DiagnosticContext): Promise<void>;
  prepareForDelete?(filePath: string, context?: DiagnosticContext): Promise<boolean>;
  retryCleanup?(): Promise<boolean>;
  isCleanupPending?(): boolean;
}

/** 预缓存不是普通读取的许可条件；只有真实在途或未确认取消才阻止后续 I/O。 */
export async function prepareCloudFileRead(cacher: CloudFileCacher | undefined, filePath: string,
  location: number, context?: DiagnosticContext): Promise<boolean> {
  let cacheFailed = false;
  try {
    if (cacher?.isCleanupPending?.()) return false;
    if (location === 2 && cacher !== undefined) {
      try {
        await cacher.cache(filePath, context);
      } catch (_) {
        cacheFailed = true;
        if (context !== undefined) {
          CloudBackupDiagnostics.mark(context, DiagnosticStage.CACHE_END, DiagnosticResult.FAIL,
            { reason: DiagnosticReason.UNKNOWN });
        }
      }
    }
    const pending = cacher?.isCleanupPending?.();
    if (pending === true || (cacheFailed && pending !== false)) {
      if (context !== undefined) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.CACHE_DRAIN, DiagnosticResult.BLOCKED,
          { reason: DiagnosticReason.INFLIGHT_UNCONFIRMED, drained: false });
      }
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

class NativeCloudCacheClient implements CloudCacheClient {
  private client: cloudSync.CloudFileCache = new cloudSync.CloudFileCache();
  private callback: ((progress: cloudSync.DownloadProgress) => void) | undefined = undefined;

  onProgress(listener: CloudCacheListener): void {
    this.callback = (progress: cloudSync.DownloadProgress): void => {
      listener({ uri: progress.uri, state: progress.state as number as CloudCacheState, error: progress.error });
    };
    this.client.on('progress', this.callback);
  }

  offProgress(): void {
    if (this.callback !== undefined) {
      this.client.off('progress', this.callback);
      this.callback = undefined;
    }
  }

  start(uri: string): Promise<void> {
    return this.client.start(uri);
  }

  stop(uri: string): Promise<void> {
    return this.client.stop(uri);
  }
}

class NativeCloudCacheFactory implements CloudCacheFactory {
  create(): CloudCacheClient {
    return new NativeCloudCacheClient();
  }

  toUri(filePath: string): string {
    return fileUri.getUriFromPath(filePath);
  }
}

class SystemCloudCacheTimer implements CloudCacheTimer {
  schedule(callback: () => void, milliseconds: number): number {
    return setTimeout(callback, milliseconds);
  }

  cancel(id: number): void {
    clearTimeout(id);
  }
}

function cacheFailure(context: DiagnosticContext, stage: DiagnosticStage, error: Object): void {
  let code: number = -1;
  try {
    code = (error as BusinessError).code;
  } catch (_) {
    // 不转换原生异常；SDK 数值仍须由诊断 facade 按域白名单验证。
  }
  CloudBackupDiagnostics.mark(context, stage, DiagnosticResult.FAIL,
    { errorDomain: DiagnosticErrorDomain.CACHE, code: code });
}

function cacheDiagnosticState(state: CloudCacheState): DiagnosticState {
  switch (state) {
    case CloudCacheState.RUNNING: return DiagnosticState.RUNNING;
    case CloudCacheState.COMPLETED: return DiagnosticState.COMPLETED;
    case CloudCacheState.FAILED: return DiagnosticState.FAILED;
    case CloudCacheState.STOPPED: return DiagnosticState.STOPPED;
    default: return DiagnosticState.UNKNOWN;
  }
}

enum CloudCacheFailure { FAILED, START_FAILED, TIMEOUT, CANCELLED }

function cacheError(failure: CloudCacheFailure): Error {
  switch (failure) {
    case CloudCacheFailure.START_FAILED: return new Error('CLOUD_CACHE_START_FAILED');
    case CloudCacheFailure.TIMEOUT: return new Error('CLOUD_CACHE_TIMEOUT');
    case CloudCacheFailure.CANCELLED: return new Error('CLOUD_CACHE_CANCELLED');
    default: return new Error('CLOUD_CACHE_FAILED');
  }
}

/** 结果与真实 I/O 结束分离；失败后保留同一 client、URI、订阅和在途 stop。 */
class CloudCacheOperation {
  readonly result: Promise<void>;
  readonly drained: Promise<void>;
  private resolveResult: () => void = (): void => {};
  private rejectResult: (error: Error) => void = (_error: Error): void => {};
  private resolveDrain: () => void = (): void => {};
  private resultSettled: boolean = false;
  private safe: boolean = false;
  private startInvoked: boolean = false;
  private startSettled: boolean = false;
  private accepted: boolean = false;
  private completed: boolean = false;
  private terminal: boolean = false;
  private cancelRequested: boolean = false;
  private stopAttempted: boolean = false;
  private stopPending: boolean = false;
  private subscribed: boolean = false;
  private timerId: number = -1;
  private mismatchReported: boolean = false;
  private lastState: DiagnosticState | undefined = undefined;
  private cleanupWaiters: Set<(safe: boolean) => void> = new Set();
  private cancellationReported: boolean = false;

  private client: CloudCacheClient;
  private uri: string;
  private timer: CloudCacheTimer;
  private timeoutMs: number;
  private cleanupTimeoutMs: number;
  private context: DiagnosticContext;
  private ownsContext: boolean;
  private onCancellation: () => void;

  constructor(client: CloudCacheClient, uri: string, timer: CloudCacheTimer,
    timeoutMs: number, cleanupTimeoutMs: number, context: DiagnosticContext,
    ownsContext: boolean, onCancellation: () => void = (): void => {}) {
    this.client = client;
    this.uri = uri;
    this.timer = timer;
    this.timeoutMs = timeoutMs;
    this.cleanupTimeoutMs = cleanupTimeoutMs;
    this.context = context;
    this.ownsContext = ownsContext;
    this.onCancellation = onCancellation;
    this.result = new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      this.resolveResult = resolve;
      this.rejectResult = reject;
    });
    this.drained = new Promise<void>((resolve: () => void) => { this.resolveDrain = resolve; });
  }

  start(): void {
    try {
      this.timerId = this.timer.schedule(() => {
        this.cancelRequested = true;
        this.finishFailure(CloudCacheFailure.TIMEOUT, DiagnosticReason.TIMEOUT);
        this.stopIfNeeded(false);
      }, this.timeoutMs);
      this.subscribed = true;
      this.client.onProgress((progress: CloudCacheProgress): void => { this.onProgress(progress); });
      this.startInvoked = true;
      this.client.start(this.uri).then(() => {
        this.startSettled = true;
        this.accepted = true;
        CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_START, DiagnosticResult.OK);
        this.afterStart();
      }, (error: Object) => {
        this.startSettled = true;
        cacheFailure(this.context, DiagnosticStage.CACHE_START, error);
        this.cancelRequested = true;
        this.finishFailure(CloudCacheFailure.START_FAILED);
        // IPC 拒绝不等于底层绝未启动；保留真实句柄直到 stop/终态确认。
        this.afterStart();
      });
    } catch (error) {
      this.startSettled = true;
      cacheFailure(this.context, DiagnosticStage.CACHE_START, error as Object);
      this.cancelRequested = true;
      this.finishFailure(CloudCacheFailure.START_FAILED);
      if (!this.startInvoked) {
        this.markDrained();
      } else {
        this.afterStart();
      }
    }
  }

  isDrained(): boolean {
    return this.safe;
  }

  isCleanupPending(): boolean {
    return !this.safe && (this.cancelRequested || this.resultSettled);
  }

  /** 每次显式调用最多发起一次 stop；已有在途 stop 只等待，不重复发送。 */
  cancelAndDrain(): Promise<boolean> {
    if (this.safe) {
      return Promise.resolve(true);
    }
    this.cancelRequested = true;
    this.finishFailure(CloudCacheFailure.CANCELLED, DiagnosticReason.CANCELLED);
    return new Promise<boolean>((resolve: (safe: boolean) => void) => {
      let settled = false;
      let timerId = -1;
      const finish = (safe: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.cleanupWaiters.delete(finish);
        if (timerId >= 0) {
          try { this.timer.cancel(timerId); } catch (_) {}
        }
        resolve(safe);
      };
      this.cleanupWaiters.add(finish);
      try {
        timerId = this.timer.schedule(() => { finish(this.safe); }, this.cleanupTimeoutMs);
      } catch (_) {
        finish(false);
      }
      this.stopIfNeeded(true);
      if (this.safe) {
        finish(true);
      }
    });
  }

  private afterStart(): void {
    if (this.terminal && !this.stopPending) {
      if (this.accepted && this.completed && !this.cancelRequested) {
        this.finishSuccess();
      }
      this.markDrained();
    } else if (this.cancelRequested) {
      this.stopIfNeeded(false);
    }
  }

  private onProgress(progress: CloudCacheProgress): void {
    // on() 期间产生的初始事件不属于尚未调用的 start。
    if (this.safe || !this.startInvoked) {
      return;
    }
    if (progress.uri !== this.uri) {
      if (!this.mismatchReported) {
        this.mismatchReported = true;
        CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_PROGRESS, DiagnosticResult.PENDING,
          { uriMatches: false, reason: DiagnosticReason.URI_MISMATCH });
      }
      return;
    }
    const state = cacheDiagnosticState(progress.state);
    if (state !== this.lastState) {
      this.lastState = state;
      CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_PROGRESS,
        progress.error === 0 ? DiagnosticResult.PENDING : DiagnosticResult.FAIL,
        { uriMatches: true, state: state, errorDomain: DiagnosticErrorDomain.CACHE, code: progress.error });
    }
    const terminal = progress.state === CloudCacheState.COMPLETED || progress.state === CloudCacheState.FAILED ||
      progress.state === CloudCacheState.STOPPED;
    if (terminal) {
      this.terminal = true;
    }
    if (progress.error !== 0 || progress.state === CloudCacheState.FAILED || progress.state === CloudCacheState.STOPPED) {
      this.cancelRequested = true;
      this.finishFailure(CloudCacheFailure.FAILED);
      if (this.startSettled) {
        this.afterStart();
      }
    } else if (progress.state === CloudCacheState.COMPLETED) {
      this.completed = true;
      if (this.startSettled) {
        this.afterStart();
      }
    }
  }

  private stopIfNeeded(explicitRetry: boolean): void {
    if (this.safe || !this.startSettled || this.stopPending) {
      return;
    }
    if (this.terminal) {
      this.markDrained();
      return;
    }
    if (this.stopAttempted && !explicitRetry) {
      return;
    }
    this.stopAttempted = true;
    this.stopPending = true;
    CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_STOP, DiagnosticResult.BEGIN);
    try {
      this.client.stop(this.uri).then(() => {
        this.stopPending = false;
        CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_STOP, DiagnosticResult.OK);
        this.markDrained();
      }, (error: Object) => { this.stopFailed(error); });
    } catch (error) {
      this.stopFailed(error as Object);
    }
  }

  private stopFailed(error: Object): void {
    this.stopPending = false;
    cacheFailure(this.context, DiagnosticStage.CACHE_STOP, error);
    if (this.terminal) {
      this.markDrained();
    } else {
      CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_DRAIN, DiagnosticResult.BLOCKED,
        { drained: false, reason: DiagnosticReason.INFLIGHT_UNCONFIRMED });
      this.notifyCleanup(false);
    }
  }

  private clearTimer(): void {
    if (this.timerId >= 0) {
      try { this.timer.cancel(this.timerId); } catch (_) {}
      this.timerId = -1;
    }
  }

  private finishSuccess(): void {
    if (!this.resultSettled) {
      this.resultSettled = true;
      this.clearTimer();
      CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_END, DiagnosticResult.OK);
      this.resolveResult();
    }
  }

  private finishFailure(failure: CloudCacheFailure, reason: DiagnosticReason = DiagnosticReason.UNKNOWN): void {
    if (this.cancelRequested && !this.cancellationReported &&
      (!this.terminal || !this.startSettled)) {
      this.cancellationReported = true;
      this.onCancellation();
    }
    if (!this.resultSettled) {
      this.resultSettled = true;
      this.clearTimer();
      CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_END, DiagnosticResult.FAIL, { reason: reason });
      this.rejectResult(cacheError(failure));
    }
  }

  private markDrained(): void {
    if (this.safe || this.stopPending || !this.startSettled) {
      return;
    }
    this.safe = true;
    this.clearTimer();
    if (this.subscribed) {
      try {
        this.client.offProgress();
      } catch (error) {
        cacheFailure(this.context, DiagnosticStage.CACHE_DRAIN, error as Object);
      }
      this.subscribed = false;
    }
    CloudBackupDiagnostics.mark(this.context, DiagnosticStage.CACHE_DRAIN, DiagnosticResult.OK, { drained: true });
    if (this.ownsContext) {
      CloudBackupDiagnostics.end(this.context);
    }
    this.resolveDrain();
    this.notifyCleanup(true);
  }

  private notifyCleanup(safe: boolean): void {
    for (const finish of Array.from(this.cleanupWaiters)) {
      finish(safe);
    }
  }
}

export function waitForCloudFileCache(client: CloudCacheClient, uri: string,
  timer: CloudCacheTimer, timeoutMs: number, context?: DiagnosticContext): Promise<void> {
  const trace = context === undefined ? CloudBackupDiagnostics.begin(DiagnosticKind.CACHE) : context;
  const operation = new CloudCacheOperation(client, uri, timer, timeoutMs, timeoutMs, trace, context === undefined);
  operation.start();
  return operation.result;
}

class CloudCacheRequest {
  readonly result: Promise<void>;
  cancelled: boolean = false;
  private settled: boolean = false;
  private resolve: () => void = (): void => {};
  private reject: (error: Error) => void = (_error: Error): void => {};

  constructor() {
    this.result = new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }

  finish(error?: Error): void {
    if (!this.settled) {
      this.settled = true;
      if (error === undefined) {
        this.resolve();
      } else {
        this.reject(error);
      }
    }
  }
}

/** 令牌/图标共用串行内容缓存；高层业务冲突由 operation gate 立即拒绝。 */
export class CloudFileCacheLoader implements CloudFileCacher {
  private static instance: CloudFileCacheLoader | null = null;
  private queue: Promise<void> = Promise.resolve();
  private pending: Map<string, CloudCacheRequest> = new Map();
  private active: CloudCacheOperation | undefined = undefined;
  private activePath: string = '';

  private factory: CloudCacheFactory;
  private timer: CloudCacheTimer;
  private timeoutMs: number;
  private cleanupTimeoutMs: number;

  constructor(factory: CloudCacheFactory = new NativeCloudCacheFactory(),
    timer: CloudCacheTimer = new SystemCloudCacheTimer(), timeoutMs: number = 60000,
    cleanupTimeoutMs: number = 5000) {
    this.factory = factory;
    this.timer = timer;
    this.timeoutMs = timeoutMs;
    this.cleanupTimeoutMs = cleanupTimeoutMs;
  }

  static getInstance(): CloudFileCacheLoader {
    if (CloudFileCacheLoader.instance === null) {
      CloudFileCacheLoader.instance = new CloudFileCacheLoader();
    }
    return CloudFileCacheLoader.instance;
  }

  cache(filePath: string, context?: DiagnosticContext): Promise<void> {
    if (this.active !== undefined && this.active.isCleanupPending()) {
      return Promise.reject(new Error('CLOUD_CACHE_CLEANUP_PENDING'));
    }
    const existing = this.pending.get(filePath);
    if (existing !== undefined) {
      return existing.result;
    }
    const request = new CloudCacheRequest();
    this.pending.set(filePath, request);
    const task = this.queue.then(async (): Promise<void> => {
      const trace = context === undefined ? CloudBackupDiagnostics.begin(DiagnosticKind.CACHE) : context;
      let operation: CloudCacheOperation | undefined = undefined;
      try {
        if (request.cancelled) {
          request.finish(new Error('CLOUD_CACHE_CANCELLED'));
          return;
        }
        if (this.active !== undefined && !this.active.isDrained()) {
          CloudBackupDiagnostics.mark(trace, DiagnosticStage.CACHE_ADMIT, DiagnosticResult.BLOCKED,
            { reason: DiagnosticReason.INFLIGHT_UNCONFIRMED });
          request.finish(new Error('CLOUD_CACHE_CLEANUP_PENDING'));
          return;
        }
        CloudBackupDiagnostics.mark(trace, DiagnosticStage.CACHE_ADMIT, DiagnosticResult.OK);
        const uri = this.factory.toUri(filePath);
        operation = new CloudCacheOperation(this.factory.create(), uri, this.timer, this.timeoutMs,
          this.cleanupTimeoutMs, trace, context === undefined, (): void => { this.cancelQueuedRequests(request); });
        const ownedOperation = operation;
        this.active = ownedOperation;
        this.activePath = filePath;
        ownedOperation.drained.then(() => {
          // 旧回调只解除自己的记录，不能覆盖新任务的真实句柄。
          if (this.active === ownedOperation) {
            this.active = undefined;
            this.activePath = '';
          }
        });
        ownedOperation.start();
        try {
          await ownedOperation.result;
          request.finish();
        } catch (error) {
          // operation.result 仅包含本模块固定错误常量。
          request.finish(error as Error);
        }
      } catch (error) {
        cacheFailure(trace, DiagnosticStage.CACHE_START, error as Object);
        request.finish(new Error('CLOUD_CACHE_START_FAILED'));
      } finally {
        if (this.pending.get(filePath) === request) {
          this.pending.delete(filePath);
        }
        if (operation === undefined && context === undefined) {
          CloudBackupDiagnostics.end(trace);
        }
      }
    });
    // 队列只串行已接纳的内容请求；失败不自动补发，未确认 I/O 的后续请求直接失败。
    this.queue = task.then(() => {}, () => {});
    return request.result;
  }

  private cancelQueuedRequests(activeRequest?: CloudCacheRequest): void {
    for (const request of Array.from(this.pending.values())) {
      if (request !== activeRequest) {
        request.cancelled = true;
        request.finish(new Error('CLOUD_CACHE_CANCELLED'));
      }
    }
  }

  isCleanupPending(): boolean {
    if (this.active !== undefined && !this.active.isDrained()) {
      return true;
    }
    for (const request of Array.from(this.pending.values())) {
      if (!request.cancelled) {
        return true;
      }
    }
    return false;
  }

  /** 无任务时立即通过；取消目标排队请求/已有下载，绝不创建下载来删除文件。 */
  async prepareForDelete(filePath: string, _context?: DiagnosticContext): Promise<boolean> {
    const request = this.pending.get(filePath);
    if (request !== undefined) {
      request.cancelled = true;
      request.finish(new Error('CLOUD_CACHE_CANCELLED'));
    }
    const operation = this.active;
    if (operation === undefined || operation.isDrained()) {
      return !this.isCleanupPending();
    }
    if (this.activePath !== filePath) {
      return false;
    }
    return operation.cancelAndDrain();
  }

  /** 由仍持有 gate 许可的原操作显式调用；不重入 gate、不建立新 native client。 */
  retryCleanup(): Promise<boolean> {
    const operation = this.active;
    if (operation === undefined || operation.isDrained()) {
      // retry 只能排空已有工作；尚未启动的请求也不能在 retry 返回后偷偷下载。
      this.cancelQueuedRequests();
      return Promise.resolve(true);
    }
    return operation.cancelAndDrain();
  }
}

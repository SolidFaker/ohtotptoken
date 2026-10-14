import { PreparedLocalBackup, TokenBatchProgressCallback } from 'common';
import { TokenBatchDialogHost, TokenBatchOperation, TokenBatchPermit } from './TokenBatchOperation';

interface LocalBackupMenuError {
  code?: number | string;
  message?: string;
}

/** 原生操作菜单取消为无 code 的固定 cancel；未知错误不可伪装成取消。 */
export function isLocalBackupMenuCancellation(error: Object | undefined | null): boolean {
  try {
    if (error === undefined || error === null) { return false; }
    const candidate = error as LocalBackupMenuError;
    return candidate.code === undefined && candidate.message === 'cancel';
  } catch (_) { return false; }
}

export enum LocalBackupStage {
  IDLE = 'idle',
  CHOOSING = 'choosing',
  PICKING = 'picking',
  PASSWORD = 'password',
  PREPARING = 'preparing',
  CONFIRMING = 'confirming',
  EXECUTING = 'executing',
  RESULT = 'result'
}

/** 页面作用域；仅阶段可观察，不把密钥、文件引用或快照放入 AppStorage。 */
@ObservedV2
export class LocalBackupFlow {
  @Trace stage: LocalBackupStage = LocalBackupStage.IDLE;
  private generation: number = 0;
  private mounted: boolean = true;
  private cancelled: boolean = false;
  private pending: number = 0;
  private permit: TokenBatchPermit | undefined;
  private prepared: PreparedLocalBackup | undefined;
  private changed: (executing: boolean) => void;

  constructor(changed: (executing: boolean) => void = () => {}) { this.changed = changed; }

  isBusy(): boolean { return this.permit !== undefined; }
  isExecuting(): boolean { return this.stage === LocalBackupStage.EXECUTING; }

  activate(): void { this.mounted = true; }

  begin(stage: LocalBackupStage = LocalBackupStage.CHOOSING): number | undefined {
    if (!this.mounted || this.permit !== undefined) { return undefined; }
    const permit = TokenBatchOperation.acquire(this);
    if (permit === undefined) { return undefined; }
    this.permit = permit;
    this.cancelled = false;
    this.generation++;
    this.setStage(stage);
    return this.generation;
  }

  isCurrent(generation: number): boolean {
    return this.mounted && !this.cancelled && this.generation === generation && this.permit !== undefined &&
      TokenBatchOperation.owns(this, this.permit);
  }

  transition(generation: number, stage: LocalBackupStage): boolean {
    if (!this.isCurrent(generation) || this.pending > 0) { return false; }
    this.setStage(stage);
    return true;
  }

  private setStage(stage: LocalBackupStage): void {
    this.stage = stage;
    this.changed(this.isExecuting());
  }

  remember(generation: number, prepared: PreparedLocalBackup): boolean {
    if (!this.isCurrent(generation)) { prepared.dispose(); return false; }
    this.prepared?.dispose();
    this.prepared = prepared;
    return true;
  }

  snapshot(generation: number): PreparedLocalBackup | undefined {
    return this.isCurrent(generation) ? this.prepared : undefined;
  }

  cancel(): boolean {
    if (this.isExecuting()) { return false; }
    this.cancelled = true;
    this.prepared?.dispose();
    this.prepared = undefined;
    if (this.pending === 0) { this.release(); }
    return true;
  }

  invalidate(): void {
    this.mounted = false;
    this.cancelled = true;
    this.prepared?.dispose();
    this.prepared = undefined;
    if (this.pending === 0) { this.release(); }
  }

  finish(generation: number): void {
    if (generation !== this.generation) { return; }
    this.cancelled = true;
    if (this.pending === 0) { this.release(); }
  }

  private release(): void {
    this.prepared?.dispose();
    this.prepared = undefined;
    if (this.permit !== undefined) { TokenBatchOperation.release(this, this.permit); }
    this.permit = undefined;
    this.setStage(LocalBackupStage.IDLE);
  }

  /** 测试和密码框的内联进度共用此入口；已启动的 Promise 结束前不释放许可。 */
  async work<T>(generation: number, executing: boolean, operation: () => Promise<T>): Promise<T | undefined> {
    const permit = this.permit;
    if (permit === undefined || !this.isCurrent(generation) || this.pending > 0) { return undefined; }
    this.setStage(executing ? LocalBackupStage.EXECUTING : LocalBackupStage.PREPARING);
    this.pending++;
    try {
      const result = await TokenBatchOperation.hold(this, permit, operation);
      return this.isCurrent(generation) ? result : undefined;
    } finally {
      this.pending--;
      if (this.cancelled || !this.mounted) { this.release(); }
    }
  }

  async progress(host: TokenBatchDialogHost, title: ResourceStr, generation: number, executing: boolean,
    operation: (report: TokenBatchProgressCallback) => Promise<void>): Promise<void> {
    const permit = this.permit;
    if (permit === undefined || !this.isCurrent(generation) || this.pending > 0) { return; }
    this.setStage(executing ? LocalBackupStage.EXECUTING : LocalBackupStage.PREPARING);
    this.pending++;
    try {
      await TokenBatchOperation.runWithPermit(host, title, this, permit, operation,
        () => this.isCurrent(generation), executing ? undefined : () => { this.cancel(); });
    } finally {
      this.pending--;
      if (this.cancelled || !this.mounted) { this.release(); }
    }
  }
}

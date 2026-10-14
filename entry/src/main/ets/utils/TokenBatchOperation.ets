import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TokenBatchProgress, TokenBatchProgressCallback, TokenBatchStage, dialogSystemMaterial } from 'common';
import { TokenProgressDialogParams } from '../dialogs/TokenProgressDialog';

/** 由真实 UI 组件实现；不能在普通工具类中直接调用全局 @Builder。 */
export interface TokenBatchDialogHost {
  getUIContext(): UIContext;
  buildTokenProgressDialog(params: TokenProgressDialogParams): void;
}

export class TokenBatchPermit {
  readonly owner: Object;
  running: boolean = false;
  constructor(owner: Object) { this.owner = owner; }
}

/** 许可覆盖用户确认阶段，进度层只覆盖实际处理阶段。 */
export class TokenBatchOperation {
  private static active: TokenBatchPermit | undefined;

  static isBusy(): boolean { return TokenBatchOperation.active !== undefined; }

  static acquire(owner: Object): TokenBatchPermit | undefined {
    if (TokenBatchOperation.isBusy()) { return undefined; }
    const permit = new TokenBatchPermit(owner);
    TokenBatchOperation.active = permit;
    return permit;
  }

  static owns(owner: Object, permit: TokenBatchPermit): boolean {
    return TokenBatchOperation.active === permit && permit.owner === owner;
  }

  static release(owner: Object, permit: TokenBatchPermit): boolean {
    if (!TokenBatchOperation.owns(owner, permit) || permit.running) { return false; }
    TokenBatchOperation.active = undefined;
    return true;
  }

  static async hold<T>(owner: Object, permit: TokenBatchPermit, operation: () => Promise<T>): Promise<T> {
    if (!TokenBatchOperation.owns(owner, permit) || permit.running) {
      throw new Error('Invalid token operation permit');
    }
    permit.running = true;
    try { return await operation(); } finally { permit.running = false; }
  }

  static async run(host: TokenBatchDialogHost, title: ResourceStr,
    operation: (report: TokenBatchProgressCallback) => Promise<void>): Promise<void> {
    const permit = TokenBatchOperation.acquire(host);
    if (permit === undefined) { throw new Error('A token operation is already running'); }
    try {
      await TokenBatchOperation.runWithPermit(host, title, host, permit, operation);
    } finally {
      TokenBatchOperation.release(host, permit);
    }
  }

  static async runWithPermit(host: TokenBatchDialogHost, title: ResourceStr, owner: Object, permit: TokenBatchPermit,
    operation: (report: TokenBatchProgressCallback) => Promise<void>, canContinue: () => boolean = () => true,
    cancel?: () => void): Promise<void> {
    await TokenBatchOperation.hold(owner, permit, async () => {
      await TokenBatchOperation.showProgress(host, title, operation, canContinue, cancel);
    });
  }

  private static async showProgress(host: TokenBatchDialogHost, title: ResourceStr,
    operation: (report: TokenBatchProgressCallback) => Promise<void>, canContinue: () => boolean,
    cancel?: () => void): Promise<void> {
    const context = host.getUIContext();
    let dialogId: number | undefined = undefined;
    let running = true;
    const start = Date.now();
    try {
      const initial: TokenBatchProgress = { stage: TokenBatchStage.PREPARING, completed: 0, total: 0 };
      const params = new TokenProgressDialogParams(title, initial);
      const prompt = context.getPromptAction();
      dialogId = await prompt.openCustomDialog({
        systemMaterial: dialogSystemMaterial(),
        builder: () => host.buildTokenProgressDialog(params),
        autoCancel: false,
        alignment: DialogAlignment.Center,
        onWillDismiss: (action: DismissDialogAction) => {
          if (!running) {
            action.dismiss();
          } else if (cancel !== undefined) {
            cancel();
            action.dismiss();
          }
        }
      });
      let lastUpdate = 0;
      let lastStage = TokenBatchStage.PREPARING;
      let stageStart = Date.now();
      const report = (progress: TokenBatchProgress): void => {
        if (!running) {
          return;
        }
        const now = Date.now();
        const changedStage = progress.stage !== lastStage;
        if (changedStage) {
          hilog.info(0xFF00, 'TokenBatchUI', `stage=${lastStage} elapsedMs=${now - stageStart}`);
          stageStart = now;
          lastStage = progress.stage;
        }
        // 每个阶段首尾必达；中间最多约12帧/秒，避免每个 ASSET 回调都重绘 Dialog。
        if (changedStage || progress.completed === 0 || progress.completed === progress.total || now - lastUpdate >= 80) {
          params.progress = progress;
          lastUpdate = now;
        }
      };
      if (canContinue()) { await operation(report); }
      hilog.info(0xFF00, 'TokenBatchUI', `operation finished totalMs=${Date.now() - start}`);
    } finally {
      running = false;
      try {
        if (dialogId !== undefined) {
          context.getPromptAction().closeCustomDialog(dialogId);
        }
      } catch (_) {
        // 例如宿主已销毁；不把关闭弹窗失败误报成数据写入失败。
        hilog.warn(0xFF00, 'TokenBatchUI', 'Could not close progress dialog');
      }
    }
  }
}

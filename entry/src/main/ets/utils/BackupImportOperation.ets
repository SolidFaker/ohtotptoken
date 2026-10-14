import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TokenConfig, TokenGroup, TokenGroupStore, PreparedLocalBackup, TokenBatchProgressCallback,
  restoreFromBackup, showSnackBar, SnackBarNotifyType
} from 'common';
import { TokenBatchDialogHost, TokenBatchOperation } from './TokenBatchOperation';

export type TokenImportHandler = (tokens: TokenConfig[], report?: TokenBatchProgressCallback) => Promise<void>;

export interface LocalBackupGroupMerger {
  merge(groups: TokenGroup[]): Promise<void>;
}

export class LocalBackupCommitError extends Error {
  readonly groupsCompleted: boolean;
  constructor(groupsCompleted: boolean) {
    super('Local backup import incomplete');
    this.groupsCompleted = groupsCompleted;
  }
}

/** 必须由已确认且持有批量许可的会话调用；分组和令牌不构成跨存储事务。 */
export async function commitPreparedBackup(prepared: PreparedLocalBackup, onImport: TokenImportHandler,
  report: TokenBatchProgressCallback, groups: LocalBackupGroupMerger = TokenGroupStore.getInstance()): Promise<number> {
  const snapshot = prepared.takeForCommit();
  let groupsCompleted = false;
  try {
    await groups.merge(snapshot.groups);
    groupsCompleted = true;
    await onImport(snapshot.configs, report);
    return snapshot.configs.length;
  } catch (_) {
    throw new LocalBackupCommitError(groupsCompleted);
  }
}

/** 文件读取/解密与数据库写入共用一个 Dialog，不能到解密结束后才显示 Loading。 */
export async function importBackupWithProgress(host: TokenBatchDialogHost, uri: string, encrypted: boolean,
  password: string, onImport: TokenImportHandler): Promise<boolean> {
  if (TokenBatchOperation.isBusy()) {
    return false;
  }
  let count = 0;
  try {
    await TokenBatchOperation.run(host, $r('app.string.token_batch_import_title'), async (report) => {
      const backup = await restoreFromBackup(uri, encrypted, password, report);
      count = backup.configs.length;
      await onImport(backup.configs, report);
    });
    showSnackBar($r('app.string.toast_multi_token_update', count), SnackBarNotifyType.SUCCESS);
    return true;
  } catch (_) {
    hilog.error(0xFF00, 'TokenBatchUI', 'Backup import failed');
    showSnackBar($r('app.string.token_batch_import_failed'), SnackBarNotifyType.ERROR);
    return false;
  }
}

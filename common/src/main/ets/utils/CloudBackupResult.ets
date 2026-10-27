import { CloudBackupRecord } from './CloudBackupCrypto';

export enum CloudBackupFailureReason {
  NONE = 'NONE',
  NOT_READY = 'NOT_READY',
  NOT_SIGNED_IN = 'NOT_SIGNED_IN',
  IDENTITY_UNAVAILABLE = 'IDENTITY_UNAVAILABLE',
  BUSY = 'BUSY',
  CLEANUP_PENDING = 'CLEANUP_PENDING',
  INVALID_TARGET = 'INVALID_TARGET',
  READ_FAILED = 'READ_FAILED',
  WRITE_FAILED = 'WRITE_FAILED',
  FORMAT_INVALID = 'FORMAT_INVALID',
  DECRYPT_FAILED = 'DECRYPT_FAILED',
  DELETE_FAILED = 'DELETE_FAILED',
  ICON_FAILED = 'ICON_FAILED',
  SYNC_FAILED = 'SYNC_FAILED',
  /** 发布后一致性校验未通过：正式文件重读解析或数量/设备标识比对失败 */
  POST_VERIFY_FAILED = 'POST_VERIFY_FAILED',
  UNKNOWN = 'UNKNOWN',
}

export class CloudBackupActionResult {
  success: boolean = false;
  reason: CloudBackupFailureReason = CloudBackupFailureReason.NONE;
  partialFailure: boolean = false;
  localComplete: boolean = false;
  syncStartAccepted: boolean = false;
  /** 清理操作本地删除成功的文件数（非清理操作恒为 0） */
  deletedCount: number = 0;
  /** 清理操作因归属无法确认而跳过并保留的记录数 */
  skippedUnowned: number = 0;
  /** 恢复操作实际合并写入的令牌数（非恢复操作恒为 0） */
  restoredCount: number = 0;
}

export function cloudBackupFailure(reason: CloudBackupFailureReason): CloudBackupActionResult {
  const result = new CloudBackupActionResult();
  result.reason = reason;
  return result;
}

export class CloudBackupHistoryResult {
  records: CloudBackupRecord[] = [];
  success: boolean = false;
  reason: CloudBackupFailureReason = CloudBackupFailureReason.NONE;
}

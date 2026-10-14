/**
 * SyncTimeHelper — 云同步时间戳辅助工具
 *
 * CLOUD_SYNC_LAST_TIME 存储格式统一为 unix 毫秒时间戳字符串（如 "1745385600000"），
 * UI 显示时通过 formatTimestamp() 转为可读格式（如 "2026-04-23 14:30"）。
 *
 * parseStoredTimestamp() 同时兼容旧版日期字符串格式（如 "2026-04-23 14:30"），
 * 首次读取时自动向上兼容。
 */
import { padZero } from './CommonUtils';
import { CloudBackupDiagnostics, DiagnosticKind, DiagnosticStage, DiagnosticResult, DiagnosticReason,
  DiagnosticErrorDomain } from './CloudBackupDiagnostics';

export class SyncTimeHelper {
  /** 将 unix 毫秒时间戳转为 "YYYY-MM-DD HH:mm" 格式字符串，ts <= 0 返回空串 */
  static formatTimestamp(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts);
    return `${d.getFullYear()}-${padZero(d.getMonth() + 1)}-${padZero(d.getDate())} ${padZero(d.getHours())}:${padZero(d.getMinutes())}`;
  }

  /** 判断时间戳是否为今天 */
  static isToday(ts: number): boolean {
    if (ts <= 0) {
      return false;
    }
    const d = new Date(ts);
    const today = new Date();
    return d.getFullYear() === today.getFullYear() &&
      d.getMonth() === today.getMonth() &&
      d.getDate() === today.getDate();
  }

  /** 获取昨天 23:59:59.999 的时间戳，用于清空备份后将 lastSyncTime 设为"已过期" */
  static getYesterdayEndTs(): number {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return today.getTime() - 1;
  }

  /** 判断时间戳距今是否在指定分钟数内 */
  static isWithinMinutes(ts: number, minutes: number): boolean {
    if (ts <= 0) {
      return false;
    }
    return (Date.now() - ts) < minutes * 60000;
  }

  /** 获取今天 00:00:00.000 的时间戳 */
  static getTodayStartTs(): number {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return today.getTime();
  }

  /**
   * 解析存储的时间值为 unix 毫秒时间戳。
   * 兼容两种格式：
   * - 新格式：纯数字字符串（如 "1745385600000"）
   * - 旧格式：日期字符串（如 "2026-04-23 14:30"）
   * 无法解析时返回 0。
   */
  static parseStoredTimestamp(value: string | number): number {
    if (typeof value === 'number') {
      return value as number;
    }
    if (!value || value.length === 0) {
      return 0;
    }
    const parsed = Number(value);
    if (!isNaN(parsed) && parsed > 0) {
      return parsed;
    }
    try {
      const parts = value.split(/[- :\s]/);
      if (parts.length >= 5) {
        const d = new Date(
          parseInt(parts[0]),
          parseInt(parts[1]) - 1,
          parseInt(parts[2]),
          parseInt(parts[3]),
          parseInt(parts[4])
        );
        return d.getTime();
      }
    } catch (_) {
      const diagnostic = CloudBackupDiagnostics.begin(DiagnosticKind.SYNC);
      CloudBackupDiagnostics.mark(diagnostic, DiagnosticStage.TIME_PARSE, DiagnosticResult.FAIL,
        { reason: DiagnosticReason.INVALID_FORMAT, errorDomain: DiagnosticErrorDomain.APP });
      CloudBackupDiagnostics.end(diagnostic);
    }
    return 0;
  }
}

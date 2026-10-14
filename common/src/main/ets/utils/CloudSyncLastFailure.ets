import { AppPreference, PREF_KEYS } from './AppPreference';
import { CloudBackupFailureReason } from './CloudBackupResult';

/**
 * 最近一次云备份失败的持久化状态（PREF_KEYS.CLOUD_SYNC_LAST_FAILURE）。
 *
 * 设计要点：
 * - 值为固定结构 JSON `{ failedAt, stage, reason }`，字段全部为枚举或时间戳，
 *   不落任何文件名、令牌数量、错误文本——与 cloud-backup-diagnostics 的隐私边界一致。
 * - 备份整体成功时清除；清除前跨进程重启持续可见（AppPreference 持久化天然保证）。
 * - 结构非法（第三方脏数据、版本变更）一律按"无记录"处理，不抛异常。
 */

/** 失败所处管线的固定阶段枚举；只表达位置，不携带文件名或数量。 */
export enum CloudSyncFailureStage {
  UNKNOWN = 'UNKNOWN',
  /** 设备身份读取失败 */
  DEVICE_INFO = 'DEVICE_INFO',
  /** 令牌/分组快照读取失败 */
  SNAPSHOT = 'SNAPSHOT',
  /** 备份加密失败 */
  ENCRYPT = 'ENCRYPT',
  /** 暂存写入/关闭失败 */
  WRITE = 'WRITE',
  /** 暂存产物回读校验失败 */
  STAGED_VERIFY = 'STAGED_VERIFY',
  /** 发布（移动到正式名）失败 */
  PUBLISH = 'PUBLISH',
  /** 发布后一致性校验未通过 */
  POST_PUBLISH_VERIFY = 'POST_PUBLISH_VERIFY',
  /** 轮换剪除/清理扫描阶段失败 */
  ROTATE = 'ROTATE',
  /** 图标包备份失败 */
  ICON = 'ICON',
  /** 同步提交失败 */
  SYNC = 'SYNC',
}

/** 持久化的失败记录；字段全部为枚举或时间戳。 */
export class CloudSyncLastFailure {
  failedAt: number = 0;
  stage: CloudSyncFailureStage = CloudSyncFailureStage.UNKNOWN;
  reason: CloudBackupFailureReason = CloudBackupFailureReason.UNKNOWN;
}

/** 详情页渲染分支的纯分类结果（LocalUnit 可测，不持有资源引用）。 */
export interface CloudSyncFailureView {
  stage: CloudSyncFailureStage;
  reason: CloudBackupFailureReason;
  /** 阶段枚举可映射为已知文案；false 时页面展示通用"未知阶段" */
  knownStage: boolean;
  /** 原因枚举可映射为已知文案；false 时页面展示通用失败文案 */
  knownReason: boolean;
}

const STAGES: CloudSyncFailureStage[] = [
  CloudSyncFailureStage.UNKNOWN, CloudSyncFailureStage.DEVICE_INFO, CloudSyncFailureStage.SNAPSHOT,
  CloudSyncFailureStage.ENCRYPT, CloudSyncFailureStage.WRITE, CloudSyncFailureStage.STAGED_VERIFY,
  CloudSyncFailureStage.PUBLISH, CloudSyncFailureStage.POST_PUBLISH_VERIFY, CloudSyncFailureStage.ROTATE,
  CloudSyncFailureStage.ICON, CloudSyncFailureStage.SYNC,
];

const REASONS: CloudBackupFailureReason[] = [
  CloudBackupFailureReason.NONE, CloudBackupFailureReason.NOT_READY, CloudBackupFailureReason.NOT_SIGNED_IN,
  CloudBackupFailureReason.IDENTITY_UNAVAILABLE, CloudBackupFailureReason.BUSY, CloudBackupFailureReason.CLEANUP_PENDING,
  CloudBackupFailureReason.INVALID_TARGET, CloudBackupFailureReason.READ_FAILED, CloudBackupFailureReason.WRITE_FAILED,
  CloudBackupFailureReason.FORMAT_INVALID, CloudBackupFailureReason.DECRYPT_FAILED, CloudBackupFailureReason.DELETE_FAILED,
  CloudBackupFailureReason.ICON_FAILED, CloudBackupFailureReason.SYNC_FAILED, CloudBackupFailureReason.POST_VERIFY_FAILED,
  CloudBackupFailureReason.UNKNOWN,
];

function isValidFailure(record: CloudSyncLastFailure): boolean {
  return record !== null && typeof record === 'object' && Number.isFinite(record.failedAt) && record.failedAt >= 0 &&
    STAGES.indexOf(record.stage) >= 0 && REASONS.indexOf(record.reason) >= 0;
}

/**
 * 记录 → 视图模型的纯映射：null 表示无失败记录（页面不渲染失败行）。
 * 枚举值超出白名单（脏数据）降级为"未知阶段/未知原因"的已知占位，不抛异常。
 */
export function cloudSyncFailureView(record: CloudSyncLastFailure | null): CloudSyncFailureView | null {
  if (record === null || !isValidFailure(record)) {
    return null;
  }
  const view: CloudSyncFailureView = {
    stage: record.stage, reason: record.reason,
    knownStage: record.stage !== CloudSyncFailureStage.UNKNOWN,
    knownReason: record.reason !== CloudBackupFailureReason.UNKNOWN,
  };
  return view;
}

/** CLOUD_SYNC_LAST_FAILURE 键的读写收口；业务层不直接拼装 JSON。 */
export class CloudSyncFailureState {
  /**
   * 记录最近一次备份失败；只写枚举字段。failedAt 为墙钟毫秒时间戳，
   * 仅用于排查定位（诊断/日志对照），当前 UI 不展示、不作任何时效判断。
   */
  static record(stage: CloudSyncFailureStage, reason: CloudBackupFailureReason): void {
    const entry = new CloudSyncLastFailure();
    entry.failedAt = Date.now();
    entry.stage = STAGES.indexOf(stage) >= 0 ? stage : CloudSyncFailureStage.UNKNOWN;
    entry.reason = REASONS.indexOf(reason) >= 0 ? reason : CloudBackupFailureReason.UNKNOWN;
    AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, JSON.stringify(entry));
  }

  /** 备份整体成功时清除失败状态；键值为空字符串即视为无记录。 */
  static clear(): void {
    AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, '');
  }

  /** 读回持久化记录；缺失或结构非法（含第三方脏数据）一律返回 null。 */
  static read(): CloudSyncLastFailure | null {
    const raw = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE) as string;
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as CloudSyncLastFailure;
      return isValidFailure(parsed) ? parsed : null;
    } catch (_) {
      return null;
    }
  }
}

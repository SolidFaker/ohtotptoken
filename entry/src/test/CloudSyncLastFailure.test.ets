import { describe, it, expect } from '@ohos/hypium';
import {
  AppPreference, CloudBackupFailureReason, CloudSyncFailureStage, CloudSyncFailureState,
  CloudSyncLastFailure, cloudSyncFailureView, PREF_KEYS,
} from 'common';

/**
 * CLOUD_SYNC_LAST_FAILURE 失败状态键（guard-against-zero-byte-orphan）：
 * - 写入/清除/回读（AppPreference 持久化键，重启可见性由同一存储保证）；
 * - 脏数据防御：非法 JSON / 缺字段 / 未知枚举一律降级为"无记录"或未知占位；
 * - 详情页渲染分支的纯分类器（失败可见 / 无记录不渲染 / 未知枚举兜底）。
 */
export default function cloudSyncLastFailureTest() {
  describe('cloudSyncLastFailureTest', () => {
    it('record_write_read_clear_roundtrip', 0, () => {
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, '');
      expect(CloudSyncFailureState.read()).assertNull();

      CloudSyncFailureState.record(CloudSyncFailureStage.POST_PUBLISH_VERIFY,
        CloudBackupFailureReason.POST_VERIFY_FAILED);
      const stored = CloudSyncFailureState.read();
      expect(stored !== null).assertTrue();
      if (stored === null) return;
      // LocalUnit 时钟为 stub：只断言时间戳数值合法，不做墙钟比对。
      expect(Number.isFinite(stored.failedAt) && stored.failedAt >= 0).assertTrue();
      expect(stored.stage).assertEqual(CloudSyncFailureStage.POST_PUBLISH_VERIFY);
      expect(stored.reason).assertEqual(CloudBackupFailureReason.POST_VERIFY_FAILED);

      // 备份整体成功清除后回到"无记录"。
      CloudSyncFailureState.clear();
      expect(CloudSyncFailureState.read()).assertNull();
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE)).assertEqual('');
    });

    it('read_survives_persisted_shape_and_rejects_dirty_data', 0, () => {
      // 模拟重启后从持久层读回：直接写键值再读（同一 AppPreference 存储形态）。
      const persisted = JSON.stringify({
        failedAt: 1234, stage: CloudSyncFailureStage.WRITE, reason: CloudBackupFailureReason.WRITE_FAILED,
      } as CloudSyncLastFailure);
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, persisted);
      const restored = CloudSyncFailureState.read();
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.stage).assertEqual(CloudSyncFailureStage.WRITE);
        expect(restored.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
        expect(restored.failedAt).assertEqual(1234);
      }

      for (const dirty of ['not-json', '{}', 'null',
        JSON.stringify({ failedAt: -1, stage: 'WRITE', reason: 'WRITE_FAILED' }),
        JSON.stringify({ failedAt: 1, stage: 'NOT_A_STAGE', reason: 'WRITE_FAILED' }),
        JSON.stringify({ failedAt: 1, stage: 'WRITE', reason: 'NOT_A_REASON' }),
        JSON.stringify({ stage: 'WRITE', reason: 'WRITE_FAILED' })]) {
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, dirty);
        expect(CloudSyncFailureState.read()).assertNull();
      }
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, '');
    });

    it('record_coerces_invalid_enum_input_to_unknown_placeholders', 0, () => {
      CloudSyncFailureState.record('NOT_A_STAGE' as CloudSyncFailureStage,
        'NOT_A_REASON' as CloudBackupFailureReason);
      const stored = CloudSyncFailureState.read();
      expect(stored !== null).assertTrue();
      if (stored !== null) {
        expect(stored.stage).assertEqual(CloudSyncFailureStage.UNKNOWN);
        expect(stored.reason).assertEqual(CloudBackupFailureReason.UNKNOWN);
      }
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, '');
    });

    it('view_classifier_maps_render_branches_for_detail_page', 0, () => {
      // 无记录 → 不渲染失败行
      expect(cloudSyncFailureView(null)).assertNull();

      // 已知阶段/原因 → 正常渲染分支
      const known = new CloudSyncLastFailure();
      known.failedAt = 100;
      known.stage = CloudSyncFailureStage.POST_PUBLISH_VERIFY;
      known.reason = CloudBackupFailureReason.POST_VERIFY_FAILED;
      const knownView = cloudSyncFailureView(known);
      expect(knownView !== null).assertTrue();
      if (knownView !== null) {
        expect(knownView.knownStage).assertTrue();
        expect(knownView.knownReason).assertTrue();
        expect(knownView.stage).assertEqual(CloudSyncFailureStage.POST_PUBLISH_VERIFY);
      }

      // 未知枚举（生产写入路径会把非法输入收敛为 UNKNOWN）→ 仍渲染，落"未知阶段/原因"兜底分支
      const unknown = new CloudSyncLastFailure();
      unknown.failedAt = 100;
      unknown.stage = CloudSyncFailureStage.UNKNOWN;
      unknown.reason = CloudBackupFailureReason.UNKNOWN;
      const unknownView = cloudSyncFailureView(unknown);
      expect(unknownView !== null).assertTrue();
      if (unknownView !== null) {
        expect(unknownView.knownStage).assertFalse();
        expect(unknownView.knownReason).assertFalse();
      }

      // 任意垃圾枚举串 / 非法时间戳 / 非对象 → 与无记录同等处理，不渲染
      const garbage = new CloudSyncLastFailure();
      garbage.failedAt = 100;
      garbage.stage = 'NOT_A_STAGE' as CloudSyncFailureStage;
      garbage.reason = 'NOT_A_REASON' as CloudBackupFailureReason;
      expect(cloudSyncFailureView(garbage)).assertNull();
      const broken = new CloudSyncLastFailure();
      broken.failedAt = -5;
      expect(cloudSyncFailureView(broken)).assertNull();
    });
  });
}

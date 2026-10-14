import { describe, it, expect } from '@ohos/hypium';
import {
  CloudBackupActionResult, CloudBackupFailureReason, CloudBackupHistoryResult, cloudBackupFailure,
} from 'common';

export default function cloudBackupResultTest(): void {
  describe('CloudBackupResultTest', () => {
    it('failure_factory_keeps_local_and_cloud_completion_separate', 0, () => {
      const failure = cloudBackupFailure(CloudBackupFailureReason.SYNC_FAILED);
      expect(failure.success).assertFalse();
      expect(failure.reason).assertEqual(CloudBackupFailureReason.SYNC_FAILED);
      expect(failure.localComplete).assertFalse();
      expect(failure.syncStartAccepted).assertFalse();
      failure.localComplete = true;
      expect(failure.success).assertFalse();
      expect(failure.syncStartAccepted).assertFalse();
    });
    it('decrypt_failure_is_distinct_from_invalid_format_and_never_claims_partial_writes', 0, () => {
      const result = cloudBackupFailure(CloudBackupFailureReason.DECRYPT_FAILED);
      expect(result.reason).assertEqual('DECRYPT_FAILED');
      expect(result.reason === CloudBackupFailureReason.FORMAT_INVALID).assertFalse();
      expect(result.success).assertFalse();
      expect(result.partialFailure).assertFalse();
      expect(result.localComplete).assertFalse();
      expect(result.syncStartAccepted).assertFalse();
    });
    it('result_defaults_never_claim_success_or_share_history_arrays', 0, () => {
      const result = new CloudBackupActionResult();
      const first = new CloudBackupHistoryResult();
      const second = new CloudBackupHistoryResult();
      expect(result.success).assertFalse();
      expect(result.partialFailure).assertFalse();
      expect(first.success).assertFalse();
      expect(first.records === second.records).assertFalse();
    });
  });
}

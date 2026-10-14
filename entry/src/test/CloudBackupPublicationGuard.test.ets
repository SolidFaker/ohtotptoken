import { describe, it, expect } from '@ohos/hypium';
import {
  CloudBackupPublicationGuard, CloudBackupPublicationPort, CloudPublicationReceipt, CloudPublicationState,
  CloudStageStat, CloudBackupDiagnostics, DiagnosticKind, CloudBackupRecord, CloudBackupMetadataStatus,
  CloudBackupIdentityStatus, applyCloudPublicationIsolation,
} from 'common';

class PublicationGuardTestPort implements CloudBackupPublicationPort {
  readonly receipts: CloudPublicationReceipt[] = [];
  readonly sources: Set<string> = new Set();
  forgotten: number = 0;
  failLoad: boolean = false;
  failSave: boolean = false;
  failMark: boolean = false;
  failForget: boolean = false;
  async load(): Promise<CloudPublicationReceipt[]> {
    if (this.failLoad) throw new Error('SYNTHETIC_PUBLICATION_IO');
    return this.receipts.map((receipt: CloudPublicationReceipt): CloudPublicationReceipt => ({
      id: receipt.id, version: receipt.version, scope: receipt.scope, cloudRoot: receipt.cloudRoot,
      fileName: receipt.fileName, source: receipt.source, state: receipt.state,
    }));
  }
  async save(receipt: CloudPublicationReceipt): Promise<string> {
    if (this.failSave) throw new Error('SYNTHETIC_PUBLICATION_IO');
    const id = 'publication-000001';
    this.receipts.push({ id: id, version: receipt.version, scope: receipt.scope, cloudRoot: receipt.cloudRoot,
      fileName: receipt.fileName, source: receipt.source, state: receipt.state });
    return id;
  }
  async mark(id: string, state: CloudPublicationState): Promise<void> {
    if (this.failMark) throw new Error('SYNTHETIC_PUBLICATION_IO');
    this.receipts.find((receipt: CloudPublicationReceipt): boolean => receipt.id === id)!.state = state;
  }
  async forget(id: string): Promise<void> {
    if (this.failForget) throw new Error('SYNTHETIC_PUBLICATION_IO');
    const index = this.receipts.findIndex((receipt: CloudPublicationReceipt): boolean => receipt.id === id);
    if (index >= 0) this.receipts.splice(index, 1);
    this.forgotten++;
  }
  async inspect(path: string): Promise<CloudStageStat | undefined> {
    return this.sources.has(path) ? { directory: false, regular: true, symbolic: false } : undefined;
  }
}

const PUBLICATION_TEST_ROOT = '/publication-test-cloud';
const PUBLICATION_TEST_SCOPE = 'publication-test-account';
const PUBLICATION_TEST_SOURCE = PUBLICATION_TEST_ROOT + '/.cloud-backup-owned-123456/content.tmp';
const PUBLICATION_TEST_FILE = 'otp_backup_123.enc';

export default function cloudBackupPublicationGuardTest() {
  describe('cloudBackupPublicationGuardTest', () => {
    it('publication_guard_restart_ambiguous_move_is_isolated_without_deletion_proof', 0, async () => {
      const port = new PublicationGuardTestPort();
      const context = CloudBackupDiagnostics.begin(DiagnosticKind.BACKUP);
      const guard = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      expect(await guard.recover(context)).assertTrue();
      await guard.register(PUBLICATION_TEST_SOURCE, PUBLICATION_TEST_FILE, context);
      const restarted = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      expect(await restarted.recover(context)).assertTrue();
      expect(restarted.isolatedFileNames().join(',')).assertEqual(PUBLICATION_TEST_FILE);
      expect(restarted.rejected().length).assertEqual(0);
      expect(port.forgotten).assertEqual(0);
      CloudBackupDiagnostics.end(context);
    });

    it('publication_guard_present_source_cancels_collision_before_any_stage_cleanup', 0, async () => {
      const port = new PublicationGuardTestPort();
      const context = CloudBackupDiagnostics.begin(DiagnosticKind.BACKUP);
      const guard = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      await guard.recover(context);
      await guard.register(PUBLICATION_TEST_SOURCE, PUBLICATION_TEST_FILE, context);
      port.sources.add(PUBLICATION_TEST_SOURCE);
      const restarted = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      expect(await restarted.recover(context)).assertTrue();
      expect(restarted.isolatedFileNames().length).assertEqual(0);
      expect(port.forgotten).assertEqual(1);
      CloudBackupDiagnostics.end(context);
    });

    it('publication_guard_failed_confirmed_proof_never_grants_rejected_ownership', 0, async () => {
      const port = new PublicationGuardTestPort();
      const context = CloudBackupDiagnostics.begin(DiagnosticKind.BACKUP);
      const guard = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      await guard.recover(context);
      const id = await guard.register(PUBLICATION_TEST_SOURCE, PUBLICATION_TEST_FILE, context);
      port.failMark = true;
      let rejected = false;
      try { await guard.published(id, context); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
      expect(guard.isAvailable()).assertFalse();
      port.failMark = false;
      const restarted = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      expect(await restarted.recover(context)).assertTrue();
      expect(restarted.rejected().length).assertEqual(0);
      expect(restarted.hasIsolation()).assertTrue();
      CloudBackupDiagnostics.end(context);
    });

    it('publication_guard_rejected_proof_survives_restart_until_explicit_confirmed_sync_ack', 0, async () => {
      const port = new PublicationGuardTestPort();
      const context = CloudBackupDiagnostics.begin(DiagnosticKind.BACKUP);
      const guard = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      await guard.recover(context);
      const id = await guard.register(PUBLICATION_TEST_SOURCE, PUBLICATION_TEST_FILE, context);
      await guard.published(id, context);
      await guard.reject(id, context);
      const restarted = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      await restarted.recover(context);
      expect(restarted.rejected().length).assertEqual(1);
      expect(port.forgotten).assertEqual(0);
      await restarted.acknowledgeRejected(id, context);
      expect(restarted.hasIsolation()).assertFalse();
      expect(port.forgotten).assertEqual(1);
      CloudBackupDiagnostics.end(context);
    });

    it('publication_guard_load_failure_blocks_even_previous_valid_state', 0, async () => {
      const port = new PublicationGuardTestPort();
      const context = CloudBackupDiagnostics.begin(DiagnosticKind.BACKUP);
      const guard = new CloudBackupPublicationGuard(PUBLICATION_TEST_ROOT, PUBLICATION_TEST_SCOPE, port);
      await guard.recover(context);
      port.failLoad = true;
      expect(await guard.recover(context)).assertFalse();
      expect(guard.isAvailable()).assertFalse();
      let blocked = false;
      try { guard.isolatedFileNames(); } catch (_) { blocked = true; }
      expect(blocked).assertTrue();
      CloudBackupDiagnostics.end(context);
    });

    it('publication_guard_task_and_port_filter_clear_identity_and_unknown_count_only_for_exact_id', 0, () => {
      const record: CloudBackupRecord = { id: PUBLICATION_TEST_FILE, timestamp: 123, date: '', size: 1,
        tokenCount: 4, tokenCountKnown: true, deviceId: 'synthetic-device', deviceName: 'Synthetic',
        metadataStatus: CloudBackupMetadataStatus.VALID, identityStatus: CloudBackupIdentityStatus.COMPLETE,
        location: 3, encrypted: true };
      applyCloudPublicationIsolation([record], [PUBLICATION_TEST_FILE]);
      expect(record.metadataStatus).assertEqual(CloudBackupMetadataStatus.INVALID);
      expect(record.tokenCountKnown).assertFalse();
      expect(record.deviceId).assertEqual('');
      expect(record.tokenCount).assertEqual(0);
    });
  });
}

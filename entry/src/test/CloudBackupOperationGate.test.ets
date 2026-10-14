import { describe, it, expect } from '@ohos/hypium';
import { CloudBackupOperationGate, CloudBackupOperationKind, CloudBackupOperationLease } from 'common';

export default function cloudBackupOperationGateTest() {
  describe('cloudBackupOperationGateTest', () => {
    it('gate_conflicts_reject_immediately_without_automatic_backup_queue', 0, () => {
      const gate = new CloudBackupOperationGate();
      const clear = gate.tryEnter(CloudBackupOperationKind.CLEAR);
      expect(clear !== undefined).assertTrue();
      expect(gate.isBusy()).assertTrue();
      expect(gate.tryEnter(CloudBackupOperationKind.BACKUP) === undefined).assertTrue();
      expect(gate.tryEnter(CloudBackupOperationKind.RESTORE) === undefined).assertTrue();
      expect(gate.tryEnter(CloudBackupOperationKind.HISTORY) === undefined).assertTrue();
      expect(gate.tryEnter(CloudBackupOperationKind.ICONS) === undefined).assertTrue();
      if (clear !== undefined) {
        expect(clear.release()).assertTrue();
      }
      expect(gate.isBusy()).assertFalse();
      const next = gate.tryEnter(CloudBackupOperationKind.CLEAR);
      expect(next !== undefined).assertTrue();
      if (next !== undefined) {
        next.release();
      }
    });

    it('gate_retains_unknown_io_until_original_owner_resolves', 0, () => {
      const gate = new CloudBackupOperationGate();
      const owner = gate.tryEnter(CloudBackupOperationKind.HISTORY);
      if (owner === undefined) {
        expect(false).assertTrue();
        return;
      }
      owner.retainUnknownIo();
      owner.retainUnknownIo();
      expect(owner.release()).assertFalse();
      expect(gate.owns(owner)).assertTrue();
      expect(gate.tryEnter(CloudBackupOperationKind.CLEAR) === undefined).assertTrue();
      owner.resolveUnknownIo();
      expect(gate.isBusy()).assertTrue();
      expect(owner.release()).assertTrue();
      expect(owner.release()).assertFalse();
      expect(gate.isBusy()).assertFalse();
    });

    it('gate_retained_owner_cannot_authorize_new_child_work', 0, () => {
      const gate = new CloudBackupOperationGate();
      const owner = gate.tryEnter(CloudBackupOperationKind.BACKUP);
      if (owner === undefined) {
        expect(false).assertTrue();
        return;
      }
      expect(gate.canUse(owner)).assertTrue();
      owner.retainUnknownIo();
      expect(owner.isCleanupPending()).assertTrue();
      expect(gate.owns(owner)).assertTrue();
      expect(gate.canUse(owner)).assertFalse();
      owner.resolveUnknownIo();
      expect(owner.isCleanupPending()).assertFalse();
      expect(gate.canUse(owner)).assertTrue();
      owner.release();
      expect(gate.canUse(owner)).assertFalse();
    });

    it('gate_late_owner_callbacks_cannot_release_new_owner', 0, () => {
      const gate = new CloudBackupOperationGate();
      const oldOwner = gate.tryEnter(CloudBackupOperationKind.HISTORY);
      if (oldOwner === undefined) {
        expect(false).assertTrue();
        return;
      }
      oldOwner.retainUnknownIo();
      oldOwner.resolveUnknownIo();
      expect(oldOwner.release()).assertTrue();
      const next = gate.tryEnter(CloudBackupOperationKind.BACKUP);
      expect(next !== undefined).assertTrue();
      oldOwner.retainUnknownIo();
      oldOwner.resolveUnknownIo();
      expect(oldOwner.release()).assertFalse();
      expect(gate.isBusy()).assertTrue();
      expect(gate.owns(oldOwner)).assertFalse();
      if (next !== undefined) {
        expect(gate.owns(next)).assertTrue();
        expect(next.release()).assertTrue();
      }
    });

    it('gate_nested_call_uses_owner_identity_not_reentry_or_fabricated_lease', 0, () => {
      const gate = new CloudBackupOperationGate();
      const owner = gate.tryEnter(CloudBackupOperationKind.BACKUP);
      const otherGate = new CloudBackupOperationGate();
      const otherOwner = otherGate.tryEnter(CloudBackupOperationKind.BACKUP);
      const fabricated = new CloudBackupOperationLease(CloudBackupOperationKind.BACKUP,
        (_lease: CloudBackupOperationLease): boolean => true);
      expect(gate.owns(fabricated)).assertFalse();
      if (owner !== undefined) {
        expect(gate.owns(owner)).assertTrue();
        expect(gate.tryEnter(owner.kind) === undefined).assertTrue();
        owner.release();
      }
      if (otherOwner !== undefined) {
        expect(gate.owns(otherOwner)).assertFalse();
        otherOwner.release();
      }
    });

    it('gate_delayed_icon_and_taskpool_lifetimes_keep_owner_until_awaited', 0, async () => {
      const gate = new CloudBackupOperationGate();
      const owner = gate.tryEnter(CloudBackupOperationKind.BACKUP);
      if (owner === undefined) {
        expect(false).assertTrue();
        return;
      }
      let completeIcons: () => void = (): void => {};
      const icons = new Promise<void>((resolve: () => void) => { completeIcons = resolve; });
      const ownedWork = icons.then(() => { owner.release(); });
      await Promise.resolve();
      expect(gate.tryEnter(CloudBackupOperationKind.CLEAR) === undefined).assertTrue();
      completeIcons();
      await ownedWork;
      const history = gate.tryEnter(CloudBackupOperationKind.HISTORY);
      expect(history !== undefined).assertTrue();
      expect(gate.tryEnter(CloudBackupOperationKind.BACKUP) === undefined).assertTrue();
      if (history !== undefined) {
        history.release();
      }
      expect(gate.isBusy()).assertFalse();
    });

    it('gate_singleton_is_process_shared_but_test_instances_are_isolated', 0, () => {
      expect(CloudBackupOperationGate.getInstance() === CloudBackupOperationGate.getInstance()).assertTrue();
      const first = new CloudBackupOperationGate();
      const second = new CloudBackupOperationGate();
      const owner = first.tryEnter(CloudBackupOperationKind.CLEAR);
      expect(second.isBusy()).assertFalse();
      if (owner !== undefined) {
        owner.release();
      }
    });
  });
}

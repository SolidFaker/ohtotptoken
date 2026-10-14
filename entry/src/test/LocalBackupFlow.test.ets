import { describe, it, expect } from '@ohos/hypium';
import { PreparedLocalBackup } from 'common';
import { isLocalBackupMenuCancellation, LocalBackupFlow, LocalBackupStage } from '../main/ets/utils/LocalBackupFlow';
import { TokenBatchOperation } from '../main/ets/utils/TokenBatchOperation';
import { DeferredBackupWork, localBackupPayload } from './fakes/LocalBackupFakes';

class MenuFailure extends Error {
  code: number | string;
  constructor(code: number | string) { super('SYNTHETIC_PRIVATE'); this.code = code; }
}

export default function localBackupFlowTest(): void {
  describe('LocalBackupFlowTest', () => {
    it('menu_cancel_is_distinct_from_string_numeric_and_unknown_failures', 0, () => {
      expect(isLocalBackupMenuCancellation(new Error('cancel'))).assertTrue();
      expect(isLocalBackupMenuCancellation(new Error('SYNTHETIC_PRIVATE'))).assertFalse();
      for (const code of [100001, '100001', 401, '401']) {
        expect(isLocalBackupMenuCancellation(new MenuFailure(code))).assertFalse();
      }
      expect(isLocalBackupMenuCancellation(undefined)).assertFalse();
    });

    it('menu_picker_password_confirmation_cancel_and_reentry', 0, () => {
      for (const stage of [LocalBackupStage.CHOOSING, LocalBackupStage.PICKING, LocalBackupStage.PASSWORD, LocalBackupStage.CONFIRMING]) {
        const flow = new LocalBackupFlow();
        const generation = flow.begin(stage)!;
        expect(flow.begin() === undefined).assertTrue();
        expect(flow.isCurrent(generation)).assertTrue();
        expect(flow.cancel()).assertTrue();
        expect(flow.isCurrent(generation)).assertFalse();
        expect(TokenBatchOperation.isBusy()).assertFalse();
      }
    });

    it('cancel_during_io_holds_permit_until_safe_end_and_discards_late_result', 0, async () => {
      const flow = new LocalBackupFlow();
      const generation = flow.begin()!;
      const deferred = new DeferredBackupWork();
      const work = flow.work(generation, false, async () => { await deferred.promise; return 'late'; });
      expect(flow.cancel()).assertTrue();
      expect(TokenBatchOperation.isBusy()).assertTrue();
      expect(flow.begin() === undefined).assertTrue();
      deferred.complete();
      expect(await work === undefined).assertTrue();
      expect(TokenBatchOperation.isBusy()).assertFalse();
      const next = flow.begin()!;
      flow.finish(generation);
      expect(flow.isCurrent(next)).assertTrue();
      flow.finish(next);
    });

    it('write_rejects_normal_close_and_invalid_host_drains_without_success', 0, async () => {
      const states: boolean[] = [];
      const flow = new LocalBackupFlow((executing: boolean) => { states.push(executing); });
      const generation = flow.begin()!;
      const deferred = new DeferredBackupWork();
      const work = flow.work(generation, true, async () => { await deferred.promise; return true; });
      expect(flow.isExecuting()).assertTrue();
      expect(flow.cancel()).assertFalse();
      flow.invalidate();
      expect(TokenBatchOperation.isBusy()).assertTrue();
      deferred.complete();
      expect(await work === undefined).assertTrue();
      expect(flow.begin() === undefined).assertTrue();
      expect(TokenBatchOperation.isBusy()).assertFalse();
      expect(states.includes(true)).assertTrue();
      flow.activate();
      const next = flow.begin()!;
      flow.finish(next);
    });

    it('cancel_clears_snapshot_and_failure_finally_can_finish', 0, async () => {
      const flow = new LocalBackupFlow();
      let generation = flow.begin()!;
      const snapshot = PreparedLocalBackup.fromText(JSON.stringify(localBackupPayload()));
      expect(flow.remember(generation, snapshot)).assertTrue();
      flow.cancel();
      let disposed = false;
      try { snapshot.takeForCommit(); } catch (_) { disposed = true; }
      expect(disposed).assertTrue();
      generation = flow.begin()!;
      try { await flow.work(generation, false, async () => { throw new Error('synthetic'); }); } catch (_) {}
      flow.finish(generation);
      expect(TokenBatchOperation.isBusy()).assertFalse();
    });
  });
}

import { describe, it, expect } from '@ohos/hypium';
import { TokenBatchOperation, TokenBatchPermit } from '../main/ets/utils/TokenBatchOperation';
import { DeferredBackupWork } from './fakes/LocalBackupFakes';

class PermitOwner {}

export default function tokenBatchOperationTest(): void {
  describe('TokenBatchOperationPermitTest', () => {
    it('owner_bound_nonreentrant_idempotent_release_and_next_operation', 0, async () => {
      const owner = new PermitOwner();
      const other = new PermitOwner();
      const permit = TokenBatchOperation.acquire(owner)!;
      try {
        expect(TokenBatchOperation.acquire(owner) === undefined).assertTrue();
        expect(TokenBatchOperation.acquire(other) === undefined).assertTrue();
        expect(TokenBatchOperation.release(other, permit)).assertFalse();
        expect(TokenBatchOperation.release(owner, new TokenBatchPermit(owner))).assertFalse();
        let calls = 0;
        await TokenBatchOperation.hold(owner, permit, async () => { calls++; });
        await TokenBatchOperation.hold(owner, permit, async () => { calls++; });
        expect(calls).assertEqual(2);
      } finally { TokenBatchOperation.release(owner, permit); }
      expect(TokenBatchOperation.release(owner, permit)).assertFalse();
      const next = TokenBatchOperation.acquire(other)!;
      expect(TokenBatchOperation.isBusy()).assertTrue();
      expect(TokenBatchOperation.release(owner, permit)).assertFalse();
      TokenBatchOperation.release(other, next);
      expect(TokenBatchOperation.isBusy()).assertFalse();
    });

    it('running_permit_cannot_be_released_or_reentered', 0, async () => {
      const owner = new PermitOwner();
      const permit = TokenBatchOperation.acquire(owner)!;
      const deferred = new DeferredBackupWork();
      const pending = TokenBatchOperation.hold(owner, permit, () => deferred.promise);
      try {
        expect(TokenBatchOperation.release(owner, permit)).assertFalse();
        let rejected = false;
        try { await TokenBatchOperation.hold(owner, permit, async () => {}); } catch (_) { rejected = true; }
        expect(rejected).assertTrue();
      } finally {
        deferred.complete();
        await pending;
        TokenBatchOperation.release(owner, permit);
      }
      expect(TokenBatchOperation.isBusy()).assertFalse();
    });

    it('operation_failure_does_not_strand_running_flag', 0, async () => {
      const owner = new PermitOwner();
      const permit = TokenBatchOperation.acquire(owner)!;
      try { await TokenBatchOperation.hold(owner, permit, async () => { throw new Error('synthetic'); }); } catch (_) {}
      expect(TokenBatchOperation.release(owner, permit)).assertTrue();
    });
  });
}

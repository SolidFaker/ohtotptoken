import { describe, it, expect, afterEach } from '@ohos/hypium';
import {
  PreparedLocalBackup, readLocalBackupSource, TokenConfig, TokenGroup, TokenGroupStore,
  useCryptoEngineForTest, resetCryptoEngineForTest, encodeLocalBackup, TokenBackup
} from 'common';
import { commitPreparedBackup, LocalBackupCommitError, LocalBackupGroupMerger } from '../main/ets/utils/BackupImportOperation';
import {
  LocalBackupCryptoFake, LocalBackupGroupFake, localBackupPayload, localBackupToken, LocalBackupTextFake, LOCAL_BACKUP_SENTINEL
} from './fakes/LocalBackupFakes';

class GroupMerger implements LocalBackupGroupMerger {
  calls: number = 0;
  fail: boolean = false;
  async merge(_groups: TokenGroup[]): Promise<void> {
    this.calls++;
    if (this.fail) { throw new Error(LOCAL_BACKUP_SENTINEL); }
  }
}

export default function localBackupImportTest(): void {
  describe('LocalBackupImportTest', () => {
    afterEach(() => { resetCryptoEngineForTest(); });

    it('read_validation_and_summary_cancel_do_not_write_groups_or_tokens', 0, async () => {
      const kv = new LocalBackupGroupFake();
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      TokenGroupStore.getInstance().state.groups = [];
      const io = new LocalBackupTextFake();
      const source = await readLocalBackupSource('synthetic.bak', io);
      const prepared = await source.prepare();
      expect(prepared.tokenCount).assertEqual(4);
      prepared.dispose();
      source.dispose();
      expect(kv.writes).assertEqual(0);
      expect(io.writes).assertEqual(0);
      io.failRead = true;
      try { await readLocalBackupSource(LOCAL_BACKUP_SENTINEL, io); } catch (error) {
        expect((error as Error).message.includes(LOCAL_BACKUP_SENTINEL)).assertFalse();
      }
      expect(kv.writes).assertEqual(0);
      let invalid = false;
      try { PreparedLocalBackup.fromText('{"magic":1}'); } catch (_) { invalid = true; }
      expect(invalid).assertTrue();
      expect(kv.writes).assertEqual(0);
    });

    it('password_failure_writes_nothing_and_retry_uses_same_read', 0, async () => {
      const kv = new LocalBackupGroupFake();
      TokenGroupStore.getInstance().useKvBackendForTest(kv);
      TokenGroupStore.getInstance().state.groups = [];
      useCryptoEngineForTest(new LocalBackupCryptoFake());
      const io = new LocalBackupTextFake();
      io.content = await encodeLocalBackup(new TokenBackup(1, [localBackupToken()]), true, 'synthetic');
      const source = await readLocalBackupSource('synthetic.txt', io);
      let failed = false;
      try { await source.prepare('wrong'); } catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(kv.writes).assertEqual(0);
      const prepared = await source.prepare('synthetic');
      expect(io.reads).assertEqual(1);
      prepared.dispose();
      source.dispose();
      expect(kv.writes).assertEqual(0);
    });

    it('group_failure_stops_token_write_and_redacts_error', 0, async () => {
      const merger = new GroupMerger();
      merger.fail = true;
      let calls = 0;
      let failed = false;
      try {
        await commitPreparedBackup(PreparedLocalBackup.fromText(JSON.stringify(localBackupPayload())),
          async () => { calls++; }, () => {}, merger);
      } catch (error) {
        failed = error instanceof LocalBackupCommitError && !error.groupsCompleted;
        expect((error as Error).message.includes(LOCAL_BACKUP_SENTINEL)).assertFalse();
      }
      expect(failed).assertTrue();
      expect(calls).assertEqual(0);
      expect(merger.calls).assertEqual(1);
    });

    it('after_group_success_failure_is_partial_not_rollback', 0, async () => {
      const merger = new GroupMerger();
      let partial = false;
      try {
        await commitPreparedBackup(PreparedLocalBackup.fromText(JSON.stringify(localBackupPayload())),
          async () => { throw new Error(LOCAL_BACKUP_SENTINEL); }, () => {}, merger);
      } catch (error) { partial = error instanceof LocalBackupCommitError && error.groupsCompleted; }
      expect(partial).assertTrue();
      expect(merger.calls).assertEqual(1);
    });

    it('commit_consumes_confirmed_snapshot_unique_count_and_always_passes_report', 0, async () => {
      const payload = localBackupPayload();
      const duplicate = localBackupToken('totp');
      duplicate.TokenName = 'last';
      payload.configs.push(duplicate);
      const prepared = PreparedLocalBackup.fromText(JSON.stringify(payload));
      payload.configs = [];
      const merger = new GroupMerger();
      let actual: TokenConfig[] = [];
      const count = await commitPreparedBackup(prepared, async (tokens, report) => {
        expect(report !== undefined).assertTrue();
        actual = tokens;
      }, () => {}, merger);
      expect(count).assertEqual(4);
      expect(actual[0].TokenName).assertEqual('last');
      expect(merger.calls).assertEqual(1);
    });
  });
}

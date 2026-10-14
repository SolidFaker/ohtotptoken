import { describe, it, expect } from '@ohos/hypium';
import { LocalBackupFileIo, LocalBackupError, LocalBackupFailure, readLocalBackupSource, restoreFromBackup } from 'common';
import { DeferredBackupWork, LocalBackupFileFake, LOCAL_BACKUP_SENTINEL } from './fakes/LocalBackupFakes';

export default function localBackupFileIoTest(): void {
  describe('LocalBackupFileIoTest', () => {
    it('reads_utf8_across_short_chunks_and_closes', 0, async () => {
      const port = new LocalBackupFileFake();
      const text = '中文跨块🙂 synthetic'.repeat(25);
      port.bytes = port.encode(text);
      expect(await new LocalBackupFileIo(port).readText('synthetic://test')).assertEqual(text);
      expect(port.closes).assertEqual(1);
    });

    it('writes_exact_view_until_all_bytes_complete', 0, async () => {
      const port = new LocalBackupFileFake();
      const text = '保存🙂中文';
      await new LocalBackupFileIo(port).writeText('synthetic://test', text);
      expect(port.decode(new Uint8Array(port.written))).assertEqual(text);
      expect(port.writes > 1).assertTrue();
      expect(port.closes).assertEqual(1);
    });

    it('success_waits_for_close_and_no_early_release', 0, async () => {
      const port = new LocalBackupFileFake();
      port.closeDelay = new DeferredBackupWork();
      let complete = false;
      const operation = new LocalBackupFileIo(port).writeText('synthetic://test', 'x').then(() => { complete = true; });
      for (let i = 0; i < 8; i++) { await Promise.resolve(); }
      expect(port.closes).assertEqual(1);
      expect(complete).assertFalse();
      port.closeDelay.complete();
      await operation;
      expect(complete).assertTrue();
    });

    it('fixed_errors_for_open_encode_write_and_close_without_sensitive_cause', 0, async () => {
      for (const stage of ['open', 'encode', 'write', 'close']) {
        const port = new LocalBackupFileFake();
        port.failAt = stage;
        let failed = false;
        try { await new LocalBackupFileIo(port).writeText(LOCAL_BACKUP_SENTINEL, LOCAL_BACKUP_SENTINEL); } catch (error) {
          failed = error instanceof LocalBackupError && error.reason === LocalBackupFailure.SAVE;
          expect((error as Error).message.includes(LOCAL_BACKUP_SENTINEL)).assertFalse();
        }
        expect(failed).assertTrue();
        expect(port.closes).assertEqual(stage === 'open' || stage === 'encode' ? 0 : 1);
      }
    });

    it('zero_write_progress_fails_and_still_closes', 0, async () => {
      const port = new LocalBackupFileFake();
      port.writeChunk = 0;
      let failed = false;
      try { await new LocalBackupFileIo(port).writeText('synthetic://test', 'content'); } catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(port.writes).assertEqual(1);
      expect(port.closes).assertEqual(1);
    });

    it('read_and_close_failures_are_not_success', 0, async () => {
      for (const stage of ['read', 'close']) {
        const port = new LocalBackupFileFake();
        port.failAt = stage;
        let failed = false;
        try { await new LocalBackupFileIo(port).readText(LOCAL_BACKUP_SENTINEL); } catch (error) {
          failed = error instanceof LocalBackupError && error.reason === LocalBackupFailure.READ;
          expect((error as Error).message.includes(LOCAL_BACKUP_SENTINEL)).assertFalse();
        }
        expect(failed).assertTrue();
        expect(port.closes).assertEqual(1);
      }
    });

    it('cancel_before_open_does_not_start_io', 0, async () => {
      const port = new LocalBackupFileFake();
      const io = new LocalBackupFileIo(port, () => true);
      for (const writing of [false, true]) {
        let cancelled = false;
        try {
          if (writing) { await io.writeText('synthetic://test', 'content'); } else { await io.readText('synthetic://test'); }
        } catch (error) { cancelled = error instanceof LocalBackupError && error.reason === LocalBackupFailure.CANCELLED; }
        expect(cancelled).assertTrue();
      }
      expect(port.opens).assertEqual(0);
    });

    it('source_wrapper_preserves_fixed_cancel_reason', 0, async () => {
      const port = new LocalBackupFileFake();
      let cancelled = false;
      try { await readLocalBackupSource('synthetic.bak', new LocalBackupFileIo(port, () => true)); } catch (error) {
        cancelled = error instanceof LocalBackupError && error.reason === LocalBackupFailure.CANCELLED;
      }
      expect(cancelled).assertTrue();
      cancelled = false;
      try { await restoreFromBackup('synthetic.bak', false, '', undefined, new LocalBackupFileIo(port, () => true)); } catch (error) {
        cancelled = error instanceof LocalBackupError && error.reason === LocalBackupFailure.CANCELLED;
      }
      expect(cancelled).assertTrue();
      expect(port.opens).assertEqual(0);
    });

    it('cancel_during_open_still_closes_and_never_reads', 0, async () => {
      const port = new LocalBackupFileFake();
      port.openDelay = new DeferredBackupWork();
      let cancelled = false;
      const operation = new LocalBackupFileIo(port, () => cancelled).readText('synthetic://test').catch(() => 'cancelled');
      cancelled = true;
      port.openDelay.complete();
      expect(await operation).assertEqual('cancelled');
      expect(port.reads).assertEqual(0);
      expect(port.closes).assertEqual(1);
    });

    it('write_already_started_finishes_without_fake_rollback', 0, async () => {
      const port = new LocalBackupFileFake();
      port.writeDelay = new DeferredBackupWork();
      let cancelled = false;
      const operation = new LocalBackupFileIo(port, () => cancelled).writeText('synthetic://test', 'content');
      await Promise.resolve();
      cancelled = true;
      port.writeDelay.complete();
      await operation;
      expect(port.decode(new Uint8Array(port.written))).assertEqual('content');
      expect(port.closes).assertEqual(1);
    });
  });
}

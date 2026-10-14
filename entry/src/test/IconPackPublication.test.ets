import { describe, it, expect } from '@ohos/hypium';
import { IconPackPublication, CloudBackupDiagnostics, DiagnosticKind, ICON_PACK_ZIP, ICON_PACK_META,
  ICON_PACK_GENERATIONS } from 'common';
import { MemoryFs, MemoryFsError } from './fakes/BackupFakes';

const ROOT = '/cloud/' + ICON_PACK_GENERATIONS;
const TEMP = '/temp/new.zip';
const OLD_META = '{"version":1,"timestamp":1,"deviceId":"same","packs":[]}';
function metadata(timestamp: number, device: string = 'same'): string {
  return JSON.stringify({ version: 1, timestamp, deviceId: device, packs: [] });
}
class GenerationFixtureFs extends MemoryFs {
  failCommitDelete: boolean = false;
  failCommitClose: boolean = false;
  async deleteFile(path: string): Promise<void> {
    if (this.failCommitDelete && path.endsWith('/committed.json')) throw new MemoryFsError(13900005);
    return super.deleteFile(path);
  }
  async writeTextFile(path: string, content: string): Promise<void> {
    await super.writeTextFile(path, content);
    if (this.failCommitClose && path.endsWith('/committed.json')) throw new MemoryFsError(13900005);
  }
}
function seeded(): GenerationFixtureFs {
  const fs = new GenerationFixtureFs();
  fs.files.set('/cloud/' + ICON_PACK_ZIP, 'old');
  fs.files.set('/cloud/' + ICON_PACK_META, OLD_META);
  fs.files.set(TEMP, 'new');
  return fs;
}
function publication(fs: MemoryFs, valid: boolean = true): IconPackPublication {
  return new IconPackPublication(fs, '/cloud', CloudBackupDiagnostics.begin(DiagnosticKind.ICON),
    async (path: string): Promise<boolean> => valid && fs.files.has(path));
}
function seedGeneration(fs: MemoryFs, id: string, timestamp: number, device: string = 'same'): void {
  fs.dirs.add(ROOT);
  fs.dirs.add(ROOT + '/' + id);
  fs.files.set(ROOT + '/' + id + '/' + ICON_PACK_ZIP, 'generation-' + timestamp);
  const meta = metadata(timestamp, device);
  fs.files.set(ROOT + '/' + id + '/' + ICON_PACK_META, meta);
  fs.files.set(ROOT + '/' + id + '/committed.json', JSON.stringify({version: 1, id, timestamp, metadata: meta}));
}
export default function iconPackPublicationTest() {
  describe('iconPackPublicationTest', () => {
    it('publish_immutable_generation_never_moves_or_deletes_legacy_backup', 0, async () => {
      const fs = seeded();
      expect(await publication(fs).publish(TEMP, metadata(2))).assertTrue();
      const snapshot = await publication(fs).snapshot();
      expect(snapshot?.zipPath).assertEqual(ROOT + '/generation-000001/' + ICON_PACK_ZIP);
      expect(fs.files.get('/cloud/' + ICON_PACK_ZIP)).assertEqual('old');
      expect(fs.files.get('/cloud/' + ICON_PACK_META)).assertEqual(OLD_META);
      expect(fs.publishAttempts.length).assertEqual(0);
      expect(fs.replaceAttempts.length).assertEqual(0);
    });
    it('copy_failure_preserves_all_existing_generations', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1);
      fs.failCopyFor.add(TEMP);
      expect(await publication(fs).publish(TEMP, metadata(2))).assertFalse();
      expect(fs.files.get(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP)).assertEqual('generation-1');
      expect(fs.files.get('/cloud/' + ICON_PACK_ZIP)).assertEqual('old');
    });
    it('verify_failure_reclaims_only_operation_owned_uncommitted_directory', 0, async () => {
      const fs = seeded();
      expect(await publication(fs, false).publish(TEMP, metadata(2))).assertFalse();
      expect(fs.dirs.has(ROOT + '/generation-000001')).assertFalse();
      expect(fs.files.get('/cloud/' + ICON_PACK_ZIP)).assertEqual('old');
    });
    it('commit_fsync_failure_keeps_visible_new_generation', 0, async () => {
      const fs = seeded();
      fs.failSyncFor.add(ROOT + '/generation-000001/committed.json');
      expect(await publication(fs).publish(TEMP, metadata(2))).assertFalse();
      expect(fs.files.has(ROOT + '/generation-000001/' + ICON_PACK_ZIP)).assertTrue();
      expect((await publication(fs).snapshot())?.zipPath).assertEqual(ROOT + '/generation-000001/' + ICON_PACK_ZIP);
    });
    it('uncommitted_process_rebuild_never_promotes_or_deletes_old_generation', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1);
      fs.dirs.add(ROOT + '/generation-BBBBBB');
      fs.files.set(ROOT + '/generation-BBBBBB/' + ICON_PACK_ZIP, 'partial');
      const snapshot = await publication(fs).snapshot();
      expect(snapshot?.zipPath).assertEqual(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP);
      expect(fs.files.has(ROOT + '/generation-BBBBBB/' + ICON_PACK_ZIP)).assertTrue();
      expect(fs.deletedPaths.length).assertEqual(0);
    });
    it('gc_retains_latest_two_and_never_deletes_later_than_publisher', 0, async () => {
      const fs = seeded();
      seedGeneration(fs, 'generation-AAAAAA', 1);
      seedGeneration(fs, 'generation-BBBBBB', 2);
      seedGeneration(fs, 'generation-CCCCCC', 9);
      expect(await publication(fs).publish(TEMP, metadata(3))).assertTrue();
      expect(fs.files.has(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP)).assertFalse();
      expect(fs.files.has(ROOT + '/generation-BBBBBB/' + ICON_PACK_ZIP)).assertFalse();
      expect(fs.files.has(ROOT + '/generation-CCCCCC/' + ICON_PACK_ZIP)).assertTrue();
      expect(fs.files.has(ROOT + '/generation-000001/' + ICON_PACK_ZIP)).assertTrue();
      expect(fs.files.get('/cloud/' + ICON_PACK_ZIP)).assertEqual('old');
    });
    it('corrupt_or_incomplete_higher_commit_does_not_block_old_snapshot', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1);
      seedGeneration(fs, 'generation-BBBBBB', 9);
      fs.files.delete(ROOT + '/generation-BBBBBB/' + ICON_PACK_ZIP);
      expect((await publication(fs).snapshot())?.zipPath).assertEqual(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP);
      fs.files.set(ROOT + '/generation-BBBBBB/committed.json', '{');
      expect((await publication(fs).snapshot())?.zipPath).assertEqual(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP);
    });
    it('gc_refuses_foreign_contents_without_touching_latest', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1);
      seedGeneration(fs, 'generation-BBBBBB', 2);
      fs.files.set(ROOT + '/generation-AAAAAA/foreign.txt', 'foreign');
      expect(await publication(fs).publish(TEMP, metadata(3))).assertFalse();
      expect(fs.files.get(ROOT + '/generation-AAAAAA/foreign.txt')).assertEqual('foreign');
      expect(fs.files.has(ROOT + '/generation-000001/' + ICON_PACK_ZIP)).assertTrue();
    });
    it('clear_scoped_generations_checks_each_own_metadata_without_zip_reads', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1, 'same');
      seedGeneration(fs, 'generation-BBBBBB', 2, 'other');
      fs.failReadFor.add(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP);
      expect(await publication(fs).clear(['same'])).assertTrue();
      expect(fs.files.has(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP)).assertFalse();
      expect(fs.files.has(ROOT + '/generation-BBBBBB/' + ICON_PACK_ZIP)).assertTrue();
      expect(fs.files.get('/cloud/' + ICON_PACK_ZIP)).assertEqual('old');
    });
    it('explicit_clear_reclaims_partial_generation_and_retry_does_not_require_commit', 0, async () => {
      const fs = seeded(); fs.dirs.add(ROOT); fs.dirs.add(ROOT + '/generation-AAAAAA');
      fs.files.set(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP, 'partial');
      expect(await publication(fs).clear()).assertTrue();
      expect(fs.files.has(ROOT + '/generation-AAAAAA/' + ICON_PACK_ZIP)).assertFalse();
    });
    it('scoped_clear_commit_unlink_failure_preserves_identity_for_rebuild_retry', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1, 'same');
      fs.failCommitDelete = true;
      expect(await publication(fs).clear(['same'])).assertFalse();
      expect(fs.files.has(ROOT + '/generation-AAAAAA/' + ICON_PACK_META)).assertTrue();
      fs.failCommitDelete = false;
      expect(await publication(fs).clear(['same'])).assertTrue();
      expect(fs.dirs.has(ROOT + '/generation-AAAAAA')).assertFalse();
    });
    it('scoped_clear_empty_directory_retry_after_rmdir_failure', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1, 'same');
      fs.failRemoveDirFor.add(ROOT + '/generation-AAAAAA');
      expect(await publication(fs).clear(['same'])).assertFalse();
      expect(fs.files.has(ROOT + '/generation-AAAAAA/' + ICON_PACK_META)).assertFalse();
      fs.failRemoveDirFor.clear();
      expect(await publication(fs).clear(['same'])).assertTrue();
      expect(fs.dirs.has(ROOT + '/generation-AAAAAA')).assertFalse();
    });
    it('commit_close_error_after_visible_write_never_reclaims_self', 0, async () => {
      const fs = seeded(); fs.failCommitClose = true;
      expect(await publication(fs).publish(TEMP, metadata(2))).assertFalse();
      expect(fs.files.has(ROOT + '/generation-000001/' + ICON_PACK_ZIP)).assertTrue();
      expect((await publication(fs).snapshot())?.zipPath).assertEqual(ROOT + '/generation-000001/' + ICON_PACK_ZIP);
    });
    it('directory_traversal_and_invalid_generation_ids_are_not_recognized', 0, async () => {
      const fs = seeded();fs.dirs.add(ROOT);fs.dirs.add(ROOT + '/foreign');
      fs.files.set(ROOT + '/foreign/committed.json', '{}');
      expect(await publication(fs).clear()).assertTrue();
      expect(fs.files.has(ROOT + '/foreign/committed.json')).assertTrue();
    });
    it('oversized_marker_is_skipped_without_destroying_any_backup', 0, async () => {
      const fs = seeded(); seedGeneration(fs, 'generation-AAAAAA', 1);
      fs.files.set(ROOT + '/generation-AAAAAA/committed.json', 'x'.repeat(1024 * 1024 + 1));
      expect((await publication(fs).snapshot())?.zipPath).assertEqual('/cloud/' + ICON_PACK_ZIP);
      expect(fs.deletedPaths.length).assertEqual(0);
    });
  });
}

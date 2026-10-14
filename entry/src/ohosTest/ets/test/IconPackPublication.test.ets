import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import {
  CloudBackupDiagnostics, DiagnosticKind, FileIoFsGateway, IconPackPublication,
  ICON_PACK_GENERATIONS, ICON_PACK_ZIP, ICON_PACK_META
} from 'common';

interface FixtureReceipt {
  version: number;
  cloud: string;
  local: string;
  temp: string;
  checkpoint: string;
}

interface FixtureMetadata {
  version: number;
  timestamp: number;
  deviceId: string;
  deviceName: string;
  packs: Object[];
  enabledPacks: string[];
  deletedPacks: string[];
}

const RECEIPT = '.icon-publication-device-fixture.json';
const CHECKPOINTS = ['directory', 'zip', 'metadata', 'commit', 'commit-sync', 'prune'];

class NativeFixtureGateway extends FileIoFsGateway {
  checkpoint: string = '';
  failMetadata: boolean = false;
  failCommitSync: boolean = false;
  failCommitDelete: boolean = false;
  failDirectoryDelete: boolean = false;
  paused: boolean = false;

  private async pauseAt(checkpoint: string): Promise<void> {
    if (this.checkpoint !== checkpoint || this.paused) return;
    this.paused = true;
    await abilityDelegatorRegistry.getAbilityDelegator().print('ICON_FIXTURE_CHECKPOINT=' + checkpoint);
    await new Promise<void>((_resolve: () => void): void => {});
  }

  async makeTempDir(prefix: string): Promise<string> {
    const path = await super.makeTempDir(prefix);
    if (prefix.endsWith('/generation-XXXXXX')) await this.pauseAt('directory');
    return path;
  }

  async copyFile(source: string, destination: string): Promise<void> {
    await super.copyFile(source, destination);
    if (destination.indexOf('/' + ICON_PACK_GENERATIONS + '/') >= 0 && destination.endsWith('/' + ICON_PACK_ZIP)) {
      await this.pauseAt('zip');
    }
  }

  async writeTextFile(path: string, content: string): Promise<void> {
    if (this.failMetadata && path.indexOf('/' + ICON_PACK_GENERATIONS + '/') >= 0 && path.endsWith('/' + ICON_PACK_META)) {
      throw new Error('SYNTHETIC_METADATA_WRITE_FAILED');
    }
    await super.writeTextFile(path, content);
    if (path.indexOf('/' + ICON_PACK_GENERATIONS + '/') >= 0) {
      if (path.endsWith('/' + ICON_PACK_META)) await this.pauseAt('metadata');
      if (path.endsWith('/committed.json')) await this.pauseAt('commit');
    }
  }

  async syncFile(path: string): Promise<void> {
    await super.syncFile(path);
    if (path.endsWith('/committed.json')) {
      if (this.failCommitSync) throw new Error('SYNTHETIC_POST_FSYNC_FAILURE');
      await this.pauseAt('commit-sync');
    }
  }

  async deleteFile(path: string): Promise<void> {
    if (path.endsWith('/committed.json') && this.failCommitDelete) throw new Error('SYNTHETIC_UNLINK_FAILURE');
    if (path.indexOf('/' + ICON_PACK_GENERATIONS + '/') >= 0 && path.endsWith('/' + ICON_PACK_ZIP)) {
      await this.pauseAt('prune');
    }
    await super.deleteFile(path);
  }

  async removeDir(path: string): Promise<void> {
    if (path.indexOf('/' + ICON_PACK_GENERATIONS + '/generation-') >= 0 && this.failDirectoryDelete) {
      throw new Error('SYNTHETIC_RMDIR_FAILURE');
    }
    await super.removeDir(path);
  }
}

function metadata(timestamp: number, device: string = 'synthetic-device'): FixtureMetadata {
  return { version: 1, timestamp, deviceId: device, deviceName: 'Synthetic Fixture', packs: [],
    enabledPacks: [], deletedPacks: [] };
}

function validOwnedPath(path: string, parent: string, prefix: string): boolean {
  const suffix = path.substring(parent.length + 1);
  return path.startsWith(parent + '/') && suffix.startsWith(prefix) &&
    suffix.length === prefix.length + 6 && /^[A-Za-z0-9]+$/.test(suffix.substring(prefix.length)) &&
    suffix.indexOf('/') < 0;
}

async function printFailure(error: Object): Promise<void> {
  let code = 'UNKNOWN';
  try {
    const value = (error as BusinessError).code;
    if (typeof value === 'number' && [13900002, 13900005, 13900012, 13900020, 13900031, 900001, 900003].includes(value)) {
      code = String(value);
    }
  } catch (_) {}
  await abilityDelegatorRegistry.getAbilityDelegator().print('ICON_FIXTURE_FAILED code=' + code);
}

/** 仅显式注册的自有合成目录；不启动主 Ability、不修改账号、注册表、令牌或偏好。 */
export default function iconPackPublicationDeviceTest(): void {
  describe('IconPackPublicationDeviceTest', () => {
    const app = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
    const parameters = abilityDelegatorRegistry.getArguments().parameters;
    const parameter = (name: string): string => parameters[name] || parameters['-s ' + name] || '';
    const cloudMode = parameter('cloudBackupOwnedFixture') === 'true';
    const phase = parameter('fixturePhase') || 'run';
    const checkpoint = parameter('fixtureCheckpoint') || '';
    const cloudParent = cloudMode ? app.cloudFileDir : app.filesDir;
    const gateway = new NativeFixtureGateway();
    const receiptPath = app.filesDir + '/' + RECEIPT;
    let fixture: FixtureReceipt | undefined = undefined;
    let owned = false;

    const validReceipt = (record: FixtureReceipt): boolean => {
      return record.version === 2 && CHECKPOINTS.includes(record.checkpoint) &&
        (record.cloud === '' || validOwnedPath(record.cloud, cloudParent, '.icon-pub-test-')) &&
        (record.local === '' || validOwnedPath(record.local, app.filesDir, '.icon-pub-local-')) &&
        (record.temp === '' || validOwnedPath(record.temp, app.tempDir, 'icon-pub-temp-'));
    };

    const saveReceipt = async (record: FixtureReceipt): Promise<void> => {
      await gateway.writeTextFile(receiptPath, JSON.stringify(record));
      await gateway.syncFile(receiptPath);
    };

    const loadReceipt = async (): Promise<FixtureReceipt> => {
      const record = JSON.parse(await gateway.readTextFile(receiptPath)) as FixtureReceipt;
      if (!validReceipt(record)) throw new Error('FIXTURE_RECEIPT_INVALID');
      return record;
    }

    const createFixture = async (): Promise<FixtureReceipt> => {
      if (fs.accessSync(receiptPath)) throw new Error('FIXTURE_RECEIPT_ALREADY_EXISTS');
      const record: FixtureReceipt = { version: 2, cloud: '', local: '', temp: '', checkpoint: checkpoint || 'directory' };
      fixture = record;
      record.local = await fs.mkdtemp(app.filesDir + '/.icon-pub-local-XXXXXX');
      owned = true;
      await saveReceipt(record);
      record.temp = await fs.mkdtemp(app.tempDir + '/icon-pub-temp-XXXXXX');
      await saveReceipt(record);
      record.cloud = await fs.mkdtemp(cloudParent + '/.icon-pub-test-XXXXXX');
      await saveReceipt(record);
      return record;
    }

    const cleanFixture = async (record: FixtureReceipt): Promise<void> => {
      if (!validReceipt(record)) throw new Error('FIXTURE_RECEIPT_INVALID');
      let failed = false;
      for (const path of [record.cloud, record.local, record.temp]) {
        if (path.length === 0) continue;
        try { await fs.rmdir(path); } catch (error) {
          if ((error as BusinessError).code !== 13900002) failed = true;
        }
      }
      if (failed) {
        await saveReceipt(record);
        throw new Error('FIXTURE_CLEANUP_FAILED');
      }
      try { await fs.unlink(receiptPath); } catch (error) {
        if ((error as BusinessError).code !== 13900002) throw error as Error;
      }
      owned = false;
    }

    const createZip = async (record: FixtureReceipt, timestamp: number): Promise<string> => {
      const source = await fs.mkdtemp(record.temp + '/source-XXXXXX');
      const zip = record.local + '/synthetic-' + timestamp + '.zip';
      try {
        await fs.mkdir(source + '/user_icons');
        await gateway.writeTextFile(source + '/user_icons/fixture.svg', '<svg xmlns="http://www.w3.org/2000/svg"><text>synthetic</text></svg>');
        await gateway.writeTextFile(source + '/icon_packs_meta.json', JSON.stringify(metadata(timestamp)));
        await zlib.compressFile(source, zip, { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
        await gateway.syncFile(zip);
        return zip;
      } finally {
        await fs.rmdir(source);
      }
    }

    const publication = (record: FixtureReceipt): IconPackPublication => {
      return new IconPackPublication(gateway, record.cloud, CloudBackupDiagnostics.begin(DiagnosticKind.ICON),
        async (path: string, expectedText: string): Promise<boolean> => {
          const dir = await fs.mkdtemp(record.temp + '/verify-XXXXXX');
          try {
            await zlib.decompressFile(path, dir);
            const actual = JSON.parse(await gateway.readTextFile(dir + '/icon_packs_meta.json')) as FixtureMetadata;
            const expected = JSON.parse(expectedText) as FixtureMetadata;
            const svg = await gateway.readTextFile(dir + '/user_icons/fixture.svg');
            return actual.timestamp === expected.timestamp && actual.version === 1 &&
              JSON.stringify(actual.packs) === JSON.stringify(expected.packs) && svg.indexOf('synthetic') >= 0;
          } catch (_) {
            return false;
          } finally {
            await fs.rmdir(dir);
          }
        });
    }

    const readableTimestamp = async (record: FixtureReceipt): Promise<number> => {
      const snapshot = await publication(record).snapshot();
      if (snapshot === undefined) return -1;
      const content = JSON.parse(await gateway.readTextFile(snapshot.metaPath)) as FixtureMetadata;
      return content.timestamp;
    }

    const execute = async (body: (record: FixtureReceipt) => Promise<void>): Promise<void> => {
      let passed = false;
      try {
        await abilityDelegatorRegistry.getAbilityDelegator().print(cloudMode ? 'ICON_FIXTURE_MODE=CLOUD' : 'ICON_FIXTURE_MODE=LOCAL');
        fixture = phase === 'verify' || phase === 'cleanup' ? await loadReceipt() : await createFixture();
        owned = true;
        await body(fixture);
        passed = true;
      } catch (error) {
        await printFailure(error);
      } finally {
        if (owned && fixture !== undefined) {
          gateway.failMetadata = false;
          gateway.failCommitSync = false;
          gateway.failCommitDelete = false;
          gateway.failDirectoryDelete = false;
          try { await cleanFixture(fixture); } catch (error) { passed = false; await printFailure(error); }
        }
      }
      expect(passed).assertTrue();
    }

    if (phase === 'cleanup') {
      it('cleanup_only_owned_fixture', 0, async () => {
        await execute(async (_record: FixtureReceipt): Promise<void> => {});
      });
      return;
    }
    if (phase === 'arm') {
      it('arm_checkpoint_without_touching_existing_backups', 0, async () => {
        await execute(async (record: FixtureReceipt): Promise<void> => {
          if (!CHECKPOINTS.includes(checkpoint)) throw new Error('FIXTURE_CHECKPOINT_INVALID');
          const first = await createZip(record, 1);
          if (!await publication(record).publish(first, JSON.stringify(metadata(1)))) throw new Error('FIXTURE_BASE_PUBLISH_FAILED');
          if (checkpoint === 'prune') {
            const second = await createZip(record, 2);
            if (!await publication(record).publish(second, JSON.stringify(metadata(2)))) throw new Error('FIXTURE_BASE_PUBLISH_FAILED');
          }
          gateway.checkpoint = checkpoint;
          const next = await createZip(record, 3);
          await publication(record).publish(next, JSON.stringify(metadata(3)));
          throw new Error('FIXTURE_CHECKPOINT_NOT_REACHED');
        });
      });
      return;
    }
    if (phase === 'verify') {
      it('restart_preserves_committed_generation_and_owned_cleanup', 0, async () => {
        await execute(async (record: FixtureReceipt): Promise<void> => {
          const actual = await readableTimestamp(record);
          const committed = record.checkpoint === 'commit' || record.checkpoint === 'commit-sync' || record.checkpoint === 'prune';
          const expected = committed ? 3 : 1;
          if (actual !== expected) throw new Error('FIXTURE_RESTART_GENERATION_MISMATCH');
          if (!await publication(record).clear()) throw new Error('FIXTURE_CLEAR_FAILED');
        });
      });
      return;
    }

    it('native_cloud_mkdtemp_fsync_zip_roundtrip_and_repeated_publication', 0, async () => {
      await execute(async (record: FixtureReceipt): Promise<void> => {
        for (const timestamp of [1, 2, 3]) {
          const zip = await createZip(record, timestamp);
          if (!await publication(record).publish(zip, JSON.stringify(metadata(timestamp)))) throw new Error('FIXTURE_PUBLISH_FAILED');
          if (await readableTimestamp(record) !== timestamp) throw new Error('FIXTURE_READBACK_FAILED');
        }
        const ids = await gateway.listFiles(record.cloud + '/' + ICON_PACK_GENERATIONS);
        if (ids.length !== 2) throw new Error('FIXTURE_RETENTION_FAILED');
      });
    });

    it('native_metadata_failure_and_missing_temp_keep_old_zip', 0, async () => {
      await execute(async (record: FixtureReceipt): Promise<void> => {
        const oldZip = await createZip(record, 1);
        if (!await publication(record).publish(oldZip, JSON.stringify(metadata(1)))) throw new Error('FIXTURE_BASE_PUBLISH_FAILED');
        gateway.failMetadata = true;
        const next = await createZip(record, 2);
        if (await publication(record).publish(next, JSON.stringify(metadata(2)))) throw new Error('FIXTURE_FALSE_SUCCESS');
        gateway.failMetadata = false;
        if (await readableTimestamp(record) !== 1) throw new Error('FIXTURE_OLD_LOST');
        await fs.unlink(next);
        if (await publication(record).publish(next, JSON.stringify(metadata(2)))) throw new Error('FIXTURE_FALSE_SUCCESS');
        if (await readableTimestamp(record) !== 1) throw new Error('FIXTURE_OLD_LOST');
      });
    });

    it('native_commit_visible_failure_keeps_new_generation', 0, async () => {
      await execute(async (record: FixtureReceipt): Promise<void> => {
        const first = await createZip(record, 1);
        if (!await publication(record).publish(first, JSON.stringify(metadata(1)))) throw new Error('FIXTURE_BASE_PUBLISH_FAILED');
        gateway.failCommitSync = true;
        const next = await createZip(record, 2);
        if (await publication(record).publish(next, JSON.stringify(metadata(2)))) throw new Error('FIXTURE_FALSE_SUCCESS');
        gateway.failCommitSync = false;
        if (await readableTimestamp(record) !== 2) throw new Error('FIXTURE_COMMIT_LOST');
      });
    });

    it('native_scoped_clear_failure_retries_original_scope', 0, async () => {
      await execute(async (record: FixtureReceipt): Promise<void> => {
        const first = await createZip(record, 1);
        if (!await publication(record).publish(first, JSON.stringify(metadata(1)))) throw new Error('FIXTURE_BASE_PUBLISH_FAILED');
        gateway.failCommitDelete = true;
        if (await publication(record).clear(['synthetic-device'])) throw new Error('FIXTURE_FALSE_SUCCESS');
        gateway.failCommitDelete = false;
        if (!await publication(record).clear(['synthetic-device'])) throw new Error('FIXTURE_SCOPE_RETRY_FAILED');
        const next = await createZip(record, 2);
        if (!await publication(record).publish(next, JSON.stringify(metadata(2)))) throw new Error('FIXTURE_BASE_PUBLISH_FAILED');
        gateway.failDirectoryDelete = true;
        if (await publication(record).clear(['synthetic-device'])) throw new Error('FIXTURE_FALSE_SUCCESS');
        gateway.failDirectoryDelete = false;
        if (!await publication(record).clear(['synthetic-device'])) throw new Error('FIXTURE_SCOPE_RETRY_FAILED');
      });
    });

    it('native_legacy_fixed_name_remains_untouched_after_new_publish', 0, async () => {
      await execute(async (record: FixtureReceipt): Promise<void> => {
        const oldZip = await createZip(record, 1);
        await gateway.copyFile(oldZip, record.cloud + '/' + ICON_PACK_ZIP);
        const legacy = JSON.stringify(metadata(1));
        await gateway.writeTextFile(record.cloud + '/' + ICON_PACK_META, legacy);
        const next = await createZip(record, 2);
        if (!await publication(record).publish(next, JSON.stringify(metadata(2)))) throw new Error('FIXTURE_PUBLISH_FAILED');
        if (await gateway.readTextFile(record.cloud + '/' + ICON_PACK_META) !== legacy) throw new Error('FIXTURE_LEGACY_CHANGED');
        if (!await publication(record).clear(['synthetic-device'])) throw new Error('FIXTURE_CLEAR_FAILED');
        if (await readableTimestamp(record) !== 1) throw new Error('FIXTURE_LEGACY_LOST');
      });
    });
  });
}

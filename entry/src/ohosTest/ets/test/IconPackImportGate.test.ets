import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import {
  FileIoFsGateway, IconPackImportMutex, IconPackZipGateReject, IconPackZipEntryInfo, ZipRawEntryInfo,
  InstalledPackInfo, gateZipTotalSize, gateZipRawEntries, gateZipCentralIndex,
  gateExtractedPackEntries, collectIconPackDirEntries, removeIconPackDirBestEffort
} from 'common';
import type { ZipIndex } from '../../../main/ets/components/IconPackZipReader';
import { makeImportFixture } from './IconPackImportFixtures';

interface ZipReaderModule {
  readZipIndex(bytes: ArrayBuffer): Promise<ZipIndex>;
}

function centralEntries(index: ZipIndex): IconPackZipEntryInfo[] {
  const result: IconPackZipEntryInfo[] = [];
  for (const item of index.entries) {
    const mapped: IconPackZipEntryInfo = {
      relativePath: item.relativePath, sizeBytes: item.sizeBytes, isDirectory: item.isDirectory
    };
    result.push(mapped);
  }
  return result;
}

function originalEntries(index: ZipIndex): ZipRawEntryInfo[] {
  const result: ZipRawEntryInfo[] = [];
  for (const item of index.rawEntries) {
    const mapped: ZipRawEntryInfo = {
      rawName: item.rawName, sizeBytes: item.sizeBytes, isDirectory: item.isDirectory
    };
    result.push(mapped);
  }
  return result;
}

function requireTrue(value: boolean): void {
  if (!value) throw new Error('IMPORT_FIXTURE_ASSERT_FAILED');
}

async function readArchive(path: string): Promise<ArrayBuffer> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const size = (await fs.stat(file.fd)).size;
    const bytes = new ArrayBuffer(size);
    let offset = 0;
    while (offset < size) {
      const chunk = new ArrayBuffer(Math.min(65536, size - offset));
      const length = await fs.read(file.fd, chunk);
      if (length <= 0) throw new Error('IMPORT_FIXTURE_SHORT_READ');
      new Uint8Array(bytes, offset, length).set(new Uint8Array(chunk, 0, length));
      offset += length;
    }
    return bytes;
  } finally {
    await fs.close(file);
  }
}

/** 真实 JSZip、生产 reader/gate 与原生落盘；不调用真实注册表、令牌、账号或偏好。 */
export default function iconPackImportGateDeviceTest(): void {
  describe('IconPackImportGateDeviceTest', () => {
    const app = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
    const gateway = new FileIoFsGateway();
    const loadReader = async (): Promise<ZipReaderModule> => {
      return await import('../../../main/ets/components/IconPackZipReader');
    };
    const execute = async (body: (dir: string) => Promise<void>, allocate: boolean = true): Promise<void> => {
      let dir = '';
      let passed = false;
      try {
        await abilityDelegatorRegistry.getAbilityDelegator().print('ICON_IMPORT_FIXTURE_MODE=ISOLATED');
        if (allocate) dir = await fs.mkdtemp(app.tempDir + '/icon-import-test-XXXXXX');
        await body(dir);
        passed = true;
      } catch (_) {
        await abilityDelegatorRegistry.getAbilityDelegator().print('ICON_IMPORT_FIXTURE_FAILED');
      } finally {
        if (dir.length > 0) {
          try {
            await removeIconPackDirBestEffort(dir);
            if (fs.accessSync(dir)) passed = false;
          } catch (_) {
            passed = false;
            await abilityDelegatorRegistry.getAbilityDelegator().print('ICON_IMPORT_FIXTURE_CLEANUP_FAILED');
          }
        }
      }
      expect(passed).assertTrue();
    };

    it('native_valid_archive_precheck_extract_recheck_without_registry', 0, async () => {
      await execute(async (dir: string): Promise<void> => {
        const path = dir + '/fixture.zip';
        const bytes = await makeImportFixture('valid');
        await gateway.writeBinaryFile(path, new Uint8Array(bytes));
        await gateway.syncFile(path);
        requireTrue(gateZipTotalSize(await zlib.getOriginalSize(path)).ok);
        const reader = await loadReader();
        const index = await reader.readZipIndex(await readArchive(path));
        requireTrue(gateZipRawEntries(originalEntries(index)).ok);
        requireTrue(gateZipCentralIndex(centralEntries(index), index.packJsonContent, []).ok);
        const out = dir + '/extract';
        await fs.mkdir(out);
        await zlib.decompressFile(path, out);
        requireTrue(gateExtractedPackEntries(await collectIconPackDirEntries(out)).ok);
        requireTrue((await gateway.readTextFile(out + '/icons/fixture.svg')).indexOf('synthetic') >= 0);
      });
    });

    for (const kind of ['file-path', 'directory-path']) {
      it('native_original_' + kind + '_rejected_without_extraction', 0, async () => {
        await execute(async (dir: string): Promise<void> => {
          const reader = await loadReader();
          const index = await reader.readZipIndex(await makeImportFixture(kind));
          const raw = originalEntries(index);
          requireTrue(raw.some((item: ZipRawEntryInfo): boolean => item.rawName.indexOf('..') >= 0));
          const verdict = gateZipRawEntries(raw);
          requireTrue(!verdict.ok && verdict.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH);
          requireTrue((await fs.listFile(dir)).length === 0);
        });
      });
    }

    for (const kind of ['declared-meta', 'actual-meta']) {
      it('native_' + kind + '_fixed_size_rejection_without_extraction', 0, async () => {
        await execute(async (dir: string): Promise<void> => {
          const reader = await loadReader();
          let rejected = false;
          try {
            await reader.readZipIndex(await makeImportFixture(kind));
          } catch (error) {
            rejected = (error as Error).name === 'ICON_PACK_META_TOO_LARGE';
          }
          requireTrue(rejected);
          requireTrue((await fs.listFile(dir)).length === 0);
        });
      });
    }

    it('native_shared_mutex_and_synthetic_duplicate_identity', 0, async () => {
      await execute(async (_dir: string): Promise<void> => {
        requireTrue(!IconPackImportMutex.isHeld());
        requireTrue(IconPackImportMutex.tryAcquire());
        try {
          requireTrue(!IconPackImportMutex.tryAcquire());
          const reader = await loadReader();
          const index = await reader.readZipIndex(await makeImportFixture('valid'));
          const same: InstalledPackInfo = { name: 'Synthetic Import Fixture', version: '1' };
          const other: InstalledPackInfo = { name: 'Synthetic Import Fixture', version: '2' };
          const verdict = gateZipCentralIndex(centralEntries(index), index.packJsonContent, [same]);
          requireTrue(!verdict.ok && verdict.reject === IconPackZipGateReject.DUPLICATE_NAME_VERSION);
          requireTrue(gateZipCentralIndex(centralEntries(index), index.packJsonContent, [other]).ok);
        } finally {
          IconPackImportMutex.release();
        }
        requireTrue(!IconPackImportMutex.isHeld());
      });
    });

    it('readonly_audit_publication_receipt_and_exact_fixture_roots_absent', 0, async () => {
      await execute(async (_dir: string): Promise<void> => {
        requireTrue(!fs.accessSync(app.filesDir + '/.icon-publication-device-fixture.json'));
        for (const parent of [app.filesDir, app.cloudFileDir]) {
          const names = await fs.listFile(parent);
          requireTrue(!names.some((name: string): boolean =>
            /^\.icon-pub-(test|local)-[A-Za-z0-9]{6}$/.test(name)));
        }
        const tempNames = await fs.listFile(app.tempDir);
        requireTrue(!tempNames.some((name: string): boolean =>
          /^(icon-pub-source|icon-pub-verify|icon-pub-temp|icon-import-test)-[A-Za-z0-9]{6}$/.test(name)));
        await abilityDelegatorRegistry.getAbilityDelegator().print('ICON_FIXTURE_CLEANUP=AUDITED_ABSENT');
      }, false);
    });
  });
}

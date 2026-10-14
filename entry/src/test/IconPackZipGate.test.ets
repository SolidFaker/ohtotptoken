import { describe, it, expect } from '@ohos/hypium';
import {
  IconPackZipGateLimits, IconPackZipGateReject, gateZipTotalSize, gateExtractedPackEntries,
  gateZipCentralIndex, gatePackIdentity, gateZipRawEntries, mapGetOriginalSizeError,
  IconPackImportMutex, IconPackZipEntryInfo, InstalledPackInfo, ZipRawEntryInfo
} from 'common';

/** 门控拒绝原因 → 用户文案（common 四语言资源）。 */
class GateSyntheticZlibError extends Error {
  code: number;
  constructor(code: number) {
    super('synthetic zlib failure');
    this.code = code;
  }
}

function entry(relativePath: string, sizeBytes: number): IconPackZipEntryInfo {
  const item: IconPackZipEntryInfo = { relativePath: relativePath, sizeBytes: sizeBytes, isDirectory: false };
  return item;
}

function dirEntry(relativePath: string): IconPackZipEntryInfo {
  const item: IconPackZipEntryInfo = { relativePath: relativePath, sizeBytes: 0, isDirectory: true };
  return item;
}

function installed(name: string, version: string): InstalledPackInfo {
  const item: InstalledPackInfo = { name: name, version: version };
  return item;
}

function rawEntry(rawName: string, sizeBytes: number, isDirectory: boolean): ZipRawEntryInfo {
  const item: ZipRawEntryInfo = { rawName: rawName, sizeBytes: sizeBytes, isDirectory: isDirectory };
  return item;
}

const VALID_PACK_JSON = '{"name":"aegis-icons","version":20260701}';

export default function iconPackZipGateTest() {
  describe('iconPackZipGateTest', () => {
    it('total_size_gate_allows_normal_pack_and_rejects_oversize', 0, () => {
      expect(gateZipTotalSize(1024 * 1024).ok).assertTrue();
      expect(gateZipTotalSize(IconPackZipGateLimits.MAX_TOTAL_UNCOMPRESSED_BYTES).ok).assertTrue();
      const over = gateZipTotalSize(IconPackZipGateLimits.MAX_TOTAL_UNCOMPRESSED_BYTES + 1);
      expect(over.ok).assertFalse();
      expect(over.reject === IconPackZipGateReject.TOO_LARGE_TOTAL).assertTrue();
    });

    it('total_size_gate_rejects_invalid_measurements_as_io_error', 0, () => {
      expect(gateZipTotalSize(-1).reject === IconPackZipGateReject.IO_ERROR).assertTrue();
      expect(gateZipTotalSize(Number.NaN).reject === IconPackZipGateReject.IO_ERROR).assertTrue();
    });

    it('zlib_error_mapping_buckets_damage_and_unknown_codes', 0, () => {
      expect(mapGetOriginalSizeError(new GateSyntheticZlibError(900003))
        === IconPackZipGateReject.NOT_ZIP_OR_DAMAGED).assertTrue();
      expect(mapGetOriginalSizeError(new GateSyntheticZlibError(900001))
        === IconPackZipGateReject.NOT_ZIP_OR_DAMAGED).assertTrue();
      expect(mapGetOriginalSizeError(new GateSyntheticZlibError(13900020))
        === IconPackZipGateReject.IO_ERROR).assertTrue();
    });

    it('extracted_gate_requires_root_pack_json', 0, () => {
      const good = gateExtractedPackEntries([entry('pack.json', 256), entry('icons/1_Primary/a.svg', 900)]);
      expect(good.ok).assertTrue();
      const missing = gateExtractedPackEntries([entry('icons/1_Primary/a.svg', 900), entry('meta/pack.json', 256)]);
      expect(missing.ok).assertFalse();
      expect(missing.reject === IconPackZipGateReject.MISSING_PACK_META).assertTrue();
      const empty = gateExtractedPackEntries([]);
      expect(empty.reject === IconPackZipGateReject.MISSING_PACK_META).assertTrue();
    });

    it('extracted_gate_enforces_count_single_size_and_total_caps', 0, () => {
      const many: IconPackZipEntryInfo[] = [];
      for (let index = 0; index <= IconPackZipGateLimits.MAX_EXTRACTED_FILE_COUNT; index++) {
        many.push(entry(`icons/i${index}.svg`, 1));
      }
      many.unshift(entry('pack.json', 10));
      expect(gateExtractedPackEntries(many).reject === IconPackZipGateReject.ENTRY_OVERFLOW).assertTrue();

      const single = gateExtractedPackEntries([
        entry('pack.json', 10), entry('icons/huge.png', IconPackZipGateLimits.MAX_SINGLE_FILE_BYTES + 1)
      ]);
      expect(single.reject === IconPackZipGateReject.FILE_TOO_LARGE).assertTrue();

      const items: IconPackZipEntryInfo[] = [entry('pack.json', 10)];
      for (let index = 0; index < 100; index++) {
        items.push(entry(`icons/bulk${index}.svg`, IconPackZipGateLimits.MAX_TOTAL_UNCOMPRESSED_BYTES / 50));
      }
      expect(gateExtractedPackEntries(items).reject === IconPackZipGateReject.TOO_LARGE_TOTAL).assertTrue();
    });

    it('extracted_gate_rejects_escape_paths_and_invalid_sizes', 0, () => {
      const slip = gateExtractedPackEntries([entry('pack.json', 1), entry('../outside.svg', 1)]);
      expect(slip.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      const absolute = gateExtractedPackEntries([entry('pack.json', 1), entry('/etc/steal.svg', 1)]);
      expect(absolute.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      const backslash = gateExtractedPackEntries([entry('pack.json', 1), entry('icons\\evil.svg', 1)]);
      expect(backslash.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      const nul = gateExtractedPackEntries([entry('pack.json', 1), entry('ico\u0000ns/a.svg', 1)]);
      expect(nul.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      const negative = gateExtractedPackEntries([entry('pack.json', 1), entry('icons/a.svg', -5)]);
      expect(negative.reject === IconPackZipGateReject.IO_ERROR).assertTrue();
    });

    it('extracted_gate_allows_exactly_at_limits', 0, () => {
      const items: IconPackZipEntryInfo[] = [entry('pack.json', IconPackZipGateLimits.MAX_SINGLE_FILE_BYTES)];
      for (let index = 1; index < IconPackZipGateLimits.MAX_EXTRACTED_FILE_COUNT; index++) {
        items.push(entry(`icons/i${index}.svg`, 1));
      }
      expect(items.length).assertEqual(IconPackZipGateLimits.MAX_EXTRACTED_FILE_COUNT);
      expect(gateExtractedPackEntries(items).ok).assertTrue();

      const segments: string[] = [];
      for (let index = 0; index < IconPackZipGateLimits.MAX_ENTRY_DEPTH - 1; index++) {
        segments.push(`d${index}`);
      }
      segments.push('f.svg');
      const atDepth = gateExtractedPackEntries([entry('pack.json', 1), entry(segments.join('/'), 1)]);
      expect(atDepth.ok).assertTrue();
      segments.push('too-deep.svg');
      const beyond = gateExtractedPackEntries([entry('pack.json', 1), entry(segments.join('/'), 1)]);
      expect(beyond.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
    });

    it('total_size_gate_rejects_infinite_measurement', 0, () => {
      expect(gateZipTotalSize(Number.POSITIVE_INFINITY).reject === IconPackZipGateReject.IO_ERROR).assertTrue();
    });

    it('central_index_gate_checks_paths_meta_and_duplicate_identity', 0, () => {
      const good = [dirEntry('icons/'), entry('pack.json', 256), entry('icons/1_Primary/a.svg', 900)];
      expect(gateZipCentralIndex(good, VALID_PACK_JSON, []).ok).assertTrue();

      const noMeta = gateZipCentralIndex([entry('icons/a.svg', 1)], null, []);
      expect(noMeta.reject === IconPackZipGateReject.MISSING_PACK_META).assertTrue();

      const slipDir = gateZipCentralIndex([dirEntry('../escape/'), entry('pack.json', 1)], VALID_PACK_JSON, []);
      expect(slipDir.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();

      const zeroByteFiles: IconPackZipEntryInfo[] = [entry('pack.json', 1)];
      for (let index = 0; index < IconPackZipGateLimits.MAX_EXTRACTED_FILE_COUNT; index++) {
        zeroByteFiles.push(entry(`empty${index}.svg`, 0));
      }
      expect(gateZipCentralIndex(zeroByteFiles, VALID_PACK_JSON, [])
        .reject === IconPackZipGateReject.ENTRY_OVERFLOW).assertTrue();

      const duplicate = gateZipCentralIndex(
        [entry('pack.json', 256)], VALID_PACK_JSON, [installed('aegis-icons', '20260701')]);
      expect(duplicate.reject === IconPackZipGateReject.DUPLICATE_NAME_VERSION).assertTrue();

      const otherVersion = gateZipCentralIndex(
        [entry('pack.json', 256)], VALID_PACK_JSON, [installed('aegis-icons', '20260501')]);
      expect(otherVersion.ok).assertTrue();
    });

    it('identity_gate_parses_meta_and_normalizes_versions', 0, () => {
      expect(gatePackIdentity(VALID_PACK_JSON, [installed('aegis-icons', '20260701')])
        .reject === IconPackZipGateReject.DUPLICATE_NAME_VERSION).assertTrue();
      expect(gatePackIdentity('{"name":"aegis-icons","version":"20260701"}',
        [installed('aegis-icons', '20260701')]
      ).reject === IconPackZipGateReject.DUPLICATE_NAME_VERSION).assertTrue();
      expect(gatePackIdentity(VALID_PACK_JSON, []).ok).assertTrue();
      expect(gatePackIdentity(VALID_PACK_JSON, [installed('other-pack', '20260701')]).ok).assertTrue();
      expect(gatePackIdentity('not json', []).reject === IconPackZipGateReject.INVALID_PACK_META).assertTrue();
      expect(gatePackIdentity('[]', []).reject === IconPackZipGateReject.INVALID_PACK_META).assertTrue();
      expect(gatePackIdentity('{"version":123}', []).reject === IconPackZipGateReject.INVALID_PACK_META).assertTrue();
      expect(gatePackIdentity('{"name":"x"}', [installed('x', '0')])
        .reject === IconPackZipGateReject.DUPLICATE_NAME_VERSION).assertTrue();
    });

    it('raw_gate_rejects_parent_traversal_in_file_and_directory_entries', 0, () => {
      // 文件条目原始路径含 `..`（jszip 归一化后不可见的走私形态）。
      const smuggledMeta = gateZipRawEntries([rawEntry('x/../pack.json', 10, false)]);
      expect(smuggledMeta.ok).assertFalse();
      expect(smuggledMeta.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      // 目录条目原始路径含 `..`：unsafeOriginalName 不覆盖目录条目，只有原始中央目录门能拦。
      const smuggledDir = gateZipRawEntries([rawEntry('../evil/', 0, true)]);
      expect(smuggledDir.ok).assertFalse();
      expect(smuggledDir.reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      // 合法结构（嵌套目录 + 根级 pack.json）原样通过。
      expect(gateZipRawEntries([
        rawEntry('pack.json', 256, false),
        rawEntry('icons/', 0, true),
        rawEntry('icons/1_Primary/a.svg', 900, false)
      ]).ok).assertTrue();
    });

    it('raw_gate_rejects_backslash_nul_absolute_and_depth', 0, () => {
      expect(gateZipRawEntries([rawEntry('icons\\a.svg', 1, false)])
        .reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      expect(gateZipRawEntries([rawEntry('a\u0000b.svg', 1, false)])
        .reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      expect(gateZipRawEntries([rawEntry('/etc/pack.json', 1, false)])
        .reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      const deep: ZipRawEntryInfo[] = [];
      let deepName = '';
      for (let index = 0; index <= IconPackZipGateLimits.MAX_ENTRY_DEPTH; index++) {
        deepName += `d${index}/`;
      }
      deep.push(rawEntry(deepName, 0, true));
      expect(gateZipRawEntries(deep).reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      expect(gateZipRawEntries([rawEntry('', 0, false)])
        .reject === IconPackZipGateReject.UNSAFE_ENTRY_PATH).assertTrue();
      // 中文/多字节目录名不受影响（UTF-8 多字节序列不含 ASCII 结构字符）。
      expect(gateZipRawEntries([rawEntry('图标/', 0, true), rawEntry('图标/主.svg', 3, false)]).ok).assertTrue();
    });

    it('import_mutex_is_process_wide_try_acquire_without_clock', 0, () => {
      IconPackImportMutex.release();
      expect(IconPackImportMutex.tryAcquire()).assertTrue();
      expect(IconPackImportMutex.isHeld()).assertTrue();
      expect(IconPackImportMutex.tryAcquire()).assertFalse();
      IconPackImportMutex.release();
      expect(IconPackImportMutex.isHeld()).assertFalse();
      expect(IconPackImportMutex.tryAcquire()).assertTrue();
      IconPackImportMutex.release();
      // 重复 release 幂等（异常路径双释放不留死锁）。
      IconPackImportMutex.release();
      expect(IconPackImportMutex.tryAcquire()).assertTrue();
      IconPackImportMutex.release();
    });
  });
}

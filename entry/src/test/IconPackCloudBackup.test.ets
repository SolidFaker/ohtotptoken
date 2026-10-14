import { describe, it, expect } from '@ohos/hypium';
import {
  AppPreference,
  AegisIconPack,
  BUILTIN_DEFAULT_PACK_ID,
  CloudBackupOperationGate,
  CloudBackupOperationKind,
  CloudFileCacher,
  HuaweiAccountManager,
  IconPackArchiver,
  IconPackBackupStatus,
  IconPackCloudBackup,
  IconPackDevicePort,
  IconPackRegistry,
  IconPackRestoreResult,
  IconPackSyncState,
  IconPackSyncStarter,
  PREF_KEYS,
  mergeEnabledPacks,
} from 'common';
import { MemoryFs } from './fakes/BackupFakes';
import { DownloadAwareFs, FakeFileCacher, cloudTestTurn } from './fakes/CloudCacheFakes';

/**
 * 图标包云备份状态机测试（Phase 2 FsGateway + IconPackArchiver 端口注入）。
 *
 * 覆盖：IDLE→X→IDLE 互斥转换（含并发拒绝与失败复位）、备份流程
 * （staging/zip/伴生元数据）、5 分钟去抖与云端较新判定、
 * 清理流程、状态查询降级、enabledPacks 合并策略（纯函数）。
 */

/** 可门控的假压缩器：compress 挂起直到测试放行，用于构造并发窗口 */
class GatedArchiver implements IconPackArchiver {
  compressCalls: number = 0;
  decompressCalls: number = 0;
  private release: (() => void) | null = null;
  private gate: Promise<void> | null = null;
  hang: boolean = false;

  compress(_srcDir: string, _destZip: string): Promise<void> {
    this.compressCalls++;
    if (this.hang) {
      this.gate = new Promise<void>((resolve: () => void) => {
        this.release = resolve;
      });
      return this.gate;
    }
    return Promise.resolve();
  }

  decompress(_zipPath: string, _destDir: string): Promise<void> {
    this.decompressCalls++;
    return Promise.resolve();
  }

  releaseGate(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }
}

/** 假设备端口：LocalUnit 下 deviceInfo API 不可用 */
class FakeIconDevice implements IconPackDevicePort {
  deviceId(): string {
    return 'test-odid';
  }

  deviceName(): string {
    return 'TestDevice';
  }
}

/**
 * 假解压器：decompress 时把预置的"zip 内容"写入目标目录（模拟解压产物）。
 * 键为相对路径，值为文件内容。直接写 MemoryFs 公共字段（与既有播种惯例一致），
 * 并逐级登记父目录——真实解压产物包含目录，递归拷贝依赖 dirs 判定 isDirectory。
 */
class FakeUnpackArchiver implements IconPackArchiver {
  contents: Map<string, string> = new Map();
  decompressCalls: number = 0;
  compressCalls: number = 0;
  fs: MemoryFs;

  constructor(fs: MemoryFs) {
    this.fs = fs;
  }

  compress(srcDir: string, _destZip: string): Promise<void> {
    this.compressCalls++;
    if (this.contents.has('icon_packs_meta.json')) {
      const metadata = this.fs.files.get(srcDir + '/icon_packs_meta.json');
      if (metadata !== undefined) this.contents.set('icon_packs_meta.json', metadata);
    }
    return Promise.resolve();
  }

  decompress(_zipPath: string, destDir: string): Promise<void> {
    this.decompressCalls++;
    this.contents.forEach((content: string, relPath: string) => {
      // 逐级登记父目录（与真实解压一致，供递归拷贝识别子目录）
      const segments = relPath.split('/');
      let prefix = destDir;
      for (let i = 0; i < segments.length - 1; i++) {
        prefix = `${prefix}/${segments[i]}`;
        this.fs.dirs.add(prefix);
      }
      this.fs.files.set(`${destDir}/${relPath}`, content);
    });
    return Promise.resolve();
  }
}

/** ZIP 解压也必须真正尝试普通读取，不能由空实现伪造恢复成功。 */
class ReadCheckingUnpackArchiver extends FakeUnpackArchiver {
  async decompress(zipPath: string, destDir: string): Promise<void> {
    await this.fs.readTextFile(zipPath);
    await super.decompress(zipPath, destDir);
  }
}

/** 可门控且可产出解压产物的假压缩器：兼具备份并发门控与发布校验产物。 */
class GatedUnpackArchiver extends FakeUnpackArchiver {
  hang: boolean = false;
  private release: (() => void) | null = null;

  compress(srcDir: string, destZip: string): Promise<void> {
    const compressed = super.compress(srcDir, destZip);
    if (this.hang) {
      return new Promise<void>((resolve: () => void) => {
        this.release = resolve;
      });
    }
    return compressed;
  }

  releaseGate(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }
}

/** 假图标包注册表：内存维护包列表与启用列表，记录全部调用供断言。 */
class FakeIconRegistry implements IconPackRegistry {
  packs: AegisIconPack[] = [];
  enabledPacks: string[] = [];
  removedPacks: string[] = [];
  addedPackPaths: string[] = [];
  loadUserIconsCalls: string[] = [];
  reloadEnabledPacksCalls: number = 0;
  lastAppliedPacks: string[] = [];
  /** addPackFromDevice 对这些路径抛错（模拟损坏包） */
  failAddFor: Set<string> = new Set();
  failRemoveFor: Set<string> = new Set();
  failLoadUserIcons: boolean = false;
  failReloadEnabledPacks: boolean = false;

  listPacks(): AegisIconPack[] {
    return this.packs;
  }

  async loadUserIcons(userIconDir: string): Promise<void> {
    this.loadUserIconsCalls.push(userIconDir);
    if (this.failLoadUserIcons) throw new Error('user icons unavailable');
  }

  async addPackFromDevice(path: string): Promise<void> {
    if (this.failAddFor.has(path)) {
      throw new Error('corrupt pack');
    }
    this.addedPackPaths.push(path);
    const pack = new AegisIconPack();
    pack.uuid = 'dyn_' + path.split('/').pop();
    pack.on_device_path = path;
    this.packs.push(pack);
  }

  async removePack(pack: AegisIconPack): Promise<void> {
    if (this.failRemoveFor.has(pack.uuid)) throw new Error('pack removal unavailable');
    this.removedPacks.push(pack.uuid);
    this.packs = this.packs.filter(p => p.on_device_path !== pack.on_device_path);
  }

  getEnabledPacks(): string[] {
    return this.enabledPacks;
  }

  setEnabledPacks(packs: string[]): void {
    this.enabledPacks = packs;
    this.lastAppliedPacks = packs;
  }

  reloadEnabledPacksFromPreference(): void {
    this.reloadEnabledPacksCalls++;
    if (this.failReloadEnabledPacks) throw new Error('enabled packs unavailable');
    // 与生产语义一致：恢复前以偏好内容为干净基线
    this.enabledPacks = AppPreference.loadEnabledPacks();
  }
}

function bindDepsWithRegistry(fs: MemoryFs, archiver: IconPackArchiver,
  registry: FakeIconRegistry): void {
  IconPackCloudBackup.getInstance().useDepsForTest({
    fs: fs,
    archiver: archiver,
    device: new FakeIconDevice(),
    registry: registry,
    filesDir: '/data/files',
    cloudDir: '/cloud',
    cacheDir: '/data/cache',
  });
}

function bindDeps(fs: MemoryFs, archiver: IconPackArchiver): void {
  IconPackCloudBackup.getInstance().useDepsForTest({
    fs: fs,
    archiver: archiver,
    device: new FakeIconDevice(),
    registry: new FakeIconRegistry(),
    filesDir: '/data/files',
    cloudDir: '/cloud',
    cacheDir: '/data/cache',
  });
}


class FakeIconSync implements IconPackSyncStarter {
  fail: boolean = false;
  accepted: boolean = true;
  calls: number = 0;

  async start(): Promise<boolean> {
    this.calls++;
    if (this.fail) {
      throw new Error('sync unavailable');
    }
    return this.accepted;
  }
}

/** 旧 cacher 不提供安全状态；失败不能被视为已经排空。 */
class UnconfirmedIconCache implements CloudFileCacher {
  calls: string[] = [];
  async cache(path: string): Promise<void> {
    this.calls.push(path);
    throw new Error('cache safety unavailable');
  }
}

function bindCloudDeps(fs: DownloadAwareFs, cache: CloudFileCacher | undefined, sync: FakeIconSync,
  archiver: IconPackArchiver = new GatedArchiver()): void {
  IconPackCloudBackup.getInstance().useDepsForTest({
    fs: fs, cache: cache, sync: sync, archiver: archiver, device: new FakeIconDevice(),
    registry: new FakeIconRegistry(), filesDir: '/data/files', cloudDir: '/cloud', cacheDir: '/data/cache',
  });
}

function resetSingleton(): void {
  IconPackCloudBackup.getInstance().resetForTest();
  AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '');
}

/** 让出一轮事件循环（等待挂起操作完成状态迁移，避免用例间竞态） */
function delayForTurn(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), 1);
  });
}

export default function iconPackCloudBackupTest() {
  describe('iconPackCloudBackupTest', () => {
    it('backup_full_flow_writes_zip_meta_and_timestamp', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      // 备份端发布校验要求暂存 zip 可解压且内部元数据可解析
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":1,"enabledPacks":["p1"],"deletedPacks":[],"packs":[]}');
      bindDeps(fs, archiver);
      // 本地有图标包内容；假压缩器不产 zip，预置供 copyFile 到 cloudDir
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertTrue();
      expect(archiver.compressCalls).assertEqual(1);
      // zip 与伴生元数据文件落到 cloudDir
      const generation = '/cloud/.icon_packs_generations/generation-000001';
      expect(fs.files.has(generation + '/icon_packs_backup.zip')).assertTrue();
      expect(fs.files.has(generation + '/icon_packs_sync_meta.json')).assertTrue();
      const meta = fs.files.get(generation + '/icon_packs_sync_meta.json') ?? '';
      // 伴生元数据含设备与包列表字段
      expect(meta.includes('"deviceName":"TestDevice"')).assertTrue();
      expect(meta.includes('"packs"')).assertTrue();
      // 时间戳记录（防抖基准）
      const lastTime = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
      expect(lastTime.length > 0).assertTrue();
      expect(fs.files.has(generation + '/committed.json')).assertTrue();
      expect(fs.publishAttempts.length).assertEqual(0);
      expect(fs.replaceAttempts.length).assertEqual(0);
      expect(fs.files.has('/cloud/.icon_packs_backup_pending.zip')).assertFalse();
      // staging 目录清理
      expect(fs.files.has('/data/cache/icon_pack_staging/icon_packs_meta.json')).assertFalse();
    });

    it('backup_without_content_skips_cleanly', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertTrue();
      expect(archiver.compressCalls).assertEqual(0);
      expect(fs.files.size).assertEqual(0);
    });

    it('backup_failure_returns_false_and_resets_state_to_idle', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.failWrite = true;

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertFalse();
      // 失败也必须回到 IDLE，否则状态机永久锁死
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('publish_verify_failure_keeps_existing_zip_and_old_meta', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      // GatedArchiver.decompress 不产内容 → 暂存 zip 校验失败
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'new-zip');
      // 云端既有好 zip（含不可再生自定义图标）与旧 meta
      fs.files.set('/cloud/icon_packs_backup.zip', 'old-good-zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":100}');

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertFalse();
      // 旧 zip 与旧 meta 原样保留；未提交同步
      expect(fs.files.get('/cloud/icon_packs_backup.zip')).assertEqual('old-good-zip');
      expect(fs.files.get('/cloud/icon_packs_sync_meta.json')).assertEqual('{"version":1,"timestamp":100}');
      expect(fs.replacedPairs.length).assertEqual(0);
      // 暂存残片已回收，状态机复位
      expect(fs.files.has('/cloud/.icon_packs_backup_pending.zip')).assertFalse();
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('publish_copy_verify_and_move_failures_do_not_copy_formal_zip_or_commit_success', 0, async () => {
      // move 用例只注入修改目标前失败，不模拟 SDK 中途失败或真机杀进程。
      for (const failure of [0, 1, 2]) {
        resetSingleton();
        const fs = new MemoryFs();
        const archiver = new FakeUnpackArchiver(fs);
        const sync = new FakeIconSync();
        if (failure !== 1) {
          archiver.contents.set('icon_packs_meta.json', '{"packs":[],"enabledPacks":[]}');
        }
        IconPackCloudBackup.getInstance().useDepsForTest({
          fs: fs, archiver: archiver, sync: sync, device: new FakeIconDevice(),
          registry: new FakeIconRegistry(), filesDir: '/data/files', cloudDir: '/cloud', cacheDir: '/data/cache',
        });
        fs.files.set('/data/files/icon_packs/pack.json', '{}');
        fs.files.set('/data/cache/icon_packs_backup.zip', 'new-zip');
        fs.files.set('/cloud/icon_packs_backup.zip', 'old-good-zip');
        fs.files.set('/cloud/icon_packs_sync_meta.json', '{"timestamp":100}');
        AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '100');
        if (failure === 0) fs.failCopyFor.add('/data/cache/icon_packs_backup.zip');
        if (failure === 2) fs.failSyncFor.add('/cloud/.icon_packs_generations/generation-000001/icon_packs_backup.zip');

        expect(await IconPackCloudBackup.getInstance().backupIconPacks()).assertFalse();
        expect(fs.files.get('/cloud/icon_packs_backup.zip')).assertEqual('old-good-zip');
        expect(fs.files.get('/cloud/icon_packs_sync_meta.json')).assertEqual('{"timestamp":100}');
        expect(fs.copiedPairs.some(pair => pair.endsWith('->/cloud/icon_packs_backup.zip'))).assertFalse();
        expect(fs.replaceAttempts.length).assertEqual(0);
        expect(fs.publishAttempts.length).assertEqual(0);
        expect(fs.replacedPairs.length).assertEqual(0);
        expect(fs.written.has('/cloud/icon_packs_sync_meta.json')).assertFalse();
        expect(fs.files.has('/cloud/.icon_packs_backup_pending.zip')).assertFalse();
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('100');
        expect(sync.calls).assertEqual(0);
        expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      }
    });

    it('publish_temporary_cleanup_failure_does_not_sync_or_advance_time', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const archiver = new FakeUnpackArchiver(fs);
      const sync = new FakeIconSync();
      archiver.contents.set('icon_packs_meta.json', '{"packs":[],"enabledPacks":[]}');
      bindCloudDeps(fs, new FakeFileCacher(fs), sync, archiver);
      fs.files.set('/data/files/icon_packs/pack.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');
      // 暂存解压试读后清理失败：不得移动正式 zip；另一用户文件/陌生云残片不受影响。
      fs.failDeleteFor.add('/data/cache/icon_pack_publish_verify/icon_packs_meta.json');
      fs.files.set('/cloud/unowned_pending.zip', 'foreign');
      fs.files.set('/data/files/user_icons/existing.svg', 'existing');
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '100');

      expect(await IconPackCloudBackup.getInstance().backupIconPacks()).assertFalse();
      expect(fs.replaceAttempts.length).assertEqual(0);
      expect(sync.calls).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('100');
      expect(fs.files.get('/cloud/unowned_pending.zip')).assertEqual('foreign');
      expect(fs.files.get('/data/files/user_icons/existing.svg')).assertEqual('existing');
    });

    it('collection_copy_failure_aborts_backup_before_publish', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      bindDeps(fs, archiver);
      fs.files.set('/data/files/icon_packs/a.json', 'a');
      fs.files.set('/data/files/icon_packs/b.json', 'b');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');
      fs.failCopyFor.add('/data/files/icon_packs/b.json');

      const ok = await IconPackCloudBackup.getInstance().backupIconPacks();
      expect(ok).assertFalse();
      // 收集不完整：不压缩、不发布、不写伴生元数据（缺文件不得假成功）
      expect(archiver.compressCalls).assertEqual(0);
      expect(fs.files.has('/cloud/icon_packs_backup.zip')).assertFalse();
      expect(fs.files.has('/cloud/icon_packs_sync_meta.json')).assertFalse();
      expect(fs.replacedPairs.length).assertEqual(0);
      // staging 残留已回收
      expect((await fs.listFiles('/data/cache/icon_pack_staging')).length).assertEqual(0);
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('directory_listing_failure_is_not_silently_treated_as_no_content', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const archiver = new GatedArchiver();
      bindCloudDeps(fs, new FakeFileCacher(fs), new FakeIconSync(), archiver);

      // listFiles 故障（非 ENOENT）不得当作"无内容"按成功跳过
      fs.failList = true;
      expect(await IconPackCloudBackup.getInstance().backupIconPacks()).assertFalse();
      expect(archiver.compressCalls).assertEqual(0);
      expect(fs.files.size).assertEqual(0);
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('restore_reports_failed_files_instead_of_silent_success', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('icon_packs/a.json', 'a');
      archiver.contents.set('icon_packs/b.json', 'b');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":10,"enabledPacks":["x"],"deletedPacks":[],"packs":[{"uuid":"x","name":"X","version":1,"iconCount":1}]}');
      fs.failCopyFor.add('/data/cache/icon_pack_restore/icon_packs/b.json');

      const result: IconPackRestoreResult = await IconPackCloudBackup.getInstance().restoreIconPacks();
      // 失败文件计入结果：成功 1、失败 1，不再静默吞错或硬编码计数
      expect(result.failedFiles).assertEqual(1);
      expect(result.restoredFiles).assertEqual(1);
      expect(result.restoredCount).assertEqual(1);
      expect(fs.files.has('/data/files/icon_packs/a.json')).assertTrue();
      expect(fs.files.has('/data/files/icon_packs/b.json')).assertFalse();
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('');
      // 同一 zip/timestamp：去掉故障后仍可重试并最终推进水位。
      fs.failCopyFor.clear();
      const retry = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(retry.failedFiles).assertEqual(0);
      expect(retry.restoredFiles).assertEqual(2);
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('10');
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('operations_are_mutually_exclusive_via_state_machine', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      fs.files.set('/data/files/icon_packs/pack1.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');
      const archiver = new GatedUnpackArchiver(fs);
      // 发布校验要求暂存 zip 解压出可解析元数据
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":1,"enabledPacks":[],"deletedPacks":[],"packs":[]}');
      archiver.hang = true;
      bindDeps(fs, archiver);

      // 等待备份进入 BACKING_UP（挂起在 compress 门控上）
      const pending = IconPackCloudBackup.getInstance().backupIconPacks();
      await delayForTurn();
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.BACKING_UP);

      // 并发操作全部被拒绝
      expect(await IconPackCloudBackup.getInstance().checkCloudBackupNewer()).assertFalse();
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertFalse();
      const restore = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(restore.restoredCount).assertEqual(0);
      expect(restore.restoredFiles).assertEqual(0);

      archiver.releaseGate();
      expect(await pending).assertTrue();
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('check_newer_true_when_cloud_meta_is_fresher', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '1000');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":5000,"deviceId":"d","deviceName":"M","enabledPacks":[],"deletedPacks":[],"packs":[]}');

      const newer = await IconPackCloudBackup.getInstance().checkCloudBackupNewer();
      expect(newer).assertTrue();
    });

    it('cloud_metadata_read_survives_safe_cache_failure_or_missing_cacher', 0, async () => {
      for (const withCache of [true, false]) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        cache.fail = true;
        bindCloudDeps(fs, withCache ? cache : undefined, new FakeIconSync());
        const meta = '/cloud/icon_packs_sync_meta.json';
        fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
        fs.files.set(meta, '{"timestamp":5000,"deviceId":"remote-device","deviceName":"Remote Phone",' +
          '"packs":[{"uuid":"remote-pack","name":"Remote Pack","version":2,"iconCount":7}]}');
        fs.locationOverride.set(meta, 2);
        fs.readableCloudPaths.add(meta);

        const icons = IconPackCloudBackup.getInstance();
        expect(await icons.checkCloudBackupNewer()).assertTrue();
        const status = await icons.getCloudBackupStatus();
        expect(status.exists).assertTrue();
        expect(status.metadataKnown).assertTrue();
        expect(status.packCount).assertEqual(1);
        expect(status.sourceDeviceId).assertEqual('remote-device');
        expect(status.sourceDeviceName).assertEqual('Remote Phone');
        expect(status.packs[0].uuid).assertEqual('remote-pack');
        expect(status.packs[0].iconCount).assertEqual(7);
        expect(fs.locationOverride.get(meta)).assertEqual(2);
        expect(fs.readPaths.join(',')).assertEqual(`${meta},${meta}`);
        expect(cache.calls.length).assertEqual(withCache ? 2 : 0);
        expect(cache.prepareCalls.length).assertEqual(0);
        expect(cache.cancelCalls.length).assertEqual(0);
        expect(cache.retryCleanupCalls).assertEqual(0);
        expect(fs.deleteAttempts.length).assertEqual(0);
        expect(icons.isCleanupPending()).assertFalse();
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      }
    });

    it('ordinary_read_failure_keeps_cloud_metadata_and_ownership_unknown', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      cache.fail = true;
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const meta = '/cloud/icon_packs_sync_meta.json';
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set(meta, '{"timestamp":5000,"deviceId":"remote-device","deviceName":"Remote Phone","packs":[]}');
      fs.locationOverride.set(meta, 2);
      fs.readableCloudPaths.add(meta);
      fs.failReadFor.add(meta);

      const icons = IconPackCloudBackup.getInstance();
      expect(await icons.checkCloudBackupNewer()).assertFalse();
      const status = await icons.getCloudBackupStatus();
      expect(status.exists).assertTrue();
      expect(status.metadataKnown).assertFalse();
      expect(status.metadataAbsent).assertFalse();
      expect(status.packCount).assertEqual(0);
      expect(status.packs.length).assertEqual(0);
      expect(status.sourceDeviceId).assertEqual('');
      expect(status.sourceDeviceName).assertEqual('');
      expect(await icons.clearCloudBackupForDevices(['remote-device'])).assertFalse();
      expect(fs.readPaths.join(',')).assertEqual(`${meta},${meta},${meta}`);
      expect(cache.calls.length).assertEqual(3);
      expect(cache.prepareCalls.length).assertEqual(0);
      expect(cache.cancelCalls.length).assertEqual(0);
      expect(fs.deleteAttempts.length).assertEqual(0);
      expect(fs.files.size).assertEqual(2);
      expect(sync.calls).assertEqual(0);
      expect(icons.isCleanupPending()).assertFalse();
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('status_reports_definitive_absent_when_meta_and_zip_missing', 0, async () => {
      // 云端目录从未写过元数据（无内容跳过）：应报告确定缺失，而非读取失败未知态。
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);

      const icons = IconPackCloudBackup.getInstance();
      const status = await icons.getCloudBackupStatus();
      expect(status.exists).assertFalse();
      expect(status.metadataKnown).assertFalse();
      expect(status.metadataAbsent).assertTrue();
      expect(status.packCount).assertEqual(0);
      expect(status.packs.length).assertEqual(0);
      expect(status.sourceDeviceId).assertEqual('');
      expect(status.sourceDeviceName).assertEqual('');
      expect(fs.statPaths.includes('/cloud/icon_packs_sync_meta.json')).assertTrue();
      expect(fs.readPaths.length).assertEqual(0);
      expect(cache.calls.length).assertEqual(0);
      expect(icons.isCleanupPending()).assertFalse();
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('status_keeps_unknown_when_zip_exists_without_meta', 0, async () => {
      // zip 在而元数据缺失：有备份物但内容不明，仍是未知态而不是确定未备份。
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');

      const icons = IconPackCloudBackup.getInstance();
      const status = await icons.getCloudBackupStatus();
      expect(status.exists).assertTrue();
      expect(status.metadataKnown).assertFalse();
      expect(status.metadataAbsent).assertTrue();
      expect(icons.isCleanupPending()).assertFalse();
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('status_keeps_unknown_when_meta_stat_fails_without_missing_code', 0, async () => {
      // stat 以非 ENOENT 错误失败：不能断定“从未备份”，保持未知态。
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      fs.failStatFor.add('/cloud/icon_packs_sync_meta.json');

      const icons = IconPackCloudBackup.getInstance();
      const status = await icons.getCloudBackupStatus();
      expect(status.metadataKnown).assertFalse();
      expect(status.metadataAbsent).assertFalse();
      expect(fs.readPaths.length).assertEqual(0);
      expect(icons.isCleanupPending()).assertFalse();
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('check_newer_false_when_within_five_minutes_debounce', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      // 刚刚恢复过（相对 stub 时钟 1 分钟前）→ 去抖跳过
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${Date.now() - 60000}`);
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":9999999999999,"deviceId":"","deviceName":"","enabledPacks":[],"deletedPacks":[],"packs":[]}');

      const newer = await IconPackCloudBackup.getInstance().checkCloudBackupNewer();
      expect(newer).assertFalse();
    });

    it('check_newer_false_when_meta_missing', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);

      expect(await IconPackCloudBackup.getInstance().checkCloudBackupNewer()).assertFalse();
    });

    it('clear_removes_zip_and_meta_and_returns_true', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{}');

      const ok = await IconPackCloudBackup.getInstance().clearCloudBackup();
      expect(ok).assertTrue();
      expect(fs.files.size).assertEqual(0);
    });


    it('icon_clear_cloud_only_unlinks_without_download_stat_or_read', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const zip = '/cloud/icon_packs_backup.zip';
      const meta = '/cloud/icon_packs_sync_meta.json';
      fs.files.set(zip, 'zip');
      fs.files.set(meta, 'invalid metadata');
      fs.locationOverride.set(zip, 2);
      fs.locationOverride.set(meta, 2);
      fs.failStatFor.add(zip);
      fs.failStatFor.add(meta);
      cache.fail = true;

      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertTrue();
      expect(cache.calls.length).assertEqual(0);
      expect(cache.prepareCalls.join(',')).assertEqual(`${zip},${meta}`);
      expect(fs.statPaths.length).assertEqual(0);
      expect(fs.readPaths.length).assertEqual(0);
      expect(fs.deleteAttempts.join(',')).assertEqual(`${zip},${meta}`);
      expect(fs.files.size).assertEqual(0);
      expect(sync.calls).assertEqual(1);
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('icon_clear_propagates_list_delete_and_sync_throw_or_rejection', 0, async () => {
      for (const failure of [0, 1, 2, 3]) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        const sync = new FakeIconSync();
        bindCloudDeps(fs, cache, sync);
        const zip = '/cloud/icon_packs_backup.zip';
        fs.files.set(zip, 'zip');
        fs.files.set('/cloud/icon_packs_sync_meta.json', '{}');
        fs.failList = failure === 0;
        if (failure === 1) fs.failDeleteFor.add(zip);
        sync.fail = failure === 2;
        sync.accepted = failure !== 3;
        AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '1234');
        expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertFalse();
        expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('1234');
        expect(fs.files.has(zip)).assertEqual(failure < 2);
        expect(sync.calls).assertEqual(failure === 0 ? 0 : 1);
        expect(cache.calls.length).assertEqual(0);
      }
    });

    it('icon_clear_retries_remaining_zip_after_meta_was_deleted', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const zip = '/cloud/icon_packs_backup.zip';
      fs.files.set(zip, 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{}');
      fs.failDeleteFor.add(zip);
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertFalse();
      expect(fs.files.has(zip)).assertTrue();
      expect(fs.files.has('/cloud/icon_packs_sync_meta.json')).assertFalse();
      resetSingleton();
      bindCloudDeps(fs, cache, sync);
      fs.failDeleteFor.clear();
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertTrue();
      expect(fs.files.size).assertEqual(0);
      expect(sync.calls).assertEqual(2);
    });

    it('icon_clear_absent_files_is_idempotent_but_requires_sync', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertTrue();
      sync.fail = true;
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertFalse();
      expect(sync.calls).assertEqual(2);
    });

    it('shared_gate_blocks_all_independent_icon_entries_before_io', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const gate = CloudBackupOperationGate.getInstance();
      const owner = gate.tryEnter(CloudBackupOperationKind.CLEAR);
      expect(owner !== undefined).assertTrue();
      if (owner === undefined) return;
      try {
        const icons = IconPackCloudBackup.getInstance();
        expect(await icons.backupIconPacks()).assertFalse();
        expect(await icons.clearCloudBackup()).assertFalse();
        expect(await icons.clearCloudBackupForDevices(['test-odid'])).assertFalse();
        expect(await icons.checkCloudBackupNewer()).assertFalse();
        expect(await icons.checkAndAutoRestore()).assertFalse();
        expect((await icons.restoreIconPacks()).restoredFiles).assertEqual(0);
        const status = await icons.getCloudBackupStatus();
        expect(status.metadataKnown).assertFalse();
        expect(fs.listCalls).assertEqual(0);
        expect(fs.statPaths.length).assertEqual(0);
        expect(fs.readPaths.length).assertEqual(0);
        expect(cache.calls.length).assertEqual(0);
        expect(cache.prepareCalls.length).assertEqual(0);
        expect(sync.calls).assertEqual(0);
        expect(gate.owns(owner)).assertTrue();
      } finally {
        owner.release();
      }
    });

    it('nested_backup_and_clear_reuse_owner_and_defer_all_sync', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      const archiver = new FakeUnpackArchiver(fs);
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":1,"enabledPacks":[],"deletedPacks":[],"packs":[]}');
      bindCloudDeps(fs, cache, sync, archiver);
      fs.files.set('/data/files/icon_packs/pack.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');
      const gate = CloudBackupOperationGate.getInstance();
      const owner = gate.tryEnter(CloudBackupOperationKind.BACKUP);
      expect(owner !== undefined).assertTrue();
      if (owner === undefined) return;
      try {
        const icons = IconPackCloudBackup.getInstance();
        expect(await icons.backupIconPacks(owner, true)).assertTrue();
        expect(gate.owns(owner)).assertTrue();
        expect(await icons.clearCloudBackup(owner, true)).assertTrue();
        expect(gate.owns(owner)).assertTrue();
        expect(sync.calls).assertEqual(0);
        expect(fs.files.has('/cloud/icon_packs_backup.zip')).assertFalse();
      } finally {
        owner.release();
      }
      expect(gate.isBusy()).assertFalse();
    });

    it('stale_and_unknown_io_owners_cannot_start_new_icon_work', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const gate = CloudBackupOperationGate.getInstance();
      const stale = gate.tryEnter(CloudBackupOperationKind.BACKUP);
      expect(stale !== undefined).assertTrue();
      if (stale === undefined) return;
      stale.release();
      expect(await IconPackCloudBackup.getInstance().backupIconPacks(stale, true)).assertFalse();
      const owner = gate.tryEnter(CloudBackupOperationKind.CLEAR);
      expect(owner !== undefined).assertTrue();
      if (owner === undefined) return;
      try {
        owner.retainUnknownIo();
        expect(await IconPackCloudBackup.getInstance().clearCloudBackup(owner, true)).assertFalse();
        expect(fs.listCalls).assertEqual(0);
        expect(owner.release()).assertFalse();
        expect(gate.owns(owner)).assertTrue();
      } finally {
        owner.resolveUnknownIo();
        owner.release();
      }
    });

    it('unknown_cancellation_retains_gate_and_retry_only_drains_original_work', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const icons = IconPackCloudBackup.getInstance();
      const gate = CloudBackupOperationGate.getInstance();
      const zip = '/cloud/icon_packs_backup.zip';
      fs.files.set(zip, 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{}');
      cache.inFlightPaths.add(zip);
      cache.failCancel = true;
      expect(await icons.clearCloudBackup()).assertFalse();
      expect(icons.getState()).assertEqual(IconPackSyncState.IDLE);
      expect(icons.isCleanupPending()).assertTrue();
      expect(gate.isBusy()).assertTrue();
      expect(fs.deleteAttempts.length).assertEqual(0);
      expect(sync.calls).assertEqual(0);
      expect(await icons.backupIconPacks()).assertFalse();
      expect((await icons.getCloudBackupStatus()).metadataKnown).assertFalse();
      expect(await icons.retryPendingCleanup()).assertFalse();
      cache.failCancel = false;
      expect(await icons.retryPendingCleanup()).assertTrue();
      expect(icons.isCleanupPending()).assertFalse();
      expect(gate.isBusy()).assertFalse();
      expect(cache.calls.length).assertEqual(0);
      expect(fs.deleteAttempts.length).assertEqual(0);
      expect(sync.calls).assertEqual(0);
      expect(cache.retryCleanupCalls).assertEqual(2);
      const next = gate.tryEnter(CloudBackupOperationKind.HISTORY);
      expect(next !== undefined).assertTrue();
      if (next === undefined) return;
      try {
        cache.complete();
        expect(await icons.retryPendingCleanup()).assertTrue();
        expect(gate.owns(next)).assertTrue();
      } finally {
        next.release();
      }
      expect(await icons.clearCloudBackup()).assertTrue();
      expect(fs.files.size).assertEqual(0);
    });

    it('nested_unknown_io_is_retained_until_parent_resolves_it', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const zip = '/cloud/icon_packs_backup.zip';
      fs.files.set(zip, 'zip');
      cache.inFlightPaths.add(zip);
      cache.failCancel = true;
      const gate = CloudBackupOperationGate.getInstance();
      const owner = gate.tryEnter(CloudBackupOperationKind.CLEAR);
      expect(owner !== undefined).assertTrue();
      if (owner === undefined) return;
      try {
        const icons = IconPackCloudBackup.getInstance();
        expect(await icons.clearCloudBackup(owner, true)).assertFalse();
        expect(owner.isCleanupPending()).assertTrue();
        expect(owner.release()).assertFalse();
        expect(await icons.retryPendingCleanup()).assertTrue();
        expect(cache.retryCleanupCalls).assertEqual(0);
        expect(gate.owns(owner)).assertTrue();
        cache.failCancel = false;
        expect(await cache.retryCleanup()).assertTrue();
        // 即使 loader 已确认，子调用也不得自行撤销父许可的屏障。
        expect(await icons.backupIconPacks(owner, true)).assertFalse();
      } finally {
        owner.resolveUnknownIo();
        owner.release();
      }
      expect(gate.isBusy()).assertFalse();
    });

    it('partial_delete_submits_sync_but_keeps_unknown_io_gate', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const zip = '/cloud/icon_packs_backup.zip';
      const meta = '/cloud/icon_packs_sync_meta.json';
      fs.files.set(zip, 'zip');
      fs.files.set(meta, '{}');
      cache.inFlightPaths.add(meta);
      cache.failCancel = true;
      const icons = IconPackCloudBackup.getInstance();
      expect(await icons.clearCloudBackup()).assertFalse();
      expect(fs.files.has(zip)).assertFalse();
      expect(fs.files.has(meta)).assertTrue();
      expect(sync.calls).assertEqual(1);
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertTrue();
      cache.failCancel = false;
      expect(await icons.retryPendingCleanup()).assertTrue();
      expect(sync.calls).assertEqual(1);
    });

    it('clear_treats_only_explicit_enoent_as_success', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const zip = '/cloud/icon_packs_backup.zip';
      fs.files.set(zip, 'zip');
      fs.absentOnDeleteFor.add(zip);
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertTrue();
      expect(fs.deleteAttempts.length).assertEqual(1);
      expect(sync.calls).assertEqual(1);
      fs.files.set(zip, 'zip');
      fs.absentOnDeleteFor.clear();
      fs.failDeleteFor.add(zip);
      expect(await IconPackCloudBackup.getInstance().clearCloudBackup()).assertFalse();
      expect(fs.files.has(zip)).assertTrue();
      expect(cache.calls.length).assertEqual(0);
    });

    it('scoped_clear_deletes_selected_owner_and_skips_other_owner', 0, async () => {
      for (const selected of [true, false]) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        const sync = new FakeIconSync();
        bindCloudDeps(fs, cache, sync);
        const zip = '/cloud/icon_packs_backup.zip';
        const meta = '/cloud/icon_packs_sync_meta.json';
        fs.files.set(zip, 'zip');
        fs.files.set(meta, '{"deviceId":"old-device","packs":[]}');
        fs.locationOverride.set(zip, 2);
        fs.locationOverride.set(meta, 2);
        const ids = selected ? ['current-device', 'old-device'] : ['current-device'];
        expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(ids)).assertTrue();
        expect(fs.files.has(zip)).assertEqual(!selected);
        expect(fs.files.has(meta)).assertEqual(!selected);
        expect(cache.calls.join(',')).assertEqual(meta);
        expect(sync.calls).assertEqual(0);
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      }
    });

    it('scoped_clear_uses_readable_cloud_owner_after_safe_cache_failure', 0, async () => {
      for (const selected of [true, false]) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        cache.fail = true;
        const sync = new FakeIconSync();
        bindCloudDeps(fs, cache, sync);
        const zip = '/cloud/icon_packs_backup.zip';
        const meta = '/cloud/icon_packs_sync_meta.json';
        fs.files.set(zip, 'zip');
        fs.files.set(meta, '{"deviceId":"old-device","packs":[]}');
        fs.locationOverride.set(zip, 2);
        fs.locationOverride.set(meta, 2);
        fs.readableCloudPaths.add(meta);

        const ids = selected ? ['old-device'] : ['test-odid'];
        expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(ids)).assertTrue();
        expect(fs.files.has(zip)).assertEqual(!selected);
        expect(fs.files.has(meta)).assertEqual(!selected);
        expect(fs.locationOverride.get(meta)).assertEqual(2);
        expect(fs.statPaths.join(',')).assertEqual(meta);
        expect(fs.readPaths.join(',')).assertEqual(meta);
        expect(cache.calls.join(',')).assertEqual(meta);
        expect(cache.prepareCalls.join(',')).assertEqual(selected ? `${zip},${meta}` : '');
        expect(fs.deleteAttempts.join(',')).assertEqual(selected ? `${zip},${meta}` : '');
        expect(cache.cancelCalls.length).assertEqual(0);
        expect(cache.retryCleanupCalls).assertEqual(0);
        expect(sync.calls).assertEqual(0);
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      }
    });

    it('scoped_clear_rejects_missing_invalid_and_unreadable_identity', 0, async () => {
      for (const content of ['', '{', 'null', '{}', '{"deviceId":7}', '{"deviceId":" "}',
        '{"deviceId":"unknown_odid"}']) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        const sync = new FakeIconSync();
        bindCloudDeps(fs, cache, sync);
        fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
        if (content !== '') fs.files.set('/cloud/icon_packs_sync_meta.json', content);
        expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(['test-odid'])).assertFalse();
        expect(fs.deleteAttempts.length).assertEqual(0);
        expect(sync.calls).assertEqual(0);
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      }
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(['test-odid'])).assertTrue();
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"deviceId":"test-odid"}');
      fs.locationOverride.set('/cloud/icon_packs_sync_meta.json', 2);
      cache.fail = true;
      expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(['test-odid'])).assertFalse();
      expect(fs.deleteAttempts.length).assertEqual(0);
    });

    it('scoped_delete_failure_keeps_ownership_evidence_across_restart_retry', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      bindCloudDeps(fs, cache, sync);
      const zip = '/cloud/icon_packs_backup.zip';
      const meta = '/cloud/icon_packs_sync_meta.json';
      fs.files.set(zip, 'zip');
      fs.files.set(meta, '{"deviceId":"old-device"}');
      fs.failDeleteFor.add(zip);
      expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(['old-device'])).assertFalse();
      expect(fs.files.has(meta)).assertTrue();
      expect(fs.deleteAttempts.join(',')).assertEqual(zip);
      resetSingleton();
      bindCloudDeps(fs, cache, sync);
      fs.failDeleteFor.clear();
      expect(await IconPackCloudBackup.getInstance().clearCloudBackupForDevices(['old-device'])).assertTrue();
      expect(fs.files.size).assertEqual(0);
      expect(sync.calls).assertEqual(0);
    });

    it('read_timeout_returns_to_idle_but_does_not_release_unknown_io', 0, async () => {
      for (const action of [0, 1, 2, 3]) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        cache.fail = true;
        cache.failKeepsInFlight = true;
        cache.failCancel = true;
        const sync = new FakeIconSync();
        const archiver = new GatedArchiver();
        bindCloudDeps(fs, cache, sync, archiver);
        fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
        fs.files.set('/cloud/icon_packs_sync_meta.json', '{"deviceId":"test-odid","packs":[]}');
        fs.locationOverride.set('/cloud/icon_packs_backup.zip', 2);
        fs.locationOverride.set('/cloud/icon_packs_sync_meta.json', 2);
        fs.readableCloudPaths.add('/cloud/icon_packs_backup.zip');
        fs.readableCloudPaths.add('/cloud/icon_packs_sync_meta.json');
        const icons = IconPackCloudBackup.getInstance();
        if (action === 0) expect((await icons.restoreIconPacks()).restoredFiles).assertEqual(0);
        if (action === 1) expect((await icons.getCloudBackupStatus()).metadataKnown).assertFalse();
        if (action === 2) expect(await icons.checkCloudBackupNewer()).assertFalse();
        if (action === 3) expect(await icons.clearCloudBackupForDevices(['test-odid'])).assertFalse();
        expect(icons.getState()).assertEqual(IconPackSyncState.IDLE);
        expect(icons.isCleanupPending()).assertTrue();
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertTrue();
        expect(fs.deleteAttempts.length).assertEqual(0);
        expect(fs.readPaths.length).assertEqual(0);
        expect(fs.dirs.size).assertEqual(0);
        expect(archiver.decompressCalls).assertEqual(0);
        expect(cache.prepareCalls.length).assertEqual(0);
        expect(cache.cancelCalls.length).assertEqual(0);
        expect(cache.retryCleanupCalls).assertEqual(0);
        expect(await icons.clearCloudBackup()).assertFalse();
        expect(fs.deleteAttempts.length).assertEqual(0);
        cache.failCancel = false;
        expect(await icons.retryPendingCleanup()).assertTrue();
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
      }
    });

    it('cache_failure_without_safety_introspection_blocks_read_and_retains_gate', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new UnconfirmedIconCache();
      const sync = new FakeIconSync();
      const archiver = new GatedArchiver();
      bindCloudDeps(fs, cache, sync, archiver);
      const meta = '/cloud/icon_packs_sync_meta.json';
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set(meta, '{"deviceId":"test-odid","packs":[]}');
      fs.locationOverride.set(meta, 2);
      fs.readableCloudPaths.add(meta);
      const icons = IconPackCloudBackup.getInstance();
      try {
        const status = await icons.getCloudBackupStatus();
        expect(status.exists).assertTrue();
        expect(status.metadataKnown).assertFalse();
        expect(status.sourceDeviceId).assertEqual('');
        expect(icons.getState()).assertEqual(IconPackSyncState.IDLE);
        expect(icons.isCleanupPending()).assertTrue();
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertTrue();
        expect(await icons.clearCloudBackupForDevices(['test-odid'])).assertFalse();
        expect((await icons.restoreIconPacks()).restoredFiles).assertEqual(0);
        expect(await icons.retryPendingCleanup()).assertFalse();
        expect(cache.calls.join(',')).assertEqual(meta);
        expect(fs.readPaths.length).assertEqual(0);
        expect(fs.deleteAttempts.length).assertEqual(0);
        expect(archiver.decompressCalls).assertEqual(0);
        expect(sync.calls).assertEqual(0);
      } finally {
        // 无安全状态的 fake 不能确认排空，仅测试重置可撤销本用例持有的许可。
        resetSingleton();
      }
    });

    it('backup_sync_rejection_does_not_advance_timestamp', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      const archiver = new FakeUnpackArchiver(fs);
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":1,"enabledPacks":[],"deletedPacks":[],"packs":[]}');
      bindCloudDeps(fs, cache, sync, archiver);
      fs.files.set('/data/files/icon_packs/pack.json', '{}');
      fs.files.set('/data/cache/icon_packs_backup.zip', 'zip');
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '1234');
      sync.accepted = false;
      expect(await IconPackCloudBackup.getInstance().backupIconPacks()).assertFalse();
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('1234');
      expect(sync.calls).assertEqual(1);
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('incomplete_test_dependencies_never_fall_through_to_native_operations', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const icons = IconPackCloudBackup.getInstance();
      icons.useDepsForTest({ fs: fs });
      expect(await icons.backupIconPacks()).assertFalse();
      expect(fs.listCalls).assertEqual(0);
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('status_rejects_invalid_metadata_instead_of_fabricating_remote_count', 0, async () => {
      for (const content of ['null', '{}', '{"packs":3}', '{"packs":[{}]}',
        '{"packs":[],"deviceName":7}', '{"packs":[],"timestamp":"bad"}']) {
        resetSingleton();
        const fs = new MemoryFs();
        bindDeps(fs, new GatedArchiver());
        fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
        fs.files.set('/cloud/icon_packs_sync_meta.json', content);
        const status = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
        expect(status.exists).assertTrue();
        expect(status.metadataKnown).assertFalse();
        expect(status.packCount).assertEqual(0);
        expect(status.sourceDeviceName).assertEqual('');
      }
    });

    it('zip_restore_tries_ordinary_read_after_safe_cache_failure', 0, async () => {
      for (const readFails of [false, true]) {
        resetSingleton();
        const fs = new DownloadAwareFs();
        const cache = new FakeFileCacher(fs);
        cache.fail = true;
        const archiver = new ReadCheckingUnpackArchiver(fs);
        archiver.contents.set('icon_packs_meta.json', '{"timestamp":5000,"enabledPacks":[],"deletedPacks":[],"packs":[]}');
        archiver.contents.set('user_icons/restored.svg', 'icon');
        bindCloudDeps(fs, cache, new FakeIconSync(), archiver);
        const zip = '/cloud/icon_packs_backup.zip';
        fs.files.set(zip, 'zip');
        fs.locationOverride.set(zip, 2);
        fs.readableCloudPaths.add(zip);
        if (readFails) fs.failReadFor.add(zip);

        const icons = IconPackCloudBackup.getInstance();
        const result = await icons.restoreIconPacks();
        expect(result.restoredFiles).assertEqual(readFails ? 0 : 1);
        expect(archiver.decompressCalls).assertEqual(readFails ? 0 : 1);
        expect(fs.readPaths[0]).assertEqual(zip);
        expect(fs.locationOverride.get(zip)).assertEqual(2);
        expect(fs.files.has('/data/files/user_icons/restored.svg')).assertEqual(!readFails);
        expect(fs.files.has(zip)).assertTrue();
        expect(cache.calls.join(',')).assertEqual(zip);
        expect(cache.prepareCalls.length).assertEqual(0);
        expect(cache.cancelCalls.length).assertEqual(0);
        expect(cache.retryCleanupCalls).assertEqual(0);
        expect(icons.isCleanupPending()).assertFalse();
        expect(icons.getState()).assertEqual(IconPackSyncState.IDLE);
        expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual(readFails ? '' : '5000');
      }
    });

    it('icon_restore_and_status_use_download_completion', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const cache = new FakeFileCacher(fs);
      const sync = new FakeIconSync();
      const archiver = new FakeUnpackArchiver(fs);
      archiver.contents.set('user_icons/restored.svg', 'icon');
      IconPackCloudBackup.getInstance().useDepsForTest({
        fs: fs, cache: cache, sync: sync, archiver: archiver, device: new FakeIconDevice(),
        registry: new FakeIconRegistry(), filesDir: '/data/files', cloudDir: '/cloud', cacheDir: '/data/cache',
      });
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.locationOverride.set('/cloud/icon_packs_backup.zip', 2);
      cache.hang = true;
      const restoring = IconPackCloudBackup.getInstance().restoreIconPacks();
      await cloudTestTurn();
      expect(archiver.decompressCalls).assertEqual(0);
      cache.complete();
      expect((await restoring).restoredFiles).assertEqual(1);
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"deviceId":"d","deviceName":"Phone","packs":[]}');
      fs.locationOverride.set('/cloud/icon_packs_sync_meta.json', 2);
      const status = IconPackCloudBackup.getInstance().getCloudBackupStatus();
      await cloudTestTurn();
      expect(fs.readPaths.includes('/cloud/icon_packs_sync_meta.json')).assertFalse();
      cache.complete();
      expect((await status).sourceDeviceName).assertEqual('Phone');
    });

    it('status_reports_zip_and_meta_fields', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zipdata');
      fs.files.set('/cloud/icon_packs_sync_meta.json',
        '{"version":1,"timestamp":7000,"deviceId":"dev-1","deviceName":"Mate60","enabledPacks":["p1"],"deletedPacks":[],"packs":[{"uuid":"p1","name":"Pack One","version":2,"iconCount":10}]}');

      const status: IconPackBackupStatus = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
      expect(status.exists).assertTrue();
      expect(status.metadataKnown).assertTrue();
      expect(status.size).assertEqual(7);
      expect(status.packCount).assertEqual(1);
      expect(status.sourceDeviceId).assertEqual('dev-1');
      expect(status.sourceDeviceName).assertEqual('Mate60');
      expect(status.packs.length).assertEqual(1);
      expect(status.packs[0].iconCount).assertEqual(10);
    });

    it('status_marks_missing_remote_metadata_unknown_without_local_fallback', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const registry = new FakeIconRegistry();
      registry.packs.push(new AegisIconPack());
      bindDepsWithRegistry(fs, new GatedArchiver(), registry);

      const status = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
      expect(status.exists).assertFalse();
      expect(status.metadataKnown).assertFalse();
      expect(status.packCount).assertEqual(0);
      expect(status.sourceDeviceId).assertEqual('');
      expect(status.sourceDeviceName).assertEqual('');
      expect(CloudBackupOperationGate.getInstance().isBusy()).assertFalse();
    });

    it('merge_enabled_packs_appends_local_only_and_defaults_when_empty', 0, () => {
      // 云端列表为基础，本地独有追加
      let merged = mergeEnabledPacks(['p1', 'p2'], ['p2', 'p3', 'p4']);
      expect(merged.join(',')).assertEqual('p1,p2,p3,p4');

      // 云端为空 → 内置默认包兜底 + 本地追加
      merged = mergeEnabledPacks([], ['p9']);
      expect(merged.join(',')).assertEqual(`${BUILTIN_DEFAULT_PACK_ID},p9`);
    });

    it('restore_returns_empty_result_without_state_leak', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new GatedArchiver();
      bindDeps(fs, archiver);
      // 云端无 zip → stat 失败 → 空结果
      const result: IconPackRestoreResult = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(result.restoredCount).assertEqual(0);
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('restore_full_chain_deletes_refreshes_merges_and_applies', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      // 本地已有 p1（将被云端 deletedPacks 标记删除）
      const localPack = new AegisIconPack();
      localPack.uuid = 'p1';
      localPack.on_device_path = '/data/files/icon_packs/p1';
      registry.packs.push(localPack);
      registry.enabledPacks = ['p1'];
      bindDepsWithRegistry(fs, archiver, registry);

      // 云端：zip + "解压产物"（新包 packA + 元数据）
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('icon_packs/packA/pack.json', '{"name":"PackA"}');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":5000,"enabledPacks":["p2"],"deletedPacks":["p1"],' +
        '"packs":[{"uuid":"p2","name":"Pack Two","version":1,"iconCount":3},{"uuid":"p3","name":"Pack Three","version":1,"iconCount":4}]}');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      // 恢复结果计数
      expect(result.restoredCount).assertEqual(2);
      expect(result.restoredFiles).assertEqual(1);
      // deletedPacks 清理：p1 被删除
      expect(registry.removedPacks.join(',')).assertEqual('p1');
      // 磁盘重载：user_icons 触达 + 新包 packA 按路径加载
      expect(registry.loadUserIconsCalls.join(',')).assertEqual('/data/files/user_icons');
      expect(registry.addedPackPaths.join(',')).assertEqual('/data/files/icon_packs/packA');
      // 合并应用：云端 enabledPacks 为基础 + 本地新增 packA（dyn_packA）
      expect(registry.lastAppliedPacks.join(',')).assertEqual('p2,dyn_packA');
      // 偏好持久化 + 恢复时间戳更新（防抖基准）
      const saved = AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string;
      expect(saved).assertEqual('["p2","dyn_packA"]');
      const lastTime = AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string;
      expect(lastTime).assertEqual('5000');
      // 临时目录已清理（解压产物不残留）
      expect(fs.files.has('/data/cache/icon_pack_restore/icon_packs_meta.json')).assertFalse();
      // 拷贝确实发生：filesDir 出现解压出的包文件
      expect(fs.files.has('/data/files/icon_packs/packA/pack.json')).assertTrue();
      // 状态机复位
      expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
    });

    it('restore_skips_unknown_deleted_uuid_and_broken_pack_load', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      // deletedPacks 引用本地不存在的 uuid；解压出的包损坏（加载抛错）不得中断恢复
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('icon_packs/broken/pack.json', 'not-json');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":6000,"enabledPacks":["p2"],"deletedPacks":["ghost"],' +
        '"packs":[{"uuid":"p2","name":"Pack Two","version":1,"iconCount":1}]}');
      registry.failAddFor.add('/data/files/icon_packs/broken');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      // 未知 uuid 不触发删除；损坏包仍允许其他恢复步骤，但计入不完整，不推进水位。
      expect(registry.removedPacks.length).assertEqual(0);
      expect(result.restoredCount).assertEqual(1);
      expect(result.restoredFiles).assertEqual(1);
      expect(result.failedFiles).assertEqual(1);
      expect(registry.lastAppliedPacks.join(',')).assertEqual('p2');
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('');
      registry.failAddFor.clear();
      expect((await IconPackCloudBackup.getInstance().restoreIconPacks()).failedFiles).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('6000');
    });

    it('restore_registry_delete_load_and_reload_failures_keep_watermark_retryable', 0, async () => {
      for (const failure of [0, 1, 2]) {
        resetSingleton();
        const fs = new MemoryFs();
        const archiver = new FakeUnpackArchiver(fs);
        const registry = new FakeIconRegistry();
        const pack = new AegisIconPack();
        pack.uuid = 'deleted';
        pack.on_device_path = '/data/files/icon_packs/deleted';
        registry.packs.push(pack);
        bindDepsWithRegistry(fs, archiver, registry);
        fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
        archiver.contents.set('user_icons/restored.svg', 'svg');
        archiver.contents.set('icon_packs_meta.json',
          '{"timestamp":7000,"enabledPacks":[],"deletedPacks":["deleted"],"packs":[]}');
        if (failure === 0) registry.failRemoveFor.add('deleted');
        registry.failLoadUserIcons = failure === 1;
        registry.failReloadEnabledPacks = failure === 2;
        AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '100');

        const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
        expect(result.failedFiles).assertEqual(1);
        expect(result.restoredFiles).assertEqual(1);
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('100');
        registry.failRemoveFor.clear();
        registry.failLoadUserIcons = false;
        registry.failReloadEnabledPacks = false;
        expect((await IconPackCloudBackup.getInstance().restoreIconPacks()).failedFiles).assertEqual(0);
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('7000');
      }
    });

    it('restore_temporary_cleanup_failure_reports_partial_and_does_not_advance', 0, async () => {
      resetSingleton();
      const fs = new DownloadAwareFs();
      const archiver = new FakeUnpackArchiver(fs);
      bindCloudDeps(fs, new FakeFileCacher(fs), new FakeIconSync(), archiver);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('user_icons/restored.svg', 'svg');
      archiver.contents.set('icon_packs_meta.json',
        '{"timestamp":8000,"enabledPacks":[],"deletedPacks":[],"packs":[]}');
      fs.failDeleteFor.add('/data/cache/icon_pack_restore/user_icons/restored.svg');
      fs.files.set('/data/files/user_icons/existing.svg', 'existing');
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '100');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(result.failedFiles).assertEqual(1);
      expect(result.restoredFiles).assertEqual(1);
      expect(fs.files.get('/data/files/user_icons/existing.svg')).assertEqual('existing');
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('100');
      fs.failDeleteFor.clear();
      expect((await IconPackCloudBackup.getInstance().restoreIconPacks()).failedFiles).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('8000');
    });

    it('restore_without_meta_copies_files_but_skips_registry_mutations', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      // zip 存在但无元数据（旧版本备份）：文件拷贝仍执行，注册表不改写
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      archiver.contents.set('user_icons/custom.svg', 'svg-data');

      const result = await IconPackCloudBackup.getInstance().restoreIconPacks();
      expect(result.restoredCount).assertEqual(0);
      expect(result.restoredFiles).assertEqual(1);
      expect(registry.removedPacks.length).assertEqual(0);
      expect(registry.lastAppliedPacks.length).assertEqual(0);
      expect(registry.reloadEnabledPacksCalls).assertEqual(0);
      // 拷贝发生：user_icons 内容落地 filesDir
      expect(fs.files.has('/data/files/user_icons/custom.svg')).assertTrue();
      expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string).assertEqual('');
    });

    it('auto_restore_full_chain_gated_by_pref_login_and_fires', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      // 去抖/较新判定读取的是伴生元数据文件（不解压 zip）
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":9000,"deviceId":"d","deviceName":"M","enabledPacks":["cloud1"],"deletedPacks":[],"packs":[{"uuid":"cloud1","name":"C","version":1,"iconCount":1}]}');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":9000,"enabledPacks":["cloud1"],"deletedPacks":[],"packs":[{"uuid":"cloud1","name":"C","version":1,"iconCount":1}]}');
      // 账号门禁直接改单例布尔，finally 复位防跨套件泄漏
      HuaweiAccountManager.getInstance().userLogin = false;
      try {
        // 云同步开关关闭 → 直接跳过
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();

        // 开关开启但账号未登录 → 跳过
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();

        // 登录后整链路执行：恢复成功返回 true，状态机复位
        HuaweiAccountManager.getInstance().userLogin = true;
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertTrue();
        expect(registry.lastAppliedPacks.join(',')).assertEqual('cloud1');
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME) as string).assertEqual('9000');
        expect(IconPackCloudBackup.getInstance().getState()).assertEqual(IconPackSyncState.IDLE);
      } finally {
        HuaweiAccountManager.getInstance().userLogin = false;
      }
    });

    it('auto_restore_partial_returns_false_then_retries_same_cloud_timestamp', 0, async () => {
      resetSingleton();
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"timestamp":9000}');
      archiver.contents.set('user_icons/a.svg', 'a');
      archiver.contents.set('user_icons/b.svg', 'b');
      archiver.contents.set('icon_packs_meta.json',
        '{"timestamp":9000,"enabledPacks":[],"deletedPacks":[],"packs":[]}');
      fs.failCopyFor.add('/data/cache/icon_pack_restore/user_icons/b.svg');
      const previousLogin = HuaweiAccountManager.getInstance().userLogin;
      const previousEnable = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
      try {
        HuaweiAccountManager.getInstance().userLogin = true;
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();
        expect(fs.files.has('/data/files/user_icons/a.svg')).assertTrue();
        expect(fs.files.has('/data/files/user_icons/b.svg')).assertFalse();
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('');
        fs.failCopyFor.clear();
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertTrue();
        expect(archiver.decompressCalls).assertEqual(2);
        expect(AppPreference.getPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME)).assertEqual('9000');
      } finally {
        HuaweiAccountManager.getInstance().userLogin = previousLogin;
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, previousEnable);
      }
    });

    it('auto_restore_skips_when_local_already_fresh', 0, async () => {
      resetSingleton();
      HuaweiAccountManager.getInstance().userLogin = true;
      const fs = new MemoryFs();
      const archiver = new FakeUnpackArchiver(fs);
      const registry = new FakeIconRegistry();
      bindDepsWithRegistry(fs, archiver, registry);
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      // 刚刚恢复过（相对 stub 时钟 1 分钟前）→ 去抖内不自动恢复。
      // 伴生元数据存在且时间戳更新，保证走的是去抖分支而非"缺 meta"分支
      AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, `${Date.now() - 60000}`);
      fs.files.set('/cloud/icon_packs_backup.zip', 'zip');
      fs.files.set('/cloud/icon_packs_sync_meta.json', '{"version":1,"timestamp":9999999999999,"deviceId":"","deviceName":"","enabledPacks":[],"deletedPacks":[],"packs":[]}');
      archiver.contents.set('icon_packs_meta.json',
        '{"version":1,"timestamp":9999999999999,"enabledPacks":[],"deletedPacks":[],"packs":[]}');

      try {
        expect(await IconPackCloudBackup.getInstance().checkAndAutoRestore()).assertFalse();
        expect(archiver.decompressCalls).assertEqual(0);
      } finally {
        HuaweiAccountManager.getInstance().userLogin = false;
      }
    });
  });
}

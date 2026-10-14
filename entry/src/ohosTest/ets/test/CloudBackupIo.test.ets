import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import {
  CloudBackupCrypto, CloudBackupCryptoMode, CloudBackupIdentityStatus,
  FileIoFsGateway, getCloudBackupIdentityStatus, CloudBackupStaging, NativeCloudBackupStagingPort,
  DiagnosticContext, DiagnosticKind
} from 'common';

class LocalOnlyStagingPort extends NativeCloudBackupStagingPort {
  async sync(_context?: DiagnosticContext): Promise<boolean> { return true; }
}

/**
 * 原生 I/O 验收：仅使用本套件 mkdtemp 创建的 cacheDir 子目录和合成内容。
 * 不读取 cloudDir、不启动同步/下载、不启动 Ability、不修改令牌或既有备份。
 * 本套件不证明云目录 moveFile 支持、原子可见性或双设备同步结果。
 */
export default function cloudBackupIoTest(): void {
  describe('CloudBackupIoDeviceTest', () => {
    let fixtureDir: string = '';
    const gateway = new FileIoFsGateway();

    beforeAll(async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      fixtureDir = await fs.mkdtemp(context.cacheDir + '/cloud-backup-io-XXXXXX');
    });

    afterAll(async () => {
      // 只有成功 mkdtemp 后才拥有目录；绝不扫描或删除任何既有备份目录。
      if (fixtureDir.length > 0) {
        await fs.rmdir(fixtureDir);
      }
    });

    it('native_write_preserves_nonzero_byteoffset_and_exact_view_length', 0, async () => {
      const path = fixtureDir + '/sliced.tmp';
      const backing = new Uint8Array([88, 65, 228, 184, 173, 90]);
      await gateway.writeBinaryFile(path, backing.subarray(1, 5));
      expect((await gateway.stat(path)).size).assertEqual(4);
      expect(await gateway.readTextFile(path)).assertEqual('A中');
    });

    it('native_text_write_roundtrip_preserves_non_ascii_without_padding', 0, async () => {
      const path = fixtureDir + '/unicode.tmp';
      const text = '合成 I/O fixture é';
      await gateway.writeTextFile(path, text);
      expect(await gateway.readTextFile(path)).assertEqual(text);
    });

    it('native_repeated_text_encoding_ignores_buffer_pool_offsets', 0, async () => {
      let offsetObserved = false;
      for (let index = 0; index < 16; index++) {
        const sample = buffer.from('pool-allocation-probe', 'utf-8');
        offsetObserved = offsetObserved || sample.byteOffset > 0;
        const text = `合成 pooled fixture ${index} é🧪`;
        const path = fixtureDir + '/pooled-' + index + '.tmp';
        await gateway.writeNewTextFile(path, text);
        expect(await gateway.readTextFile(path)).assertEqual(text);
      }
      expect(offsetObserved).assertTrue();
      const empty = fixtureDir + '/encoded-empty.tmp';
      await gateway.writeTextFile(empty, '');
      expect(await gateway.readTextFile(empty)).assertEqual('');
    });

    it('native_zero_length_file_is_distinct_from_io_failure', 0, async () => {
      const path = fixtureDir + '/empty.tmp';
      await gateway.writeBinaryFile(path, new Uint8Array(0));
      expect((await gateway.stat(path)).size).assertEqual(0);
      expect(await gateway.readTextFile(path)).assertEqual('');
      let failed = false;
      try { await gateway.readTextFile(fixtureDir + '/absent.tmp'); } catch (_) { failed = true; }
      expect(failed).assertTrue();
    });

    it('native_new_write_readback_header_validation_and_publication', 0, async () => {
      const source = fixtureDir + '/.pending.tmp';
      const destination = fixtureDir + '/fixture-backup.enc';
      const crypto = CloudBackupCrypto.getInstance();
      const plaintext = '{"fixture":"synthetic I/O only"}';
      const encrypted = await crypto.encrypt(plaintext, CloudBackupCryptoMode.HUAWEI_ACCOUNT,
        'synthetic-fixture-key', 0, 1700000000000, 'synthetic-fixture-device', '合成测试设备');
      await gateway.writeNewTextFile(source, encrypted);
      const readback = await gateway.readTextFile(source);
      expect(readback === encrypted).assertTrue();
      const header = crypto.parseTokenHeader(readback);
      expect(header.tokenCount).assertEqual(0);
      expect(getCloudBackupIdentityStatus(header.deviceId, header.deviceName)).assertEqual(CloudBackupIdentityStatus.COMPLETE);
      expect(await crypto.verifyToken(readback)).assertTrue();
      await gateway.publishFile(source, destination);
      expect((await gateway.readTextFile(destination)) === encrypted).assertTrue();
      expect(fs.accessSync(source)).assertFalse();
      const restored = await crypto.decrypt(await gateway.readTextFile(destination), CloudBackupCryptoMode.HUAWEI_ACCOUNT,
        'synthetic-fixture-key');
      expect(restored === plaintext).assertTrue();
    });

    it('native_receipt_survives_instance_restart_and_only_reaps_its_owned_ciphertext', 0, async () => {
      const root = await fs.mkdtemp(fixtureDir + '/owned-cloud-XXXXXX');
      const local = await fs.mkdtemp(fixtureDir + '/owned-local-XXXXXX');
      const context = new DiagnosticContext(0, DiagnosticKind.BACKUP, -1);
      const scope = 'a'.repeat(64);
      const port = new LocalOnlyStagingPort(local);
      const first = new CloudBackupStaging(root, scope, port);
      const source = await first.create('synthetic-unfinished-ciphertext', context);
      expect(fs.accessSync(source)).assertTrue();
      const restarted = new CloudBackupStaging(root, scope, new LocalOnlyStagingPort(local));
      expect(await restarted.recover(context)).assertTrue();
      expect(fs.accessSync(source)).assertFalse();
      expect((await port.load()).length).assertEqual(0);
      const next = await restarted.create('synthetic-complete-ciphertext', context);
      const destination = root + '/otp_backup_42.enc';
      await restarted.publish(next, destination, context);
      expect(await restarted.discard(next, context)).assertTrue();
      await restarted.acknowledgeSync(context);
      expect(await gateway.readTextFile(destination)).assertEqual('synthetic-complete-ciphertext');
      expect((await port.load()).length).assertEqual(0);
    });

    it('native_publish_and_new_write_refuse_existing_target_without_overwrite', 0, async () => {
      const source = fixtureDir + '/collision-source.tmp';
      const destination = fixtureDir + '/collision-target.enc';
      await gateway.writeNewTextFile(source, 'owned-source');
      await gateway.writeNewTextFile(destination, 'owned-existing-target');
      let publishFailed = false;
      try { await gateway.publishFile(source, destination); } catch (_) { publishFailed = true; }
      expect(publishFailed).assertTrue();
      expect(await gateway.readTextFile(source)).assertEqual('owned-source');
      expect(await gateway.readTextFile(destination)).assertEqual('owned-existing-target');
      let newWriteFailed = false;
      try { await gateway.writeNewTextFile(destination, 'must-not-replace'); } catch (_) { newWriteFailed = true; }
      expect(newWriteFailed).assertTrue();
      expect(await gateway.readTextFile(destination)).assertEqual('owned-existing-target');
    });
  });
}

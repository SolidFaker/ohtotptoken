import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { CloudBackupCrypto, FileIoFsGateway, CloudFileCacheLoader, CloudBackupSyncService } from 'common';

/** 仅在显式选择测试账号后注册；只触碰本次 mkdtemp 创建的隔离目录。 */
export default function cloudBackupCloudLifecycleTest(): void {
  describe('CloudBackupOwnedCloudLifecycleDeviceTest', () => {
    it('owned_cloud_fixture_write_publish_read_delete_contract', 0, async () => {
      const args = abilityDelegatorRegistry.getArguments();
      expect(args.parameters['cloudBackupOwnedFixture']).assertEqual('true');
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      expect(context !== undefined).assertTrue();
      if (context === undefined) return;
      const dir = await fs.mkdtemp(`${context.cloudFileDir}/.cloud-backup-test-XXXXXX`);
      const pending = `${dir}/pending.tmp`;
      const published = `${dir}/fixture.enc`;
      const gateway = new FileIoFsGateway();
      let pendingOwned = false;
      let publishedOwned = false;
      try {
        const crypto = CloudBackupCrypto.getInstance();
        const body = '{"tokens":[],"groups":[]}';
        const sealed = await crypto.encrypt(body, crypto.getMode(true), 'synthetic-test-key', 0,
          1745385600000, 'synthetic-device-id', 'Synthetic Device');
        await gateway.writeNewTextFile(pending, sealed);
        pendingOwned = true;
        expect(await gateway.readTextFile(pending) === sealed).assertTrue();
        await gateway.publishFile(pending, published);
        pendingOwned = false;
        publishedOwned = true;
        const header = crypto.parseTokenHeader(await gateway.readTextFile(published));
        expect(header.deviceName === 'Synthetic Device').assertTrue();
        expect(await CloudFileCacheLoader.getInstance().prepareForDelete(published)).assertTrue();
        await gateway.deleteFile(published);
        publishedOwned = false;
        expect(await CloudBackupSyncService.getInstance().start()).assertTrue();
      } finally {
        if (pendingOwned) { try { await fs.unlink(pending); } catch (_) {} }
        if (publishedOwned) { try { await fs.unlink(published); } catch (_) {} }
        try { await fs.rmdir(dir); } catch (_) {}
      }
    });
  });
}

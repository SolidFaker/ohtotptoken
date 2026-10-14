import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LocalBackupFileIo, LocalBackupError, LocalBackupFailure } from 'common';

/** 只使用测试独占目录，不读写选择器目标或正式备份。 */
export default function localBackupFileIoDeviceTest(): void {
  describe('LocalBackupFileIoDeviceTest', () => {
    it('production_utf8_large_roundtrip_and_fixed_failure', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const directory = await fs.mkdtemp(context.cacheDir + '/local-backup-io-XXXXXX');
      const path = directory + '/synthetic.txt';
      const io = new LocalBackupFileIo();
      const text = '中文🙂跨块内容\n'.repeat(20000);
      try {
        await io.writeText(path, text);
        expect(await io.readText(path)).assertEqual(text);
        await io.writeText(path, 'short');
        expect(await io.readText(path)).assertEqual('short');
        let failed = false;
        try { await io.writeText(directory + '/missing/target.txt', 'synthetic'); } catch (error) {
          failed = error instanceof LocalBackupError && error.reason === LocalBackupFailure.SAVE;
        }
        expect(failed).assertTrue();
      } finally {
        await fs.rmdir(directory);
      }
    });
  });
}

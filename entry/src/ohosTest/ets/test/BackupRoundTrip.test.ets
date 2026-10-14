import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  CloudBackupCrypto,
  TokenBackup,
  restoreFromBackup,
  saveBackupToFile,
  TokenConfig,
  otpType,
  base32Encode, CryptoFrameworkCryptoEngine, LocalBackupFileIo, LocalBackupKind, readLocalBackupSource,
} from 'common';

/**
 * 真机备份 round-trip 冒烟（Phase 3，docs/TEST_PLAN.md 第 4 节出口条件）。
 *
 * LocalUnit 无法验证 cryptoFramework/base32/文件 IO 的数值正确性；
 * 本套件在真机用生产实现做完整的 备份→恢复 回路，验证密文可解、
 * 头部元信息可读、令牌数据无损、错误密码被拒绝。
 * 用例只写临时文件并自清理，不清库、不触碰用户数据。
 */
export default function backupRoundTripTest(): void {
  describe('BackupRoundTripDeviceTest', () => {
    let context: common.Context;
    let tempDir: string;

    const makeToken = (uuid: string, name: string): TokenConfig => {
      const token = new TokenConfig('JBSWY3DPEHPK3PXP', otpType.TOTP, name, 'RoundTripIssuer');
      token.TokenUUID = uuid;
      return token;
    };

    const cleanupFile = (filePath: string): void => {
      try {
        fs.unlinkSync(filePath);
      } catch (_) {
        // 清理失败不影响用例结果
      }
    };

    beforeAll(async () => {
      context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      // 不启动首页，避免测试环境中已开启的自动云备份及偏好迁移。
      tempDir = await fs.mkdtemp(context.cacheDir + '/backup-roundtrip-XXXXXX');
    });
    afterAll(async () => {
      if (tempDir) { await fs.rmdir(tempDir); }
    });

    it('plaintext_backup_file_roundtrip_preserves_tokens', 0, async () => {
      const token = makeToken('rt-plain-1', 'PlainRoundTrip');
      const backup = new TokenBackup(1, [token]);
      backup.groups = [];
      const filePath = `${tempDir}/plain.bak`;

      try {
        await saveBackupToFile(filePath, backup, false, '');
        const restored = await restoreFromBackup(filePath, false, '');

        expect(restored.magic).assertEqual(backup.magic);
        expect(restored.configs.length).assertEqual(1);
        expect(restored.configs[0].TokenUUID).assertEqual('rt-plain-1');
        expect(restored.configs[0].TokenSecret).assertEqual('JBSWY3DPEHPK3PXP');
      } finally {
        cleanupFile(filePath);
      }
    });

    it('encrypted_backup_file_roundtrip_with_password', 0, async () => {
      const token = makeToken('rt-enc-1', 'EncRoundTrip');
      const backup = new TokenBackup(1, [token]);
      backup.groups = [];
      const filePath = `${tempDir}/enc.bak`;
      const password = 'round-trip-pass-0';

      try {
        // 生产 encryptFile（cryptoFramework AES + PBKDF2）→ base32 落盘
        await saveBackupToFile(filePath, backup, true, password);
        expect(fs.accessSync(filePath)).assertTrue();

        const restored = await restoreFromBackup(filePath, true, password);
        expect(restored.configs.length).assertEqual(1);
        expect(restored.configs[0].TokenUUID).assertEqual('rt-enc-1');
      } finally {
        cleanupFile(filePath);
      }
    });

    it('encrypted_backup_rejects_wrong_password', 0, async () => {
      const token = makeToken('rt-enc-2', 'EncRoundTrip2');
      const backup = new TokenBackup(1, [token]);
      backup.groups = [];
      const filePath = `${tempDir}/enc2.bak`;

      try {
        await saveBackupToFile(filePath, backup, true, 'correct-pass');
        let threw = false;
        try {
          await restoreFromBackup(filePath, true, 'wrong-pass');
        } catch (err) {
          threw = true;
        }
        expect(threw).assertTrue();
      } finally {
        cleanupFile(filePath);
      }
    });

    it('local_content_detection_four_types_legacy_and_cancel_snapshot', 0, async () => {
      const tokens = [otpType.TOTP, otpType.HOTP, otpType.Steam, otpType.Forti].map((type: otpType): TokenConfig => {
        const token = makeToken(`synthetic-type-${type}`, '合成🙂');
        token.TokenType = type;
        token.FortiToken = 'SYNTHETIC';
        token.FortiDevID = 'SYNTHETIC';
        if (type === otpType.Steam) { token.TokenDigits = 5; }
        return token;
      });
      const backup = new TokenBackup(1, tokens);
      backup.groups = [];
      const path = `${tempDir}/synthetic-legacy.bak`;
      const engine = new CryptoFrameworkCryptoEngine();
      const json = JSON.stringify(backup).replace(/,"TokenGroupId":""/g, '').replace(/,"TokenFavorite":false/g, '')
        .replace(/"TokenUUID":"[^"]+",?/g, '');
      try {
        await new LocalBackupFileIo().writeText(path, base32Encode(engine.utf8Encode(json)));
        const plain = await readLocalBackupSource(path);
        expect(plain.kind).assertEqual(LocalBackupKind.PLAIN);
        const prepared = await plain.prepare();
        expect(prepared.tokenCount).assertEqual(4);
        prepared.dispose();
        let disposed = false;
        try { prepared.takeForCommit(); } catch (_) { disposed = true; }
        expect(disposed).assertTrue();
        plain.dispose();
        const key = await engine.pbkdf2Derive('synthetic-legacy-password', new Uint8Array(16), 10000, 16);
        const ciphertext = await engine.aesCbcEncrypt(engine.utf8Encode(json), key, engine.utf8Encode('ohtotptokenaesiv'));
        await new LocalBackupFileIo().writeText(path, base32Encode(ciphertext));
        const legacy = await readLocalBackupSource(path);
        expect(legacy.kind).assertEqual(LocalBackupKind.LEGACY_CANDIDATE);
        const legacyPrepared = await legacy.prepare('synthetic-legacy-password');
        expect(legacyPrepared.tokenCount).assertEqual(4);
        legacyPrepared.dispose();
        legacy.dispose();
      } finally { cleanupFile(path); }
    });

    it('cloud_backup_crypto_roundtrip_preserves_header_and_payload', 0, async () => {
      const crypto = CloudBackupCrypto.getInstance();
      const mode = crypto.getMode(true);
      const payload = '{"tokens":[{"TokenUUID":"rt-cloud-1","TokenSecret":"S"}],"groups":[]}';
      const sealed = await crypto.encrypt(payload, mode, 'union-device-test', 2, 1726000000000, 'odid-rt', 'Mate60RT');

      // 头部元信息可独立解析（云端列表页依赖，不解密载荷）
      const header = crypto.parseTokenHeader(sealed);
      expect(header.tokenCount).assertEqual(2);
      expect(header.deviceId).assertEqual('odid-rt');
      expect(header.deviceName).assertEqual('Mate60RT');

      // 完整解密还原
      const decrypted = await crypto.decrypt(sealed, mode, 'union-device-test');
      expect(decrypted).assertEqual(payload);
    });
  });
}

import { describe, it, expect } from '@ohos/hypium';
import {
  BackupTextIo,
  base32Encode,
  stringToIntArray,
  TokenBackup,
  TokenConfig,
  TokenGroup,
  TokenGroupKvBackend,
  TokenGroupStore,
  otpType,
  readLocalBackupSource,
  restoreFromBackup,
  saveBackupToFile,
  useCryptoEngineForTest,
} from 'common';
import { FakeCryptoEngine } from './fakes/BackupFakes';

/**
 * 本地文件备份管线测试（Phase 2 BackupTextIo 端口注入 + CryptoEngine 假引擎）。
 *
 * 覆盖：明文/加密 base32 往返、magic/结构校验、分组合并。
 * 文件 I/O 经内存 BackupTextIo，cryptoFramework 经假引擎。
 */

const TOKEN_BACKUP_MAGIC = 0x55aaeebb;

class MemoryBackupTextIo implements BackupTextIo {
  files: Map<string, string> = new Map();
  writeCalls: number = 0;

  readText(uri: string): Promise<string> {
    const content = this.files.get(uri);
    if (content === undefined) {
      return Promise.reject(new Error(`no such file ${uri}`));
    }
    return Promise.resolve(content);
  }

  writeText(uri: string, content: string): Promise<void> {
    this.writeCalls++;
    this.files.set(uri, content);
    return Promise.resolve();
  }
}

class MemoryGroupKv implements TokenGroupKvBackend {
  saved: TokenGroup[] | null = null;

  getValue<T>(_key: string): Promise<T | null> {
    if (this.saved === null) {
      return Promise.resolve(null);
    }
    return Promise.resolve(JSON.parse(JSON.stringify(this.saved)) as T);
  }

  setValue<T>(_key: string, value: T): Promise<void> {
    this.saved = JSON.parse(JSON.stringify(value)) as TokenGroup[];
    return Promise.resolve();
  }
}

function makeToken(uuid: string, secret: string): TokenConfig {
  const token = new TokenConfig(secret, otpType.TOTP);
  token.TokenUUID = uuid;
  token.RankScore = 0;
  return token;
}

/** TokenGroupStore 绑定内存 KV，隔离分组状态 */
function bindGroupStore(): void {
  TokenGroupStore.getInstance().useKvBackendForTest(new MemoryGroupKv());
  TokenGroupStore.getInstance().state.groups = [];
}

function putBackupFile(io: MemoryBackupTextIo, uri: string, json: string): void {
  io.files.set(uri, base32Encode(stringToIntArray(json)));
}

export default function tokenBackupTest() {
  describe('tokenBackupTest', () => {
    it('plaintext_backup_roundtrip_preserves_configs_and_groups', 0, async () => {
      const io = new MemoryBackupTextIo();
      bindGroupStore();
      const group = new TokenGroup('g1', 'Work', 0xFF0000FF);
      TokenGroupStore.getInstance().state.groups = [group];

      const backup = new TokenBackup(1, [makeToken('u1', 'secret1'), makeToken('u2', 'secret2')]);
      await saveBackupToFile('memory://backup.txt', backup, false, '', io);

      // 写出内容应为 base32 文本，且只写一次
      const written = io.files.get('memory://backup.txt') ?? '';
      expect(written.length > 0).assertTrue();
      expect(io.writeCalls).assertEqual(1);

      // 清空内存分组后恢复：分组按 ID 合并回来
      TokenGroupStore.getInstance().state.groups = [];
      const restored = await restoreFromBackup('memory://backup.txt', false, '', undefined, io);
      expect(restored.magic).assertEqual(TOKEN_BACKUP_MAGIC);
      expect(restored.configs.length).assertEqual(2);
      expect(restored.configs[0].TokenUUID).assertEqual('u1');
      expect(restored.configs[1].TokenSecret).assertEqual('secret2');
      const groups = TokenGroupStore.getInstance().state.groups;
      expect(groups.length).assertEqual(1);
      expect(groups[0].id).assertEqual('g1');
    });

    it('encrypted_backup_roundtrip_with_fake_engine', 0, async () => {
      useCryptoEngineForTest(new FakeCryptoEngine());
      const io = new MemoryBackupTextIo();
      bindGroupStore();

      const backup = new TokenBackup(1, [makeToken('u1', 'enc_secret')]);
      await saveBackupToFile('memory://enc.txt', backup, true, 'password1', io);
      const written = io.files.get('memory://enc.txt') ?? '';
      expect(written.length > 0).assertTrue();

      const restored = await restoreFromBackup('memory://enc.txt', true, 'password1', undefined, io);
      expect(restored.configs.length).assertEqual(1);
      expect(restored.configs[0].TokenSecret).assertEqual('enc_secret');
    });

    it('restore_rejects_wrong_magic', 0, async () => {
      const io = new MemoryBackupTextIo();
      bindGroupStore();
      putBackupFile(io, 'memory://bad.txt', '{"magic":1,"version":1,"configs":[]}');

      let threw = false;
      try {
        await restoreFromBackup('memory://bad.txt', false, '', undefined, io);
      } catch (e) {
        threw = (e as Error).message === 'invalid backup file';
      }
      expect(threw).assertTrue();
    });

    it('restore_rejects_non_array_configs', 0, async () => {
      const io = new MemoryBackupTextIo();
      bindGroupStore();
      putBackupFile(io, 'memory://bad2.txt', `{"magic":${TOKEN_BACKUP_MAGIC},"version":1,"configs":{}}`);

      let threw = false;
      try {
        await restoreFromBackup('memory://bad2.txt', false, '', undefined, io);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('prepare_does_not_merge_groups_and_export_snapshot_is_detached', 0, async () => {
      bindGroupStore();
      const io = new MemoryBackupTextIo();
      const token = makeToken('snapshot', 'synthetic');
      const group = new TokenGroup('snapshot-group', 'Original');
      TokenGroupStore.getInstance().state.groups = [group];
      const backup = new TokenBackup(1, [token]);
      token.TokenName = 'Changed';
      group.name = 'Changed';
      await saveBackupToFile('synthetic.bak', backup, false, '', io);
      TokenGroupStore.getInstance().state.groups = [];
      const source = await readLocalBackupSource('synthetic.bak', io);
      const prepared = await source.prepare();
      expect(TokenGroupStore.getInstance().state.groups.length).assertEqual(0);
      const snapshot = prepared.takeForCommit();
      expect(snapshot.configs[0].TokenName).assertEqual('Name');
      expect(snapshot.groups[0].name).assertEqual('Original');
      source.dispose();
    });

    it('restore_missing_file_rejects', 0, async () => {
      const io = new MemoryBackupTextIo();
      bindGroupStore();
      let threw = false;
      try {
        await restoreFromBackup('memory://missing.txt', false, '', undefined, io);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });
}

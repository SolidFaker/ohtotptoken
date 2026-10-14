import { describe, beforeAll, afterEach, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import {
  AppPreference,
  DeviceMigrationKv,
  performBackup,
  performRestore,
  TokenConfig,
  TokenStore,
  otpType,
} from 'common';

/**
 * 真机换机迁移冒烟（Phase 3，docs/TEST_PLAN.md 第 4 节出口条件）。
 *
 * performBackup/performRestore 的编排决策（成功才清空明文中转 KV、错误向上传播）
 * 已在 LocalUnit 用内存端口穷举；本套件在真机验证默认 KvManager 生产适配器
 * （distributedKVStore 加密 KV ↔ 非加密 KV）可初始化、可同步往返、返回计数合理。
 *
 * 已知风险（红方评审标记，待真机核实）：生产扫描用 getEntries('^')（键前缀语义），
 * 而令牌键以 _token_uuid_ 开头——若分布式 KV 内部键形态不含 '^' 前缀，迁移会静默
 * 空转。roundtrip 用例用自种令牌 + backupCount > 0 硬护栏暴露该风险。
 */

/** 注入用假实现：copyToEncrypt 失败，验证恢复失败时不清理明文中转 */
class FailingRestoreKv implements DeviceMigrationKv {
  calls: string[] = [];

  initForBackup(_ctx: common.Context): Promise<void> {
    this.calls.push('init');
    return Promise.resolve();
  }

  copyToNoEncrypt(): Promise<number> {
    this.calls.push('backup');
    return Promise.resolve(3);
  }

  copyToEncrypt(): Promise<number> {
    this.calls.push('restore');
    return Promise.reject(new Error('restore boom'));
  }

  clearNoEncrypt(): Promise<void> {
    this.calls.push('clear');
    return Promise.resolve();
  }
}

/** 注入用假实现：init 即失败，验证 BackupExtension 依赖的错误传播契约 */
class FailingInitKv implements DeviceMigrationKv {
  initForBackup(_ctx: common.Context): Promise<void> {
    return Promise.reject(new Error('kv init boom'));
  }

  copyToNoEncrypt(): Promise<number> {
    return Promise.resolve(0);
  }

  copyToEncrypt(): Promise<number> {
    return Promise.resolve(0);
  }

  clearNoEncrypt(): Promise<void> {
    return Promise.resolve();
  }
}

export default function deviceMigrationTest(): void {
  describe('DeviceMigrationDeviceTest', () => {
    let context: common.UIAbilityContext;
    let seedToken: TokenConfig;
    const ownedIds: string[] = [];

    beforeAll(async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({
        bundleName: abilityDelegatorRegistry.getArguments().bundleName,
        abilityName: 'EntryAbility'
      });
      const ability = await delegator.waitAbilityMonitor(monitor, 20000);
      context = ability.context as common.UIAbilityContext;
      await delegator.removeAbilityMonitor(monitor);
      AppStorage.setOrCreate('appContext', context);
      await AppPreference.loadSettings();
      await TokenStore.getInstance().initTokenStore();
      await TokenStore.getInstance().LoadTokenByDataBase();
    });

    afterEach(async () => {
      // 兜底清理测试令牌（断言失败中断也不留脏数据）
      const store = TokenStore.getInstance();
      for (const uuid of ownedIds) {
        try {
          await store.deleteToken(uuid);
        } catch (_) {
          // 清理失败不掩盖用例结果
        }
      }
    });

    it('perform_backup_syncs_to_non_encrypt_kv', 0, async () => {
      // 生产适配器直通：加密 KV → 非加密 KV。自种令牌保证库非空，护栏 count > 0
      const store = TokenStore.getInstance();
      seedToken = new TokenConfig('JBSWY3DPEHPK3PXP', otpType.TOTP, 'MigrationSeed', 'MigrationSmokeIssuer');
      ownedIds.push(seedToken.TokenUUID);
      await store.updateToken(seedToken);

      const count = await performBackup(context);
      expect(Number.isFinite(count)).assertTrue();
      expect(count > 0).assertTrue();
    });

    it('perform_restore_roundtrip_returns_matching_count', 0, async () => {
      // 备份 → 恢复往返：单机无对端传输时，恢复读到的正是刚备份写入的条目；
      // 恢复成功（count>0）后明文中转被清空（生产编排决策）。
      // backupCount > 0 护栏防止 0==0 空转通过（getEntries('^') 风险探测）
      const store = TokenStore.getInstance();
      seedToken = new TokenConfig('JBSWY3DPEHPK3PXP', otpType.TOTP, 'MigrationRoundTrip', 'MigrationSmokeIssuer');
      ownedIds.push(seedToken.TokenUUID);
      await store.updateToken(seedToken);

      const backupCount = await performBackup(context);
      expect(backupCount > 0).assertTrue();
      const restoreCount = await performRestore(context);
      expect(Number.isFinite(restoreCount)).assertTrue();
      expect(restoreCount).assertEqual(backupCount);
    });

    it('restore_failure_does_not_clear_staging_kv', 0, async () => {
      // 设备侧固化编排契约：copyToEncrypt 抛错时向上传播，且不走 clearNoEncrypt
      const failingKv = new FailingRestoreKv();
      let threw = false;
      try {
        await performRestore(context, failingKv);
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(failingKv.calls.join(',')).assertEqual('init,restore');
    });

    it('backup_failure_propagates_error_to_extension', 0, async () => {
      // BackupExtension 依赖 performBackup 抛错感知失败：错误必须穿透而非被吞
      const failingKv = new FailingInitKv();
      let threw = false;
      try {
        await performBackup(context, failingKv);
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });
}

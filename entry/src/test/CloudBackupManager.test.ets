import { describe, it, expect } from '@ohos/hypium';
import { buffer } from '@kit.ArkTS';
import {
  AppPreference,
  BackupCryptoEngine,
  Base64Codec,
  CloudBackupAccountPort,
  CloudBackupCrypto,
  CloudBackupCryptoMode,
  CloudBackupTokenHeader,
  CloudBackupActionResult,
  CloudBackupFailureReason,
  CloudBackupIdentityStatus,
  CloudBackupMetadataStatus,
  CloudBackupOperationGate,
  CloudBackupOperationLease,
  DiagnosticContext,
  CloudBackupDevicePort,
  CloudBackupGroupPort,
  CloudBackupIconPort,
  CloudBackupManager,
  CloudBackupTokenPort,
  MemoryCloudBackupPublicationPort,
  CloudSyncFailureStage,
  CloudSyncFailureState,
  CloudSyncStarter,
  PREF_KEYS,
  TokenConfig,
  TokenGroup,
  otpType,
} from 'common';
import { sha256 } from '../main/ets/crypto/PureHash';
import { base64Decode, base64Encode, utf8ToBytes } from '../main/ets/steam/SteamCrypto';
import { MemoryFs } from './fakes/BackupFakes';
import { DownloadAwareFs, FakeFileCacher, cloudTestTurn } from './fakes/CloudCacheFakes';

/**
 * 云备份编排逻辑测试（Phase 2 端口注入：FsGateway + 账号/设备/令牌/分组/图标包/同步）。
 *
 * 覆盖：登录门禁、备份写文件与失败回退、MAX_BACKUP_COUNT 最旧清理、
 * 记录扫描（过滤/排序/头部解析降级）、新旧载荷恢复、三种清理粒度、
 * 自动备份门禁。加密数值由注入引擎保证可逆，不测 AES 本身。
 */

function bytesToHex(data: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < data.length; i++) {
    hex += data[i].toString(16).padStart(2, '0');
  }
  return hex;
}

class PureTsCodec implements Base64Codec {
  encodeText(text: string): string {
    return base64Encode(utf8ToBytes(text));
  }

  decodeText(base64Str: string): string {
    return buffer.from(base64Decode(base64Str)).toString('utf-8');
  }

  encodeBytes(data: Uint8Array): string {
    return base64Encode(data);
  }

  decodeBytes(base64Str: string): Uint8Array {
    return base64Decode(base64Str);
  }
}

/** 可逆 XOR 备份引擎（密钥流由 PureHash SHA-256 派生） */
class XorBackupEngine implements BackupCryptoEngine {
  round: number = 0;

  randomBytes(length: number): Uint8Array {
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      out[i] = (this.round * 37 + i * 13 + 5) & 0xff;
    }
    this.round++;
    return out;
  }

  async sha256Hex(data: string): Promise<string> {
    return bytesToHex(sha256(utf8ToBytes(data)));
  }

  async aesCbcEncrypt(plaintext: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    return this.xor(plaintext, password, salt, iv);
  }

  async aesCbcDecrypt(ciphertext: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    return this.xor(ciphertext, password, salt, iv);
  }

  private xor(data: Uint8Array, password: string, salt: Uint8Array, iv: Uint8Array): Uint8Array {
    const material = utf8ToBytes(password + ':' + bytesToHex(salt) + bytesToHex(iv));
    const pad = sha256(material);
    const out = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i++) {
      out[i] = data[i] ^ pad[i % pad.length];
    }
    return out;
  }
}

/** 只模拟原生失败边界，正确密钥仍执行可逆引擎；真实错误密钥 AES 用 Node 回归。 */
class NativeCryptoFailure extends Error {
  code: number;
  constructor(code: number) {
    super('SYNTHETIC_PRIVATE_CRYPTO_FAILURE');
    this.name = 'CloudBackupTokenError';
    this.code = code;
  }
}

class FaultInjectingBackupEngine extends XorBackupEngine {
  failDecrypt: boolean = false;
  failHash: boolean = false;
  emptyHash: boolean = false;

  async sha256Hex(data: string): Promise<string> {
    if (this.failHash) throw new NativeCryptoFailure(1);
    return this.emptyHash ? '' : super.sha256Hex(data);
  }

  async aesCbcDecrypt(ciphertext: Uint8Array, password: string, salt: Uint8Array,
    iv: Uint8Array): Promise<Uint8Array> {
    if (this.failDecrypt || password !== 'union-1') throw new NativeCryptoFailure(2);
    return super.aesCbcDecrypt(ciphertext, password, salt, iv);
  }
}

class FakeAccount implements CloudBackupAccountPort {
  login: boolean = true;
  union: string = 'union-1';

  isUserLogin(): boolean {
    return this.login;
  }

  unionId(): string {
    return this.union;
  }
}

class FakeDevice implements CloudBackupDevicePort {
  id: string = 'odid-A';
  name: string = 'Mate60';

  deviceId(): string {
    return this.id;
  }

  deviceName(): string {
    return this.name;
  }
}

class FakeTokens implements CloudBackupTokenPort {
  list: TokenConfig[] = [];
  updated: TokenConfig[] = [];
  updateAttempts: TokenConfig[] = [];
  /** 0 起，失败发生在该次写入之前；先前已成功的写入不能当作已回滚。 */
  failUpdateAt: number = -1;
  readCalls: number = 0;
  /** 快照读取失败（模拟 TokenStore/RDB 拒绝），不得向用户抛未处理异常。 */
  failGet: boolean = false;

  getTokens(): Promise<TokenConfig[]> {
    this.readCalls++;
    if (this.failGet) return Promise.reject(new Error('token store unavailable'));
    return Promise.resolve(this.list);
  }

  updateToken(token: TokenConfig): Promise<void> {
    const attempt = this.updateAttempts.length;
    this.updateAttempts.push(token);
    if (attempt === this.failUpdateAt) return Promise.reject(new Error('token write unavailable'));
    this.updated.push(token);
    return Promise.resolve();
  }
}

class FakeGroups implements CloudBackupGroupPort {
  groups: TokenGroup[] = [];
  mergedGroups: TokenGroup[] | null = null;
  mergeCalls: number = 0;

  currentGroups(): TokenGroup[] {
    return this.groups;
  }

  merge(groups: TokenGroup[] | undefined): Promise<void> {
    this.mergeCalls++;
    this.mergedGroups = groups !== undefined ? groups : null;
    return Promise.resolve();
  }
}

/** 延后阶段使用显式 release，不依赖 LocalUnit 的 wall clock。 */
class DeferredPhase {
  private release: (() => void) | null = null;

  wait(): Promise<void> {
    return new Promise<void>((resolve: () => void) => { this.release = resolve; });
  }

  complete(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }
}

class FakeIcons implements CloudBackupIconPort {
  backupCalls: number = 0;
  clearCalls: number = 0;
  clearAllCalls: number = 0;
  clearDeviceIds: string[][] = [];
  failBackup: boolean = false;
  rejectBackup: boolean = false;
  failClear: boolean = false;
  rejectClear: boolean = false;
  backupPhase: DeferredPhase | null = null;
  clearPhase: DeferredPhase | null = null;
  deferredSync: boolean[] = [];
  ownedLease: boolean[] = [];
  hasContext: boolean[] = [];
  deletedAtClear: number[] = [];
  events: string[] = [];
  fs: MemoryFs | null = null;

  private observe(owner?: CloudBackupOperationLease, deferSync?: boolean, context?: DiagnosticContext): void {
    this.deferredSync.push(deferSync === true);
    this.ownedLease.push(owner !== undefined && CloudBackupOperationGate.getInstance().owns(owner));
    this.hasContext.push(context !== undefined);
  }

  async backupIconPacks(owner?: CloudBackupOperationLease, deferSync?: boolean,
    context?: DiagnosticContext): Promise<boolean> {
    this.backupCalls++;
    this.observe(owner, deferSync, context);
    this.events.push('icons-backup-begin');
    if (this.backupPhase !== null) await this.backupPhase.wait();
    this.events.push('icons-backup-end');
    if (this.rejectBackup) throw new Error('icons unavailable');
    return !this.failBackup;
  }

  clearCloudBackup(owner?: CloudBackupOperationLease, deferSync?: boolean,
    context?: DiagnosticContext): Promise<boolean> {
    this.clearAllCalls++;
    return this.clear(owner, deferSync, context);
  }

  clearCloudBackupForDevices(ids: string[], owner?: CloudBackupOperationLease,
    deferSync?: boolean, context?: DiagnosticContext): Promise<boolean> {
    this.clearDeviceIds.push([...ids]);
    return this.clear(owner, deferSync, context);
  }

  private async clear(owner?: CloudBackupOperationLease, deferSync?: boolean,
    context?: DiagnosticContext): Promise<boolean> {
    this.clearCalls++;
    this.observe(owner, deferSync, context);
    this.deletedAtClear.push(this.fs !== null ? this.fs.deletedPaths.length : 0);
    this.events.push('icons-clear-begin');
    if (this.clearPhase !== null) await this.clearPhase.wait();
    this.events.push('icons-clear-end');
    if (this.rejectClear) throw new Error('icons unavailable');
    return !this.failClear;
  }
}

class FakeSync implements CloudSyncStarter {
  startCalls: number = 0;
  fail: boolean = false;
  events: string[] = [];
  fs: MemoryFs | null = null;
  deletedAtStart: number[] = [];

  async start(): Promise<void> {
    this.startCalls++;
    this.deletedAtStart.push(this.fs !== null ? this.fs.deletedPaths.length : 0);
    this.events.push('sync');
    if (this.fail) throw new Error('sync down');
  }
}

class FlakySync extends FakeSync {}

/** 可注入单文件 IO 故障，但不将仅云端位置冒充删除障碍。 */
class FlakyFs extends DownloadAwareFs {}

/** 在真实 fake 发布边界注入竞争或读回损坏，不替换管理器的安全分支。 */
class PublicationRaceFs extends DownloadAwareFs {
  collideTemp: boolean = false;
  collideFinal: boolean = false;
  corruptReadback: boolean = false;
  unreadableTemp: boolean = false;
  collidedPath: string = '';
  readonly otherOwnerContent: string = 'other-owner-file';

  async writeNewTextFile(path: string, content: string): Promise<void> {
    if (this.collideTemp) {
      this.collidedPath = path;
      this.files.set(path, this.otherOwnerContent);
    }
    await super.writeNewTextFile(path, content);
    if (this.corruptReadback) this.readOverride.set(path, '');
    if (this.unreadableTemp) this.failReadFor.add(path);
  }

  async publishFile(source: string, destination: string): Promise<void> {
    if (this.collideFinal) {
      this.collidedPath = destination;
      this.files.set(destination, this.otherOwnerContent);
    }
    await super.publishFile(source, destination);
  }
}

/** 发布后校验注入：正式文件被替换为不一致内容，或正式文件不可读。 */
class PostPublishFaultFs extends DownloadAwareFs {
  /** 发布成功后把正式文件替换为该内容（构造数量不一致的合法备份头）。 */
  mismatchFormal: string = '';
  /** 正式文件（otp_backup_*.enc）普通读取失败，模拟重读 IO 故障/缺失。 */
  unreadableFormal: boolean = false;

  async publishFile(source: string, destination: string): Promise<void> {
    await super.publishFile(source, destination);
    if (this.mismatchFormal !== '') {
      this.files.set(destination, this.mismatchFormal);
    }
  }

  async readTextFile(path: string): Promise<string> {
    if (this.unreadableFormal && /^\/cloud\/otp_backup_-?\d+\.enc(?![\s\S])/.test(path)) {
      throw new Error('formal read unavailable');
    }
    return super.readTextFile(path);
  }
}

class PublicationRejectedDeleteFs extends PostPublishFaultFs {
  async publishFile(source: string, destination: string): Promise<void> {
    await super.publishFile(source, destination);
    this.failDeleteFor.add(destination);
  }
}

function makeToken(uuid: string, secret: string): TokenConfig {
  const token = new TokenConfig(secret, otpType.TOTP);
  token.TokenUUID = uuid;
  token.RankScore = 0;
  return token;
}

interface TestRig {
  fs: DownloadAwareFs;
  account: FakeAccount;
  device: FakeDevice;
  tokens: FakeTokens;
  groups: FakeGroups;
  icons: FakeIcons;
  sync: FakeSync;
  cache: FakeFileCacher;
}

function freshRig(): TestRig {
  CloudBackupCrypto.useEngineForTest(new XorBackupEngine(), new PureTsCodec());
  AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '');
  AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_FAILURE, '');
  // 复位静态偏好与单例，隔离套件间污染
  AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
  AppPreference.setPreference(PREF_KEYS.ICON_PACK_CLOUD_SYNC_TIME, '');
  CloudBackupManager.getInstance().resetForTest();

  const fs = new DownloadAwareFs();
  const rig: TestRig = {
    fs: fs,
    cache: new FakeFileCacher(fs),
    account: new FakeAccount(),
    device: new FakeDevice(),
    tokens: new FakeTokens(),
    groups: new FakeGroups(),
    icons: new FakeIcons(),
    sync: new FakeSync(),
  };
  bindRig(rig);
  return rig;
}

function bindRig(rig: TestRig): void {
  rig.icons.fs = rig.fs;
  rig.sync.events = rig.icons.events;
  rig.sync.fs = rig.fs;
  CloudBackupManager.getInstance().useDepsForTest({
    fs: rig.fs, account: rig.account, device: rig.device, tokens: rig.tokens,
    groups: rig.groups, icons: rig.icons, sync: rig.sync, cache: rig.cache, cloudDir: '/cloud',
  });
}

function formalPaths(fs: MemoryFs): string[] {
  const paths: string[] = [];
  fs.files.forEach((_: string, path: string) => {
    if (/^\/cloud\/otp_backup_-?\d+\.enc(?![\s\S])/.test(path)) paths.push(path);
  });
  return paths.sort();
}

function invalidBackupIds(): string[] {
  return ['', '../otp_backup_42.enc', '/cloud/otp_backup_42.enc', 'child/otp_backup_42.enc',
    'child\\otp_backup_42.enc', 'otp_backup_42.enc/../other', 'otp_backup_42.enc.tmp',
    'prefix_otp_backup_42.enc', 'otp_backup_42tail.enc', 'otp_backup_1.5.enc',
    'otp_backup_1e3.enc', 'otp_backup_+42.enc', 'otp_backup_--42.enc',
    'otp_backup_NaN.enc', 'otp_backup_9007199254740992.enc', 'otp_backup_42.enc\n',
    'otp_backup_42.enc\r', 'otp_backup_42.enc\r\n', 'otp_backup_42.enc\u2028',
    'otp_backup_42.enc\u2029', 'otp_backup_42.enc\u0000'];
}

function clearScope(manager: CloudBackupManager, scope: number): Promise<CloudBackupActionResult> {
  return scope === 0 ? manager.clearCloudStorageResult() : scope === 1 ? manager.clearDeviceCloudStorageResult()
    : manager.clearDeviceNameCloudStorageResult();
}

function backupFileName(ts: number): string {
  return `otp_backup_${ts}.enc`;
}

/** 直接向假文件系统写入一份合法加密备份 */
async function seedBackup(rig: TestRig, ts: number, plaintext: string, deviceId: string,
  deviceName: string = 'Mate60'): Promise<void> {
  const crypto = CloudBackupCrypto.getInstance();
  const content = await crypto.encrypt(plaintext, crypto.getMode(true), 'union-1', 1, ts, deviceId, deviceName);
  rig.fs.files.set(`/cloud/${backupFileName(ts)}`, content);
}

/** 每个负例都经过正常加密/签名，排除“签名失败掩盖结构验证”的伪回归。 */
async function assertInvalidRestoreHasNoSideEffects(payload: string): Promise<void> {
  const rig = freshRig();
  rig.tokens.list = [makeToken('existing-local', 'existing-secret')];
  rig.groups.groups = [new TokenGroup('existing-group', 'Keep group')];
  AppPreference.setPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED, '["keep-pack"]');
  AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
  await seedBackup(rig, 112, payload, 'odid-A');
  const path = '/cloud/otp_backup_112.enc';
  const source = rig.fs.files.get(path)!;
  expect(await CloudBackupCrypto.getInstance().verifyToken(source)).assertTrue();

  const manager = CloudBackupManager.getInstance();
  const result = await manager.restoreFromBackupRecordResult('otp_backup_112.enc');
  expect(result.success).assertFalse();
  expect(result.reason).assertEqual(CloudBackupFailureReason.DECRYPT_FAILED);
  expect(result.partialFailure).assertFalse();
  expect(result.localComplete).assertFalse();
  expect(result.syncStartAccepted).assertFalse();
  expect(rig.tokens.updateAttempts.length).assertEqual(0);
  expect(rig.tokens.updated.length).assertEqual(0);
  expect(rig.tokens.list.length).assertEqual(1);
  expect(rig.tokens.list[0].TokenUUID).assertEqual('existing-local');
  expect(rig.groups.mergeCalls).assertEqual(0);
  expect(rig.groups.mergedGroups).assertNull();
  expect(rig.groups.groups[0].id).assertEqual('existing-group');
  expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED)).assertEqual('["keep-pack"]');
  expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
  expect(rig.fs.newWriteCalls.length).assertEqual(0);
  expect(rig.fs.deleteAttempts.length).assertEqual(0);
  expect(rig.fs.files.get(path)).assertEqual(source);
  expect(rig.icons.backupCalls).assertEqual(0);
  expect(rig.icons.clearCalls).assertEqual(0);
  expect(rig.sync.startCalls).assertEqual(0);
  expect(manager.isBusy()).assertFalse();
}

function payloadWithLateToken(late: string, legacy: boolean = false): string {
  const first = JSON.stringify(makeToken('valid-first', 'first-secret'));
  const tokens = `[${first},${late}]`;
  return legacy ? tokens : `{"tokens":${tokens},"groups":[{"id":"new-group","name":"Imported"}],` +
    '"enabledPacks":["new-pack"]}';
}

export default function cloudBackupManagerTest() {
  describe('cloudBackupManagerTest', () => {
    it('backup_aborts_when_not_logged_in', 0, async () => {
      const rig = freshRig();
      rig.account.login = false;

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertFalse();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('backup_success_writes_file_sets_pref_and_triggers_sync_icons', 0, async () => {
      const rig = freshRig();
      rig.tokens.list = [makeToken('u1', 'secret1')];

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertTrue();
      // 文件名规则 otp_backup_{ts}.enc
      let backupFiles: string[] = [];
      rig.fs.files.forEach((_: string, name: string) => {
        backupFiles.push(name.substring(name.lastIndexOf('/') + 1));
      });
      expect(backupFiles.length).assertEqual(1);
      expect(backupFiles[0].startsWith('otp_backup_')).assertTrue();
      expect(backupFiles[0].endsWith('.enc')).assertTrue();
      // 独占临时写入 → 读回验证 → 不覆盖发布，图标阶段结束后才提交一次同步。
      expect(rig.fs.newWriteCalls.length).assertEqual(1);
      const temp = rig.fs.newWriteCalls[0];
      expect(temp.startsWith('/cloud/.otp_backup_pending_')).assertTrue();
      expect(rig.fs.readPaths.includes(temp)).assertTrue();
      expect(rig.fs.files.has(temp)).assertFalse();
      expect(rig.fs.publishedPairs.length).assertEqual(1);
      expect(rig.fs.publishedPairs[0]).assertEqual(`${temp}->/cloud/${backupFiles[0]}`);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(rig.icons.backupCalls).assertEqual(1);
      expect(rig.icons.deferredSync[0]).assertTrue();
      expect(rig.icons.ownedLease[0]).assertTrue();
      expect(rig.icons.hasContext[0]).assertTrue();
      expect(rig.icons.events.join(',')).assertEqual('icons-backup-begin,icons-backup-end,sync');
      // last time 已记录（同步内存缓存）
      const lastTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
      expect(lastTime.length > 0).assertTrue();
    });

    it('backup_write_failure_returns_false', 0, async () => {
      const rig = freshRig();
      rig.fs.failWrite = true;

      const result = await CloudBackupManager.getInstance().backupToCloud();
      expect(result).assertFalse();
      expect(rig.sync.startCalls).assertEqual(0);
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.fs.publishAttempts.length).assertEqual(0);
      expect(rig.icons.backupCalls).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('');
    });

    it('post_publish_verify_pass_clears_failure_key_and_updates_time', 0, async () => {
      const rig = freshRig();
      rig.tokens.list = [makeToken('u1', 'secret1')];
      // 预置一次历史失败状态：备份成功（含发布后校验通过）后必须清除。
      CloudSyncFailureState.record(CloudSyncFailureStage.SYNC, CloudBackupFailureReason.SYNC_FAILED);

      const result = await CloudBackupManager.getInstance().backupToCloudResult();
      expect(result.success).assertTrue();
      expect((AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string).length > 0).assertTrue();
      expect(CloudSyncFailureState.read()).assertNull();
    });

    it('post_publish_verify_count_mismatch_fails_cleans_formal_and_propagates', 0, async () => {
      const rig = freshRig();
      rig.tokens.list = [makeToken('u1', 'secret1')];
      const fs = new PostPublishFaultFs();
      const crypto = CloudBackupCrypto.getInstance();
      // 发布后被偷换为"合法但令牌数量不一致"的备份头（0 vs 本机 1）。
      fs.mismatchFormal = await crypto.encrypt('{}', crypto.getMode(true), 'union-1', 0, 999, 'odid-A', 'Mate60');
      CloudBackupManager.getInstance().useDepsForTest({
        fs: fs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cache: rig.cache, cloudDir: '/cloud',
      });

      const result = await CloudBackupManager.getInstance().backupToCloudResult();
      expect(result.success).assertFalse();
      expect(result.reason).assertEqual(CloudBackupFailureReason.POST_VERIFY_FAILED);
      // 正式目录无本次备份残留；删除已随同步提交传播。
      expect(formalPaths(fs).length).assertEqual(0);
      expect(fs.deletedPaths.length).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(rig.icons.backupCalls).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('');
      const failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.POST_PUBLISH_VERIFY);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.POST_VERIFY_FAILED);
      }
    });

    it('post_publish_verify_read_failure_fails_without_time_update', 0, async () => {
      const rig = freshRig();
      rig.tokens.list = [makeToken('u1', 'secret1')];
      const fs = new PostPublishFaultFs();
      fs.unreadableFormal = true;
      CloudBackupManager.getInstance().useDepsForTest({
        fs: fs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cache: rig.cache, cloudDir: '/cloud',
      });

      const result = await CloudBackupManager.getInstance().backupToCloudResult();
      expect(result.success).assertFalse();
      expect(result.reason).assertEqual(CloudBackupFailureReason.POST_VERIFY_FAILED);
      // 重读失败也收敛为校验失败：文件被尝试清理并传播，时间与失败键如实落库。
      expect(formalPaths(fs).length).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('');
      const failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.POST_PUBLISH_VERIFY);
      }
    });

    it('publication_manager_compound_unlink_sync_failure_survives_restart_and_blocks_restore', 0, async () => {
      const rig = freshRig();
      rig.tokens.list = [makeToken('guard-synthetic', 'guard-secret')];
      const manager = CloudBackupManager.getInstance();
      const rejectFs = new PublicationRejectedDeleteFs();
      rejectFs.unreadableFormal = true;
      const rejectedPublication = new MemoryCloudBackupPublicationPort(rejectFs);
      manager.useDepsForTest({ fs: rejectFs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud', publication: rejectedPublication });
      const failed = await manager.backupToCloudResult();
      expect(failed.reason).assertEqual(CloudBackupFailureReason.POST_VERIFY_FAILED);
      expect(failed.partialFailure).assertTrue();
      expect(rejectedPublication.receipts.size).assertEqual(1);
      const id = formalPaths(rejectFs)[0].substring('/cloud/'.length);
      manager.resetForTest();
      manager.useDepsForTest({ fs: rejectFs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud', publication: rejectedPublication });
      rejectFs.unreadableFormal = false;
      const history = await manager.listBackupHistoryResult();
      expect(history.records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.INVALID);
      expect(history.records[0].tokenCountKnown).assertFalse();
      expect((await manager.restoreFromBackupRecordResult(id)).reason).assertEqual(CloudBackupFailureReason.POST_VERIFY_FAILED);
      expect(rig.tokens.updated.length).assertEqual(0);
      rejectFs.failDeleteFor.clear();
      rig.sync.fail = true;
      expect(await manager.retryPendingCleanup()).assertFalse();
      expect(formalPaths(rejectFs).length).assertEqual(0);
      expect(rejectedPublication.receipts.size).assertEqual(1);
      rig.sync.fail = false;
      expect(await manager.retryPendingCleanup()).assertTrue();
      expect(rejectedPublication.receipts.size).assertEqual(0);
    });

    it('backup_failure_records_persistent_failure_key_by_stage', 0, async () => {
      // 设备身份不可用 → 阶段 DEVICE_INFO
      let rig = freshRig();
      rig.device.id = '';
      expect((await CloudBackupManager.getInstance().backupToCloudResult()).reason)
        .assertEqual(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
      let failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.DEVICE_INFO);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
      }

      // 写入失败 → 阶段 WRITE / WRITE_FAILED，正式目录无残留
      rig = freshRig();
      rig.fs.failWrite = true;
      expect(await CloudBackupManager.getInstance().backupToCloud()).assertFalse();
      failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.WRITE);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
      }
      expect(formalPaths(rig.fs).length).assertEqual(0);

      // 发布失败 → 阶段 PUBLISH（同一 WRITE_FAILED 原因码下的细分阶段）
      rig = freshRig();
      rig.fs.failPublish = true;
      expect(await CloudBackupManager.getInstance().backupToCloud()).assertFalse();
      failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.PUBLISH);
      }
      expect(formalPaths(rig.fs).length).assertEqual(0);

      // 加密失败 → 阶段 ENCRYPT / FORMAT_INVALID
      rig = freshRig();
      const faultEngine = new FaultInjectingBackupEngine();
      faultEngine.failHash = true;
      CloudBackupCrypto.useEngineForTest(faultEngine, new PureTsCodec());
      rig.tokens.list = [makeToken('u1', 'secret1')];
      expect((await CloudBackupManager.getInstance().backupToCloudResult()).reason)
        .assertEqual(CloudBackupFailureReason.FORMAT_INVALID);
      failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.ENCRYPT);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.FORMAT_INVALID);
      }
      expect(formalPaths(rig.fs).length).assertEqual(0);

      // 令牌快照读取失败 → 阶段 SNAPSHOT / READ_FAILED（零容忍，异常不外泄）
      rig = freshRig();
      rig.tokens.failGet = true;
      expect((await CloudBackupManager.getInstance().backupToCloudResult()).reason)
        .assertEqual(CloudBackupFailureReason.READ_FAILED);
      failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.SNAPSHOT);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.READ_FAILED);
      }
      expect(rig.fs.newWriteCalls.length).assertEqual(0);

      // 暂存回读损坏 → 阶段 STAGED_VERIFY（phase=FS_VERIFY 映射），发布未发生
      rig = freshRig();
      const raceFs = new PublicationRaceFs();
      raceFs.corruptReadback = true;
      rig.tokens.list = [makeToken('u1', 'secret1')];
      CloudBackupManager.getInstance().useDepsForTest({
        fs: raceFs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cache: rig.cache, cloudDir: '/cloud',
      });
      expect((await CloudBackupManager.getInstance().backupToCloudResult()).reason)
        .assertEqual(CloudBackupFailureReason.WRITE_FAILED);
      failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.STAGED_VERIFY);
      }
      expect(raceFs.publishAttempts.length).assertEqual(0);

      // 同步提交失败 → 阶段 SYNC / SYNC_FAILED（本地文件已发布并校验通过）
      rig = freshRig();
      rig.tokens.list = [makeToken('u1', 'secret1')];
      rig.sync.fail = true;
      const syncFail = await CloudBackupManager.getInstance().backupToCloudResult();
      expect(syncFail.success).assertFalse();
      expect(syncFail.reason).assertEqual(CloudBackupFailureReason.SYNC_FAILED);
      failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.SYNC);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.SYNC_FAILED);
      }
      expect(formalPaths(rig.fs).length).assertEqual(1);
    });

    it('rotation_prune_failure_is_partial_failure_and_persisted', 0, async () => {
      const rig = freshRig();
      const manager = CloudBackupManager.getInstance();
      for (let i = 0; i < manager.maxBackupCount; i++) {
        expect(await manager.backupToCloud()).assertTrue();
      }
      // 最老有效本机记录删除失败：不静默标记完全成功，失败计入并持久展示。
      rig.fs.failDeleteFor.add(formalPaths(rig.fs)[0]);
      const result = await manager.backupToCloudResult();
      expect(result.success).assertFalse();
      expect(result.partialFailure).assertTrue();
      expect(result.reason).assertEqual(CloudBackupFailureReason.DELETE_FAILED);
      const failure = CloudSyncFailureState.read();
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure.stage).assertEqual(CloudSyncFailureStage.ROTATE);
        expect(failure.reason).assertEqual(CloudBackupFailureReason.DELETE_FAILED);
      }
    });

    it('backup_prunes_oldest_only_beyond_max_count', 0, async () => {
      const rig = freshRig();
      const manager = CloudBackupManager.getInstance();
      // 重复创建使用管理器单调文件号，不要求 stub 时钟推进，也不制造负 header 时间。
      expect(await manager.backupToCloud()).assertTrue();
      const oldest = formalPaths(rig.fs)[0];
      for (let i = 1; i < manager.maxBackupCount; i++) {
        expect(await manager.backupToCloud()).assertTrue();
      }
      expect(formalPaths(rig.fs).length).assertEqual(5);
      expect(rig.fs.deletedPaths.length).assertEqual(0);
      const before = formalPaths(rig.fs);
      // 其他设备和不可解析历史均不属于本机自动保留策略，不能当作失败产物回收。
      await seedBackup(rig, 253402300799000, '{"tokens":[]}', 'odid-B');
      rig.fs.files.set('/cloud/otp_backup_253402300799001.enc', 'broken-history');
      const foreign = rig.fs.files.get('/cloud/otp_backup_253402300799000.enc');
      expect(await manager.backupToCloud()).assertTrue();
      expect(formalPaths(rig.fs).length).assertEqual(7);
      expect(rig.fs.deletedPaths.length).assertEqual(1);
      expect(rig.fs.deletedPaths[0]).assertEqual(oldest);
      for (const path of before) {
        expect(rig.fs.files.has(path)).assertEqual(path !== oldest);
      }
      expect(rig.fs.files.get('/cloud/otp_backup_253402300799000.enc')).assertEqual(foreign);
      expect(rig.fs.files.get('/cloud/otp_backup_253402300799001.enc')).assertEqual('broken-history');
    });

    it('list_history_filters_suffix_and_nan_and_sorts_desc', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 2000, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 3000, '{"tokens":[]}', 'odid-B');
      rig.fs.files.set('/cloud/otp_backup_notanumber.enc', 'junk');
      rig.fs.files.set('/cloud/unrelated.txt', 'junk');

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(2);
      // 时间戳降序
      expect(records[0].timestamp).assertEqual(3000);
      expect(records[1].timestamp).assertEqual(2000);
      // 头部解析成功：deviceId/设备名来自加密头
      expect(records[0].deviceId).assertEqual('odid-B');
      expect(records[0].deviceName).assertEqual('Mate60');
    });

    it('list_history_header_parse_failure_falls_back_to_stat', 0, async () => {
      const rig = freshRig();
      // 非 JWT 三段式内容 → 头部解析失败，回退 stat
      rig.fs.files.set('/cloud/otp_backup_4000.enc', 'not-a-jwt');

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(1);
      expect(records[0].tokenCount).assertEqual(0);
      expect(records[0].deviceId).assertEqual('');
      expect(records[0].size).assertEqual(9);
    });

    it('restore_from_cloud_false_when_no_records', 0, async () => {
      const rig = freshRig();
      const result = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(result).assertFalse();
      expect(rig.tokens.updated.length).assertEqual(0);
    });

    it('restore_new_payload_restores_tokens_groups_and_packs', 0, async () => {
      const rig = freshRig();
      const tokenJson = JSON.stringify(makeToken('u1', 'restored_secret'));
      const payload = `{"tokens":[${tokenJson}],"groups":[{"id":"g1","name":"Work"}],"enabledPacks":["pack-x"],"packMeta":[]}`;
      await seedBackup(rig, 5000, payload, 'odid-A');
      await seedBackup(rig, 6000, payload, 'odid-A');

      // 恢复最新（6000）
      const result = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(result).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenUUID).assertEqual('u1');
      expect(rig.tokens.updated[0].TokenSecret).assertEqual('restored_secret');
      expect(rig.groups.mergedGroups !== null && rig.groups.mergedGroups!.length === 1).assertTrue();
    });

    it('restore_legacy_array_payload_skips_group_merge', 0, async () => {
      const rig = freshRig();
      const tokenJson = JSON.stringify(makeToken('legacy', 'legacy_secret'));
      await seedBackup(rig, 7000, `[${tokenJson}]`, 'odid-A');

      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord(backupFileName(7000));
      expect(result).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenUUID).assertEqual('legacy');
      expect(rig.groups.mergedGroups).assertNull();
    });

    it('restore_cloud_only_file_location2_still_restores', 0, async () => {
      const rig = freshRig();
      const tokenJson = JSON.stringify(makeToken('cloud', 'cloud_secret'));
      await seedBackup(rig, 8600, `{"tokens":[${tokenJson}]}`, 'odid-A');
      // 本用例未配置 readableCloudPaths，保留缓存完成前读取失败的场景。
      rig.fs.locationOverride.set('/cloud/otp_backup_8600.enc', 2);

      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord(backupFileName(8600));
      expect(result).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenSecret).assertEqual('cloud_secret');
    });

    it('restore_missing_record_returns_false', 0, async () => {
      freshRig();
      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord('otp_backup_9999.enc');
      expect(result).assertFalse();
    });

    it('list_history_parses_header_of_cloud_only_location2_records', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 8700, '{"tokens":[]}', 'odid-B', 'OtherDev');
      // 本用例选择未缓存即不可读的 fake 行为，不代表 location=2 必然无法普通读取。
      rig.fs.locationOverride.set('/cloud/otp_backup_8700.enc', 2);

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(1);
      // header 解析成功 → 设备归属/令牌数不降级为空/0
      expect(records[0].deviceId).assertEqual('odid-B');
      expect(records[0].deviceName).assertEqual('OtherDev');
      expect(records[0].tokenCount).assertEqual(1);
      expect(rig.cache.calls.length).assertEqual(1);
      expect(rig.fs.locationOverride.get('/cloud/otp_backup_8700.enc')).assertEqual(3);
    });

    it('clear_all_deletes_cloud_only_location2_files', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 8800, '{"tokens":[]}', 'odid-B', 'OtherDev');
      rig.fs.locationOverride.set('/cloud/otp_backup_8800.enc', 2);

      const ok = await CloudBackupManager.getInstance().clearCloudStorage();
      expect(ok).assertTrue();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.fs.deleteAttempts.includes('/cloud/otp_backup_8800.enc')).assertTrue();
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('device_scoped_clear_skips_unresolved_and_reports_counts', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9340, '{"tokens":[]}', 'odid-A');
      // header 不可解析（如事故孤儿）：设备归属无法确认 → 跳过保留，不再阻断本设备清理
      rig.fs.files.set('/cloud/otp_backup_9350.enc', 'junk');

      const byDevice = await CloudBackupManager.getInstance().clearDeviceCloudStorageResult();
      expect(byDevice.success).assertTrue();
      expect(byDevice.deletedCount).assertEqual(1);
      expect(byDevice.skippedUnowned).assertEqual(1);
      expect(rig.fs.files.has('/cloud/otp_backup_9340.enc')).assertFalse();
      expect(rig.fs.files.has('/cloud/otp_backup_9350.enc')).assertTrue();
      // 无归属记录绝不自动认领：图标清理只覆盖归属明确的设备。
      expect(rig.icons.clearDeviceIds[0].join(',')).assertEqual('odid-A');

      // 同名旧安装清理：无法确认设备名的记录同样跳过并计数（本机记录不属于同名旧安装范围）。
      const byName = await CloudBackupManager.getInstance().clearDeviceNameCloudStorageResult();
      expect(byName.success).assertTrue();
      expect(byName.skippedUnowned).assertEqual(1);
      expect(byName.deletedCount).assertEqual(0);
      expect(rig.fs.files.has('/cloud/otp_backup_9350.enc')).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(1);
    });

    it('cache_cloud_only_backups_scans_backup_files_only', 0, async () => {
      const rig = freshRig();
      const flaky = new FlakyFs();
      const cache = new FakeFileCacher(flaky);
      CloudBackupManager.getInstance().useDepsForTest({
        fs: flaky, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cache: cache, cloudDir: '/cloud',
      });
      const crypto = CloudBackupCrypto.getInstance();
      const mk = async (ts: number, odid: string): Promise<void> => {
        const content = await crypto.encrypt('{}', crypto.getMode(true), 'union-1', 1, ts, odid, 'Mate60');
        flaky.files.set(`/cloud/${backupFileName(ts)}`, content);
      };
      await mk(8900, 'odid-A');
      await mk(8950, 'odid-B');
      flaky.files.set('/cloud/icon_packs_backup.zip', 'zipbytes');
      // 一个云端仅存（触发缓存分支）、一个本地（跳过）、一个 stat 失败（跳过并继续）
      flaky.locationOverride.set('/cloud/otp_backup_8900.enc', 2);
      flaky.failStatFor.add('/cloud/otp_backup_8950.enc');

      await CloudBackupManager.getInstance().cacheCloudOnlyBackups();
      // 只缓存备份文件；stat 失败不阻断历史的降级展示
      expect(flaky.files.size).assertEqual(3);
      expect(flaky.deletedPaths.length).assertEqual(0);
      expect(cache.calls.length).assertEqual(1);
      expect(cache.calls[0]).assertEqual('/cloud/otp_backup_8900.enc');
      expect(flaky.readPaths.length).assertEqual(0);
    });

    it('restore_aborts_when_not_logged_in', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 8000, '{"tokens":[]}', 'odid-A');
      rig.account.login = false;

      const result = await CloudBackupManager.getInstance().restoreFromBackupRecord(backupFileName(8000));
      expect(result).assertFalse();
      expect(rig.tokens.updated.length).assertEqual(0);
    });

    it('clear_storage_deletes_all_and_resets_last_time', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9100, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 9200, '{"tokens":[]}', 'odid-B');

      const result = await CloudBackupManager.getInstance().clearCloudStorage();
      expect(result).assertTrue();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(1);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('0');
      // 批量清理后触发 FileSync 将删除动作推到云端
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('clear_device_storage_deletes_only_matching_odid', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9300, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 9400, '{"tokens":[]}', 'odid-B');

      const result = await CloudBackupManager.getInstance().clearDeviceCloudStorage();
      expect(result).assertTrue();
      expect(rig.fs.files.size).assertEqual(1);
      expect(rig.fs.files.has('/cloud/otp_backup_9400.enc')).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('clear_device_name_storage_deletes_stale_install_only', 0, async () => {
      const rig = freshRig();
      // 同名设备、不同 ODID（卸载重装遗留）
      await seedBackup(rig, 9500, '{"tokens":[]}', 'odid-OLD');
      // 当前 ODID：保留；其他名称：保留
      await seedBackup(rig, 9600, '{"tokens":[]}', 'odid-A');
      await seedBackup(rig, 9700, '{"tokens":[]}', 'odid-B', 'OtherDev');

      const result = await CloudBackupManager.getInstance().clearDeviceNameCloudStorage();
      expect(result).assertTrue();
      expect(rig.fs.files.size).assertEqual(2);
      expect(rig.fs.files.has('/cloud/otp_backup_9600.enc')).assertTrue();
      expect(rig.fs.files.has('/cloud/otp_backup_9700.enc')).assertTrue();
      // 有实际删除才清理图标包
      expect(rig.icons.clearCalls).assertEqual(1);

      // 无遗留：不触发图标包清理
      const iconsBefore = rig.icons.clearCalls;
      const again = await CloudBackupManager.getInstance().clearDeviceNameCloudStorage();
      expect(again).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(iconsBefore);
    });

    it('delete_record_syncs_only_on_success', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9800, '{"tokens":[]}', 'odid-A');

      const missing = await CloudBackupManager.getInstance().deleteBackupRecord('otp_backup_1111.enc');
      expect(missing).assertTrue();
      expect(rig.sync.startCalls).assertEqual(1);

      const ok = await CloudBackupManager.getInstance().deleteBackupRecord(backupFileName(9800));
      expect(ok).assertTrue();
      expect(rig.sync.startCalls).assertEqual(2);
    });

    it('auto_backup_skips_when_disabled', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);

      await CloudBackupManager.getInstance().checkAndAutoBackup();
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('auto_backup_runs_when_last_backup_is_stale', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      // 上次备份相对 stub 时钟在一天前 → 不命中"今日已备份"跳过分支
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${Date.now() - 86400000}`);

      await CloudBackupManager.getInstance().checkAndAutoBackup();
      expect(rig.fs.written.size).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('auto_backup_skips_when_logged_out', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      rig.account.login = false;

      await CloudBackupManager.getInstance().checkAndAutoBackup();
      expect(rig.fs.written.size).assertEqual(0);
    });

    it('restore_invalid_record_returns_false_without_writes', 0, async () => {
      const rig = freshRig();
      // 非 3 段格式 → decrypt 抛 CloudBackupTokenError → 恢复失败且异常被吞、零写入
      rig.fs.files.set(`/cloud/${backupFileName(9500)}`, 'garbage-not-a-token');

      const ok = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(ok).assertFalse();
      expect(rig.tokens.updated.length).assertEqual(0);
    });

    it('backup_sync_failure_preserves_local_file_but_not_success_time', 0, async () => {
      const rig = freshRig();
      rig.sync.fail = true;
      rig.tokens.list.push(makeToken('u1', 'SECRET'));
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
      const manager = CloudBackupManager.getInstance();
      const result = await manager.backupToCloudResult();
      expect(result.success).assertFalse();
      expect(result.reason).assertEqual(CloudBackupFailureReason.SYNC_FAILED);
      expect(result.localComplete).assertTrue();
      expect(result.syncStartAccepted).assertFalse();
      expect(formalPaths(rig.fs).length).assertEqual(1);
      expect(rig.icons.backupCalls).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
      // 旧布尔接口不能继续误报成功；独立重试同步不应再创建一份备份。
      expect(await manager.backupToCloud()).assertFalse();
      const filesBefore = formalPaths(rig.fs).join(',');
      rig.sync.fail = false;
      expect(await manager.retrySync()).assertTrue();
      expect(formalPaths(rig.fs).join(',')).assertEqual(filesBefore);
      expect(rig.sync.startCalls).assertEqual(3);
    });

    it('clear_cloud_storage_reports_failure_when_delete_fails', 0, async () => {
      const rig = freshRig();
      const flaky = new FlakyFs();
      // useDepsForTest 为整体替换语义：先注入再向同一个假文件系统种子备份
      CloudBackupManager.getInstance().useDepsForTest({
        fs: flaky, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud',
      });
      const crypto = CloudBackupCrypto.getInstance();
      const content = await crypto.encrypt('{}', crypto.getMode(true), 'union-1', 1, 9100, 'odid-A', 'Mate60');
      flaky.files.set(`/cloud/${backupFileName(9100)}`, content);
      flaky.failDeleteFor.add(`/cloud/${backupFileName(9100)}`);

      const ok = await CloudBackupManager.getInstance().clearCloudStorage();
      // 部分删除失败必须如实返回 false：云端残留文件时不得向用户报"清理成功"
      // （此前测试标注的"归产品决策"已由用户反馈落锤：误报成功即缺陷）
      expect(ok).assertFalse();
      // 全部范围不依赖 token 归属，token 失败仍尝试图标；两阶段之后只同步一次。
      expect(rig.icons.clearCalls).assertEqual(1);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string).assertEqual('');
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('clear_methods_return_false_when_any_target_delete_fails', 0, async () => {
      const rig = freshRig();
      const flaky = new FlakyFs();
      CloudBackupManager.getInstance().useDepsForTest({
        fs: flaky, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud',
      });
      // f1=当前 ODID、f2=同名旧安装（deviceName 匹配当前设备）、f3=异名他设备
      const crypto = CloudBackupCrypto.getInstance();
      const mk = async (ts: number, odid: string, name: string): Promise<void> => {
        const content = await crypto.encrypt('{}', crypto.getMode(true), 'union-1', 1, ts, odid, name);
        flaky.files.set(`/cloud/${backupFileName(ts)}`, content);
      };
      await mk(9310, 'odid-A', 'Mate60');
      await mk(9320, 'odid-OLD', 'Mate60');
      await mk(9330, 'odid-B', 'OtherDev');

      // 本设备清理：目标 f1 删除失败 → false
      flaky.failDeleteFor.add(`/cloud/${backupFileName(9310)}`);
      expect(await CloudBackupManager.getInstance().clearDeviceCloudStorage()).assertFalse();
      expect(rig.icons.clearCalls).assertEqual(1);
      expect(flaky.files.has(`/cloud/${backupFileName(9310)}`)).assertTrue();

      // 同名旧备份保留 token 归属证据，先清图标再删 token
      flaky.failDeleteFor.delete(`/cloud/${backupFileName(9310)}`);
      flaky.failDeleteFor.add(`/cloud/${backupFileName(9320)}`);
      expect(await CloudBackupManager.getInstance().clearDeviceNameCloudStorage()).assertFalse();
      expect(rig.icons.clearCalls).assertEqual(2);

      // 全量清理：f2 仍失败，但仍清理不依赖该 token 的图标。
      expect(await CloudBackupManager.getInstance().clearCloudStorage()).assertFalse();
      expect(rig.icons.clearCalls).assertEqual(3);
      expect(rig.sync.startCalls).assertEqual(3);
      expect(flaky.files.has(`/cloud/${backupFileName(9320)}`)).assertTrue();
      expect(flaky.files.has(`/cloud/${backupFileName(9310)}`)).assertFalse();
      expect(flaky.files.has(`/cloud/${backupFileName(9330)}`)).assertFalse();
    });

    it('clear_device_name_storage_noop_does_not_clear_icons', 0, async () => {
      const rig = freshRig();
      // 只有"同名不同 ODID"才算遗留备份；异名设备备份不受影响、不触发图标包清理
      await seedBackup(rig, 9200, '{}', 'odid-B', 'Pixel8');

      const ok = await CloudBackupManager.getInstance().clearDeviceNameCloudStorage();
      expect(ok).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(0);
      expect(rig.fs.deletedPaths.length).assertEqual(0);
    });

    it('list_records_skip_files_that_fail_stat_and_continue', 0, async () => {
      const rig = freshRig();
      const flaky = new FlakyFs();
      CloudBackupManager.getInstance().useDepsForTest({
        fs: flaky, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud',
      });
      const crypto = CloudBackupCrypto.getInstance();
      const content1 = await crypto.encrypt('{"tokens":[]}', crypto.getMode(true), 'union-1', 1, 9300, 'odid-A', 'Mate60');
      const content2 = await crypto.encrypt('{"tokens":[]}', crypto.getMode(true), 'union-1', 1, 9400, 'odid-A', 'Mate60');
      flaky.files.set(`/cloud/${backupFileName(9300)}`, content1);
      flaky.files.set(`/cloud/${backupFileName(9400)}`, content2);
      flaky.failStatFor.add(`/cloud/${backupFileName(9300)}`);

      const records = await CloudBackupManager.getInstance().listBackupHistory();
      // 单文件 stat 失败只跳过该文件，其余记录正常返回（降序）
      expect(records.length).assertEqual(1);
      expect(records[0].timestamp).assertEqual(9400);
    });

    it('restore_new_payload_without_enabled_packs_keeps_current_setting', 0, async () => {
      const rig = freshRig();
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED, '["keep"]');
      const payload = `{"tokens":[${JSON.stringify(makeToken('t1', 'restored-secret'))}],"groups":[]}`;
      await seedBackup(rig, 9600, payload, 'odid-A');

      const ok = await CloudBackupManager.getInstance().restoreFromCloud();
      expect(ok).assertTrue();
      // 载荷无 enabledPacks 字段 → 保留本地当前启用列表
      expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string).assertEqual('["keep"]');
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.groups.mergedGroups !== null).assertTrue();
    });


    it('clear_list_errors_abort_all_scopes_without_claiming_success', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9801, '{}', 'odid-A');
      rig.fs.failList = true;
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
      const manager = CloudBackupManager.getInstance();
      expect(await manager.clearCloudStorage()).assertFalse();
      expect(await manager.clearDeviceCloudStorage()).assertFalse();
      expect(await manager.clearDeviceNameCloudStorage()).assertFalse();
      expect(rig.fs.files.size).assertEqual(1);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
    });

    it('stat_error_blocks_scoped_scan_but_all_scope_still_attempts_other_phases', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9801, '{}', 'odid-A');
      await seedBackup(rig, 9811, '{}', 'odid-B');
      rig.fs.failStatFor.add('/cloud/otp_backup_9801.enc');
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
      const manager = CloudBackupManager.getInstance();
      expect(await manager.clearDeviceCloudStorage()).assertFalse();
      expect(await manager.clearDeviceNameCloudStorage()).assertFalse();
      expect(rig.fs.files.size).assertEqual(2);
      expect(rig.icons.clearCalls).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
      const result = await manager.clearCloudStorageResult();
      expect(result.success).assertFalse();
      expect(result.partialFailure).assertTrue();
      expect(result.reason).assertEqual(CloudBackupFailureReason.DELETE_FAILED);
      expect(rig.fs.files.has('/cloud/otp_backup_9801.enc')).assertTrue();
      expect(rig.fs.files.has('/cloud/otp_backup_9811.enc')).assertFalse();
      expect(rig.icons.clearCalls).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
    });

    it('clear_and_single_delete_report_sync_start_failure', 0, async () => {
      for (const scope of [0, 1, 2, 3]) {
        const rig = freshRig();
        const sync = new FlakySync();
        sync.fail = true;
        CloudBackupManager.getInstance().useDepsForTest({
          fs: rig.fs, account: rig.account, device: rig.device, tokens: rig.tokens,
          groups: rig.groups, icons: rig.icons, sync: sync, cache: rig.cache, cloudDir: '/cloud',
        });
        await seedBackup(rig, 9802, '{}', scope === 2 ? 'old-odid' : 'odid-A');
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
        const manager = CloudBackupManager.getInstance();
        const result = scope === 3 ? await manager.deleteBackupRecordResult('otp_backup_9802.enc')
          : await clearScope(manager, scope);
        expect(result.success).assertFalse();
        expect(result.localComplete).assertTrue();
        expect(result.syncStartAccepted).assertFalse();
        expect(result.reason).assertEqual(CloudBackupFailureReason.SYNC_FAILED);
        expect(sync.startCalls).assertEqual(1);
        expect(rig.fs.files.size).assertEqual(0);
        expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
      }
    });

    it('clear_waits_for_icon_result_and_preserves_preference_on_failure', 0, async () => {
      for (const rejects of [true, false]) {
        for (const scope of [0, 1, 2]) {
          const rig = freshRig();
          await seedBackup(rig, 9803, '{}', scope === 2 ? 'old-odid' : 'odid-A');
          rig.icons.failClear = true;
          rig.icons.rejectClear = rejects;
          AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
          const manager = CloudBackupManager.getInstance();
          const result = await clearScope(manager, scope);
          expect(result.success).assertFalse();
          expect(result.reason).assertEqual(CloudBackupFailureReason.ICON_FAILED);
          expect(result.partialFailure).assertTrue();
          expect(result.localComplete).assertFalse();
          expect(rig.icons.clearCalls).assertEqual(1);
          expect(rig.fs.files.has('/cloud/otp_backup_9803.enc')).assertEqual(scope !== 0);
          expect(rig.fs.deleteAttempts.length).assertEqual(scope === 0 ? 1 : 0);
          expect(rig.icons.deletedAtClear[0]).assertEqual(scope === 0 ? 1 : 0);
          expect(rig.sync.startCalls).assertEqual(1);
          expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
        }
      }
    });

    it('history_waits_for_cache_and_blocks_conflicting_delete_without_queueing', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9804, '{}', 'odid-A');
      const path = '/cloud/otp_backup_9804.enc';
      rig.fs.locationOverride.set(path, 2);
      rig.cache.hang = true;
      const manager = CloudBackupManager.getInstance();
      let loaded = false;
      const history = manager.listBackupHistory().then(records => {
        loaded = true;
        return records;
      });
      try {
        await cloudTestTurn();
        expect(loaded).assertFalse();
        expect(rig.fs.readPaths.length).assertEqual(0);
        expect((await manager.deleteBackupRecordResult('otp_backup_9804.enc')).reason)
          .assertEqual(CloudBackupFailureReason.BUSY);
        expect(rig.cache.prepareCalls.length).assertEqual(0);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
      } finally {
        rig.cache.complete();
        await history;
      }
      expect((await history)[0].tokenCount).assertEqual(1);
      expect(rig.fs.files.has(path)).assertTrue();
      rig.fs.locationOverride.set(path, 2);
      expect(await manager.deleteBackupRecord('otp_backup_9804.enc')).assertTrue();
      expect(rig.cache.calls.length).assertEqual(1);
      expect(rig.fs.files.has(path)).assertFalse();
    });

    it('terminal_cache_failure_attempts_read_and_reports_actual_io_error_without_implicit_delete', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9805, '{"tokens":[]}', 'odid-A');
      const path = '/cloud/otp_backup_9805.enc';
      const source = rig.fs.files.get(path);
      rig.fs.locationOverride.set(path, 2);
      rig.fs.readableCloudPaths.add(path);
      rig.fs.failReadFor.add(path);
      rig.cache.fail = true;
      const manager = CloudBackupManager.getInstance();
      const records = await manager.listBackupHistory();
      expect(records[0].deviceId).assertEqual('');
      expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.READ_FAILED);
      expect(records[0].tokenCountKnown).assertFalse();
      const restore = await manager.restoreFromBackupRecordResult('otp_backup_9805.enc');
      expect(restore.success).assertFalse();
      expect(restore.reason).assertEqual(CloudBackupFailureReason.READ_FAILED);
      expect(rig.tokens.updated.length).assertEqual(0);
      expect(rig.cache.calls.length).assertEqual(2);
      expect(rig.fs.readPaths.join(',')).assertEqual(`${path},${path}`);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
      expect(rig.fs.files.get(path)).assertEqual(source);
      expect(rig.sync.startCalls).assertEqual(0);
      expect(manager.isCleanupPending()).assertFalse();
      // 只有显式清理动作可以删除；读取失败不意味着文件应当被删除。
      expect(await manager.clearCloudStorage()).assertTrue();
      expect(rig.cache.calls.length).assertEqual(2);
      expect(rig.fs.readPaths.length).assertEqual(2);
      expect(rig.fs.deleteAttempts.includes(path)).assertTrue();
      expect(rig.fs.files.has(path)).assertFalse();
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('terminal_cache_failure_allows_readable_location2_history_and_restore_without_stat_rewrite', 0, async () => {
      const rig = freshRig();
      const token = JSON.stringify(makeToken('native-read', 'native-read-secret'));
      await seedBackup(rig, 9806, `{"tokens":[${token}]}`, 'odid-B', 'Readable cloud device');
      const path = '/cloud/otp_backup_9806.enc';
      const source = rig.fs.files.get(path);
      rig.fs.locationOverride.set(path, 2);
      rig.fs.readableCloudPaths.add(path);
      rig.cache.fail = true;
      const manager = CloudBackupManager.getInstance();
      const history = await manager.listBackupHistoryResult();
      expect(history.success).assertTrue();
      expect(history.records.length).assertEqual(1);
      expect(history.records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
      expect(history.records[0].tokenCountKnown).assertTrue();
      expect(history.records[0].tokenCount).assertEqual(1);
      expect(history.records[0].deviceId).assertEqual('odid-B');
      expect(history.records[0].deviceName).assertEqual('Readable cloud device');
      expect(history.records[0].location).assertEqual(2);
      const restore = await manager.restoreFromBackupRecordResult('otp_backup_9806.enc');
      expect(restore.success).assertTrue();
      expect(rig.tokens.updated.length).assertEqual(1);
      expect(rig.tokens.updated[0].TokenUUID).assertEqual('native-read');
      expect(rig.tokens.updated[0].TokenSecret).assertEqual('native-read-secret');
      expect(rig.cache.calls.length).assertEqual(2);
      expect(rig.fs.readPaths.join(',')).assertEqual(`${path},${path}`);
      expect(rig.fs.locationOverride.get(path)).assertEqual(2);
      expect(rig.fs.files.get(path)).assertEqual(source);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
      expect(rig.cache.prepareCalls.length).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
      expect(manager.isCleanupPending()).assertFalse();
    });

    it('previous_cache_failure_does_not_hide_fresh_readable_location3_metadata', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9807, '{"tokens":[]}', 'odid-B', 'Readable local device');
      const path = '/cloud/otp_backup_9807.enc';
      rig.fs.locationOverride.set(path, 2);
      rig.cache.fail = true;
      const manager = CloudBackupManager.getInstance();
      await manager.cacheCloudOnlyBackups();
      expect(rig.cache.calls.length).assertEqual(1);
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(manager.isCleanupPending()).assertFalse();
      // 外部同步已使内容驻留；先前缓存失败不是永久禁止读取的文件名单。
      rig.fs.locationOverride.set(path, 3);
      const records = await manager.listBackupHistory();
      expect(records.length).assertEqual(1);
      expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
      expect(records[0].tokenCountKnown).assertTrue();
      expect(records[0].deviceId).assertEqual('odid-B');
      expect(records[0].deviceName).assertEqual('Readable local device');
      expect(rig.cache.calls.length).assertEqual(1);
      expect(rig.fs.readPaths.join(',')).assertEqual(path);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
      expect(rig.fs.files.has(path)).assertTrue();
    });


    it('no_cacher_allows_readable_location2_history_and_restore_without_initiated_work', 0, async () => {
      const rig = freshRig();
      const token = JSON.stringify(makeToken('direct-read', 'direct-read-secret'));
      await seedBackup(rig, 9808, `{"tokens":[${token}]}`, 'odid-B', 'Direct read device');
      const path = '/cloud/otp_backup_9808.enc';
      rig.fs.locationOverride.set(path, 2);
      rig.fs.readableCloudPaths.add(path);
      const manager = CloudBackupManager.getInstance();
      manager.useDepsForTest({
        fs: rig.fs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cloudDir: '/cloud',
      });
      const records = await manager.listBackupHistory();
      expect(records.length).assertEqual(1);
      expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
      expect(records[0].tokenCountKnown).assertTrue();
      expect(records[0].deviceId).assertEqual('odid-B');
      expect((await manager.restoreFromBackupRecordResult('otp_backup_9808.enc')).success).assertTrue();
      expect(rig.tokens.updated[0].TokenUUID).assertEqual('direct-read');
      expect(rig.fs.readPaths.join(',')).assertEqual(`${path},${path}`);
      expect(rig.fs.locationOverride.get(path)).assertEqual(2);
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
      expect(rig.fs.files.has(path)).assertTrue();
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('failed_cache_with_unconfirmed_native_work_blocks_readable_history_and_restore', 0, async () => {
      for (const historyFirst of [true, false]) {
        const rig = freshRig();
        await seedBackup(rig, 9809, '{"tokens":[]}', 'odid-B');
        await seedBackup(rig, 9810, '{"tokens":[]}', 'odid-B');
        const path = '/cloud/otp_backup_9809.enc';
        rig.fs.locationOverride.set(path, 2);
        rig.fs.readableCloudPaths.add(path);
        rig.fs.locationOverride.set('/cloud/otp_backup_9810.enc', 3);
        rig.cache.fail = true;
        rig.cache.failKeepsInFlight = true;
        rig.cache.failCancel = true;
        const manager = CloudBackupManager.getInstance();
        try {
          const result = historyFirst ? await manager.listBackupHistoryResult()
            : await manager.restoreFromBackupRecordResult('otp_backup_9809.enc');
          expect(result.success).assertFalse();
          expect(result.reason).assertEqual(CloudBackupFailureReason.CLEANUP_PENDING);
          expect(manager.isCleanupPending()).assertTrue();
          expect((await manager.restoreFromBackupRecordResult('otp_backup_9809.enc')).reason)
            .assertEqual(CloudBackupFailureReason.CLEANUP_PENDING);
          expect((await manager.listBackupHistoryResult()).reason)
            .assertEqual(CloudBackupFailureReason.CLEANUP_PENDING);
          expect(await manager.retryPendingCleanup()).assertFalse();
          expect(rig.cache.calls.length).assertEqual(1);
          expect(rig.fs.readPaths.length).assertEqual(0);
          expect(rig.tokens.updated.length).assertEqual(0);
          expect(rig.fs.deleteAttempts.length).assertEqual(0);
          expect(rig.fs.files.size).assertEqual(2);
          expect(rig.sync.startCalls).assertEqual(0);
        } finally {
          rig.cache.failCancel = false;
          await manager.retryPendingCleanup();
        }
        expect(manager.isCleanupPending()).assertFalse();
        expect(manager.isBusy()).assertFalse();
      }
    });

    it('single_delete_retries_sync_after_local_file_is_already_gone', 0, async () => {
      const rig = freshRig();
      const sync = new FlakySync();
      sync.fail = true;
      CloudBackupManager.getInstance().useDepsForTest({
        fs: rig.fs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: sync, cache: rig.cache, cloudDir: '/cloud',
      });
      await seedBackup(rig, 9901, '{}', 'odid-A');
      const manager = CloudBackupManager.getInstance();
      expect(await manager.deleteBackupRecord('otp_backup_9901.enc')).assertFalse();
      expect(rig.fs.files.size).assertEqual(0);
      sync.fail = false;
      expect(await manager.deleteBackupRecord('otp_backup_9901.enc')).assertTrue();
      expect(sync.startCalls).assertEqual(2);
      (rig.fs as DownloadAwareFs).failStatFor.add('/cloud/otp_backup_9901.enc');
      expect(await manager.deleteBackupRecord('otp_backup_9901.enc')).assertFalse();
      expect(sync.startCalls).assertEqual(2);
    });

    it('stale_device_clear_preserves_identity_until_icons_succeed', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 9902, '{}', 'old-odid');
      rig.icons.failClear = true;
      const manager = CloudBackupManager.getInstance();
      expect(await manager.clearDeviceNameCloudStorage()).assertFalse();
      expect(rig.fs.files.has('/cloud/otp_backup_9902.enc')).assertTrue();
      manager.resetForTest();
      manager.useDepsForTest({
        fs: rig.fs, account: rig.account, device: rig.device, tokens: rig.tokens,
        groups: rig.groups, icons: rig.icons, sync: rig.sync, cache: rig.cache, cloudDir: '/cloud',
      });
      rig.icons.failClear = false;
      expect(await manager.clearDeviceNameCloudStorage()).assertTrue();
      expect(rig.icons.clearCalls).assertEqual(2);
      expect(rig.fs.files.size).assertEqual(0);
    });

    it('invalid_targets_are_rejected_before_any_file_or_cache_operation', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 42, '{"tokens":[]}', 'odid-A');
      const manager = CloudBackupManager.getInstance();
      for (const id of invalidBackupIds()) {
        const deletion = await manager.deleteBackupRecordResult(id);
        const restoration = await manager.restoreFromBackupRecordResult(id);
        expect(deletion.success).assertFalse();
        expect(deletion.reason).assertEqual(CloudBackupFailureReason.INVALID_TARGET);
        expect(restoration.success).assertFalse();
        expect(restoration.reason).assertEqual(CloudBackupFailureReason.INVALID_TARGET);
      }
      expect(rig.fs.statPaths.length).assertEqual(0);
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.cache.prepareCalls.length).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
      expect(rig.tokens.updated.length).assertEqual(0);
      expect(rig.fs.files.size).assertEqual(1);
    });

    it('history_and_all_clear_use_full_filename_match_and_keep_unrelated_artifacts', 0, async () => {
      const rig = freshRig();
      const invalid = invalidBackupIds().filter((id: string): boolean => id.length > 0 && id.indexOf('/') < 0);
      for (const id of invalid) rig.fs.files.set(`/cloud/${id}`, 'unrelated');
      rig.fs.files.set('/cloud/.otp_backup_pending_42.tmp', 'orphan-temp');
      rig.fs.files.set('/cloud/notes.txt', 'unrelated');
      await seedBackup(rig, 41, '{"tokens":[]}', 'odid-B');
      await seedBackup(rig, 42, '{"tokens":[]}', 'odid-A');
      const manager = CloudBackupManager.getInstance();
      const records = await manager.listBackupHistory();
      expect(records.length).assertEqual(2);
      expect(records[0].id).assertEqual('otp_backup_42.enc');
      expect(records[1].id).assertEqual('otp_backup_41.enc');
      expect(rig.fs.statPaths.length).assertEqual(2);
      expect(rig.fs.readPaths.length).assertEqual(2);
      rig.fs.readPaths = [];
      expect(await manager.clearCloudStorage()).assertTrue();
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.fs.deleteAttempts.length).assertEqual(2);
      for (const id of invalid) expect(rig.fs.files.get(`/cloud/${id}`)).assertEqual('unrelated');
      expect(rig.fs.files.get('/cloud/.otp_backup_pending_42.tmp')).assertEqual('orphan-temp');
      expect(rig.fs.files.get('/cloud/notes.txt')).assertEqual('unrelated');
    });

    it('all_clear_deletes_invalid_headers_and_unknown_owners_without_reading_content', 0, async () => {
      const rig = freshRig();
      rig.fs.files.set('/cloud/otp_backup_100.enc', '');
      rig.fs.files.set('/cloud/otp_backup_200.enc', 'not-a-token');
      rig.fs.locationOverride.set('/cloud/otp_backup_100.enc', 2);
      rig.fs.locationOverride.set('/cloud/otp_backup_200.enc', 2);
      rig.fs.failReadFor.add('/cloud/otp_backup_200.enc');
      rig.cache.fail = true;
      const result = await CloudBackupManager.getInstance().clearCloudStorageResult();
      expect(result.success).assertTrue();
      expect(result.localComplete).assertTrue();
      expect(result.syncStartAccepted).assertTrue();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.fs.deleteAttempts.length).assertEqual(2);
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.icons.clearAllCalls).assertEqual(1);
      expect(rig.icons.clearDeviceIds.length).assertEqual(0);
      expect(rig.icons.deletedAtClear[0]).assertEqual(2);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(rig.sync.deletedAtStart[0]).assertEqual(2);
    });

    it('backup_unresolved_identity_stops_before_token_read_or_temp_creation', 0, async () => {
      for (const id of ['', '   ', 'unknown_odid', ' UNKNOWN_ODID ']) {
        const rig = freshRig();
        rig.device.id = id;
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
        const result = await CloudBackupManager.getInstance().backupToCloudResult();
        expect(result.success).assertFalse();
        expect(result.reason).assertEqual(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
        expect(result.localComplete).assertFalse();
        expect(rig.tokens.readCalls).assertEqual(0);
        expect(rig.fs.newWriteCalls.length).assertEqual(0);
        expect(rig.fs.files.size).assertEqual(0);
        expect(rig.icons.backupCalls).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
        expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
      }
    });

    it('backup_allows_missing_device_name_but_keeps_valid_identity_and_count', 0, async () => {
      const rig = freshRig();
      rig.device.id = ' odid-A ';
      rig.device.name = '   ';
      rig.tokens.list = [makeToken('u1', 'synthetic-secret')];
      expect(await CloudBackupManager.getInstance().backupToCloud()).assertTrue();
      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(1);
      expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
      expect(records[0].identityStatus).assertEqual(CloudBackupIdentityStatus.NAME_MISSING);
      expect(records[0].deviceId).assertEqual('odid-A');
      expect(records[0].deviceName).assertEqual('');
      expect(records[0].tokenCountKnown).assertTrue();
      expect(records[0].tokenCount).assertEqual(1);
    });

    it('history_distinguishes_local_corruption_read_error_and_unavailable_cloud_content', 0, async () => {
      const rig = freshRig();
      rig.fs.files.set('/cloud/otp_backup_100.enc', '');
      rig.fs.locationOverride.set('/cloud/otp_backup_100.enc', 1);
      rig.fs.files.set('/cloud/otp_backup_200.enc', 'invalid-header');
      rig.fs.locationOverride.set('/cloud/otp_backup_200.enc', 3);
      await seedBackup(rig, 300, '{"tokens":[]}', 'odid-B');
      rig.fs.locationOverride.set('/cloud/otp_backup_300.enc', 1);
      rig.fs.failReadFor.add('/cloud/otp_backup_300.enc');
      rig.fs.files.set('/cloud/otp_backup_400.enc', '');
      rig.fs.locationOverride.set('/cloud/otp_backup_400.enc', 2);
      rig.cache.fail = true;
      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records.length).assertEqual(4);
      expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.READ_FAILED);
      expect(records[1].metadataStatus).assertEqual(CloudBackupMetadataStatus.READ_FAILED);
      expect(records[2].metadataStatus).assertEqual(CloudBackupMetadataStatus.INVALID);
      expect(records[3].metadataStatus).assertEqual(CloudBackupMetadataStatus.INVALID);
      for (const record of records) {
        expect(record.tokenCountKnown).assertFalse();
        expect(record.identityStatus).assertEqual(CloudBackupIdentityStatus.ID_MISSING);
        expect(record.deviceId).assertEqual('');
        expect(record.deviceName).assertEqual('');
      }
      expect(rig.fs.readPaths.includes('/cloud/otp_backup_400.enc')).assertTrue();
      expect(rig.cache.calls.length).assertEqual(1);
      expect(rig.fs.files.size).assertEqual(4);
      expect(rig.fs.deleteAttempts.length).assertEqual(0);
    });

    it('readable_location2_empty_or_malformed_content_stays_pending_without_delete', 0, async () => {
      for (const content of ['', 'invalid-header']) {
        const rig = freshRig();
        const path = '/cloud/otp_backup_401.enc';
        rig.fs.files.set(path, content);
        rig.fs.locationOverride.set(path, 2);
        rig.fs.readableCloudPaths.add(path);
        rig.cache.fail = true;
        const records = await CloudBackupManager.getInstance().listBackupHistory();
        expect(records.length).assertEqual(1);
        expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.PENDING);
        expect(records[0].tokenCountKnown).assertFalse();
        expect(records[0].deviceId).assertEqual('');
        expect(rig.fs.readPaths.join(',')).assertEqual(path);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.fs.files.get(path)).assertEqual(content);
        expect(rig.fs.locationOverride.get(path)).assertEqual(2);
      }
    });

    it('history_valid_missing_identity_is_not_relabelled_as_current_device_or_corruption', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 101, '{"tokens":[]}', 'unknown_odid', 'Old phone');
      await seedBackup(rig, 102, '{"tokens":[]}', 'odid-B', '  ');
      const records = await CloudBackupManager.getInstance().listBackupHistory();
      expect(records[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
      expect(records[0].identityStatus).assertEqual(CloudBackupIdentityStatus.NAME_MISSING);
      expect(records[0].tokenCountKnown).assertTrue();
      expect(records[1].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
      expect(records[1].identityStatus).assertEqual(CloudBackupIdentityStatus.ID_MISSING);
      expect(records[1].deviceId).assertEqual('');
      expect(records[1].deviceName).assertEqual('Old phone');
      expect(records[1].tokenCountKnown).assertTrue();
    });

    it('restore_wrong_key_or_native_crypto_unavailable_is_retryable_without_local_mutation', 0, async () => {
      for (const fault of ['wrong-key', 'native-aes', 'native-sha', 'empty-sha', 'empty-key']) {
        const rig = freshRig();
        const engine = new FaultInjectingBackupEngine();
        const crypto = CloudBackupCrypto.useEngineForTest(engine, new PureTsCodec());
        const token = JSON.stringify(makeToken('retry-token', 'synthetic-secret'));
        const payload = `{"tokens":[${token}],"groups":[{"id":"g","name":"Imported"}],"enabledPacks":["new-pack"]}`;
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED, '["keep-pack"]');
        await seedBackup(rig, 109, payload, 'odid-A');
        const path = '/cloud/otp_backup_109.enc';
        const source = rig.fs.files.get(path)!;
        expect(await crypto.verifyToken(source)).assertTrue();
        expect(crypto.parseTokenHeader(source).version).assertEqual(2);
        if (fault === 'wrong-key') rig.account.union = 'wrong-union';
        if (fault === 'empty-key') rig.account.union = '';
        engine.failDecrypt = fault === 'native-aes';
        engine.failHash = fault === 'native-sha';
        engine.emptyHash = fault === 'empty-sha';
        const manager = CloudBackupManager.getInstance();
        const failed = await manager.restoreFromBackupRecordResult('otp_backup_109.enc');
        expect(failed.success).assertFalse();
        expect(failed.reason).assertEqual(CloudBackupFailureReason.DECRYPT_FAILED);
        expect(failed.partialFailure).assertFalse();
        expect(failed.localComplete).assertFalse();
        expect(rig.tokens.updateAttempts.length).assertEqual(0);
        expect(rig.groups.mergeCalls).assertEqual(0);
        expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED)).assertEqual('["keep-pack"]');
        expect(rig.fs.newWriteCalls.length).assertEqual(0);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.fs.files.get(path)).assertEqual(source);
        expect(rig.sync.startCalls).assertEqual(0);
        expect(manager.isBusy()).assertFalse();
        const history = await manager.listBackupHistory();
        expect(history[0].metadataStatus).assertEqual(CloudBackupMetadataStatus.VALID);
        // 同一原文件恢复可用，不要求先标坏、删除或重新生成备份。
        engine.failDecrypt = false;
        engine.failHash = false;
        engine.emptyHash = false;
        rig.account.union = 'union-1';
        expect((await manager.restoreFromBackupRecordResult('otp_backup_109.enc')).success).assertTrue();
        expect(rig.tokens.updated.length).assertEqual(1);
      }
    });

    it('restore_v1_mock_modes_keep_old_array_and_grouped_payloads_compatible', 0, async () => {
      for (const mode of [CloudBackupCryptoMode.NONE, CloudBackupCryptoMode.HUAWEI_ACCOUNT]) {
        for (const arrayPayload of [true, false]) {
          const rig = freshRig();
          const codec = new PureTsCodec();
          const engine = new FaultInjectingBackupEngine();
          // mock 分支不得调用 AES；仍使用真实格式校验和 SHA256，不固定返回解密明文。
          engine.failDecrypt = true;
          CloudBackupCrypto.useEngineForTest(engine, codec);
          const token = JSON.stringify(makeToken('old-token', 'synthetic-secret'));
          const text = arrayPayload ? `[${token}]` : `{"tokens":[${token}],"groups":[{"id":"g","name":"Old"}]}`;
          const header: CloudBackupTokenHeader = {
            version: 1, mode: mode, salt: 'mock_salt_108', iv: 'mock_iv_108', tokenCount: 1,
            size: text.length, timestamp: 108, deviceId: '', deviceName: '',
          };
          const body = `${codec.encodeText(JSON.stringify(header))}.${codec.encodeText(text)}`;
          rig.fs.files.set('/cloud/otp_backup_108.enc', `${body}.${await engine.sha256Hex(body)}`);
          const result = await CloudBackupManager.getInstance().restoreFromBackupRecordResult('otp_backup_108.enc');
          expect(result.success).assertTrue();
          expect(rig.tokens.updated.length).assertEqual(1);
          expect(rig.tokens.updated[0].TokenUUID).assertEqual('old-token');
          expect(rig.groups.mergeCalls).assertEqual(arrayPayload ? 0 : 1);
        }
      }
    });

    it('restore_plaintext_mock_payload_errors_remain_format_invalid_without_mutation', 0, async () => {
      for (const text of ['invalid-json', '{"tokens":{}}', '{"tokens":[],"groups":{}}', 'null']) {
        const rig = freshRig();
        const codec = new PureTsCodec();
        const engine = new FaultInjectingBackupEngine();
        engine.failDecrypt = true;
        CloudBackupCrypto.useEngineForTest(engine, codec);
        const header: CloudBackupTokenHeader = {
          version: 1, mode: CloudBackupCryptoMode.NONE, salt: 'mock_salt_108', iv: 'mock_iv_108',
          tokenCount: 0, size: text.length, timestamp: 108, deviceId: '', deviceName: '',
        };
        const body = `${codec.encodeText(JSON.stringify(header))}.${codec.encodeText(text)}`;
        rig.fs.files.set('/cloud/otp_backup_108.enc', `${body}.${await engine.sha256Hex(body)}`);
        const result = await CloudBackupManager.getInstance().restoreFromBackupRecordResult('otp_backup_108.enc');
        expect(result.reason).assertEqual(CloudBackupFailureReason.FORMAT_INVALID);
        expect(result.partialFailure).assertFalse();
        expect(rig.tokens.updateAttempts.length).assertEqual(0);
        expect(rig.groups.mergeCalls).assertEqual(0);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
      }
    });

    it('restore_integrity_and_payload_shape_failures_do_not_modify_local_data', 0, async () => {
      for (const payload of ['{"tokens":{}}', '{"tokens":[],"groups":{}}',
        '{"tokens":[],"enabledPacks":{}}', 'null']) {
        const rig = freshRig();
        await seedBackup(rig, 110, payload, 'odid-A');
        const result = await CloudBackupManager.getInstance().restoreFromBackupRecordResult('otp_backup_110.enc');
        expect(result.reason).assertEqual(CloudBackupFailureReason.DECRYPT_FAILED);
        expect(rig.tokens.updated.length).assertEqual(0);
        expect(rig.groups.mergedGroups).assertNull();
      }
      const rig = freshRig();
      const validPayload = `{"tokens":[${JSON.stringify(makeToken('tampered', 'synthetic-secret'))}],"groups":[]}`;
      await seedBackup(rig, 111, validPayload, 'odid-A');
      const content = rig.fs.files.get('/cloud/otp_backup_111.enc')!;
      rig.fs.files.set('/cloud/otp_backup_111.enc', content.substring(0, content.lastIndexOf('.') + 1) + 'bad-signature');
      const result = await CloudBackupManager.getInstance().restoreFromBackupRecordResult('otp_backup_111.enc');
      expect(result.success).assertFalse();
      expect(result.reason).assertEqual(CloudBackupFailureReason.FORMAT_INVALID);
      expect(rig.tokens.updated.length).assertEqual(0);
      expect(rig.groups.mergedGroups).assertNull();
    });

    it('restore_signed_late_invalid_token_rejects_all_before_mutation_in_both_formats', 0, async () => {
      // 第二项才非法，第一项、分组和启用包均有效；禁止逐项验证逐项写入。
      const invalidTokens = ['null', '[]', 'false', '7', '"token"', '{}',
        '{"TokenUUID":"late","TokenType":0}',
        '{"TokenUUID":"late","TokenSecret":"" ,"TokenType":0}',
        '{"TokenUUID":"   ","TokenSecret":"secret","TokenType":0}',
        '{"TokenUUID":"late","TokenSecret":"secret","TokenType":4}',
        '{"TokenUUID":"late","TokenSecret":"secret","TokenType":-1}',
        '{"TokenUUID":"late","TokenSecret":"secret","TokenType":0.5}',
        '{"TokenUUID":"late","TokenSecret":"secret","TokenType":"0"}'];
      for (const legacy of [false, true]) {
        for (const late of invalidTokens) {
          await assertInvalidRestoreHasNoSideEffects(payloadWithLateToken(late, legacy));
        }
      }
    });

    it('restore_signed_late_invalid_optional_fields_reject_before_any_write', 0, async () => {
      const invalidFields = ['"TokenName":null', '"TokenIssuer":42', '"TokenAlgorithm":{}',
        '"TokenGroupId":[]', '"TokenFavorite":"true"', '"TokenPeriod":0', '"TokenPeriod":-1',
        '"TokenPeriod":1e400', '"TokenPeriod":"30"', '"TokenDigits":0', '"TokenDigits":1.5',
        '"TokenCounter":-1', '"TokenCounter":0.5', '"TokenCounter":9007199254740992',
        '"RankScore":1e400', '"RankScore":"0"'];
      for (const field of invalidFields) {
        // JSON 数字 1e400 在解析后是 Infinity，不能用 stringify(NaN/Infinity) 的 null 替代。
        const late = `{"TokenUUID":"late","TokenSecret":"secret","TokenType":0,${field}}`;
        await assertInvalidRestoreHasNoSideEffects(payloadWithLateToken(late));
      }
    });

    it('restore_signed_duplicate_token_id_rejects_before_first_update', 0, async () => {
      const duplicate = JSON.stringify(makeToken('valid-first', 'different-secret'));
      for (const legacy of [false, true]) {
        await assertInvalidRestoreHasNoSideEffects(payloadWithLateToken(duplicate, legacy));
      }
    });

    it('restore_signed_malformed_or_duplicate_groups_reject_before_tokens_or_preferences', 0, async () => {
      const token = JSON.stringify(makeToken('valid-first', 'first-secret'));
      const invalidGroups = ['null', '[]', '"group"', '{}', '{"id":"late"}',
        '{"id":"","name":"Late"}', '{"id":"   ","name":"Late"}',
        '{"id":7,"name":"Late"}', '{"id":"late","name":""}',
        '{"id":"late","name":"   "}', '{"id":"late","name":false}',
        '{"id":"new-group","name":"Duplicate"}'];
      for (const group of invalidGroups) {
        const payload = `{"tokens":[${token}],"groups":[{"id":"new-group","name":"Valid"},${group}],` +
          '"enabledPacks":["new-pack"]}';
        await assertInvalidRestoreHasNoSideEffects(payload);
      }
    });

    it('restore_signed_late_invalid_enabled_pack_rejects_before_group_merge', 0, async () => {
      const token = JSON.stringify(makeToken('valid-first', 'first-secret'));
      for (const pack of ['null', 'false', '7', '{}', '[]', '""']) {
        const payload = `{"tokens":[${token}],"groups":[{"id":"new-group","name":"Valid"}],` +
          `"enabledPacks":["new-pack",${pack}]}`;
        await assertInvalidRestoreHasNoSideEffects(payload);
      }
    });

    it('restore_second_token_write_failure_reports_partial_mutation_not_format_failure', 0, async () => {
      for (const legacy of [false, true]) {
        const rig = freshRig();
        rig.tokens.failUpdateAt = 1;
        AppPreference.setPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED, '["keep-pack"]');
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
        const first = JSON.stringify(makeToken('first', 'first-secret'));
        const second = JSON.stringify(makeToken('second', 'second-secret'));
        const third = JSON.stringify(makeToken('third', 'third-secret'));
        const tokens = `[${first},${second},${third}]`;
        const payload = legacy ? tokens : `{"tokens":${tokens},"groups":[{"id":"g1","name":"Imported"}],` +
          '"enabledPacks":["new-pack"]}';
        await seedBackup(rig, 113, payload, 'odid-A');
        const manager = CloudBackupManager.getInstance();
        const result = await manager.restoreFromBackupRecordResult('otp_backup_113.enc');
        expect(result.success).assertFalse();
        expect(result.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
        expect(result.partialFailure).assertTrue();
        expect(result.localComplete).assertFalse();
        expect(result.syncStartAccepted).assertFalse();
        expect(rig.tokens.updateAttempts.length).assertEqual(2);
        expect(rig.tokens.updateAttempts[1].TokenUUID).assertEqual('second');
        expect(rig.tokens.updated.length).assertEqual(1);
        expect(rig.tokens.updated[0].TokenUUID).assertEqual('first');
        expect(rig.tokens.updated[0].TokenSecret).assertEqual('first-secret');
        expect(rig.groups.mergeCalls).assertEqual(legacy ? 0 : 1);
        if (legacy) expect(rig.groups.mergedGroups).assertNull();
        else expect(rig.groups.mergedGroups![0].id).assertEqual('g1');
        expect(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED))
          .assertEqual(legacy ? '["keep-pack"]' : '["new-pack"]');
        expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
        expect(rig.fs.files.has('/cloud/otp_backup_113.enc')).assertTrue();
        expect(rig.fs.newWriteCalls.length).assertEqual(0);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
        expect(manager.isBusy()).assertFalse();
      }
    });

    it('partial_write_and_close_failures_cleanup_owned_stage_without_touching_history', 0, async () => {
      for (const failClose of [false, true]) {
        const rig = freshRig();
        await seedBackup(rig, 120, '{"tokens":[]}', 'odid-B');
        const existing = rig.fs.files.get('/cloud/otp_backup_120.enc');
        rig.fs.files.set('/cloud/.otp_backup_pending_orphan.tmp', 'not-owned');
        rig.fs.failNewWriteAfterCreate = !failClose;
        rig.fs.failClose = failClose;
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
        const result = await CloudBackupManager.getInstance().backupToCloudResult();
        expect(result.success).assertFalse();
        expect(result.localComplete).assertFalse();
        expect(result.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
        expect(rig.fs.newWriteCalls.length).assertEqual(1);
        expect(rig.fs.files.has(rig.fs.newWriteCalls[0])).assertFalse();
        expect(rig.fs.files.size).assertEqual(2);
        expect(rig.fs.files.get('/cloud/otp_backup_120.enc')).assertEqual(existing);
        expect(rig.fs.files.get('/cloud/.otp_backup_pending_orphan.tmp')).assertEqual('not-owned');
        expect(rig.fs.publishAttempts.length).assertEqual(0);
        expect(rig.icons.backupCalls).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
        expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
      }
    });

    it('readback_corruption_or_io_failure_prevents_publish_and_reclaims_owned_temp', 0, async () => {
      for (const corrupt of [false, true]) {
        const rig = freshRig();
        const fs = new PublicationRaceFs();
        fs.corruptReadback = corrupt;
        fs.unreadableTemp = !corrupt;
        rig.fs = fs;
        rig.cache = new FakeFileCacher(fs);
        bindRig(rig);
        const result = await CloudBackupManager.getInstance().backupToCloudResult();
        expect(result.success).assertFalse();
        expect(result.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
        expect(fs.files.size).assertEqual(0);
        expect(fs.publishAttempts.length).assertEqual(0);
        expect(fs.deleteAttempts.includes(fs.newWriteCalls[0])).assertTrue();
        expect(rig.sync.startCalls).assertEqual(0);
        expect(rig.icons.backupCalls).assertEqual(0);
      }
    });

    it('mode1_publish_failure_does_not_fallback_to_direct_write_or_copy', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 130, '{"tokens":[]}', 'odid-B');
      const existing = rig.fs.files.get('/cloud/otp_backup_130.enc');
      rig.fs.failPublish = true;
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
      const result = await CloudBackupManager.getInstance().backupToCloudResult();
      expect(result.success).assertFalse();
      expect(result.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
      expect(result.localComplete).assertFalse();
      expect(rig.fs.publishAttempts.length).assertEqual(1);
      expect(rig.fs.publishedPairs.length).assertEqual(0);
      expect(rig.fs.copiedPairs.length).assertEqual(0);
      expect(rig.fs.files.size).assertEqual(1);
      expect(rig.fs.files.get('/cloud/otp_backup_130.enc')).assertEqual(existing);
      expect(rig.fs.files.has(rig.fs.newWriteCalls[0])).assertFalse();
      expect(rig.fs.deleteAttempts.includes(rig.fs.newWriteCalls[0])).assertTrue();
      expect(rig.icons.backupCalls).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
      expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
    });

    it('temp_and_final_collisions_never_overwrite_or_cleanup_another_owner_file', 0, async () => {
      for (const tempCollision of [true, false]) {
        const rig = freshRig();
        const fs = new PublicationRaceFs();
        fs.collideTemp = tempCollision;
        fs.collideFinal = !tempCollision;
        rig.fs = fs;
        rig.cache = new FakeFileCacher(fs);
        bindRig(rig);
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
        const result = await CloudBackupManager.getInstance().backupToCloudResult();
        expect(result.success).assertFalse();
        expect(result.reason).assertEqual(CloudBackupFailureReason.WRITE_FAILED);
        expect(fs.files.get(fs.collidedPath)).assertEqual(fs.otherOwnerContent);
        expect(fs.files.size).assertEqual(1);
        expect(fs.deleteAttempts.includes(fs.collidedPath)).assertFalse();
        expect(fs.publishedPairs.length).assertEqual(0);
        expect(fs.copiedPairs.length).assertEqual(0);
        expect(fs.publishAttempts.length).assertEqual(tempCollision ? 0 : 1);
        expect(rig.icons.backupCalls).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
        expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
      }
    });

    it('repeated_backup_uses_distinct_names_without_clock_progress', 0, async () => {
      const rig = freshRig();
      const manager = CloudBackupManager.getInstance();
      expect(await manager.backupToCloud()).assertTrue();
      const firstPath = formalPaths(rig.fs)[0];
      const firstContent = rig.fs.files.get(firstPath);
      expect(await manager.backupToCloud()).assertTrue();
      expect(formalPaths(rig.fs).length).assertEqual(2);
      expect(rig.fs.files.get(firstPath)).assertEqual(firstContent);
      expect(rig.fs.newWriteCalls[0] === rig.fs.newWriteCalls[1]).assertFalse();
      expect(rig.fs.publishedPairs.length).assertEqual(2);
      expect(rig.sync.startCalls).assertEqual(2);
    });

    it('backup_waits_for_icons_and_retains_gate_until_single_sync_after_phase', 0, async () => {
      const rig = freshRig();
      const manager = CloudBackupManager.getInstance();
      const phase = new DeferredPhase();
      rig.icons.backupPhase = phase;
      let complete = false;
      const pending = manager.backupToCloudResult().then(result => { complete = true; return result; });
      try {
        await cloudTestTurn();
        expect(rig.icons.backupCalls).assertEqual(1);
        expect(formalPaths(rig.fs).length).assertEqual(1);
        expect(complete).assertFalse();
        expect(rig.sync.startCalls).assertEqual(0);
        expect(manager.isBusy()).assertTrue();
        expect((await manager.clearCloudStorageResult()).reason).assertEqual(CloudBackupFailureReason.BUSY);
        expect((await manager.listBackupHistoryResult()).reason).assertEqual(CloudBackupFailureReason.BUSY);
        expect(rig.icons.clearCalls).assertEqual(0);
        expect(rig.icons.deferredSync[0]).assertTrue();
        expect(rig.icons.ownedLease[0]).assertTrue();
      } finally {
        phase.complete();
        await pending;
      }
      expect((await pending).success).assertTrue();
      expect(rig.sync.startCalls).assertEqual(1);
      expect(rig.icons.events.join(',')).assertEqual('icons-backup-begin,icons-backup-end,sync');
      expect(manager.isBusy()).assertFalse();
    });

    it('backup_icon_failure_is_partial_and_still_submits_local_token_file_once', 0, async () => {
      for (const rejects of [false, true]) {
        const rig = freshRig();
        rig.icons.failBackup = true;
        rig.icons.rejectBackup = rejects;
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '1234');
        const result = await CloudBackupManager.getInstance().backupToCloudResult();
        expect(result.success).assertFalse();
        expect(result.localComplete).assertTrue();
        expect(result.partialFailure).assertTrue();
        expect(result.reason).assertEqual(CloudBackupFailureReason.ICON_FAILED);
        expect(result.syncStartAccepted).assertTrue();
        expect(formalPaths(rig.fs).length).assertEqual(1);
        expect(rig.sync.startCalls).assertEqual(1);
        expect(AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME)).assertEqual('1234');
        expect(CloudBackupManager.getInstance().isBusy()).assertFalse();
      }
    });

    it('busy_auto_backup_is_skipped_not_queued_after_clear', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 140, '{"tokens":[]}', 'odid-A');
      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, true);
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
      const manager = CloudBackupManager.getInstance();
      const phase = new DeferredPhase();
      rig.icons.clearPhase = phase;
      const clearing = manager.clearCloudStorageResult();
      try {
        await cloudTestTurn();
        expect(rig.icons.clearCalls).assertEqual(1);
        expect(manager.isBusy()).assertTrue();
        expect(rig.sync.startCalls).assertEqual(0);
        await manager.checkAndAutoBackup();
        expect(rig.tokens.readCalls).assertEqual(0);
        expect(rig.fs.newWriteCalls.length).assertEqual(0);
        expect((await manager.backupToCloudResult()).reason).assertEqual(CloudBackupFailureReason.BUSY);
        expect((await manager.restoreFromBackupRecordResult('otp_backup_140.enc')).reason)
          .assertEqual(CloudBackupFailureReason.BUSY);
      } finally {
        phase.complete();
        await clearing;
      }
      await cloudTestTurn();
      expect((await clearing).success).assertTrue();
      expect(rig.fs.files.size).assertEqual(0);
      expect(rig.fs.newWriteCalls.length).assertEqual(0);
      expect(rig.icons.backupCalls).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(manager.isBusy()).assertFalse();
    });

    it('scoped_clear_awaits_icons_before_deleting_ownership_evidence_then_syncs_once', 0, async () => {
      for (const scope of [1, 2]) {
        const rig = freshRig();
        const owner = scope === 1 ? 'odid-A' : 'odid-OLD';
        await seedBackup(rig, 150, '{}', owner);
        await seedBackup(rig, 151, '{}', 'odid-B', 'Other');
        const phase = new DeferredPhase();
        rig.icons.clearPhase = phase;
        const manager = CloudBackupManager.getInstance();
        const pending = clearScope(manager, scope);
        try {
          await cloudTestTurn();
          expect(rig.icons.clearDeviceIds.length).assertEqual(1);
          expect(rig.icons.clearDeviceIds[0].join(',')).assertEqual(owner);
          expect(rig.icons.clearAllCalls).assertEqual(0);
          expect(rig.icons.deferredSync[0]).assertTrue();
          expect(rig.icons.ownedLease[0]).assertTrue();
          expect(rig.icons.deletedAtClear[0]).assertEqual(0);
          expect(rig.fs.deleteAttempts.length).assertEqual(0);
          expect(rig.fs.files.has('/cloud/otp_backup_150.enc')).assertTrue();
          expect(rig.sync.startCalls).assertEqual(0);
        } finally {
          phase.complete();
          await pending;
        }
        expect((await pending).success).assertTrue();
        expect(rig.fs.files.has('/cloud/otp_backup_150.enc')).assertFalse();
        expect(rig.fs.files.has('/cloud/otp_backup_151.enc')).assertTrue();
        expect(rig.icons.events.join(',')).assertEqual('icons-clear-begin,icons-clear-end,sync');
        expect(rig.sync.startCalls).assertEqual(1);
        expect(rig.sync.deletedAtStart[0]).assertEqual(1);
      }
    });

    it('scoped_icon_failure_preserves_evidence_for_restart_retry_in_both_scopes', 0, async () => {
      for (const scope of [1, 2]) {
        const rig = freshRig();
        const owner = scope === 1 ? 'odid-A' : 'odid-OLD';
        await seedBackup(rig, 160, '{}', owner);
        await seedBackup(rig, 161, '{}', 'odid-B', 'Other');
        rig.icons.failClear = true;
        const manager = CloudBackupManager.getInstance();
        const failed = await clearScope(manager, scope);
        expect(failed.success).assertFalse();
        expect(failed.reason).assertEqual(CloudBackupFailureReason.ICON_FAILED);
        expect(failed.partialFailure).assertTrue();
        expect(failed.localComplete).assertFalse();
        expect(rig.fs.files.size).assertEqual(2);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        manager.resetForTest();
        bindRig(rig);
        rig.icons.failClear = false;
        expect((await clearScope(manager, scope)).success).assertTrue();
        expect(rig.icons.clearDeviceIds.length).assertEqual(2);
        expect(rig.icons.clearDeviceIds[1].join(',')).assertEqual(owner);
        expect(rig.icons.clearAllCalls).assertEqual(0);
        expect(rig.fs.files.has('/cloud/otp_backup_161.enc')).assertTrue();
        expect(rig.fs.files.has('/cloud/otp_backup_160.enc')).assertFalse();
        expect(rig.sync.startCalls).assertEqual(2);
      }
    });

    it('unresolved_records_are_skipped_and_kept_during_scoped_clear', 0, async () => {
      for (const scope of [1, 2]) {
        const rig = freshRig();
        const owner = scope === 1 ? 'odid-A' : 'odid-OLD';
        await seedBackup(rig, 170, '{}', owner);
        rig.fs.files.set('/cloud/otp_backup_171.enc', 'unknown-owner');
        const manager = CloudBackupManager.getInstance();
        // 无归属记录跳过并计数；归属明确的目标照常清理（P1-1：不再整体失败）。
        const result = await clearScope(manager, scope);
        expect(result.success).assertTrue();
        expect(result.skippedUnowned).assertEqual(1);
        expect(result.deletedCount).assertEqual(1);
        expect(rig.fs.files.has('/cloud/otp_backup_171.enc')).assertTrue();
        expect(rig.fs.files.has('/cloud/otp_backup_170.enc')).assertFalse();
        expect(rig.icons.clearDeviceIds[0].join(',')).assertEqual(owner);
        expect(rig.icons.clearAllCalls).assertEqual(0);
        manager.resetForTest();
        bindRig(rig);
        await seedBackup(rig, 171, '{}', 'odid-B', 'Other');
        expect((await clearScope(manager, scope)).success).assertTrue();
        expect(rig.icons.clearDeviceIds[0].join(',')).assertEqual(owner);
        expect(rig.icons.clearAllCalls).assertEqual(0);
        expect(rig.fs.files.has('/cloud/otp_backup_171.enc')).assertTrue();
        expect(rig.fs.files.has('/cloud/otp_backup_170.enc')).assertFalse();
      }
    });

    it('scoped_clear_with_missing_local_identity_never_expands_to_all', 0, async () => {
      for (const id of ['', '   ', 'unknown_odid']) {
        const rig = freshRig();
        rig.device.id = id;
        await seedBackup(rig, 180, '{}', 'odid-A');
        const manager = CloudBackupManager.getInstance();
        expect((await manager.clearDeviceCloudStorageResult()).reason)
          .assertEqual(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
        expect((await manager.clearDeviceNameCloudStorageResult()).reason)
          .assertEqual(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
        expect(rig.fs.files.size).assertEqual(1);
        expect(rig.fs.listCalls).assertEqual(0);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.icons.clearCalls).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
      }
      const rig = freshRig();
      rig.device.name = ' ';
      expect((await CloudBackupManager.getInstance().clearDeviceNameCloudStorageResult()).reason)
        .assertEqual(CloudBackupFailureReason.IDENTITY_UNAVAILABLE);
      expect(rig.icons.clearCalls).assertEqual(0);
    });

    it('delete_cloud_only_unlink_failure_never_starts_download_fallback', 0, async () => {
      const rig = freshRig();
      const path = '/cloud/otp_backup_190.enc';
      rig.fs.files.set(path, 'unreadable');
      rig.fs.locationOverride.set(path, 2);
      rig.fs.failDeleteFor.add(path);
      const result = await CloudBackupManager.getInstance().deleteBackupRecordResult('otp_backup_190.enc');
      expect(result.success).assertFalse();
      expect(result.reason).assertEqual(CloudBackupFailureReason.DELETE_FAILED);
      expect(rig.fs.deleteAttempts.length).assertEqual(1);
      expect(rig.fs.files.has(path)).assertTrue();
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(rig.sync.startCalls).assertEqual(0);
    });

    it('single_delete_accepts_enoent_race_but_not_other_stat_or_unlink_errors', 0, async () => {
      const rig = freshRig();
      const path = '/cloud/otp_backup_200.enc';
      rig.fs.files.set(path, 'content');
      rig.fs.absentOnDeleteFor.add(path);
      const manager = CloudBackupManager.getInstance();
      const result = await manager.deleteBackupRecordResult('otp_backup_200.enc');
      expect(result.success).assertTrue();
      expect(result.localComplete).assertTrue();
      expect(rig.fs.deleteAttempts.length).assertEqual(1);
      expect(rig.fs.files.has(path)).assertFalse();
      expect(rig.sync.startCalls).assertEqual(1);
      rig.fs.failStatFor.add(path);
      expect((await manager.deleteBackupRecordResult('otp_backup_200.enc')).reason)
        .assertEqual(CloudBackupFailureReason.DELETE_FAILED);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(rig.fs.deleteAttempts.length).assertEqual(1);
    });

    it('single_delete_structured_result_supports_sync_retry_after_local_completion', 0, async () => {
      const rig = freshRig();
      await seedBackup(rig, 210, '{}', 'odid-B');
      rig.sync.fail = true;
      const manager = CloudBackupManager.getInstance();
      const first = await manager.deleteBackupRecordResult('otp_backup_210.enc');
      expect(first.success).assertFalse();
      expect(first.reason).assertEqual(CloudBackupFailureReason.SYNC_FAILED);
      expect(first.localComplete).assertTrue();
      expect(first.syncStartAccepted).assertFalse();
      expect(rig.fs.files.size).assertEqual(0);
      rig.sync.fail = false;
      const second = await manager.deleteBackupRecordResult('otp_backup_210.enc');
      expect(second.success).assertTrue();
      expect(second.localComplete).assertTrue();
      expect(second.syncStartAccepted).assertTrue();
      expect(rig.fs.deleteAttempts.length).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(2);
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(0);
    });

    it('delete_cancels_only_explicit_inflight_task_without_starting_a_download', 0, async () => {
      const rig = freshRig();
      const path = '/cloud/otp_backup_220.enc';
      rig.fs.files.set(path, 'content');
      rig.fs.locationOverride.set(path, 2);
      rig.cache.inFlightPaths.add(path);
      expect(await CloudBackupManager.getInstance().deleteBackupRecord('otp_backup_220.enc')).assertTrue();
      expect(rig.cache.prepareCalls.length).assertEqual(1);
      expect(rig.cache.cancelCalls.length).assertEqual(1);
      expect(rig.cache.inFlightPaths.size).assertEqual(0);
      expect(rig.cache.calls.length).assertEqual(0);
      expect(rig.fs.deleteAttempts.length).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
    });

    it('unconfirmed_cancel_blocks_io_until_owner_cleanup_retry_confirms_stop', 0, async () => {
      const rig = freshRig();
      const path = '/cloud/otp_backup_230.enc';
      rig.fs.files.set(path, 'content');
      rig.fs.locationOverride.set(path, 2);
      rig.cache.inFlightPaths.add(path);
      rig.cache.failCancel = true;
      const manager = CloudBackupManager.getInstance();
      try {
        const blocked = await manager.deleteBackupRecordResult('otp_backup_230.enc');
        expect(blocked.reason).assertEqual(CloudBackupFailureReason.CLEANUP_PENDING);
        expect(blocked.success).assertFalse();
        expect(manager.isCleanupPending()).assertTrue();
        expect(manager.isBusy()).assertTrue();
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.fs.statPaths.length).assertEqual(0);
        expect(rig.sync.startCalls).assertEqual(0);
        expect((await manager.backupToCloudResult()).reason).assertEqual(CloudBackupFailureReason.CLEANUP_PENDING);
        expect((await manager.listBackupHistoryResult()).reason).assertEqual(CloudBackupFailureReason.CLEANUP_PENDING);
        expect(await manager.retryPendingCleanup()).assertFalse();
        expect(rig.cache.retryCleanupCalls).assertEqual(1);
        expect(rig.cache.calls.length).assertEqual(0);
        expect(rig.fs.newWriteCalls.length).assertEqual(0);
        expect(rig.fs.deleteAttempts.length).assertEqual(0);
        expect(rig.fs.files.has(path)).assertTrue();
      } finally {
        rig.cache.failCancel = false;
        await manager.retryPendingCleanup();
      }
      expect(manager.isBusy()).assertFalse();
      expect(manager.isCleanupPending()).assertFalse();
      expect(rig.fs.files.has(path)).assertTrue();
      expect(await manager.deleteBackupRecord('otp_backup_230.enc')).assertTrue();
      expect(rig.fs.deleteAttempts.length).assertEqual(1);
      expect(rig.sync.startCalls).assertEqual(1);
      expect(rig.cache.calls.length).assertEqual(0);
    });

    it('record_presence_check_is_cheap_and_does_not_download_or_parse', 0, async () => {
      const rig = freshRig();
      const manager = CloudBackupManager.getInstance();
      rig.fs.files.set('/cloud/otp_backup_240.enc.tmp', 'temp');
      expect(await manager.hasBackupRecords()).assertFalse();
      rig.fs.files.set('/cloud/otp_backup_240.enc', 'invalid-header');
      rig.fs.locationOverride.set('/cloud/otp_backup_240.enc', 2);
      expect(await manager.hasBackupRecords()).assertTrue();
      expect(rig.fs.statPaths.length).assertEqual(0);
      expect(rig.fs.readPaths.length).assertEqual(0);
      expect(rig.cache.calls.length).assertEqual(0);
      rig.fs.failList = true;
      expect((await manager.hasBackupRecords()) === undefined).assertTrue();
      expect(manager.isBusy()).assertFalse();
    });

    it('clear_methods_abort_when_not_logged_in', 0, async () => {
      const rig = freshRig();
      rig.account.login = false;
      await seedBackup(rig, 9700, '{}', 'odid-A');

      expect(await CloudBackupManager.getInstance().clearCloudStorage()).assertFalse();
      expect(await CloudBackupManager.getInstance().clearDeviceCloudStorage()).assertFalse();
      expect(await CloudBackupManager.getInstance().clearDeviceNameCloudStorage()).assertFalse();
      expect(rig.fs.deletedPaths.length).assertEqual(0);
      expect(rig.icons.clearCalls).assertEqual(0);
    });
  });
}

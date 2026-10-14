import { TokenConfig } from './TokenConfig';
import { TokenBatchProgressCallback, TokenBatchStage, reportTokenBatchProgress } from './TokenBatchProgress';
import { TokenGroup, TokenGroupStore } from './TokenGroupStore';
import { BackupTextIo } from './StoragePorts';
import { base32Decode, base32Encode, intArrayToString, stringToIntArray } from './TokenUtils';
import { decryptFile, encryptFile } from './CryptoUtils';
import { LocalBackupFileIo } from './LocalBackupFileIo';
import {
  identifyLocalBackup, LOCAL_BACKUP_MAGIC, LocalBackupError, LocalBackupFailure, LocalBackupKind,
  LocalBackupPayload, parseLocalBackupPayload
} from './LocalBackupFormat';

export class TokenBackup {
  magic: number;
  version: number;
  configs: Array<TokenConfig>;
  groups: TokenGroup[];

  constructor(version: number, configs: Array<TokenConfig>) {
    this.magic = LOCAL_BACKUP_MAGIC;
    this.version = version;
    this.configs = JSON.parse(JSON.stringify(configs)) as TokenConfig[];
    this.groups = TokenGroupStore.getInstance().state.groups.map((group: TokenGroup): TokenGroup =>
      new TokenGroup(group.id, group.name, group.color));
  }
}

/** 源文件只读一次；密码重试复用密文，不保留 URI。 */
export class LocalBackupSource {
  readonly kind: LocalBackupKind;
  private bytes: Uint8Array;

  constructor(content: string, fileName: string) {
    const identified = identifyLocalBackup(content, fileName);
    this.kind = identified.kind;
    this.bytes = identified.bytes;
  }

  async prepare(password: string = '', report?: TokenBatchProgressCallback): Promise<PreparedLocalBackup> {
    if (this.kind !== LocalBackupKind.PLAIN && this.kind !== LocalBackupKind.PASSWORD_V2 &&
      this.kind !== LocalBackupKind.LEGACY_CANDIDATE) {
      throw new LocalBackupError(LocalBackupFailure.FORMAT);
    }
    const encrypted = this.kind !== LocalBackupKind.PLAIN;
    try {
      reportTokenBatchProgress(report, encrypted ? TokenBatchStage.DECRYPTING : TokenBatchStage.PARSING);
      const text = encrypted ? await decryptFile(this.bytes, password) :
        intArrayToString(this.bytes.buffer as ArrayBuffer);
      return PreparedLocalBackup.fromText(text, encrypted);
    } catch (_) {
      throw new LocalBackupError(encrypted ? LocalBackupFailure.PASSWORD : LocalBackupFailure.FORMAT);
    }
  }

  dispose(): void {
    this.bytes = new Uint8Array(0);
  }
}

/** 只有完整校验能创建快照；UI 只能读取计数，提交一次后解除引用。 */
export class PreparedLocalBackup {
  readonly tokenCount: number;
  readonly groupCount: number;
  readonly encrypted: boolean;
  private payload: LocalBackupPayload | undefined;

  private constructor(payload: LocalBackupPayload, encrypted: boolean) {
    this.payload = payload;
    this.tokenCount = payload.configs.length;
    this.groupCount = payload.groups.length;
    this.encrypted = encrypted;
  }

  static fromText(text: string, encrypted: boolean = false, makeUuid?: () => string): PreparedLocalBackup {
    return new PreparedLocalBackup(parseLocalBackupPayload(text, makeUuid), encrypted);
  }

  takeForCommit(): LocalBackupPayload {
    if (this.payload === undefined) { throw new LocalBackupError(LocalBackupFailure.FORMAT); }
    const snapshot = this.payload;
    this.payload = undefined;
    return snapshot;
  }

  dispose(): void { this.payload = undefined; }
}

export async function readLocalBackupSource(uri: string, io: BackupTextIo = new LocalBackupFileIo(),
  report?: TokenBatchProgressCallback): Promise<LocalBackupSource> {
  reportTokenBatchProgress(report, TokenBatchStage.READING);
  let content: string;
  try { content = await io.readText(uri); } catch (error) {
    throw new LocalBackupError(error instanceof LocalBackupError && error.reason === LocalBackupFailure.CANCELLED ?
      LocalBackupFailure.CANCELLED : LocalBackupFailure.READ);
  }
  reportTokenBatchProgress(report, TokenBatchStage.DECODING);
  return new LocalBackupSource(content, uri);
}

export async function encodeLocalBackup(backup: TokenBackup, encrypted: boolean = false,
  password: string = ''): Promise<string> {
  try {
    const json = JSON.stringify(backup);
    const raw = encrypted ? await encryptFile(json, password) : stringToIntArray(json);
    return base32Encode(raw);
  } catch (_) {
    throw new LocalBackupError(LocalBackupFailure.SAVE);
  }
}

export async function saveBackupToFile(file_uri: string, backup: TokenBackup, do_encrypt: boolean = false,
  password: string = '', io: BackupTextIo = new LocalBackupFileIo()): Promise<void> {
  try {
    await io.writeText(file_uri, await encodeLocalBackup(backup, do_encrypt, password));
  } catch (_) {
    throw new LocalBackupError(LocalBackupFailure.SAVE);
  }
}

/** 保留外部文件入口的显式加密参数和分组合并语义；预览不得调用此包装。 */
export async function restoreFromBackup(file_uri: string, is_encrypt: boolean = false, password: string = '',
  onProgress?: TokenBatchProgressCallback, io: BackupTextIo = new LocalBackupFileIo()): Promise<TokenBackup> {
  reportTokenBatchProgress(onProgress, TokenBatchStage.READING);
  let content: string;
  try { content = await io.readText(file_uri); } catch (error) {
    throw new LocalBackupError(error instanceof LocalBackupError && error.reason === LocalBackupFailure.CANCELLED ?
      LocalBackupFailure.CANCELLED : LocalBackupFailure.READ);
  }
  reportTokenBatchProgress(onProgress, TokenBatchStage.DECODING);
  const decoded = base32Decode(content);
  let text: string;
  try {
    if (is_encrypt) { reportTokenBatchProgress(onProgress, TokenBatchStage.DECRYPTING); }
    text = is_encrypt ? await decryptFile(decoded, password) : intArrayToString(decoded.buffer as ArrayBuffer);
  } catch (_) {
    throw new LocalBackupError(LocalBackupFailure.PASSWORD);
  }
  reportTokenBatchProgress(onProgress, TokenBatchStage.PARSING);
  const backup = PreparedLocalBackup.fromText(text, is_encrypt).takeForCommit();
  try { await TokenGroupStore.getInstance().merge(backup.groups); } catch (_) {
    throw new Error('Local backup group merge failed');
  }
  return backup;
}

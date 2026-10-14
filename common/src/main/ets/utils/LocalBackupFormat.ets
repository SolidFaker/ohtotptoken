import { util } from '@kit.ArkTS';
import { TokenConfig, otpType } from './TokenConfig';
import { ALL_TOKEN_GROUPS, FAVORITE_TOKEN_GROUP, TokenGroup } from './TokenGroupStore';
import { base32Decode, base32Encode, intArrayToString } from './TokenUtils';

export const LOCAL_BACKUP_MAGIC: number = 0x55aaeebb;

export enum LocalBackupKind {
  PLAIN = 'plain',
  PASSWORD_V2 = 'password_v2',
  LEGACY_CANDIDATE = 'legacy_candidate',
  MIGRATION = 'migration',
  UNSUPPORTED = 'unsupported'
}

export enum LocalBackupFailure {
  READ = 'read',
  FORMAT = 'format',
  PASSWORD = 'password',
  SAVE = 'save',
  CANCELLED = 'cancelled'
}

/** 仅携带固定阶段，不保留系统异常、路径或载荷。 */
export class LocalBackupError extends Error {
  readonly reason: LocalBackupFailure;
  constructor(reason: LocalBackupFailure) {
    super(reason === LocalBackupFailure.FORMAT ? 'invalid backup file' : `Local backup ${reason}`);
    this.reason = reason;
  }
}

export interface LocalBackupPayload {
  magic: number;
  version: number;
  configs: TokenConfig[];
  groups: TokenGroup[];
}

export interface LocalBackupIdentification {
  kind: LocalBackupKind;
  bytes: Uint8Array;
}

/** 入口专用形态检查，不改变用于 OTP secret 的宽松解码器。 */
export function decodeLocalBackupBase32(text: string): Uint8Array {
  const compact = text.replace(/^\uFEFF/, '').replace(/[ \t\r\n-]/g, '').toUpperCase();
  if (!/^[A-Z2-7]+={0,6}$/.test(compact)) {
    throw new LocalBackupError(LocalBackupFailure.FORMAT);
  }
  const body = compact.replace(/=+$/, '');
  const remainder = body.length % 8;
  if (remainder === 1 || remainder === 3 || remainder === 6 ||
    (compact.length !== body.length && compact.length % 8 !== 0)) {
    throw new LocalBackupError(LocalBackupFailure.FORMAT);
  }
  const bytes = base32Decode(body);
  if (base32Encode(bytes).replace(/=+$/, '') !== body) {
    throw new LocalBackupError(LocalBackupFailure.FORMAT);
  }
  return bytes;
}

export function identifyLocalBackup(text: string, fileName: string = ''): LocalBackupIdentification {
  const clean = text.replace(/^\uFEFF/, '').trim();
  const lines = clean.split(/\r?\n/).filter((line: string): boolean => line.trim().length > 0);
  if (lines.some((line: string): boolean => /^otpauth:\/\//i.test(line.trim()))) {
    return { kind: LocalBackupKind.MIGRATION, bytes: new Uint8Array(0) };
  }
  let bytes: Uint8Array;
  try {
    bytes = decodeLocalBackupBase32(clean);
  } catch (_) {
    return { kind: LocalBackupKind.UNSUPPORTED, bytes: new Uint8Array(0) };
  }
  if (bytes.length >= 3 && bytes[0] === 0x4F && bytes[1] === 0x54 && bytes[2] === 0x50) {
    const validV2 = bytes[3] === 2 && bytes.length >= 52 && (bytes.length - 36) % 16 === 0;
    return { kind: validV2 ? LocalBackupKind.PASSWORD_V2 : LocalBackupKind.UNSUPPORTED, bytes: bytes };
  }
  const decoded = intArrayToString(bytes.buffer as ArrayBuffer).trim();
  if (decoded.startsWith('{') || decoded.startsWith('[')) {
    try {
      const payload = JSON.parse(decoded) as LocalBackupPayload;
      if (payload !== null && payload.magic === LOCAL_BACKUP_MAGIC && Array.isArray(payload.configs)) {
        return { kind: LocalBackupKind.PLAIN, bytes: bytes };
      }
      return { kind: LocalBackupKind.UNSUPPORTED, bytes: bytes };
    } catch (_) {
      // 无头 CBC 也可能随机以 JSON 标点起始；仅解析失败仍可走受限旧格式候选。
    }
  }
  const legacy = /\.bak$/i.test(fileName.split('?')[0].split('#')[0]) && bytes.length > 0 && bytes.length % 16 === 0;
  return { kind: legacy ? LocalBackupKind.LEGACY_CANDIDATE : LocalBackupKind.UNSUPPORTED, bytes: bytes };
}

function isObject(value: Object | undefined | null): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function optionalStrings(values: (string | undefined)[]): boolean {
  return values.every((value: string | undefined): boolean => value === undefined || typeof value === 'string');
}

function optionalNumbers(values: (number | undefined)[]): boolean {
  return values.every((value: number | undefined): boolean => value === undefined ||
    (typeof value === 'number' && Number.isFinite(value)));
}

function validToken(token: TokenConfig): boolean {
  if (!isObject(token) || (token.TokenUUID !== undefined &&
    (typeof token.TokenUUID !== 'string' || token.TokenUUID.length === 0)) ||
    typeof token.TokenSecret !== 'string' || typeof token.TokenIssuer !== 'string' || typeof token.TokenName !== 'string' ||
    ![otpType.TOTP, otpType.HOTP, otpType.Steam, otpType.Forti].includes(token.TokenType) ||
    !['SHA1', 'SHA224', 'SHA256', 'SHA384', 'SHA512', 'SM3', 'MD5'].includes(token.TokenAlgorithm) ||
    !Number.isInteger(token.TokenPeriod) || token.TokenPeriod <= 0 ||
    !Number.isInteger(token.TokenDigits) || token.TokenDigits <= 0 ||
    !Number.isInteger(token.TokenCounter) || token.TokenCounter < 0 ||
    !optionalStrings([token.FortiToken, token.FortiDevID, token.TokenGroupId, token.TokenIconPath, token.TokenExternalCode]) ||
    !optionalNumbers([token.RankScore]) || (token.TokenFavorite !== undefined && typeof token.TokenFavorite !== 'boolean')) {
    return false;
  }
  const auth = token.SteamAuth;
  if (auth !== undefined && auth !== null && (!isObject(auth) ||
    !optionalStrings([auth.accountName, auth.steamid, auth.deviceId, auth.serialNumber, auth.tokenGid, auth.uri,
      auth.identitySecret, auth.revocationCode, auth.refreshToken, auth.accessToken]) ||
    !optionalNumbers([auth.serverTime, auth.steamguardScheme, auth.accessTokenExp]))) {
    return false;
  }
  const file = token.SteamMaFile;
  if (file !== undefined && (!isObject(file) ||
    !optionalStrings([file.shared_secret, file.serial_number, file.revocation_code, file.uri, file.account_name,
      file.token_gid, file.identity_secret, file.secret_1, file.device_id]) ||
    !optionalNumbers([file.server_time, file.status]) ||
    (file.fully_enrolled !== undefined && typeof file.fully_enrolled !== 'boolean') ||
    (file.Session !== undefined && file.Session !== null && typeof file.Session !== 'string' && !isObject(file.Session)))) {
    return false;
  }
  return true;
}

/** 校验整批后归一；保留合法扩展字段，不执行任何持久化或选择状态变更。 */
export function parseLocalBackupPayload(text: string, makeUuid: () => string = () => util.generateRandomUUID()): LocalBackupPayload {
  try {
    const payload = JSON.parse(text) as LocalBackupPayload;
    if (!isObject(payload) || payload.magic !== LOCAL_BACKUP_MAGIC || !Array.isArray(payload.configs) ||
      (payload.version !== undefined && (typeof payload.version !== 'number' || !Number.isFinite(payload.version))) ||
      (payload.groups !== undefined && !Array.isArray(payload.groups))) {
      throw new LocalBackupError(LocalBackupFailure.FORMAT);
    }
    if (!payload.configs.every((token: TokenConfig): boolean => validToken(token))) {
      throw new LocalBackupError(LocalBackupFailure.FORMAT);
    }
    const reserved = new Set<string>(payload.configs.map((token: TokenConfig): string => token.TokenUUID));
    const configs = new Map<string, TokenConfig>();
    for (const token of payload.configs) {
      // 2024 年旧备份不含 UUID；只在准备时生成一次，确认不能再次生成另一标识。
      if (token.TokenUUID === undefined) {
        const uuid = makeUuid();
        if (typeof uuid !== 'string' || uuid.length === 0 || reserved.has(uuid)) {
          throw new LocalBackupError(LocalBackupFailure.FORMAT);
        }
        token.TokenUUID = uuid;
        reserved.add(uuid);
      }
      token.FortiToken = token.FortiToken ?? '';
      token.FortiDevID = token.FortiDevID ?? '';
      token.RankScore = token.RankScore ?? 0;
      token.TokenGroupId = token.TokenGroupId ?? '';
      token.TokenExternalCode = token.TokenExternalCode ?? '';
      // TokenStore 同批重复标识保留首次收藏和位置，内容取最后一条。
      token.TokenFavorite = configs.get(token.TokenUUID)?.TokenFavorite ?? token.TokenFavorite ?? false;
      configs.set(token.TokenUUID, token);
    }
    const groups = new Map<string, TokenGroup>();
    for (const group of payload.groups ?? []) {
      if (!isObject(group) || typeof group.id !== 'string' || typeof group.name !== 'string') {
        throw new LocalBackupError(LocalBackupFailure.FORMAT);
      }
      if (group.id !== '' && group.id !== ALL_TOKEN_GROUPS && group.id !== FAVORITE_TOKEN_GROUP &&
        group.name.trim().length > 0 && !groups.has(group.id)) {
        groups.set(group.id, new TokenGroup(group.id, group.name.trim().slice(0, 24), group.color));
      }
    }
    payload.version = payload.version ?? 0;
    payload.configs = Array.from(configs.values());
    payload.groups = Array.from(groups.values());
    return payload;
  } catch (_) {
    throw new LocalBackupError(LocalBackupFailure.FORMAT);
  }
}

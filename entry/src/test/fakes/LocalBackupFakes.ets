import {
  BackupTextIo, base32Encode, LocalBackupFilePort, LocalBackupPayload, LOCAL_BACKUP_MAGIC,
  TokenConfig, TokenGroup, TokenGroupKvBackend, otpType
} from 'common';
import { FakeCryptoEngine } from './BackupFakes';

export const LOCAL_BACKUP_SENTINEL: string = 'SYNTHETIC_PRIVATE_PATH_PASSWORD_PLAIN_CIPHER';

export class DeferredBackupWork {
  readonly promise: Promise<void>;
  private resolve: () => void = () => {};
  constructor() { this.promise = new Promise<void>((resolve) => { this.resolve = resolve; }); }
  complete(): void { this.resolve(); }
}

/** 只为协议形态提供块填充；不是密码数值验收。 */
export class LocalBackupCryptoFake extends FakeCryptoEngine {
  async aesCbcEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    const padding = 16 - plain.length % 16;
    const padded = new Uint8Array(plain.length + padding);
    padded.set(plain);
    padded.fill(padding, plain.length);
    return super.aesCbcEncrypt(padded, key, iv);
  }
  async aesCbcDecrypt(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    const padded = await super.aesCbcDecrypt(cipher, key, iv);
    const padding = padded[padded.length - 1];
    if (padding < 1 || padding > 16 || !padded.slice(-padding).every((byte: number): boolean => byte === padding)) {
      throw new Error(LOCAL_BACKUP_SENTINEL);
    }
    return padded.slice(0, -padding);
  }
}

export function localBackupToken(uuid: string = 'synthetic-token', type: otpType = otpType.TOTP): TokenConfig {
  const token = new TokenConfig('JBSWY3DPEHPK3PXP', type, 'Synthetic issuer', 'Synthetic account');
  token.TokenUUID = uuid;
  if (type === otpType.Steam) { token.TokenDigits = 5; }
  if (type === otpType.Forti) { token.FortiToken = 'SYNTHETIC'; token.FortiDevID = 'SYNTHETIC'; }
  return token;
}

export function localBackupPayload(): LocalBackupPayload {
  return {
    magic: LOCAL_BACKUP_MAGIC, version: 1,
    configs: [localBackupToken('totp'), localBackupToken('hotp', otpType.HOTP),
      localBackupToken('steam', otpType.Steam), localBackupToken('forti', otpType.Forti)],
    groups: [new TokenGroup('synthetic-group', ' 合成分组 ', -1)]
  };
}

export function localBackupText(payload: LocalBackupPayload = localBackupPayload()): string {
  return base32Encode(new FakeCryptoEngine().utf8Encode(JSON.stringify(payload)));
}

export async function legacyLocalBackupText(engine: LocalBackupCryptoFake, json: string, password: string): Promise<string> {
  const key = await engine.pbkdf2Derive(password, new Uint8Array(16), 10000, 16);
  return base32Encode(await engine.aesCbcEncrypt(engine.utf8Encode(json), key, engine.utf8Encode('ohtotptokenaesiv')));
}

export class LocalBackupTextFake implements BackupTextIo {
  content: string = localBackupText();
  reads: number = 0;
  writes: number = 0;
  failRead: boolean = false;
  async readText(_uri: string): Promise<string> {
    this.reads++;
    if (this.failRead) { throw new Error(LOCAL_BACKUP_SENTINEL); }
    return this.content;
  }
  async writeText(_uri: string, text: string): Promise<void> { this.writes++; this.content = text; }
}

export class LocalBackupGroupFake implements TokenGroupKvBackend {
  writes: number = 0;
  fail: boolean = false;
  async getValue<T>(_key: string): Promise<T | null> { return null; }
  async setValue<T>(_key: string, _value: T): Promise<void> {
    this.writes++;
    if (this.fail) { throw new Error(LOCAL_BACKUP_SENTINEL); }
  }
}

export class LocalBackupFileFake implements LocalBackupFilePort {
  bytes: Uint8Array = new Uint8Array(0);
  written: number[] = [];
  opens: number = 0;
  reads: number = 0;
  writes: number = 0;
  closes: number = 0;
  readChunk: number = 3;
  writeChunk: number = 5;
  failAt: string = '';
  openDelay: DeferredBackupWork | undefined;
  writeDelay: DeferredBackupWork | undefined;
  closeDelay: DeferredBackupWork | undefined;
  private offset: number = 0;
  private codec: FakeCryptoEngine = new FakeCryptoEngine();

  encode(text: string): Uint8Array {
    if (this.failAt === 'encode') { throw new Error(LOCAL_BACKUP_SENTINEL); }
    const encoded = this.codec.utf8Encode(text);
    const buffer = new Uint8Array(encoded.length + 10);
    buffer.set(encoded, 5);
    return buffer.subarray(5, 5 + encoded.length);
  }
  decode(bytes: Uint8Array): string { return this.codec.utf8Decode(bytes); }
  async open(_uri: string, _writing: boolean): Promise<number> {
    this.opens++;
    if (this.openDelay !== undefined) { await this.openDelay.promise; }
    if (this.failAt === 'open') { throw new Error(LOCAL_BACKUP_SENTINEL); }
    return 7;
  }
  async read(_fd: number, bytes: ArrayBuffer): Promise<number> {
    this.reads++;
    if (this.failAt === 'read') { throw new Error(LOCAL_BACKUP_SENTINEL); }
    const length = Math.min(this.readChunk, this.bytes.length - this.offset, bytes.byteLength);
    new Uint8Array(bytes).set(this.bytes.subarray(this.offset, this.offset + length));
    this.offset += length;
    return length;
  }
  async write(_fd: number, bytes: ArrayBuffer): Promise<number> {
    this.writes++;
    if (this.writeDelay !== undefined) { await this.writeDelay.promise; }
    if (this.failAt === 'write') { throw new Error(LOCAL_BACKUP_SENTINEL); }
    const length = Math.min(this.writeChunk, bytes.byteLength);
    this.written.push(...Array.from(new Uint8Array(bytes, 0, length)));
    return length;
  }
  async close(_fd: number): Promise<void> {
    this.closes++;
    if (this.closeDelay !== undefined) { await this.closeDelay.promise; }
    if (this.failAt === 'close') { throw new Error(LOCAL_BACKUP_SENTINEL); }
  }
}

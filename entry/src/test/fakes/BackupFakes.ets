import {
  CryptoEngine,
  CryptoSealedBytes,
  FsGateway,
  FsStatInfo,
  KvBatchEntry,
  LegacyTokenKv,
  NamedSecretStore,
  SecretStore,
  TokenBatchProgressCallback,
  TokenKvStore,
  TransactionalKv,
  utf8ByteLength,
} from 'common';
import { TokenConfig } from 'common';
import { OathCryptoPort } from '../../main/ets/oath/OathApplet';
import { TagTransport } from '../../main/ets/oath/TagTransport';

/**
 * Phase 2 共享测试假实现（docs/TEST_PLAN.md 第 4 节端口注入）。
 * 仅在 entry/src/test 下使用；全部为确定性实现，无 @ohos 系统 API。
 */

/** TokenKvStore 内存实现：JSON 序列化存储，与生产加密 KV 行为一致；支持失败注入。 */
export class MemoryTokenKv implements TokenKvStore {
  entries: Map<string, string> = new Map();
  initCalls: number = 0;
  failNextBatch: boolean = false;
  lastBatchTokens: TokenConfig[] = [];
  lastBatchDeletes: string[] = [];
  batchCallCount: number = 0;

  init(): Promise<void> {
    this.initCalls++;
    return Promise.resolve();
  }

  getValue<T>(key: string): Promise<T | null> {
    const raw = this.entries.get(key);
    if (raw === undefined) {
      return Promise.resolve(null);
    }
    return Promise.resolve(JSON.parse(raw) as T);
  }

  setValue<T>(key: string, value: T): Promise<void> {
    this.entries.set(key, JSON.stringify(value));
    return Promise.resolve();
  }

  deleteValue(key: string): Promise<void> {
    this.entries.delete(key);
    return Promise.resolve();
  }

  getTokenArray(prefix: string): Promise<TokenConfig[]> {
    const out: TokenConfig[] = [];
    this.entries.forEach((value: string, key: string) => {
      if (key.startsWith(prefix) && value.length > 0) {
        out.push(JSON.parse(value) as TokenConfig);
      }
    });
    return Promise.resolve(out);
  }

  saveTokenBatch(prefix: string, tokens: TokenConfig[], deletedUuids?: string[],
    onProgress?: TokenBatchProgressCallback): Promise<void> {
    this.batchCallCount++;
    if (this.failNextBatch) {
      this.failNextBatch = false;
      return Promise.reject(new Error('kv batch failed'));
    }
    this.lastBatchTokens = tokens;
    this.lastBatchDeletes = deletedUuids !== undefined ? deletedUuids : [];
    for (const token of tokens) {
      this.entries.set(`${prefix}${token.TokenUUID}`, JSON.stringify(token));
    }
    for (const uuid of this.lastBatchDeletes) {
      this.entries.delete(`${prefix}${uuid}`);
    }
    return Promise.resolve();
  }
}

/** SecretStore 内存实现：三重验证各失败点可独立注入。 */
export class MemorySecretStore implements SecretStore {
  secrets: Map<string, string> = new Map();
  namedSecrets: Map<string, string> = new Map();
  /** upsertSecret 对这些 uuid 返回 false（模拟 ASSET add 失败） */
  failUpsertFor: Set<string> = new Set();
  /** querySecret 对这些 uuid 返回 null（模拟验证阶段查不到） */
  dropQueryFor: Set<string> = new Set();
  /** querySecret 对这些 uuid 返回被篡改值（模拟验证阶段内容不一致） */
  corruptQueryFor: Map<string, string> = new Map();
  upsertCalls: string[] = [];
  removeCalls: string[] = [];
  batchQueryCalls: number = 0;

  isSecretSizeValid(secret: string): boolean {
    if (secret.length === 0) {
      return false;
    }
    return utf8ByteLength(secret) <= 900;
  }

  async upsertSecret(tokenUUID: string, secret: string): Promise<boolean> {
    this.upsertCalls.push(tokenUUID);
    if (this.failUpsertFor.has(tokenUUID)) {
      return false;
    }
    this.secrets.set(tokenUUID, secret);
    return true;
  }

  querySecret(tokenUUID: string): Promise<string | null> {
    if (this.dropQueryFor.has(tokenUUID)) {
      return Promise.resolve(null);
    }
    // 篡改仅在 upsert 之后生效：批量预查（迁移前）视为不存在，验证查询返回被篡改值
    const corrupt = this.corruptQueryFor.get(tokenUUID);
    if (corrupt !== undefined && this.upsertCalls.indexOf(tokenUUID) >= 0) {
      return Promise.resolve(corrupt);
    }
    const value = this.secrets.get(tokenUUID);
    return Promise.resolve(value !== undefined ? value : null);
  }

  async removeSecret(tokenUUID: string): Promise<void> {
    this.removeCalls.push(tokenUUID);
    this.secrets.delete(tokenUUID);
  }

  async batchQuerySecrets(tokenUUIDs: string[]): Promise<Map<string, string>> {
    this.batchQueryCalls++;
    const result = new Map<string, string>();
    for (const uuid of tokenUUIDs) {
      const secret = await this.querySecret(uuid);
      if (secret !== null) {
        result.set(uuid, secret);
      }
    }
    return result;
  }

  upsertNamedSecret(alias: string, secret: string): Promise<boolean> {
    this.namedSecrets.set(alias, secret);
    return Promise.resolve(true);
  }

  queryNamedSecret(alias: string): Promise<string | null> {
    const value = this.namedSecrets.get(alias);
    return Promise.resolve(value !== undefined ? value : null);
  }

  async removeNamedSecret(alias: string): Promise<void> {
    this.namedSecrets.delete(alias);
  }
}

/** NamedSecretStore 内存实现（SteamSecretStore 用），记录调用序供断言。 */
export class MemoryNamedSecretStore implements NamedSecretStore {
  secrets: Map<string, string> = new Map();
  upsertCalls: string[] = [];
  removeCalls: string[] = [];
  probeCalls: string[] = [];
  /** 对命中的 alias 让 upsert 失败 */
  failUpsertFor: Set<string> = new Set();

  upsertNamedSecret(alias: string, secret: string): Promise<boolean> {
    this.upsertCalls.push(alias);
    if (this.failUpsertFor.has(alias)) {
      return Promise.resolve(false);
    }
    this.secrets.set(alias, secret);
    return Promise.resolve(true);
  }

  queryNamedSecret(alias: string): Promise<string | null> {
    this.probeCalls.push(alias);
    const value = this.secrets.get(alias);
    return Promise.resolve(value !== undefined ? value : null);
  }

  async removeNamedSecret(alias: string): Promise<void> {
    this.removeCalls.push(alias);
    this.secrets.delete(alias);
  }
}

export class MemoryFsError extends Error {
  code: number;
  constructor(code: number) {
    super('Synthetic filesystem failure');
    this.code = code;
  }
}

/** FsGateway 内存实现：文件内容 + 删除/写入记录 + location 覆盖。 */
export class MemoryFs implements FsGateway {
  files: Map<string, string> = new Map();
  dirs: Set<string> = new Set();
  written: Map<string, string> = new Map();
  deletedPaths: string[] = [];
  copiedPairs: string[] = [];
  failWrite: boolean = false;
  failClose: boolean = false;
  failPublish: boolean = false;
  failNewWriteAfterCreate: boolean = false;
  failReadFor: Set<string> = new Set();
  readOverride: Map<string, string> = new Map();
  newWriteCalls: string[] = [];
  publishedPairs: string[] = [];
  publishAttempts: string[] = [];
  locationOverride: Map<string, number> = new Map();
  /** 对这些源路径注入 copyFile 失败（模拟图标目录收集/发布的 IO 故障）。 */
  failCopyFor: Set<string> = new Set();
  /** 仅注入移动修改目标之前的失败；不能证明 SDK 移动失败或真机进程中断时保旧。 */
  failReplace: boolean = false;
  replaceAttempts: string[] = [];
  /** moveFileToReplace 成功替换记录（源->目标），供发布顺序断言。 */
  replacedPairs: string[] = [];
  /** 专用临时目录清理故障注入，默认不改变既有行为。 */
  failRemoveDirFor: Set<string> = new Set();

  stat(path: string): Promise<FsStatInfo> {
    const info = new FsStatInfo();
    const loc = this.locationOverride.get(path);
    info.location = loc !== undefined ? loc : 0;
    if (this.dirs.has(path)) {
      info.size = 0;
      info.isDirectory = true;
      return Promise.resolve(info);
    }
    const content = this.files.get(path);
    if (content === undefined) {
      return Promise.reject(new MemoryFsError(13900002));
    }
    info.size = content.length;
    info.isDirectory = false;
    return Promise.resolve(info);
  }

  listFiles(dir: string): Promise<string[]> {
    // 与 fs.listFile 语义一致：仅列出直接子项（含子目录名）
    const out: string[] = [];
    this.files.forEach((_: string, path: string) => {
      const idx = path.lastIndexOf('/');
      const parent = idx > 0 ? path.substring(0, idx) : '/';
      if (parent === dir) {
        out.push(path.substring(dir.length + 1));
      }
    });
    this.dirs.forEach((path: string) => {
      const idx = path.lastIndexOf('/');
      const parent = idx > 0 ? path.substring(0, idx) : '/';
      if (parent === dir) {
        out.push(path.substring(dir.length + 1));
      }
    });
    return Promise.resolve(out);
  }

  readTextFile(path: string): Promise<string> {
    if (this.failReadFor.has(path)) {
      return Promise.reject(new MemoryFsError(13900005));
    }
    const content = this.files.get(path);
    if (content === undefined) {
      return Promise.reject(new MemoryFsError(13900002));
    }
    return Promise.resolve(this.readOverride.get(path) ?? content);
  }

  writeTextFile(path: string, content: string): Promise<void> {
    this.files.set(path, '');
    if (this.failWrite) {
      return Promise.reject(new MemoryFsError(13900005));
    }
    this.files.set(path, content);
    this.written.set(path, content);
    if (this.failClose) {
      return Promise.reject(new MemoryFsError(13900005));
    }
    return Promise.resolve();
  }

  writeBinaryFile(path: string, data: Uint8Array): Promise<void> {
    let text = '';
    for (let i = 0; i < data.length; i++) {
      text += String.fromCharCode(data[i]);
    }
    return this.writeTextFile(path, text);
  }

  async writeNewTextFile(path: string, content: string): Promise<void> {
    this.newWriteCalls.push(path);
    if (this.files.has(path) || this.dirs.has(path)) {
      throw new MemoryFsError(13900015);
    }
    // 生产实现先写独占 staging 目录。失败只能回收本操作 stage，目标无所有权。
    const stage = `${path}.owned-stage-${this.newWriteCalls.length}`;
    this.files.set(stage, '');
    try {
      if (this.failWrite || this.failNewWriteAfterCreate) {
        throw new MemoryFsError(13900005);
      }
      this.files.set(stage, content);
      if (this.failClose) {
        throw new MemoryFsError(13900005);
      }
      this.files.set(path, content);
      this.written.set(path, content);
    } finally {
      this.files.delete(stage);
    }
  }

  syncedPaths: string[] = [];
  failSyncFor: Set<string> = new Set();

  async syncFile(path: string): Promise<void> {
    if (!this.files.has(path)) throw new MemoryFsError(13900002);
    if (this.failSyncFor.has(path)) throw new MemoryFsError(13900005);
    this.syncedPaths.push(path);
  }

  async publishFile(source: string, destination: string): Promise<void> {
    const pair = `${source}->${destination}`;
    this.publishAttempts.push(pair);
    if (source === destination || source.substring(0, source.lastIndexOf('/')) !==
      destination.substring(0, destination.lastIndexOf('/'))) {
      throw new MemoryFsError(13900020);
    }
    if (this.files.has(destination) || this.dirs.has(destination)) {
      throw new MemoryFsError(13900015);
    }
    const content = this.files.get(source);
    if (content === undefined) {
      throw new MemoryFsError(13900002);
    }
    if (this.failPublish) {
      throw new MemoryFsError(13900005);
    }
    this.files.set(destination, content);
    this.files.delete(source);
    const location = this.locationOverride.get(source);
    if (location !== undefined) {
      this.locationOverride.set(destination, location);
      this.locationOverride.delete(source);
    }
    this.publishedPairs.push(pair);
  }

  private tempSequence: number = 0;

  async makeTempDir(prefix: string): Promise<string> {
    this.tempSequence++;
    const path = prefix.replace('XXXXXX', ('000000' + this.tempSequence).slice(-6));
    if (this.dirs.has(path) || this.files.has(path)) throw new MemoryFsError(13900015);
    this.dirs.add(path);
    return path;
  }

  makeDir(path: string): Promise<void> {
    this.dirs.add(path);
    return Promise.resolve();
  }

  removeDir(path: string): Promise<void> {
    // fs.rmdir 递归删除；所有权保护必须由调用方负责，不能由 fake 的空目录假设代替。
    if (this.failRemoveDirFor.has(path)) {
      return Promise.reject(new MemoryFsError(13900005));
    }
    if (!this.dirs.has(path)) {
      return Promise.reject(new MemoryFsError(13900002));
    }
    const prefix = path + '/';
    for (const file of this.files.keys()) {
      if (file.startsWith(prefix)) this.files.delete(file);
    }
    for (const directory of this.dirs) {
      if (directory === path || directory.startsWith(prefix)) this.dirs.delete(directory);
    }
    return Promise.resolve();
  }

  deleteFile(path: string): Promise<void> {
    // 与 fs.unlink 语义一致：删除不存在的文件必须报错；目录不能用 unlink 删除
    if (this.dirs.has(path)) {
      return Promise.reject(new Error(`delete: is a directory ${path}`));
    }
    if (!this.files.has(path)) {
      return Promise.reject(new MemoryFsError(13900002));
    }
    this.deletedPaths.push(path);
    this.files.delete(path);
    return Promise.resolve();
  }

  copyFile(src: string, dest: string): Promise<void> {
    if (this.failCopyFor.has(src)) {
      return Promise.reject(new MemoryFsError(13900005));
    }
    const content = this.files.get(src);
    if (content === undefined) {
      return Promise.reject(new Error(`copy: no such file ${src}`));
    }
    this.copiedPairs.push(`${src}->${dest}`);
    this.files.set(dest, content);
    return Promise.resolve();
  }

  async moveFileToReplace(source: string, destination: string): Promise<void> {
    this.replaceAttempts.push(`${source}->${destination}`);
    if (source === destination || source.substring(0, source.lastIndexOf('/')) !==
      destination.substring(0, destination.lastIndexOf('/'))) {
      throw new MemoryFsError(13900020);
    }
    const content = this.files.get(source);
    if (content === undefined) {
      throw new MemoryFsError(13900002);
    }
    if (this.failReplace) {
      throw new MemoryFsError(13900012);
    }
    // 只模拟正常覆盖与移动前失败，不模拟原生实现中途出错/进程终止的状态。
    this.files.set(destination, content);
    this.files.delete(source);
    const location = this.locationOverride.get(source);
    if (location !== undefined) {
      this.locationOverride.set(destination, location);
      this.locationOverride.delete(source);
    }
    this.replacedPairs.push(`${source}->${destination}`);
  }
}

/** TransactionalKv 内存实现：暂存写入，commit 落盘、rollback 丢弃，记录分块调用。 */
export class MemoryTransactionalKv implements TransactionalKv {
  committed: Map<string, string> = new Map();
  staged: Map<string, string> = new Map();
  stagedDeletes: string[] = [];
  startCount: number = 0;
  commitCount: number = 0;
  rollbackCount: number = 0;
  putBatchCalls: number[][] = [];
  deleteBatchCalls: number[][] = [];
  /** 第 N 次 putBatch（0 起）抛错；-1 表示不失败 */
  failPutBatchAt: number = -1;
  private putCallIndex: number = 0;

  async startTransaction(): Promise<void> {
    this.startCount++;
    this.staged = new Map();
    this.stagedDeletes = [];
    this.putCallIndex = 0;
  }

  async putBatch(entries: KvBatchEntry[]): Promise<void> {
    this.putBatchCalls.push(entries.map((e: KvBatchEntry): number => e.key.length));
    if (this.failPutBatchAt === this.putCallIndex) {
      this.putCallIndex++;
      throw new Error('putBatch failed');
    }
    this.putCallIndex++;
    for (const entry of entries) {
      this.staged.set(entry.key, entry.value);
    }
  }

  async deleteBatch(keys: string[]): Promise<void> {
    this.deleteBatchCalls.push(keys.map((k: string): number => k.length));
    for (const key of keys) {
      this.stagedDeletes.push(key);
    }
  }

  async commit(): Promise<void> {
    this.commitCount++;
    this.staged.forEach((value: string, key: string) => {
      this.committed.set(key, value);
    });
    for (const key of this.stagedDeletes) {
      this.committed.delete(key);
    }
  }

  async rollback(): Promise<void> {
    this.rollbackCount++;
    this.staged = new Map();
    this.stagedDeletes = [];
  }
}

/** LegacyTokenKv 内存实现（旧版本令牌迁移用）。 */
export class MemoryLegacyKv implements LegacyTokenKv {
  entries: Map<string, string> = new Map();

  getRawEntries(prefix: string): Promise<KvBatchEntry[]> {
    const out: KvBatchEntry[] = [];
    this.entries.forEach((value: string, key: string) => {
      if (key.startsWith(prefix)) {
        const entry: KvBatchEntry = { key: key, value: value };
        out.push(entry);
      }
    });
    return Promise.resolve(out);
  }

  getString(key: string): Promise<string | null> {
    const value = this.entries.get(key);
    return Promise.resolve(value !== undefined ? value : null);
  }

  setString(key: string, value: string): Promise<void> {
    this.entries.set(key, value);
    return Promise.resolve();
  }

  deleteValue(key: string): Promise<void> {
    this.entries.delete(key);
    return Promise.resolve();
  }
}

/**
 * 确定性假密码引擎：XOR 流"加密"（可逆），LCG 伪随机；
 * 记录关键调用供断言。数值正确性不属本层测试目标。
 */
export class FakeCryptoEngine implements CryptoEngine {
  randomSeed: number = 1;
  failNextCbcDecrypt: boolean = false;
  failGcmOpen: boolean = false;
  lastPbkdf2Password: string = '';
  lastPbkdf2Salt: Uint8Array = new Uint8Array(0);
  lastPbkdf2Iterations: number = -1;
  lastPbkdf2KeySize: number = -1;
  sha256Calls: Uint8Array[] = [];
  /** 最近一次 aesCbcDecrypt 收到的 iv（供 legacy 固定 IV 断言） */
  lastCbcDecryptIv: Uint8Array = new Uint8Array(0);

  randomBytes(length: number): Uint8Array {
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      this.randomSeed = (this.randomSeed * 48271) % 2147483647;
      out[i] = this.randomSeed % 256;
    }
    return out;
  }

  utf8Encode(text: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const lo = text.charCodeAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 63));
      } else if (code < 0x10000) {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      } else {
        out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      }
    }
    return new Uint8Array(out);
  }

  utf8Decode(data: Uint8Array): string {
    let out = '';
    let i = 0;
    while (i < data.length) {
      let code: number;
      const b = data[i];
      if (b < 0x80) {
        code = b;
        i += 1;
      } else if (b < 0xE0) {
        code = ((b & 0x1F) << 6) | (data[i + 1] & 63);
        i += 2;
      } else if (b < 0xF0) {
        code = ((b & 0x0F) << 12) | ((data[i + 1] & 63) << 6) | (data[i + 2] & 63);
        i += 3;
      } else {
        code = ((b & 0x07) << 18) | ((data[i + 1] & 63) << 12) | ((data[i + 2] & 63) << 6) | (data[i + 3] & 63);
        i += 4;
      }
      if (code >= 0x10000) {
        code -= 0x10000;
        out += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 1023));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }

  async pbkdf2Derive(password: string, salt: Uint8Array, iterations: number, keySize: number): Promise<Uint8Array> {
    this.lastPbkdf2Password = password;
    this.lastPbkdf2Salt = salt;
    this.lastPbkdf2Iterations = iterations;
    this.lastPbkdf2KeySize = keySize;
    const out = new Uint8Array(keySize);
    let acc = 17;
    for (let i = 0; i < password.length; i++) {
      acc = (acc * 31 + password.charCodeAt(i)) % 2147483647;
    }
    for (let i = 0; i < salt.length; i++) {
      acc = (acc * 31 + salt[i]) % 2147483647;
    }
    acc = (acc + iterations) % 2147483647;
    for (let i = 0; i < keySize; i++) {
      acc = (acc * 48271) % 2147483647;
      out[i] = acc % 256;
    }
    return out;
  }

  async sha256(data: Uint8Array): Promise<Uint8Array> {
    this.sha256Calls.push(data);
    const out = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      let acc = i + 1;
      for (let j = 0; j < data.length; j++) {
        acc = ((acc * 31) + data[j] + j) % 65521;
      }
      out[i] = acc % 256;
    }
    return out;
  }

  private xorStream(data: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
    const out = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i++) {
      out[i] = data[i] ^ key[i % key.length] ^ iv[i % iv.length] ^ (i % 251);
    }
    return out;
  }

  async aesCbcEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    return this.xorStream(plain, key, iv);
  }

  async aesCbcDecrypt(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
    this.lastCbcDecryptIv = iv;
    if (this.failNextCbcDecrypt) {
      this.failNextCbcDecrypt = false;
      throw new Error('fake padding error');
    }
    return this.xorStream(cipher, key, iv);
  }

  async aesGcmSeal(plain: Uint8Array, key: Uint8Array, iv: Uint8Array, _aad: Uint8Array): Promise<CryptoSealedBytes> {
    const sealed = new CryptoSealedBytes();
    sealed.ciphertext = this.xorStream(plain, key, iv);
    const tag = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      tag[i] = (key[i % key.length] ^ iv[i % iv.length] ^ i) & 0xFF;
    }
    sealed.tag = tag;
    return sealed;
  }

  async aesGcmOpen(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array, _aad: Uint8Array,
    tag: Uint8Array): Promise<Uint8Array> {
    if (this.failGcmOpen) {
      throw new Error('fake tag mismatch');
    }
    for (let i = 0; i < 16; i++) {
      if (tag[i] !== ((key[i % key.length] ^ iv[i % iv.length] ^ i) & 0xFF)) {
        throw new Error('fake tag mismatch');
      }
    }
    return this.xorStream(cipher, key, iv);
  }
}

/** OathCryptoPort 确定性假实现：两侧计算一致，仅验证协议编排。 */
export class FakeOathCrypto implements OathCryptoPort {
  deriveCalls: number = 0;
  lastDerivePassword: string = '';
  lastDeriveSalt: Uint8Array = new Uint8Array(0);

  async pbkdf2Sha1Derive(password: string, salt: Uint8Array, _iterations: number, keySize: number):
    Promise<Uint8Array> {
    this.deriveCalls++;
    this.lastDerivePassword = password;
    this.lastDeriveSalt = salt;
    const out = new Uint8Array(keySize);
    for (let i = 0; i < keySize; i++) {
      out[i] = (password.charCodeAt(i % Math.max(password.length, 1)) + i) & 0xFF;
    }
    return out;
  }

  async hmacSha1(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
    const out = new Uint8Array(20);
    for (let i = 0; i < 20; i++) {
      const k = key.length > 0 ? key[i % key.length] : 0;
      const m = message.length > 0 ? message[i % message.length] : 0;
      out[i] = (k ^ m ^ (i * 7 + 3)) & 0xFF;
    }
    return out;
  }

  randomBytes(len: number): Uint8Array {
    const out = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      out[i] = (i * 11 + 5) & 0xFF;
    }
    return out;
  }

  utf8Decode(data: Uint8Array): string {
    return this.utf8DecodeImpl(data);
  }

  private utf8DecodeImpl(data: Uint8Array): string {
    let out = '';
    let i = 0;
    while (i < data.length) {
      let code: number;
      const b = data[i];
      if (b < 0x80) {
        code = b;
        i += 1;
      } else if (b < 0xE0) {
        code = ((b & 0x1F) << 6) | (data[i + 1] & 63);
        i += 2;
      } else if (b < 0xF0) {
        code = ((b & 0x0F) << 12) | ((data[i + 1] & 63) << 6) | (data[i + 2] & 63);
        i += 3;
      } else {
        code = ((b & 0x07) << 18) | ((data[i + 1] & 63) << 12) | ((data[i + 2] & 63) << 6) | (data[i + 3] & 63);
        i += 4;
      }
      if (code >= 0x10000) {
        code -= 0x10000;
        out += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 1023));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }
}

/** 脚本化 TagTransport：按队列回放响应，记录 APDU。 */
export class ScriptedTagTransport implements TagTransport {
  sentApdus: number[][] = [];
  private responses: number[][] = [];
  closed: boolean = false;
  connected: boolean = false;

  queueResponse(response: number[]): void {
    this.responses.push(response);
  }

  connect(): Promise<void> {
    this.connected = true;
    return Promise.resolve();
  }

  transmit(apdu: number[]): Promise<number[]> {
    this.sentApdus.push(apdu);
    const resp = this.responses.shift();
    return Promise.resolve(resp !== undefined ? resp : [0x6F, 0x00]);
  }

  close(): Promise<void> {
    this.closed = true;
    return Promise.resolve();
  }

  isConnected(): boolean {
    return this.connected && !this.closed;
  }
}

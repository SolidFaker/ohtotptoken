import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticStage, DiagnosticResult,
  DiagnosticErrorDomain,
} from './CloudBackupDiagnostics';
import { CloudBackupRecord, CloudBackupMetadataStatus, CloudBackupIdentityStatus } from './CloudBackupCrypto';
import { CloudStageStat } from './CloudBackupStaging';
import { FsGateway, FileIoFsGateway, fileIoDiagnosticCode } from './StoragePorts';

export const CLOUD_PUBLICATION_JOURNAL = '.cloud-backup-publications';

export enum CloudPublicationState {
  CANDIDATE = 'CANDIDATE',
  PUBLISHED = 'PUBLISHED',
  REJECTED = 'REJECTED',
  VERIFIED = 'VERIFIED',
}

/** Installation-local evidence, never uploaded or passed to diagnostics. */
export interface CloudPublicationReceipt {
  id: string;
  version: number;
  scope: string;
  cloudRoot: string;
  fileName: string;
  source: string;
  state: CloudPublicationState;
}

export interface CloudBackupPublicationPort {
  load(): Promise<CloudPublicationReceipt[]>;
  save(receipt: CloudPublicationReceipt): Promise<string>;
  mark(id: string, state: CloudPublicationState): Promise<void>;
  forget(id: string): Promise<void>;
  inspect(path: string): Promise<CloudStageStat | undefined>;
}

function publicationRoot(path: string): boolean {
  return path.startsWith('/') && !path.includes('\\') && !/[\u0000-\u001f\u007f]/.test(path) &&
    path.split('/').slice(1).every((part: string): boolean => part.length > 0 && part !== '.' && part !== '..');
}

function publicationName(name: string): boolean {
  return /^otp_backup_-?\d+\.enc(?![\s\S])/.test(name) &&
    Number.isSafeInteger(Number(name.substring(11, name.length - 4)));
}

function validPublication(receipt: CloudPublicationReceipt): boolean {
  if (receipt === null || typeof receipt !== 'object' || receipt.version !== 1 ||
    typeof receipt.id !== 'string' || !/^publication-[A-Za-z0-9]{6}(?![\s\S])/.test(receipt.id) ||
    typeof receipt.scope !== 'string' || receipt.scope.length === 0 || receipt.scope.length > 1024 ||
    typeof receipt.cloudRoot !== 'string' || !publicationRoot(receipt.cloudRoot) ||
    typeof receipt.fileName !== 'string' || !publicationName(receipt.fileName) ||
    typeof receipt.source !== 'string' || !publicationRoot(receipt.source)) return false;
  const source = receipt.source.substring(receipt.cloudRoot.length + 1);
  return receipt.source === receipt.cloudRoot + '/' + source &&
    (/^\.cloud-backup-owned-[A-Za-z0-9]{6}\/content\.tmp(?![\s\S])/.test(source) ||
      /^\.otp_backup_pending_-?\d+\.tmp(?![\s\S])/.test(source)) &&
    (receipt.state === CloudPublicationState.CANDIDATE || receipt.state === CloudPublicationState.PUBLISHED ||
      receipt.state === CloudPublicationState.REJECTED || receipt.state === CloudPublicationState.VERIFIED);
}

function copyPublication(receipt: CloudPublicationReceipt, id: string = receipt.id,
  state: CloudPublicationState = receipt.state): CloudPublicationReceipt {
  return { id: id, version: 1, scope: receipt.scope, cloudRoot: receipt.cloudRoot,
    fileName: receipt.fileName, source: receipt.source, state: state };
}

/** The same filter is applied to port and production TaskPool history results. */
export function applyCloudPublicationIsolation(records: CloudBackupRecord[], isolated: string[]): void {
  for (const record of records) {
    if (!isolated.includes(record.id)) continue;
    record.metadataStatus = CloudBackupMetadataStatus.INVALID;
    record.tokenCountKnown = false;
    record.tokenCount = 0;
    record.deviceId = '';
    record.deviceName = '';
    record.identityStatus = CloudBackupIdentityStatus.ID_MISSING;
  }
}

/** All methods run under the existing cloud operation lease, before staging recovery. */
export class CloudBackupPublicationGuard {
  private readonly root: string;
  private readonly scope: string;
  private readonly port: CloudBackupPublicationPort;
  private receipts: CloudPublicationReceipt[] = [];
  private available: boolean = false;

  constructor(root: string, scope: string, port: CloudBackupPublicationPort) {
    if (!publicationRoot(root) || typeof scope !== 'string' || scope.length === 0 || scope.length > 1024) {
      throw new Error('INVALID_PUBLICATION_SCOPE');
    }
    this.root = root;
    this.scope = scope;
    this.port = port;
  }

  static async production(root: string, filesDir: string, account: string): Promise<CloudBackupPublicationGuard> {
    if (account.length === 0) throw new Error('PUBLICATION_ACCOUNT_UNAVAILABLE');
    const encoded = buffer.from(account, 'utf-8');
    const bytes = new Uint8Array(encoded.length);
    for (let index = 0; index < bytes.length; index++) bytes[index] = encoded.readUInt8(index);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest = await md.digest();
    let scope = '';
    for (const value of digest.data) scope += value.toString(16).padStart(2, '0');
    return new CloudBackupPublicationGuard(root, scope, new NativeCloudBackupPublicationPort(filesDir));
  }

  private fail(context: DiagnosticContext, error: Object): void {
    this.available = false;
    CloudBackupDiagnostics.fail(context, DiagnosticStage.PUBLICATION_GUARD,
      DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
  }

  /** Source presence proves a candidate never moved. Inspect BEFORE any stage cleanup. */
  async recover(context: DiagnosticContext): Promise<boolean> {
    this.available = false;
    try {
      const loaded = await this.port.load();
      const own: CloudPublicationReceipt[] = [];
      const targets = new Set<string>();
      for (const receipt of loaded) {
        if (!validPublication(receipt)) throw new Error('INVALID_PUBLICATION_RECEIPT');
        if (receipt.scope !== this.scope || receipt.cloudRoot !== this.root) continue;
        if (targets.has(receipt.fileName)) throw new Error('DUPLICATE_PUBLICATION_RECEIPT');
        targets.add(receipt.fileName);
        own.push(copyPublication(receipt));
      }
      this.receipts = own;
      for (const receipt of [...own]) {
        if (receipt.state === CloudPublicationState.CANDIDATE) {
          await this.cancelUnpublished(receipt.id, context);
        } else if (receipt.state === CloudPublicationState.VERIFIED) {
          await this.port.forget(receipt.id);
          this.receipts = this.receipts.filter((entry: CloudPublicationReceipt): boolean => entry.id !== receipt.id);
        }
      }
      this.available = true;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.PUBLICATION_GUARD, DiagnosticResult.OK);
      return true;
    } catch (error) {
      this.fail(context, error);
      return false;
    }
  }

  isAvailable(): boolean { return this.available; }
  hasIsolation(): boolean { return this.receipts.some((entry: CloudPublicationReceipt): boolean => entry.state !== CloudPublicationState.VERIFIED); }
  /** Ambiguous candidates remain per-file isolation, not a global unknown-I/O barrier. */
  hasRejectedCleanup(): boolean {
    return this.receipts.some((entry: CloudPublicationReceipt): boolean => entry.state === CloudPublicationState.REJECTED);
  }
  isolatedFileNames(): string[] {
    if (!this.available) throw new Error('PUBLICATION_GUARD_UNAVAILABLE');
    return this.receipts.filter((entry: CloudPublicationReceipt): boolean => entry.state !== CloudPublicationState.VERIFIED)
      .map((entry: CloudPublicationReceipt): string => entry.fileName);
  }
  rejected(): CloudPublicationReceipt[] {
    if (!this.available) throw new Error('PUBLICATION_GUARD_UNAVAILABLE');
    return this.receipts.filter((entry: CloudPublicationReceipt): boolean => entry.state === CloudPublicationState.REJECTED)
      .map((entry: CloudPublicationReceipt): CloudPublicationReceipt => copyPublication(entry));
  }

  async register(source: string, fileName: string, context: DiagnosticContext): Promise<string> {
    if (!this.available) throw new Error('PUBLICATION_GUARD_UNAVAILABLE');
    const receipt: CloudPublicationReceipt = { id: 'publication-000000', version: 1,
      scope: this.scope, cloudRoot: this.root, fileName: fileName, source: source, state: CloudPublicationState.CANDIDATE };
    try {
      if (!validPublication(receipt) || this.receipts.some((entry: CloudPublicationReceipt): boolean => entry.fileName === fileName)) {
        throw new Error('INVALID_PUBLICATION_CANDIDATE');
      }
      receipt.id = await this.port.save(receipt);
      if (!validPublication(receipt)) throw new Error('INVALID_PUBLICATION_RECEIPT');
      this.receipts.push(receipt);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.PUBLICATION_GUARD, DiagnosticResult.OK);
      return receipt.id;
    } catch (error) {
      this.fail(context, error);
      throw error as Error;
    }
  }

  /** Absence is ambiguous, never evidence granting deletion ownership. */
  async cancelUnpublished(id: string, context: DiagnosticContext): Promise<boolean> {
    const receipt = this.receipts.find((entry: CloudPublicationReceipt): boolean => entry.id === id);
    if (receipt === undefined || receipt.state !== CloudPublicationState.CANDIDATE) return false;
    try {
      const source = await this.port.inspect(receipt.source);
      if (source === undefined || source.symbolic || !source.regular) return false;
      await this.port.forget(id);
      this.receipts = this.receipts.filter((entry: CloudPublicationReceipt): boolean => entry.id !== id);
      return true;
    } catch (error) {
      this.fail(context, error);
      throw error as Error;
    }
  }

  private async transition(id: string, from: CloudPublicationState, to: CloudPublicationState,
    context: DiagnosticContext): Promise<void> {
    try {
      const receipt = this.receipts.find((entry: CloudPublicationReceipt): boolean => entry.id === id);
      if (!this.available || receipt === undefined || receipt.state !== from) throw new Error('INVALID_PUBLICATION_TRANSITION');
      // The old candidate remains durable if marking confirmed publication fails.
      await this.port.mark(id, to);
      receipt.state = to;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.PUBLICATION_GUARD, DiagnosticResult.OK);
    } catch (error) {
      this.fail(context, error);
      throw error as Error;
    }
  }
  published(id: string, context: DiagnosticContext): Promise<void> {
    return this.transition(id, CloudPublicationState.CANDIDATE, CloudPublicationState.PUBLISHED, context);
  }
  verified(id: string, context: DiagnosticContext): Promise<void> {
    return this.transition(id, CloudPublicationState.PUBLISHED, CloudPublicationState.VERIFIED, context);
  }
  reject(id: string, context: DiagnosticContext): Promise<void> {
    return this.transition(id, CloudPublicationState.PUBLISHED, CloudPublicationState.REJECTED, context);
  }

  /** Explicit user deletion, never automatic ownership inference. Call after unlink/ENOENT + accepted sync. */
  async acknowledgeExplicitDeletion(fileName: string, context: DiagnosticContext): Promise<void> {
    try {
      if (!this.available || !publicationName(fileName)) throw new Error('PUBLICATION_GUARD_UNAVAILABLE');
      const receipt = this.receipts.find((entry: CloudPublicationReceipt): boolean => entry.fileName === fileName);
      if (receipt === undefined) return;
      await this.port.forget(receipt.id);
      this.receipts = this.receipts.filter((entry: CloudPublicationReceipt): boolean => entry.id !== receipt.id);
    } catch (error) {
      this.fail(context, error);
      throw error as Error;
    }
  }

  /** Call only after trusted rejected-file unlink/ENOENT AND accepted deletion sync. */
  async acknowledgeRejected(id: string, context: DiagnosticContext): Promise<void> {
    try {
      if (!this.available || !this.receipts.some((entry: CloudPublicationReceipt): boolean =>
        entry.id === id && entry.state === CloudPublicationState.REJECTED)) throw new Error('INVALID_PUBLICATION_ACK');
      await this.port.forget(id);
      this.receipts = this.receipts.filter((entry: CloudPublicationReceipt): boolean => entry.id !== id);
    } catch (error) {
      this.fail(context, error);
      throw error as Error;
    }
  }
}

/** Explicit test-only journal: no native API, reusable backing evidence for restart tests. */
export class MemoryCloudBackupPublicationPort implements CloudBackupPublicationPort {
  readonly receipts: Map<string, CloudPublicationReceipt> = new Map();
  private readonly gateway: FsGateway;
  private sequence: number = 0;
  constructor(gateway: FsGateway) { this.gateway = gateway; }
  async load(): Promise<CloudPublicationReceipt[]> { return Array.from(this.receipts.values()).map((entry: CloudPublicationReceipt): CloudPublicationReceipt => copyPublication(entry)); }
  async save(receipt: CloudPublicationReceipt): Promise<string> {
    const id = 'publication-' + (++this.sequence).toString().padStart(6, '0');
    this.receipts.set(id, copyPublication(receipt, id));
    return id;
  }
  async mark(id: string, state: CloudPublicationState): Promise<void> {
    const receipt = this.receipts.get(id);
    if (receipt === undefined) throw new Error('MISSING_PUBLICATION_RECEIPT');
    this.receipts.set(id, copyPublication(receipt, id, state));
  }
  async forget(id: string): Promise<void> { this.receipts.delete(id); }
  async inspect(path: string): Promise<CloudStageStat | undefined> {
    try {
      const state = await this.gateway.stat(path);
      return { directory: state.isDirectory, regular: !state.isDirectory, symbolic: false };
    } catch (error) {
      if (fileIoDiagnosticCode(error) === 13900002) return undefined;
      throw error as Error;
    }
  }
}

/** Immutable candidate + append-only fsync/close markers; malformed evidence blocks all use. */
export class NativeCloudBackupPublicationPort implements CloudBackupPublicationPort {
  private readonly journal: string;
  private readonly gateway: FileIoFsGateway = new FileIoFsGateway();
  constructor(filesDir: string) {
    if (!publicationRoot(filesDir)) throw new Error('INVALID_PUBLICATION_JOURNAL_ROOT');
    this.journal = filesDir + '/' + CLOUD_PUBLICATION_JOURNAL;
  }
  async inspect(path: string): Promise<CloudStageStat | undefined> {
    try {
      const state = await fs.lstat(path);
      return { directory: state.isDirectory(), regular: state.isFile(), symbolic: state.isSymbolicLink() };
    } catch (error) {
      if (fileIoDiagnosticCode(error) === 13900002) return undefined;
      throw error as Error;
    }
  }
  private async ensureJournal(): Promise<void> {
    let state = await this.inspect(this.journal);
    if (state === undefined) { await fs.mkdir(this.journal); state = await this.inspect(this.journal); }
    if (state === undefined || state.symbolic || !state.directory) throw new Error('INVALID_PUBLICATION_JOURNAL');
  }
  private directory(id: string): string {
    if (!/^publication-[A-Za-z0-9]{6}(?![\s\S])/.test(id)) throw new Error('INVALID_PUBLICATION_RECEIPT');
    return this.journal + '/' + id;
  }
  private async read(path: string): Promise<string> {
    const state = await this.inspect(path);
    if (state === undefined || state.symbolic || !state.regular) throw new Error('INVALID_PUBLICATION_PROOF');
    const size = (await fs.stat(path)).size;
    if (!Number.isSafeInteger(size) || size <= 0 || size > 8192) throw new Error('INVALID_PUBLICATION_PROOF');
    return this.gateway.readTextFile(path);
  }
  private async write(path: string, text: string): Promise<void> {
    const encoded = buffer.from(text, 'utf-8');
    const bytes = new Uint8Array(encoded.length);
    for (let index = 0; index < bytes.length; index++) bytes[index] = encoded.readUInt8(index);
    const file = await fs.open(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const length = await fs.write(file.fd, bytes.buffer.slice(offset));
        if (!Number.isInteger(length) || length <= 0 || length > bytes.length - offset) throw new Error('INCOMPLETE_PUBLICATION_PROOF');
        offset += length;
      }
      await fs.fsync(file.fd);
    } finally { await fs.close(file); }
  }
  async load(): Promise<CloudPublicationReceipt[]> {
    await this.ensureJournal();
    const receipts: CloudPublicationReceipt[] = [];
    for (const id of await fs.listFile(this.journal)) {
      const directory = this.directory(id);
      const state = await this.inspect(directory);
      if (state === undefined || state.symbolic || !state.directory) throw new Error('INVALID_PUBLICATION_RECEIPT');
      let names = await fs.listFile(directory);
      const known = ['candidate.json', 'published.json', 'verified.json', 'rejected.json',
        'candidate.pending', 'published.pending', 'verified.pending', 'rejected.pending'];
      if (names.some((name: string): boolean => !known.includes(name))) throw new Error('INVALID_PUBLICATION_PROOF');
      for (const name of names) {
        const child = await this.inspect(directory + '/' + name);
        if (child === undefined || child.symbolic || !child.regular) throw new Error('INVALID_PUBLICATION_PROOF');
      }
      // No committed candidate means publication was never permitted. Clean LOCAL fragments only.
      if (!names.includes('candidate.json')) {
        if (names.some((name: string): boolean => name !== 'candidate.pending')) throw new Error('INVALID_PUBLICATION_PROOF');
        await this.forget(id);
        continue;
      }
      // Interrupted markers never confer verified/rejected status; retain the older isolation proof.
      for (const name of names) {
        if (name.endsWith('.pending')) await fs.unlink(directory + '/' + name);
      }
      names = names.filter((name: string): boolean => !name.endsWith('.pending'));
      const receipt = JSON.parse(await this.read(directory + '/candidate.json')) as CloudPublicationReceipt;
      if (!validPublication(receipt) || receipt.id !== id || receipt.state !== CloudPublicationState.CANDIDATE) {
        throw new Error('INVALID_PUBLICATION_RECEIPT');
      }
      const published = names.includes('published.json');
      const verified = names.includes('verified.json');
      const rejected = names.includes('rejected.json');
      if ((verified && rejected) || ((verified || rejected) && !published)) throw new Error('INVALID_PUBLICATION_PROOF');
      for (const marker of ['published', 'verified', 'rejected']) {
        if (names.includes(marker + '.json') && await this.read(directory + '/' + marker + '.json') !== marker) {
          throw new Error('INVALID_PUBLICATION_PROOF');
        }
      }
      receipt.state = verified ? CloudPublicationState.VERIFIED : rejected ? CloudPublicationState.REJECTED :
        published ? CloudPublicationState.PUBLISHED : CloudPublicationState.CANDIDATE;
      receipts.push(receipt);
    }
    return receipts;
  }
  async save(receipt: CloudPublicationReceipt): Promise<string> {
    if ((await this.load()).length >= 128) throw new Error('PUBLICATION_RECEIPT_LIMIT');
    const directory = await fs.mkdtemp(this.journal + '/publication-XXXXXX');
    const id = directory.substring(this.journal.length + 1);
    if (directory !== this.directory(id)) throw new Error('INVALID_PUBLICATION_RECEIPT');
    try {
      const candidate = copyPublication(receipt, id, CloudPublicationState.CANDIDATE);
      if (!validPublication(candidate)) throw new Error('INVALID_PUBLICATION_RECEIPT');
      await this.write(directory + '/candidate.pending', JSON.stringify(candidate));
      await fs.moveFile(directory + '/candidate.pending', directory + '/candidate.json', 1);
      return id;
    } catch (error) {
      // This newly allocated LOCAL entry has not granted permission to publish yet.
      try { await this.forget(id); } catch (_) {}
      throw error as Error;
    }
  }
  async mark(id: string, state: CloudPublicationState): Promise<void> {
    const receipt = (await this.load()).find((entry: CloudPublicationReceipt): boolean => entry.id === id);
    const valid = receipt !== undefined && ((receipt.state === CloudPublicationState.CANDIDATE && state === CloudPublicationState.PUBLISHED) ||
      (receipt.state === CloudPublicationState.PUBLISHED && (state === CloudPublicationState.VERIFIED || state === CloudPublicationState.REJECTED)));
    if (!valid) throw new Error('INVALID_PUBLICATION_TRANSITION');
    const marker = state === CloudPublicationState.PUBLISHED ? 'published' : state === CloudPublicationState.VERIFIED ? 'verified' : 'rejected';
    // Incomplete fsync/close must never masquerade as a committed proof on restart.
    const pending = this.directory(id) + '/' + marker + '.pending';
    await this.write(pending, marker);
    await fs.moveFile(pending, this.directory(id) + '/' + marker + '.json', 1);
  }
  async forget(id: string): Promise<void> {
    const directory = this.directory(id);
    const state = await this.inspect(directory);
    if (state === undefined) return;
    if (!state.directory || state.symbolic) throw new Error('INVALID_PUBLICATION_RECEIPT');
    for (const name of await fs.listFile(directory)) {
      if (!['candidate.json', 'published.json', 'verified.json', 'rejected.json',
        'candidate.pending', 'published.pending', 'verified.pending', 'rejected.pending'].includes(name)) throw new Error('INVALID_PUBLICATION_PROOF');
      const child = await this.inspect(directory + '/' + name);
      if (child === undefined || child.symbolic || !child.regular) throw new Error('INVALID_PUBLICATION_PROOF');
    }
    await fs.rmdir(directory);
  }
}

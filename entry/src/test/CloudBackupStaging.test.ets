import { beforeEach, describe, it, expect } from '@ohos/hypium';
import {
  CloudBackupStaging, CloudBackupStagingPort, CloudStageReceipt, CloudStageStat,
  CloudBackupDiagnostics, DiagnosticContext, DiagnosticKind
} from 'common';

const STAGING_ROOT: string = '/synthetic/cloud-root';
const STAGING_OTHER_ROOT: string = '/synthetic/other-root';
const STAGING_SCOPE: string = 'a'.repeat(64);
const STAGING_OTHER_SCOPE: string = 'b'.repeat(64);
const STAGING_CONTENT: string = 'SYNTHETIC_OPAQUE_CIPHERTEXT';
const STAGING_DIRECTORY: string = STAGING_ROOT + '/.cloud-backup-owned-T00001';
const STAGING_SOURCE: string = STAGING_DIRECTORY + '/content.tmp';
const INVALID_STAGING_ROOTS: string[] = ['', '/', 'relative/root', '//cloud', '/cloud/', '/cloud//nested',
  '/cloud/./nested', '/cloud/../nested', '/cloud/.', '/cloud/..', '/cloud\\nested', '/cloud/\u0000',
  '/cloud/\n', '/cloud/\r', '/cloud/\t', '/cloud/\u001f', '/cloud/\u007f'];

function stagingReceipt(id: string = 'receipt-R00001', stage: string = '.cloud-backup-owned-T00001',
  scope: string = STAGING_SCOPE, root: string = STAGING_ROOT, version: number = 1): CloudStageReceipt {
  return { id: id, version: version, scope: scope, cloudRoot: root, stage: stage };
}

function copyStagingReceipt(receipt: CloudStageReceipt): CloudStageReceipt {
  return stagingReceipt(receipt.id, receipt.stage, receipt.scope, receipt.cloudRoot, receipt.version);
}

function stagingContext(): DiagnosticContext {
  // No diagnostic session, native clock, account identifier, or UUID is needed by this suite.
  return new DiagnosticContext(0, DiagnosticKind.BACKUP, -1);
}

class StagingPortError extends Error {
  code: number;
  constructor(message: string, code: number = 13900005) {
    super(message);
    this.code = code;
  }
}

class StagingSignal {
  readonly promise: Promise<void>;
  private release: () => void = (): void => {};
  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => { this.release = resolve; });
  }
  resolve(): void { this.release(); }
}

/** In-memory lstat/filesystem and durable receipt snapshots; never touches real files or user data. */
class FakeCloudBackupStagingPort implements CloudBackupStagingPort {
  directories: Set<string> = new Set<string>();
  files: Map<string, string> = new Map<string, string>();
  links: Set<string> = new Set<string>();
  receipts: Map<string, CloudStageReceipt> = new Map<string, CloudStageReceipt>();
  events: string[] = [];
  prefixes: string[] = [];
  inspected: string[] = [];
  listed: string[] = [];
  writes: string[] = [];
  unlinked: string[] = [];
  removed: string[] = [];
  forgotten: string[] = [];
  writeContext: DiagnosticContext | undefined = undefined;
  syncContext: DiagnosticContext | undefined = undefined;
  moveCalls: number = 0;
  syncCalls: number = 0;
  failCreate: boolean = false;
  failSave: boolean = false;
  failLoad: boolean = false;
  failWrite: boolean = false;
  failForget: boolean = false;
  failSync: boolean = false;
  syncAccepted: boolean = true;
  unlinkErrorCode: number = 0;
  removeErrorCode: number = 0;
  createdDirectory: string | undefined = undefined;
  returnedReceiptId: string | undefined = undefined;
  childAfterUnlink: string | undefined = undefined;
  writeStarted: StagingSignal = new StagingSignal();
  blockedWrite: StagingSignal | undefined = undefined;
  private nextDirectory: number = 0;
  private nextReceipt: number = 0;

  constructor() {
    this.directories.add(STAGING_ROOT);
    this.directories.add(STAGING_OTHER_ROOT);
  }

  private children(path: string): string[] {
    const paths: Set<string> = new Set<string>();
    for (const directory of this.directories) { paths.add(directory); }
    for (const file of this.files.keys()) { paths.add(file); }
    for (const link of this.links) { paths.add(link); }
    const names: Set<string> = new Set<string>();
    const prefix = path + '/';
    for (const child of paths) {
      if (child.startsWith(prefix)) { names.add(child.substring(prefix.length).split('/')[0]); }
    }
    return Array.from(names);
  }

  async createDirectory(prefix: string): Promise<string> {
    this.events.push('create');
    this.prefixes.push(prefix);
    if (this.failCreate) { throw new StagingPortError('CREATE_FAILED'); }
    const suffix = 'T' + (++this.nextDirectory).toString().padStart(5, '0');
    const directory = this.createdDirectory === undefined ? prefix.replace('XXXXXX', suffix) : this.createdDirectory;
    this.directories.add(directory);
    return directory;
  }

  async inspect(path: string): Promise<CloudStageStat | undefined> {
    this.inspected.push(path);
    if (!this.directories.has(path) && !this.files.has(path) && !this.links.has(path)) { return undefined; }
    return { directory: this.directories.has(path), regular: this.files.has(path), symbolic: this.links.has(path) };
  }

  async list(path: string): Promise<string[]> {
    this.listed.push(path);
    if (!this.directories.has(path)) { throw new StagingPortError('MISSING_DIRECTORY', 13900002); }
    return this.children(path);
  }

  async save(receipt: CloudStageReceipt): Promise<string> {
    this.events.push('save');
    if (this.failSave) { throw new StagingPortError('SAVE_FAILED'); }
    const id = this.returnedReceiptId === undefined ?
      'receipt-R' + (++this.nextReceipt).toString().padStart(5, '0') : this.returnedReceiptId;
    const snapshot = copyStagingReceipt(receipt);
    snapshot.id = id;
    this.receipts.set(id, snapshot);
    return id;
  }

  async load(): Promise<CloudStageReceipt[]> {
    this.events.push('load');
    if (this.failLoad) { throw new StagingPortError('LOAD_FAILED'); }
    return Array.from(this.receipts.values()).map((receipt: CloudStageReceipt): CloudStageReceipt => copyStagingReceipt(receipt));
  }

  async forget(id: string): Promise<void> {
    this.events.push('forget');
    this.forgotten.push(id);
    if (this.failForget) { throw new StagingPortError('FORGET_FAILED'); }
    this.receipts.delete(id);
  }

  async write(path: string, content: string, context?: DiagnosticContext): Promise<void> {
    this.events.push('write');
    this.writes.push(path);
    this.writeContext = context;
    // Failure deliberately leaves partial data so production cleanup, not the fake, must remove it.
    this.files.set(path, this.failWrite ? 'SYNTHETIC_PARTIAL_CIPHERTEXT' : content);
    this.writeStarted.resolve();
    if (this.blockedWrite !== undefined) { await this.blockedWrite.promise; }
    if (this.failWrite) { throw new StagingPortError('WRITE_FAILED'); }
  }

  async move(source: string, destination: string): Promise<void> {
    this.events.push('move');
    this.moveCalls++;
    if (this.files.has(destination) || this.directories.has(destination) || this.links.has(destination)) {
      throw new StagingPortError('DESTINATION_EXISTS', 13900015);
    }
    const content = this.files.get(source);
    if (content === undefined) { throw new StagingPortError('MISSING_SOURCE', 13900002); }
    this.files.set(destination, content);
    this.files.delete(source);
  }

  async unlink(path: string): Promise<void> {
    this.events.push('unlink');
    this.unlinked.push(path);
    if (this.unlinkErrorCode === 13900002) { this.files.delete(path); }
    if (this.unlinkErrorCode !== 0) { throw new StagingPortError('UNLINK_FAILED', this.unlinkErrorCode); }
    this.files.delete(path);
    if (this.childAfterUnlink !== undefined) { this.files.set(this.childAfterUnlink, 'SYNTHETIC_FOREIGN_CONTENT'); }
  }

  async removeDirectory(path: string): Promise<void> {
    this.events.push('rmdir');
    this.removed.push(path);
    if (this.removeErrorCode === 13900002) { this.directories.delete(path); }
    if (this.removeErrorCode !== 0) { throw new StagingPortError('RMDIR_FAILED', this.removeErrorCode); }
    if (this.children(path).length !== 0) { throw new StagingPortError('DIRECTORY_NOT_EMPTY'); }
    this.directories.delete(path);
  }

  async sync(context?: DiagnosticContext): Promise<boolean> {
    this.events.push('sync');
    this.syncCalls++;
    this.syncContext = context;
    if (this.failSync) { throw new StagingPortError('SYNC_FAILED'); }
    return this.syncAccepted;
  }
}

async function expectStagingFailure(action: () => Promise<void>, message: string): Promise<void> {
  let actual = '';
  try { await action(); } catch (error) { actual = (error as Error).message; }
  expect(actual).assertEqual(message);
}

function expectNoStagingCleanup(port: FakeCloudBackupStagingPort): void {
  expect(port.unlinked.length).assertEqual(0);
  expect(port.removed.length).assertEqual(0);
  expect(port.forgotten.length).assertEqual(0);
  expect(port.syncCalls).assertEqual(0);
}

export default function cloudBackupStagingTest(): void {
  describe('cloudBackupStagingTest', () => {
    beforeEach(() => { CloudBackupDiagnostics.disable(); });

    it('staging_constructor_accepts_canonical_root_and_lowercase_64_hex_scope', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      expect(await staging.recover(stagingContext())).assertTrue();
      expect(await port.inspect(STAGING_SOURCE) === undefined).assertTrue();
      expect(port.listed.length).assertEqual(0);
      expectNoStagingCleanup(port);
    });

    it('staging_constructor_rejects_noncanonical_roots_without_port_access', 0, () => {
      for (const root of INVALID_STAGING_ROOTS) {
        const port = new FakeCloudBackupStagingPort();
        let failure = '';
        try { new CloudBackupStaging(root, STAGING_SCOPE, port); }
        catch (error) { failure = (error as Error).message; }
        expect(failure).assertEqual('INVALID_STAGING_SCOPE');
        expect(port.events.length).assertEqual(0);
      }
    });

    it('staging_constructor_rejects_invalid_scope_length_case_and_suffix', 0, () => {
      const scopes: string[] = ['', 'a'.repeat(63), 'a'.repeat(65), 'A'.repeat(64), 'g'.repeat(64),
        STAGING_SCOPE + '\n', STAGING_SCOPE + '\u0000', '../' + STAGING_SCOPE];
      for (const scope of scopes) {
        const port = new FakeCloudBackupStagingPort();
        let failure = '';
        try { new CloudBackupStaging(STAGING_ROOT, scope, port); }
        catch (error) { failure = (error as Error).message; }
        expect(failure).assertEqual('INVALID_STAGING_SCOPE');
        expect(port.events.length).assertEqual(0);
      }
    });

    it('staging_receipt_validation_rejects_versions_ids_scope_and_paths_before_io', 0, async () => {
      const invalid: CloudStageReceipt[] = [
        stagingReceipt('receipt-R00001', '.cloud-backup-owned-T00001', STAGING_SCOPE, STAGING_ROOT, 0),
        stagingReceipt('receipt-R00001', '.cloud-backup-owned-T00001', STAGING_SCOPE, STAGING_ROOT, 2)
      ];
      for (const id of ['', '../receipt-R00001', 'receipt-R0000', 'receipt-R000001', 'receipt-R00001\n', 'receipt-ABC_12']) {
        invalid.push(stagingReceipt(id));
      }
      for (const stage of ['', '.', '..', '../.cloud-backup-owned-T00001', '/.cloud-backup-owned-T00001',
        '.cloud-backup-owned-T00001/content.tmp', '.cloud-backup-owned-T00001\\content.tmp',
        '.cloud-backup-owned-T0000', '.cloud-backup-owned-T000001', '.cloud-backup-owned-T00001\n']) {
        invalid.push(stagingReceipt('receipt-R00001', stage));
      }
      for (const root of INVALID_STAGING_ROOTS) {
        invalid.push(stagingReceipt('receipt-R00001', '.cloud-backup-owned-T00001', STAGING_SCOPE, root));
      }
      for (const scope of ['', 'A'.repeat(64), 'f'.repeat(63), 'g'.repeat(64), STAGING_SCOPE + '\n']) {
        invalid.push(stagingReceipt('receipt-R00001', '.cloud-backup-owned-T00001', scope));
      }
      for (const receipt of invalid) {
        const port = new FakeCloudBackupStagingPort();
        port.receipts.set(receipt.id, receipt);
        port.directories.add(STAGING_DIRECTORY);
        port.files.set(STAGING_SOURCE, STAGING_CONTENT);
        expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(stagingContext())).assertFalse();
        expect(port.inspected.length).assertEqual(0);
        expect(port.listed.length).assertEqual(0);
        expect(port.files.get(STAGING_SOURCE)).assertEqual(STAGING_CONTENT);
        expect(port.receipts.size).assertEqual(1);
        expectNoStagingCleanup(port);
      }
    });

    it('staging_create_write_publish_discard_sync_ack_preserves_formal_file', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const source = await staging.create(STAGING_CONTENT, context);
      expect(source).assertEqual(STAGING_SOURCE);
      expect(port.prefixes[0]).assertEqual(STAGING_ROOT + '/.cloud-backup-owned-XXXXXX');
      expect(port.events.join(',')).assertEqual('load,create,save,write');
      expect(port.writeContext === context).assertTrue();
      const receipts = await port.load();
      expect(receipts.length).assertEqual(1);
      expect(receipts[0].id).assertEqual('receipt-R00001');
      expect(receipts[0].version).assertEqual(1);
      expect(receipts[0].scope).assertEqual(STAGING_SCOPE);
      expect(receipts[0].cloudRoot).assertEqual(STAGING_ROOT);
      expect(receipts[0].stage).assertEqual('.cloud-backup-owned-T00001');
      const destination = STAGING_ROOT + '/otp_backup_123.enc';
      await staging.publish(source, destination, context);
      expect(port.files.get(destination)).assertEqual(STAGING_CONTENT);
      expect(port.files.has(source)).assertFalse();
      expect(port.directories.has(STAGING_DIRECTORY)).assertTrue();
      expect(await staging.discard(source, context)).assertTrue();
      expect(port.directories.has(STAGING_DIRECTORY)).assertFalse();
      expect(port.unlinked.length).assertEqual(0);
      expect(port.receipts.size).assertEqual(1);
      expect(port.syncCalls).assertEqual(0);
      expect(port.forgotten.length).assertEqual(0);
      expect(await port.sync(context)).assertTrue();
      await staging.acknowledgeSync(context);
      expect(port.syncContext === context).assertTrue();
      expect(port.receipts.size).assertEqual(0);
      expect(port.forgotten.join(',')).assertEqual('receipt-R00001');
      expect(port.events.join(',')).assertEqual('load,create,save,write,load,move,rmdir,sync,forget');
      expect(await staging.discard(source, context)).assertFalse();
      await staging.acknowledgeSync(context);
      expect(port.forgotten.length).assertEqual(1);
      expect(port.files.get(destination)).assertEqual(STAGING_CONTENT);
    });

    it('staging_ack_does_not_forget_active_receipts_and_discard_requires_exact_source', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const source = await staging.create(STAGING_CONTENT, context);
      await staging.acknowledgeSync(context);
      expect(port.receipts.size).assertEqual(1);
      for (const unknown of [STAGING_DIRECTORY, source + '/..', STAGING_ROOT + '/otp_backup_1.enc']) {
        expect(await staging.discard(unknown, context)).assertFalse();
      }
      expectNoStagingCleanup(port);
      expect(await staging.discard(source, context)).assertTrue();
      expect(port.unlinked.join(',')).assertEqual(source);
      expect(port.removed.join(',')).assertEqual(STAGING_DIRECTORY);
      expect(port.receipts.size).assertEqual(1);
      expect(port.forgotten.length).assertEqual(0);
    });

    it('staging_restarted_instance_recovers_only_receipts_matching_both_scope_and_root', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, context);
      const foreignScope = stagingReceipt('receipt-R00002', '.cloud-backup-owned-T00002', STAGING_OTHER_SCOPE);
      const foreignRoot = stagingReceipt('receipt-R00003', '.cloud-backup-owned-T00003', STAGING_SCOPE, STAGING_OTHER_ROOT);
      for (const receipt of [foreignScope, foreignRoot]) {
        port.receipts.set(receipt.id, copyStagingReceipt(receipt));
        port.directories.add(receipt.cloudRoot + '/' + receipt.stage);
        port.files.set(receipt.cloudRoot + '/' + receipt.stage + '/content.tmp', 'SYNTHETIC_OTHER_OWNER');
      }
      const unowned = STAGING_ROOT + '/.cloud-backup-owned-UN0001';
      port.directories.add(unowned);
      const formal = STAGING_ROOT + '/otp_backup_7.enc';
      port.files.set(formal, 'SYNTHETIC_EXISTING_BACKUP');
      const restarted = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      expect(await restarted.recover(context)).assertTrue();
      expect(port.files.has(STAGING_SOURCE)).assertFalse();
      expect(port.directories.has(STAGING_DIRECTORY)).assertFalse();
      expect(port.directories.has(unowned)).assertTrue();
      expect(port.files.get(formal)).assertEqual('SYNTHETIC_EXISTING_BACKUP');
      expect(port.receipts.size).assertEqual(2);
      expect(port.forgotten.join(',')).assertEqual('receipt-R00001');
      expect(port.syncCalls).assertEqual(1);
      expect(port.listed.every((path: string): boolean => path === STAGING_DIRECTORY)).assertTrue();
      for (const receipt of [foreignScope, foreignRoot]) {
        const directory = receipt.cloudRoot + '/' + receipt.stage;
        expect(port.receipts.has(receipt.id)).assertTrue();
        expect(port.files.get(directory + '/content.tmp')).assertEqual('SYNTHETIC_OTHER_OWNER');
        expect(port.inspected.indexOf(directory)).assertEqual(-1);
      }
      expect(port.inspected.indexOf(unowned)).assertEqual(-1);
      expect(port.listed.indexOf(STAGING_ROOT)).assertEqual(-1);
    });

    it('staging_pre_receipt_crash_leaves_only_unowned_empty_directory', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      // Crash window before durable save: only mkdtemp has happened, never a ciphertext write.
      const empty = await port.createDirectory(STAGING_ROOT + '/.cloud-backup-owned-XXXXXX');
      expect(port.files.size).assertEqual(0);
      expect(port.receipts.size).assertEqual(0);
      expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(stagingContext())).assertTrue();
      expect(port.directories.has(empty)).assertTrue();
      expect(port.writes.length).assertEqual(0);
      expect(port.inspected.length).assertEqual(0);
      expect(port.listed.length).assertEqual(0);
      expectNoStagingCleanup(port);
    });

    it('staging_save_failure_never_writes_or_claims_the_unreceipted_empty_stage', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      port.failSave = true;
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      await expectStagingFailure(async (): Promise<void> => {
        await staging.create(STAGING_CONTENT, stagingContext());
      }, 'SAVE_FAILED');
      expect(port.events.join(',')).assertEqual('load,create,save');
      expect(port.files.size).assertEqual(0);
      expect(port.writes.length).assertEqual(0);
      expect(port.receipts.size).assertEqual(0);
      expect(port.directories.has(STAGING_DIRECTORY)).assertTrue();
      expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(stagingContext())).assertTrue();
      expect(port.directories.has(STAGING_DIRECTORY)).assertTrue();
      expectNoStagingCleanup(port);
    });

    it('staging_create_rejects_untrusted_directory_and_saved_receipt_id_before_write', 0, async () => {
      for (const directory of [STAGING_OTHER_ROOT + '/.cloud-backup-owned-T00001', STAGING_ROOT + '/..',
        STAGING_DIRECTORY + '/nested', STAGING_DIRECTORY + '\n', STAGING_ROOT + '/.cloud-backup-stage-T00001']) {
        const port = new FakeCloudBackupStagingPort();
        port.createdDirectory = directory;
        await expectStagingFailure(async (): Promise<void> => {
          await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, stagingContext());
        }, 'INVALID_STAGING_DIRECTORY');
        expect(port.events.join(',')).assertEqual('load,create');
        expect(port.writes.length).assertEqual(0);
        expect(port.receipts.size).assertEqual(0);
        expectNoStagingCleanup(port);
      }
      const port = new FakeCloudBackupStagingPort();
      port.returnedReceiptId = '../receipt-R00001';
      await expectStagingFailure(async (): Promise<void> => {
        await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, stagingContext());
      }, 'INVALID_STAGING_RECEIPT');
      expect(port.writes.length).assertEqual(0);
      expect(port.files.size).assertEqual(0);
      expectNoStagingCleanup(port);
    });

    it('staging_load_and_directory_creation_failures_do_not_reach_save_or_write', 0, async () => {
      for (let failure = 0; failure < 2; failure++) {
        const port = new FakeCloudBackupStagingPort();
        port.failLoad = failure === 0;
        port.failCreate = failure === 1;
        await expectStagingFailure(async (): Promise<void> => {
          await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, stagingContext());
        }, failure === 0 ? 'STAGING_RECOVERY_FAILED' : 'CREATE_FAILED');
        expect(port.events.indexOf('save')).assertEqual(-1);
        expect(port.writes.length).assertEqual(0);
        expect(port.prefixes.length).assertEqual(failure === 0 ? 0 : 1);
        expectNoStagingCleanup(port);
      }
    });

    it('staging_write_failure_cleans_partial_bytes_but_retains_receipt_until_sync', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      port.failWrite = true;
      await expectStagingFailure(async (): Promise<void> => {
        await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, stagingContext());
      }, 'WRITE_FAILED');
      expect(port.events.join(',')).assertEqual('load,create,save,write,unlink,rmdir');
      expect(port.files.has(STAGING_SOURCE)).assertFalse();
      expect(port.directories.has(STAGING_DIRECTORY)).assertFalse();
      expect(port.receipts.size).assertEqual(1);
      expect(port.syncCalls).assertEqual(0);
      expect(port.forgotten.length).assertEqual(0);
      expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(stagingContext())).assertTrue();
      expect(port.syncCalls).assertEqual(1);
      expect(port.receipts.size).assertEqual(0);
    });

    it('staging_failed_cleanup_preserves_write_error_and_receipt_for_restart_retry', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      port.failWrite = true;
      port.unlinkErrorCode = 13900012;
      await expectStagingFailure(async (): Promise<void> => {
        await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, stagingContext());
      }, 'WRITE_FAILED');
      expect(port.files.get(STAGING_SOURCE)).assertEqual('SYNTHETIC_PARTIAL_CIPHERTEXT');
      expect(port.directories.has(STAGING_DIRECTORY)).assertTrue();
      expect(port.receipts.size).assertEqual(1);
      expect(port.removed.length).assertEqual(0);
      expect(port.syncCalls).assertEqual(0);
      expect(port.forgotten.length).assertEqual(0);
      port.unlinkErrorCode = 0;
      expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(stagingContext())).assertTrue();
      expect(port.files.has(STAGING_SOURCE)).assertFalse();
      expect(port.receipts.size).assertEqual(0);
    });

    it('staging_rejected_or_thrown_sync_keeps_receipt_for_successful_restart_retry', 0, async () => {
      for (const throws of [false, true]) {
        const port = new FakeCloudBackupStagingPort();
        const context = stagingContext();
        const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
        const source = await staging.create(STAGING_CONTENT, context);
        expect(await staging.discard(source, context)).assertTrue();
        port.syncAccepted = false;
        port.failSync = throws;
        expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(context)).assertFalse();
        expect(port.receipts.size).assertEqual(1);
        expect(port.forgotten.length).assertEqual(0);
        expect(port.syncCalls).assertEqual(1);
        expect(port.files.has(source)).assertFalse();
        port.syncAccepted = true;
        port.failSync = false;
        const restarted = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
        expect(await restarted.recover(context)).assertTrue();
        expect(port.receipts.size).assertEqual(0);
        expect(port.syncCalls).assertEqual(2);
        expect(port.forgotten.join(',')).assertEqual('receipt-R00001');
        expect(await restarted.recover(context)).assertTrue();
        expect(port.syncCalls).assertEqual(2);
      }
    });

    it('staging_active_stage_is_not_reaped_while_write_is_pending_or_on_next_create', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const release = new StagingSignal();
      port.blockedWrite = release;
      const pending = staging.create(STAGING_CONTENT, context);
      await port.writeStarted.promise;
      try {
        expect(await staging.recover(context)).assertTrue();
        expect(port.files.get(STAGING_SOURCE)).assertEqual(STAGING_CONTENT);
        expect(port.receipts.size).assertEqual(1);
        expectNoStagingCleanup(port);
      } finally {
        release.resolve();
        await pending;
      }
      port.blockedWrite = undefined;
      const second = await staging.create('SYNTHETIC_SECOND_CIPHERTEXT', context);
      expect(second === STAGING_SOURCE).assertFalse();
      expect(await staging.recover(context)).assertTrue();
      expect(port.files.get(STAGING_SOURCE)).assertEqual(STAGING_CONTENT);
      expect(port.files.get(second)).assertEqual('SYNTHETIC_SECOND_CIPHERTEXT');
      expect(port.receipts.size).assertEqual(2);
      expectNoStagingCleanup(port);
    });

    it('staging_unknown_child_blocks_discard_recovery_and_new_create_without_deletion', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const source = await staging.create(STAGING_CONTENT, context);
      const foreign = STAGING_DIRECTORY + '/foreign.txt';
      port.files.set(foreign, 'SYNTHETIC_FOREIGN_CONTENT');
      expect(await staging.discard(source, context)).assertFalse();
      const restarted = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      expect(await restarted.recover(context)).assertFalse();
      await expectStagingFailure(async (): Promise<void> => {
        await restarted.create('SYNTHETIC_NEW_CONTENT', context);
      }, 'STAGING_RECOVERY_FAILED');
      expect(port.writes.length).assertEqual(1);
      expect(port.prefixes.length).assertEqual(1);
      expect(port.files.get(source)).assertEqual(STAGING_CONTENT);
      expect(port.files.get(foreign)).assertEqual('SYNTHETIC_FOREIGN_CONTENT');
      expect(port.receipts.size).assertEqual(1);
      expectNoStagingCleanup(port);
    });

    it('staging_symlinks_and_replaced_directory_or_content_types_fail_closed', 0, async () => {
      for (let changed = 0; changed < 4; changed++) {
        const port = new FakeCloudBackupStagingPort();
        const context = stagingContext();
        await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).create(STAGING_CONTENT, context);
        if (changed === 0) { port.links.add(STAGING_DIRECTORY); }
        if (changed === 1) {
          port.directories.delete(STAGING_DIRECTORY);
          port.files.set(STAGING_DIRECTORY, 'SYNTHETIC_REPLACEMENT');
        }
        if (changed === 2) { port.links.add(STAGING_SOURCE); }
        if (changed === 3) {
          port.files.delete(STAGING_SOURCE);
          port.directories.add(STAGING_SOURCE);
        }
        expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(context)).assertFalse();
        expect(port.receipts.size).assertEqual(1);
        expectNoStagingCleanup(port);
      }
    });

    it('staging_rechecks_empty_directory_after_unlink_before_removal', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const source = await staging.create(STAGING_CONTENT, context);
      const foreign = STAGING_DIRECTORY + '/late-foreign.txt';
      port.childAfterUnlink = foreign;
      expect(await staging.discard(source, context)).assertFalse();
      expect(port.files.has(source)).assertFalse();
      expect(port.files.get(foreign)).assertEqual('SYNTHETIC_FOREIGN_CONTENT');
      expect(port.directories.has(STAGING_DIRECTORY)).assertTrue();
      expect(port.removed.length).assertEqual(0);
      expect(port.receipts.size).assertEqual(1);
      expect(port.forgotten.length).assertEqual(0);
      expect(port.syncCalls).assertEqual(0);
    });

    it('staging_cleanup_tolerates_only_not_found_unlink_and_rmdir_errors', 0, async () => {
      for (const code of [13900002, 13900012]) {
        for (const atUnlink of [true, false]) {
          const port = new FakeCloudBackupStagingPort();
          const context = stagingContext();
          const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
          const source = await staging.create(STAGING_CONTENT, context);
          port.unlinkErrorCode = atUnlink ? code : 0;
          port.removeErrorCode = atUnlink ? 0 : code;
          expect(await staging.discard(source, context)).assertEqual(code === 13900002);
          expect(port.receipts.size).assertEqual(1);
          expect(port.forgotten.length).assertEqual(0);
          expect(port.syncCalls).assertEqual(0);
          if (code === 13900002) {
            expect(port.files.has(source)).assertFalse();
            expect(port.directories.has(STAGING_DIRECTORY)).assertFalse();
          } else {
            expect(port.directories.has(STAGING_DIRECTORY)).assertTrue();
          }
          port.unlinkErrorCode = 0;
          port.removeErrorCode = 0;
          expect(await new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port).recover(context)).assertTrue();
          expect(port.receipts.size).assertEqual(0);
        }
      }
    });

    it('staging_forget_failure_keeps_cleaned_receipt_retryable_without_second_cleanup', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const source = await staging.create(STAGING_CONTENT, context);
      expect(await staging.discard(source, context)).assertTrue();
      expect(await port.sync(context)).assertTrue();
      port.failForget = true;
      await staging.acknowledgeSync(context);
      expect(port.receipts.size).assertEqual(1);
      expect(port.forgotten.length).assertEqual(1);
      port.failForget = false;
      await staging.acknowledgeSync(context);
      expect(port.receipts.size).assertEqual(0);
      expect(port.forgotten.length).assertEqual(2);
      expect(port.unlinked.length).assertEqual(1);
      expect(port.removed.length).assertEqual(1);
      expect(port.syncCalls).assertEqual(1);
    });

    it('staging_publish_requires_active_source_and_canonical_safe_integer_formal_name', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const source = await staging.create(STAGING_CONTENT, context);
      const invalid: string[] = [STAGING_OTHER_ROOT + '/otp_backup_1.enc',
        STAGING_ROOT + '/nested/otp_backup_1.enc', STAGING_ROOT + '/../otp_backup_1.enc',
        STAGING_ROOT + '//otp_backup_1.enc', STAGING_ROOT + '/otp_backup_1.enc\n',
        STAGING_ROOT + '/otp_backup_1.enc/extra', STAGING_ROOT + '/otp_backup_1.5.enc',
        STAGING_ROOT + '/otp_backup_+1.enc', STAGING_ROOT + '/otp_backup_NaN.enc',
        STAGING_ROOT + '/otp_backup_9007199254740992.enc', STAGING_ROOT + '/not-backup.enc'];
      for (const destination of invalid) {
        await expectStagingFailure(async (): Promise<void> => {
          await staging.publish(source, destination, context);
        }, 'INVALID_STAGING_PUBLICATION');
      }
      await expectStagingFailure(async (): Promise<void> => {
        await staging.publish(source + '/..', STAGING_ROOT + '/otp_backup_1.enc', context);
      }, 'INVALID_STAGING_PUBLICATION');
      expect(port.moveCalls).assertEqual(0);
      expect(port.files.get(source)).assertEqual(STAGING_CONTENT);
      expect(await staging.discard(source, context)).assertTrue();
    });

    it('staging_publish_rejects_missing_symlink_or_nonregular_content_before_move', 0, async () => {
      for (let changed = 0; changed < 3; changed++) {
        const port = new FakeCloudBackupStagingPort();
        const context = stagingContext();
        const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
        const source = await staging.create(STAGING_CONTENT, context);
        if (changed === 0) { port.files.delete(source); }
        if (changed === 1) { port.links.add(source); }
        if (changed === 2) { port.files.delete(source); port.directories.add(source); }
        await expectStagingFailure(async (): Promise<void> => {
          await staging.publish(source, STAGING_ROOT + '/otp_backup_1.enc', context);
        }, 'INVALID_STAGING_CONTENT');
        expect(port.moveCalls).assertEqual(0);
        expect(port.receipts.size).assertEqual(1);
        expectNoStagingCleanup(port);
      }
    });

    it('staging_formal_collision_never_overwrites_and_failed_publication_remains_discardable', 0, async () => {
      const port = new FakeCloudBackupStagingPort();
      const context = stagingContext();
      const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
      const destination = STAGING_ROOT + '/otp_backup_42.enc';
      port.files.set(destination, 'SYNTHETIC_EXISTING_BACKUP');
      const source = await staging.create(STAGING_CONTENT, context);
      await expectStagingFailure(async (): Promise<void> => {
        await staging.publish(source, destination, context);
      }, 'DESTINATION_EXISTS');
      expect(port.files.get(destination)).assertEqual('SYNTHETIC_EXISTING_BACKUP');
      expect(port.files.get(source)).assertEqual(STAGING_CONTENT);
      expect(port.receipts.size).assertEqual(1);
      expect(await staging.discard(source, context)).assertTrue();
      expect(port.unlinked.join(',')).assertEqual(source);
      expect(port.receipts.size).assertEqual(1);
      expect(await port.sync(context)).assertTrue();
      await staging.acknowledgeSync(context);
      expect(port.receipts.size).assertEqual(0);
      expect(port.files.get(destination)).assertEqual('SYNTHETIC_EXISTING_BACKUP');
    });

    it('staging_publish_accepts_negative_and_safe_integer_boundary_formal_names', 0, async () => {
      for (const value of ['-1', '0', '-9007199254740991', '9007199254740991']) {
        const port = new FakeCloudBackupStagingPort();
        const context = stagingContext();
        const staging = new CloudBackupStaging(STAGING_ROOT, STAGING_SCOPE, port);
        const source = await staging.create(STAGING_CONTENT, context);
        const destination = STAGING_ROOT + '/otp_backup_' + value + '.enc';
        await staging.publish(source, destination, context);
        expect(port.files.get(destination)).assertEqual(STAGING_CONTENT);
        expect(port.moveCalls).assertEqual(1);
        expect(await staging.discard(source, context)).assertTrue();
        expect(port.files.get(destination)).assertEqual(STAGING_CONTENT);
      }
    });
  });
}

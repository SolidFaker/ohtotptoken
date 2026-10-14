import { describe, it, expect } from '@ohos/hypium';
import {
  FileIoFsGateway, FileIoWritePort, fileIoDiagnosticCode, CloudBackupDiagnosticRecorder,
  DiagnosticClock, DiagnosticSink, DiagnosticThread, DiagnosticErrorDomain, DiagnosticKind, DiagnosticStage
} from 'common';
import { utf8ToBytes } from '../main/ets/steam/SteamCrypto';

/** 只替换系统调用，生产的有效视图/短写/关闭/发布路径全部保留。 */
class FixtureWritePort implements FileIoWritePort {
  files: Map<string, number[]> = new Map();
  directories: Set<string> = new Set();
  descriptors: Map<number, string> = new Map();
  writes: number[][] = [];
  closes: number = 0;
  opens: number = 0;
  moves: number = 0;
  deleted: string[] = [];
  results: number[] = [];
  failOpen: boolean = false;
  failWrite: boolean = false;
  failClose: boolean = false;
  failMove: boolean = false;
  failCleanup: boolean = false;
  failDeleteCode: number = 0;
  nextFd: number = 1;
  nextDirectory: number = 1;

  encodeText(text: string): Uint8Array {
    const bytes = utf8ToBytes(text);
    const backing = new Uint8Array(bytes.length + 4);
    backing.fill(255);
    backing.set(bytes, 2);
    return backing.subarray(2, 2 + bytes.length);
  }

  openFile(path: string): number {
    this.opens++;
    if (this.failOpen) { throw new Error('synthetic open failure'); }
    const fd = this.nextFd++;
    this.files.set(path, []);
    this.descriptors.set(fd, path);
    return fd;
  }

  writeSync(fd: number, bytes: ArrayBuffer): number {
    const view = new Uint8Array(bytes);
    const snapshot: number[] = [];
    for (let i = 0; i < view.length; i++) { snapshot.push(view[i]); }
    this.writes.push(snapshot);
    if (this.failWrite) { throw new Error('synthetic write failure'); }
    const result = this.results.shift() ?? view.length;
    if (result > 0 && result <= view.length && Number.isInteger(result)) {
      const path = this.descriptors.get(fd) ?? '';
      const current = this.files.get(path) ?? [];
      for (let i = 0; i < result; i++) { current.push(view[i]); }
      this.files.set(path, current);
    }
    return result;
  }

  closeFile(fd: number): void {
    this.closes++;
    this.descriptors.delete(fd);
    if (this.failClose) { throw new Error('synthetic close failure'); }
  }

  async makeTempDir(prefix: string): Promise<string> {
    const path = prefix.replace('XXXXXX', `fixture${this.nextDirectory++}`);
    if (this.directories.has(path)) { throw new Error('synthetic collision'); }
    this.directories.add(path);
    return path;
  }

  async moveFileNoReplace(source: string, destination: string): Promise<void> {
    this.moves++;
    if (this.failMove || this.files.has(destination) || this.directories.has(destination)) {
      throw new Error('synthetic move rejected');
    }
    const bytes = this.files.get(source);
    if (bytes === undefined) { throw new Error('synthetic missing source'); }
    this.files.set(destination, bytes);
    this.files.delete(source);
  }

  async deleteFile(path: string): Promise<void> {
    this.deleted.push(path);
    if (this.failDeleteCode !== 0) { throw new FixtureDeleteError(this.failDeleteCode); }
    if (this.failCleanup) { throw new Error('synthetic cleanup failure'); }
    this.files.delete(path);
  }

  async removeDir(path: string): Promise<void> {
    if (this.failCleanup) { throw new Error('synthetic cleanup failure'); }
    this.directories.delete(path);
  }
}

function bytesEqual(actual: number[] | undefined, expected: number[]): boolean {
  if (actual === undefined || actual.length !== expected.length) { return false; }
  return actual.every((value: number, index: number): boolean => value === expected[index]);
}

class FileIoDiagnosticSink implements DiagnosticSink {
  lines: string[] = [];
  write(line: string): void { this.lines.push(line); }
}

class FileIoDiagnosticClock implements DiagnosticClock {
  now(): number { return 0; }
}

class FileIoDiagnosticThread implements DiagnosticThread {
  isMainThread(): boolean { return true; }
}

class FileIoSyntheticError extends Error {
  code: number = 13900020;
  constructor() { super('SYNTH_PRIVATE_PATH_AND_CONTENT'); }
}

/** 携带 SDK fs 错误码的合成删除失败（ENOENT 宽容与如实传播的分界用例）。 */
class FixtureDeleteError extends Error {
  code: number;
  constructor(code: number) {
    super('synthetic delete failure');
    this.code = code;
  }
}

class FileIoHostileError {
  codeReads: number = 0;
  unsafeReads: number = 0;
  get code(): number {
    this.codeReads++;
    throw new Error('SYNTH_CODE_GETTER_SECRET');
  }
  get message(): string { this.unsafeReads++; return 'SYNTH_MESSAGE_SECRET'; }
  toString(): string { this.unsafeReads++; return 'SYNTH_STRING_SECRET'; }
  toJSON(): string { this.unsafeReads++; return 'SYNTH_JSON_SECRET'; }
}

class FileIoStringCodeError {
  code: string = '13900020';
}

export default function fileIoFsGatewayTest(): void {
  describe('fileIoFsGatewayTest', () => {
    it('fs_diagnostics_preserve_only_whitelisted_numeric_code_without_private_error_text', 0, () => {
      const sink = new FileIoDiagnosticSink();
      const recorder = new CloudBackupDiagnosticRecorder(sink, new FileIoDiagnosticClock(), new FileIoDiagnosticThread());
      expect(recorder.enable()).assertTrue();
      const context = recorder.begin(DiagnosticKind.BACKUP);
      const error = new FileIoSyntheticError();
      for (const stage of [DiagnosticStage.FS_OPEN, DiagnosticStage.FS_WRITE, DiagnosticStage.FS_CLOSE]) {
        recorder.fail(context, stage, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
      }
      expect(sink.lines.length).assertEqual(3);
      for (const line of sink.lines) {
        expect(line.indexOf('code=13900020') >= 0).assertTrue();
        expect(line.indexOf('SYNTH_')).assertEqual(-1);
      }
      error.code = 987654321;
      recorder.fail(context, DiagnosticStage.FS_WRITE, DiagnosticErrorDomain.FS, fileIoDiagnosticCode(error));
      expect(sink.lines[sink.lines.length - 1].indexOf('987654321')).assertEqual(-1);
      expect(sink.lines[sink.lines.length - 1].indexOf('code=UNKNOWN') >= 0).assertTrue();
    });

    it('fs_code_adapter_guards_getters_and_never_coerces_string_codes', 0, () => {
      const hostile = new FileIoHostileError();
      expect(fileIoDiagnosticCode(hostile) === undefined).assertTrue();
      expect(hostile.codeReads).assertEqual(1);
      expect(hostile.unsafeReads).assertEqual(0);
      expect(fileIoDiagnosticCode(new FileIoStringCodeError()) === undefined).assertTrue();
      expect(fileIoDiagnosticCode(null) === undefined).assertTrue();
      expect(fileIoDiagnosticCode(undefined) === undefined).assertTrue();
      expect(fileIoDiagnosticCode('13900020') === undefined).assertTrue();
      const sink = new FileIoDiagnosticSink();
      const recorder = new CloudBackupDiagnosticRecorder(sink, new FileIoDiagnosticClock(), new FileIoDiagnosticThread());
      recorder.enable();
      recorder.fail(recorder.begin(DiagnosticKind.BACKUP), DiagnosticStage.FS_WRITE,
        DiagnosticErrorDomain.FS, fileIoDiagnosticCode(hostile));
      expect(sink.lines.join('').indexOf('SYNTH_')).assertEqual(-1);
      expect(hostile.unsafeReads).assertEqual(0);
    });

    it('binary_write_passes_exact_arraybuffer_view_without_neighbor_bytes', 0, async () => {
      const port = new FixtureWritePort();
      const gateway = new FileIoFsGateway(port);
      const bytes = new Uint8Array([99, 10, 20, 30, 88]);
      await gateway.writeBinaryFile('/fixture/data', bytes.subarray(1, 4));
      expect(bytesEqual(port.files.get('/fixture/data'), [10, 20, 30])).assertTrue();
      expect(bytesEqual(port.writes[0], [10, 20, 30])).assertTrue();
      expect(port.closes).assertEqual(1);
    });

    it('text_encoder_view_preserves_non_ascii_and_omits_backing_buffer_padding', 0, async () => {
      const port = new FixtureWritePort();
      const gateway = new FileIoFsGateway(port);
      await gateway.writeTextFile('/fixture/text', 'A中');
      expect(bytesEqual(port.files.get('/fixture/text'), [65, 228, 184, 173])).assertTrue();
    });

    it('short_writes_retry_only_unwritten_bytes_until_complete', 0, async () => {
      const port = new FixtureWritePort();
      port.results = [1, 2, 1];
      const gateway = new FileIoFsGateway(port);
      await gateway.writeBinaryFile('/fixture/short', new Uint8Array([10, 20, 30, 40]));
      expect(bytesEqual(port.files.get('/fixture/short'), [10, 20, 30, 40])).assertTrue();
      expect(bytesEqual(port.writes[1], [20, 30, 40])).assertTrue();
      expect(bytesEqual(port.writes[2], [40])).assertTrue();
      expect(port.closes).assertEqual(1);
    });

    it('zero_negative_fractional_nan_and_oversized_progress_fail_and_close', 0, async () => {
      for (const result of [0, -1, 0.5, NaN, Infinity, 9]) {
        const port = new FixtureWritePort();
        port.results = [result];
        const gateway = new FileIoFsGateway(port);
        let failed = false;
        try { await gateway.writeBinaryFile('/fixture/invalid', new Uint8Array([1, 2])); } catch (_) { failed = true; }
        expect(failed).assertTrue();
        expect(port.closes).assertEqual(1);
        expect(port.writes.length).assertEqual(1);
      }
    });

    it('short_write_then_zero_progress_leaves_partial_file_but_reports_failure', 0, async () => {
      const port = new FixtureWritePort();
      port.results = [1, 0];
      let failed = false;
      try { await new FileIoFsGateway(port).writeBinaryFile('/fixture/partial', new Uint8Array([1, 2])); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(bytesEqual(port.files.get('/fixture/partial'), [1])).assertTrue();
      expect(port.closes).assertEqual(1);
    });

    it('zero_length_write_still_creates_and_closes_without_native_write', 0, async () => {
      const port = new FixtureWritePort();
      await new FileIoFsGateway(port).writeBinaryFile('/fixture/empty', new Uint8Array(0));
      expect(bytesEqual(port.files.get('/fixture/empty'), [])).assertTrue();
      expect(port.writes.length).assertEqual(0);
      expect(port.closes).assertEqual(1);
    });

    it('native_write_failure_closes_after_creation_and_close_failure_is_not_success', 0, async () => {
      const writePort = new FixtureWritePort();
      writePort.failWrite = true;
      let failed = false;
      try { await new FileIoFsGateway(writePort).writeTextFile('/fixture/write-error', 'x'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(writePort.files.has('/fixture/write-error')).assertTrue();
      expect(writePort.closes).assertEqual(1);
      const closePort = new FixtureWritePort();
      closePort.failClose = true;
      failed = false;
      try { await new FileIoFsGateway(closePort).writeTextFile('/fixture/close-error', 'x'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(closePort.closes).assertEqual(1);
    });

    it('write_error_remains_primary_when_close_also_fails', 0, async () => {
      const port = new FixtureWritePort();
      port.failWrite = true;
      port.failClose = true;
      let message = '';
      try { await new FileIoFsGateway(port).writeTextFile('/fixture/both-fail', 'x'); }
      catch (error) { message = (error as Error).message; }
      expect(message).assertEqual('synthetic write failure');
      expect(port.closes).assertEqual(1);
    });

    it('open_failure_never_closes_unowned_descriptor', 0, async () => {
      const port = new FixtureWritePort();
      port.failOpen = true;
      let failed = false;
      try { await new FileIoFsGateway(port).writeTextFile('/fixture/open-error', 'x'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(port.closes).assertEqual(0);
    });

    it('large_view_is_written_in_bounded_chunks_without_offset_leakage', 0, async () => {
      const port = new FixtureWritePort();
      const bytes = new Uint8Array(70003);
      bytes.fill(7);
      bytes[0] = 99;
      bytes[70002] = 88;
      await new FileIoFsGateway(port).writeBinaryFile('/fixture/large', bytes.subarray(1, 70002));
      const result = port.files.get('/fixture/large') ?? [];
      expect(result.length).assertEqual(70001);
      expect(result.every((value: number): boolean => value === 7)).assertTrue();
      expect(port.writes.length).assertEqual(2);
    });

    it('new_file_stages_then_publishes_without_leaving_owned_directory', 0, async () => {
      const port = new FixtureWritePort();
      await new FileIoFsGateway(port).writeNewTextFile('/fixture/pending.tmp', 'abc');
      expect(bytesEqual(port.files.get('/fixture/pending.tmp'), [97, 98, 99])).assertTrue();
      expect(port.files.size).assertEqual(1);
      expect(port.directories.size).assertEqual(0);
      expect(port.closes).assertEqual(1);
    });

    it('new_file_collision_preserves_existing_target_and_only_removes_owned_stage', 0, async () => {
      const port = new FixtureWritePort();
      port.files.set('/fixture/pending.tmp', [7, 8]);
      let failed = false;
      try { await new FileIoFsGateway(port).writeNewTextFile('/fixture/pending.tmp', 'new'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(bytesEqual(port.files.get('/fixture/pending.tmp'), [7, 8])).assertTrue();
      expect(port.deleted.indexOf('/fixture/pending.tmp')).assertEqual(-1);
      expect(port.files.size).assertEqual(1);
      expect(port.directories.size).assertEqual(0);
    });

    it('new_write_and_close_failures_never_publish_partial_target', 0, async () => {
      for (const failWrite of [true, false]) {
        const port = new FixtureWritePort();
        port.failWrite = failWrite;
        port.failClose = !failWrite;
        let failed = false;
        try { await new FileIoFsGateway(port).writeNewTextFile('/fixture/pending.tmp', 'new'); }
        catch (_) { failed = true; }
        expect(failed).assertTrue();
        expect(port.files.has('/fixture/pending.tmp')).assertFalse();
        expect(port.files.size).assertEqual(0);
        expect(port.directories.size).assertEqual(0);
        expect(port.moves).assertEqual(0);
      }
    });

    it('publish_is_no_replace_and_does_not_delete_either_file_on_rejection', 0, async () => {
      const port = new FixtureWritePort();
      port.files.set('/fixture/pending.tmp', [1, 2]);
      port.files.set('/fixture/backup.enc', [8, 9]);
      const gateway = new FileIoFsGateway(port);
      let failed = false;
      try { await gateway.publishFile('/fixture/pending.tmp', '/fixture/backup.enc'); } catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(bytesEqual(port.files.get('/fixture/backup.enc'), [8, 9])).assertTrue();
      expect(bytesEqual(port.files.get('/fixture/pending.tmp'), [1, 2])).assertTrue();
      expect(port.deleted.length).assertEqual(0);
      await gateway.publishFile('/fixture/pending.tmp', '/fixture/new.enc');
      expect(bytesEqual(port.files.get('/fixture/new.enc'), [1, 2])).assertTrue();
      expect(port.files.has('/fixture/pending.tmp')).assertFalse();
    });

    it('publish_rejects_cross_directory_alias_and_same_path_without_native_move', 0, async () => {
      const port = new FixtureWritePort();
      const gateway = new FileIoFsGateway(port);
      for (const destination of ['/other/backup.enc', '/fixture/pending.tmp', '/fixture/../backup.enc',
        '/fixture//backup.enc', '/fixture/./backup.enc', 'relative/backup.enc']) {
        let failed = false;
        try { await gateway.publishFile('/fixture/pending.tmp', destination); } catch (_) { failed = true; }
        expect(failed).assertTrue();
      }
      expect(port.moves).assertEqual(0);
    });

    it('failed_publish_does_not_fall_back_to_copy_or_direct_write', 0, async () => {
      const port = new FixtureWritePort();
      port.files.set('/fixture/pending.tmp', [1]);
      port.failMove = true;
      let failed = false;
      try { await new FileIoFsGateway(port).publishFile('/fixture/pending.tmp', '/fixture/formal.enc'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(port.opens).assertEqual(0);
      expect(port.files.has('/fixture/formal.enc')).assertFalse();
      expect(port.files.has('/fixture/pending.tmp')).assertTrue();
    });

    it('staging_cleanup_failure_never_removes_target_or_changes_success', 0, async () => {
      const port = new FixtureWritePort();
      port.failCleanup = true;
      await new FileIoFsGateway(port).writeNewTextFile('/fixture/pending.tmp', 'x');
      expect(bytesEqual(port.files.get('/fixture/pending.tmp'), [120])).assertTrue();
      expect(port.directories.size).assertEqual(1);
      expect(port.deleted.length).assertEqual(0);
    });

    it('replace_unlinks_destination_first_then_moves_without_replace', 0, async () => {
      const port = new FixtureWritePort();
      port.files.set('/fixture/formal.zip', [1, 1]);
      port.files.set('/fixture/staged.zip', [7, 8, 9]);
      await new FileIoFsGateway(port).moveFileToReplace('/fixture/staged.zip', '/fixture/formal.zip');
      expect(port.deleted.length).assertEqual(1);
      expect(port.deleted[0]).assertEqual('/fixture/formal.zip');
      expect(port.moves).assertEqual(1);
      expect(bytesEqual(port.files.get('/fixture/formal.zip'), [7, 8, 9])).assertTrue();
      expect(port.files.has('/fixture/staged.zip')).assertFalse();
    });

    it('replace_tolerates_absent_destination_and_still_moves', 0, async () => {
      const port = new FixtureWritePort();
      port.failDeleteCode = 13900002;
      port.files.set('/fixture/staged.zip', [7, 8, 9]);
      await new FileIoFsGateway(port).moveFileToReplace('/fixture/staged.zip', '/fixture/formal.zip');
      expect(port.moves).assertEqual(1);
      expect(bytesEqual(port.files.get('/fixture/formal.zip'), [7, 8, 9])).assertTrue();
    });

    it('replace_unlink_failure_propagates_and_never_moves', 0, async () => {
      const port = new FixtureWritePort();
      port.failDeleteCode = 13900012;
      port.files.set('/fixture/staged.zip', [7, 8, 9]);
      let failed = false;
      try { await new FileIoFsGateway(port).moveFileToReplace('/fixture/staged.zip', '/fixture/formal.zip'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(port.moves).assertEqual(0);
      expect(port.files.has('/fixture/staged.zip')).assertTrue();
    });

    it('replace_move_failure_propagates_without_copy_fallback', 0, async () => {
      const port = new FixtureWritePort();
      port.failMove = true;
      port.files.set('/fixture/formal.zip', [1, 1]);
      port.files.set('/fixture/staged.zip', [7, 8, 9]);
      let failed = false;
      try { await new FileIoFsGateway(port).moveFileToReplace('/fixture/staged.zip', '/fixture/formal.zip'); }
      catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(port.opens).assertEqual(0);
      expect(port.deleted.length).assertEqual(1);
      expect(port.files.has('/fixture/staged.zip')).assertTrue();
    });
  });
}

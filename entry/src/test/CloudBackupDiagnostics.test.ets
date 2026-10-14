import { describe, it, expect } from '@ohos/hypium';
import {
  CloudBackupDiagnosticRecorder, DiagnosticSink, DiagnosticClock, DiagnosticThread,
  DiagnosticKind, DiagnosticStage, DiagnosticResult, DiagnosticReason, DiagnosticErrorDomain,
  DiagnosticMode, DiagnosticState, DiagnosticDetails, DiagnosticSummary, DiagnosticUiAction,
  normalizeDiagnosticCode, normalizeDiagnosticSummary, appendDiagnosticSummary, classifyDiagnosticError,
  HuaweiAccountManager, HuaweiAccountErrorCode, normalizeHuaweiAccountLoginError
} from 'common';

class FakeDiagnosticClock implements DiagnosticClock {
  value: number = 0;
  fail: boolean = false;
  now(): number {
    if (this.fail) { throw new Error('SYNTH_CLOCK_SECRET'); }
    return this.value;
  }
}
class FakeDiagnosticSink implements DiagnosticSink {
  lines: string[] = [];
  fail: boolean = false;
  write(line: string): void {
    if (this.fail) { throw new Error('SYNTH_SINK_SECRET'); }
    this.lines.push(line);
  }
}
class FakeDiagnosticThread implements DiagnosticThread {
  main: boolean = true;
  isMainThread(): boolean { return this.main; }
}
class DiagnosticFixture {
  clock: FakeDiagnosticClock = new FakeDiagnosticClock();
  sink: FakeDiagnosticSink = new FakeDiagnosticSink();
  thread: FakeDiagnosticThread = new FakeDiagnosticThread();
  recorder: CloudBackupDiagnosticRecorder = new CloudBackupDiagnosticRecorder(this.sink, this.clock, this.thread);
}
class HostileDiagnosticError {
  reads: number = 0;
  get code(): number { this.reads++; throw new Error('SYNTH_CODE_SECRET'); }
  get message(): string { this.reads++; return '/synthetic/private/path'; }
  get cause(): string { this.reads++; return 'SYNTH_NESTED_CREDENTIAL'; }
  toString(): string { this.reads++; return 'SYNTH_TOKEN_SECRET'; }
  toJSON(): string { this.reads++; return 'SYNTH_HEADER_CIPHERTEXT'; }
}
class HostileDiagnosticDetails implements DiagnosticDetails {
  get writeComplete(): boolean { throw new Error('SYNTH_DETAILS_SECRET'); }
}
class ExtraDiagnosticDetails implements DiagnosticDetails {
  reason: DiagnosticReason = DiagnosticReason.IO_ERROR;
  writeComplete: boolean = false;
  path: string = '/synthetic/private/token.otpb';
  deviceName: string = 'SYNTH_DEVICE_NAME';
  token: string = 'SYNTH_TOKEN_SECRET';
  header: string = 'SYNTH_HEADER_CIPHERTEXT';
  toJSON(): string { throw new Error('SYNTH_TOJSON_SECRET'); }
}

// 只推进 fake uptime，不使用 LocalUnit 的 Date.now()/systemDateTime stub。
export default function CloudBackupDiagnosticsTest() {
  describe('CloudBackupDiagnosticsTest', () => {
    it('default_mode_is_minimal_and_has_independent_rolling_limits', 0, () => {
      const test = new DiagnosticFixture();
      expect(test.recorder.isEnabled()).assertFalse();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      test.recorder.mark(context, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      expect(test.sink.lines.length).assertEqual(0);
      for (let index = 0; index < 100; index++) {
        test.recorder.mark(context, DiagnosticStage.WRITE_END, DiagnosticResult.FAIL,
          { reason: DiagnosticReason.IO_ERROR, writeComplete: false });
      }
      expect(test.sink.lines.length).assertEqual(1);
      expect(test.sink.lines[0]).assertEqual('v=1 kind=BACKUP stage=WRITE_END result=FAIL reason=IO_ERROR');
      test.clock.value = 60000;
      test.recorder.mark(context, DiagnosticStage.WRITE_END, DiagnosticResult.FAIL, { reason: DiagnosticReason.IO_ERROR });
      expect(test.sink.lines.length).assertEqual(2);
      test.recorder.enable();
      test.recorder.disable();
      test.recorder.mark(context, DiagnosticStage.WRITE_END, DiagnosticResult.FAIL, { reason: DiagnosticReason.IO_ERROR });
      expect(test.sink.lines.length).assertEqual(2);
      for (let index = 1; index < 100; index++) {
        test.clock.value = index * 60000;
        test.recorder.mark(context, DiagnosticStage.WRITE_END, DiagnosticResult.FAIL, { reason: DiagnosticReason.IO_ERROR });
      }
      expect(test.sink.lines.every((line: string) => line.indexOf('op=') < 0 && line.indexOf('elapsed=') < 0)).assertTrue();
    });

    it('generation_disable_reenable_and_exact_sleep_expiry_reject_old_detail', 0, () => {
      const test = new DiagnosticFixture();
      const disabled = test.recorder.begin(DiagnosticKind.BACKUP);
      expect(test.recorder.enable()).assertTrue();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      test.recorder.mark(context, DiagnosticStage.BACKUP_BEGIN, DiagnosticResult.BEGIN);
      test.clock.value = 599999;
      expect(test.recorder.remainingTimeMs()).assertEqual(1);
      test.clock.value = 600000;
      test.recorder.mark(context, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      expect(test.recorder.isEnabled()).assertFalse();
      expect(test.sink.lines.length).assertEqual(1);
      test.recorder.enable();
      test.recorder.mark(context, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      test.recorder.mark(disabled, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      test.recorder.mark(context, DiagnosticStage.BACKUP_END, DiagnosticResult.FAIL);
      expect(test.sink.lines.length).assertEqual(2);
      expect(test.sink.lines[1].indexOf('op=') < 0).assertTrue();
      const next = test.recorder.begin(DiagnosticKind.BACKUP);
      expect(next.op > context.op).assertTrue();
      test.recorder.disable();
      test.recorder.enable();
      test.recorder.mark(next, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      expect(test.sink.lines.length).assertEqual(2);
    });

    it('error_classifier_never_reads_error_accessors_or_converts_objects', 0, () => {
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const hostile = new HostileDiagnosticError();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      test.recorder.fail(context, DiagnosticStage.FS_WRITE, DiagnosticErrorDomain.FS, hostile);
      expect(hostile.reads).assertEqual(0);
      expect(test.sink.lines[0].indexOf('code=UNKNOWN') >= 0).assertTrue();
      expect(test.sink.lines[0].indexOf('SYNTH_') < 0).assertTrue();
      test.recorder.fail(context, DiagnosticStage.FS_OPEN, DiagnosticErrorDomain.FS,
        new Error('SYNTH_ODID SYNTH_UNION_ID SYNTH_TOKEN_SECRET /synthetic/private/path'));
      expect(test.sink.lines[1].indexOf('SYNTH_') < 0).assertTrue();
      expect(test.sink.lines[1].indexOf('/synthetic') < 0).assertTrue();
    });

    it('details_are_rebuilt_and_stage_whitelisted_without_toJSON', 0, () => {
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      test.recorder.mark(context, DiagnosticStage.FS_WRITE, DiagnosticResult.FAIL, new ExtraDiagnosticDetails());
      const line = test.sink.lines[0];
      expect(line.indexOf('writeComplete=false') >= 0).assertTrue();
      expect(line.indexOf('SYNTH_') < 0 && line.indexOf('/synthetic') < 0).assertTrue();
      const safe = normalizeDiagnosticSummary(DiagnosticStage.DEVICE_INFO, DiagnosticResult.OK,
        { writeComplete: true, identityAvailable: true, mode: DiagnosticMode.STRING });
      expect(safe.details.writeComplete === undefined).assertTrue();
      expect(safe.details.mode === undefined).assertTrue();
      expect(safe.details.identityAvailable).assertTrue();
      test.recorder.mark(context, DiagnosticStage.FS_WRITE, DiagnosticResult.FAIL, new HostileDiagnosticDetails());
      expect(test.sink.lines.every((value: string) => value.indexOf('SYNTH_') < 0)).assertTrue();
    });

    it('error_codes_require_verified_domain_stage_and_numeric_type', 0, () => {
      expect(normalizeDiagnosticCode(DiagnosticStage.FS_WRITE, DiagnosticErrorDomain.FS, 13900020)).assertEqual(13900020);
      expect(normalizeDiagnosticCode(DiagnosticStage.FS_WRITE, DiagnosticErrorDomain.FS, '13900020')).assertEqual('UNKNOWN');
      expect(normalizeDiagnosticCode(DiagnosticStage.FS_WRITE, DiagnosticErrorDomain.CACHE, 13900020)).assertEqual('UNKNOWN');
      for (const code of [13900004, 13900005, 13900008, 13900025, 13900041]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.FS_CLOSE, DiagnosticErrorDomain.FS, code)).assertEqual(code);
      }
      expect(normalizeDiagnosticCode(DiagnosticStage.FS_CLOSE, DiagnosticErrorDomain.FS, 13900012)).assertEqual('UNKNOWN');
      expect(normalizeDiagnosticCode(DiagnosticStage.FS_CLOSE, DiagnosticErrorDomain.FS, 13900042)).assertEqual('UNKNOWN');
      expect(normalizeDiagnosticCode(DiagnosticStage.FS_STAGE_MOVE, DiagnosticErrorDomain.FS, 13900015)).assertEqual(13900015);
      expect(normalizeDiagnosticCode(DiagnosticStage.PUBLISH_END, DiagnosticErrorDomain.FS, 13900015)).assertEqual(13900015);
      for (const code of [13900001, 13900002, 13900008, 13900011, 13900012, 13900013, 13900015,
        13900018, 13900020, 13900025, 13900028, 13900030, 13900033, 13900041]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.FS_STAGE, DiagnosticErrorDomain.FS, code)).assertEqual(code);
      }
      expect(normalizeDiagnosticCode(DiagnosticStage.READ_END, DiagnosticErrorDomain.FS, 13900012)).assertEqual(13900012);
      expect(normalizeDiagnosticCode(DiagnosticStage.UNLINK_END, DiagnosticErrorDomain.FS, 13900002)).assertEqual(13900002);
      expect(normalizeDiagnosticCode(DiagnosticStage.HISTORY_END, DiagnosticErrorDomain.FS, 13900002)).assertEqual(13900002);
      for (const code of [401, 13600001, 22400001, 22400002, 22400003]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.SYNC_START, DiagnosticErrorDomain.SYNC, code)).assertEqual(code);
      }
      for (const code of [401, 13600001, 13900002, 14000002]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.CACHE_STOP, DiagnosticErrorDomain.CACHE, code)).assertEqual(code);
      }
      for (const code of [1, 2, 3, 4, 5]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.CACHE_PROGRESS, DiagnosticErrorDomain.CACHE, code)).assertEqual(code);
      }
      expect(normalizeDiagnosticCode(DiagnosticStage.CACHE_PROGRESS, DiagnosticErrorDomain.CACHE, 6)).assertEqual('UNKNOWN');
      for (const code of [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.SYNC_STATE, DiagnosticErrorDomain.SYNC, code)).assertEqual(code);
      }
      expect(normalizeDiagnosticCode(DiagnosticStage.SYNC_STATE, DiagnosticErrorDomain.SYNC, 9)).assertEqual('UNKNOWN');
      expect(normalizeDiagnosticCode(DiagnosticStage.ENCRYPT_END, DiagnosticErrorDomain.CRYPTO, 999999)).assertEqual('UNKNOWN');
    });

    it('new_stage_domains_and_icon_boolean_fields_are_closed', 0, () => {
      for (const stage of [DiagnosticStage.FS_PREPARE, DiagnosticStage.FS_STAGE, DiagnosticStage.FS_STAGE_MOVE,
        DiagnosticStage.TEMP_CLEANUP]) {
        const safe = normalizeDiagnosticSummary(stage, DiagnosticResult.FAIL,
          { errorDomain: DiagnosticErrorDomain.FS, code: 13900012 });
        expect(safe.stage).assertEqual(stage);
        expect(safe.details.errorDomain).assertEqual(DiagnosticErrorDomain.FS);
        expect(safe.details.code).assertEqual(13900012);
      }
      for (const stage of [DiagnosticStage.ACCOUNT_STATE, DiagnosticStage.ACCOUNT_AUTHORIZE, DiagnosticStage.ACCOUNT_INIT,
        DiagnosticStage.TIME_PARSE, DiagnosticStage.FS_ENCODE, DiagnosticStage.RESTORE_BEGIN]) {
        const safe = normalizeDiagnosticSummary(stage, DiagnosticResult.FAIL,
          { errorDomain: DiagnosticErrorDomain.APP, code: 1001502012, reason: DiagnosticReason.NOT_READY });
        expect(safe.stage).assertEqual(stage);
        expect(safe.details.errorDomain).assertEqual(DiagnosticErrorDomain.APP);
        expect(safe.details.code).assertEqual('UNKNOWN');
        expect(normalizeDiagnosticSummary(stage, DiagnosticResult.FAIL,
          { errorDomain: DiagnosticErrorDomain.FS }).details.errorDomain).assertEqual(DiagnosticErrorDomain.UNKNOWN);
      }
      for (const stage of [DiagnosticStage.RESTORE_DECRYPT, DiagnosticStage.RESTORE_VALIDATE]) {
        expect(normalizeDiagnosticSummary(stage, DiagnosticResult.FAIL,
          { errorDomain: DiagnosticErrorDomain.CRYPTO }).details.errorDomain).assertEqual(DiagnosticErrorDomain.CRYPTO);
      }
      expect(normalizeDiagnosticSummary(DiagnosticStage.ICON_CLEAR, DiagnosticResult.FAIL,
        { headerParsed: false }).details.headerParsed).assertFalse();
      expect(normalizeDiagnosticSummary(DiagnosticStage.ICON_IO, DiagnosticResult.BLOCKED,
        { drained: false }).details.drained).assertFalse();
    });

    it('publication_guard_and_ui_actions_keep_closed_fields', 0, () => {
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      for (const stage of [DiagnosticStage.PUBLICATION_GUARD, DiagnosticStage.PUBLICATION_CLEANUP]) {
        const safe = normalizeDiagnosticSummary(stage, DiagnosticResult.FAIL,
          { reason: DiagnosticReason.IO_ERROR, errorDomain: DiagnosticErrorDomain.FS, code: 13900012,
            drained: false, partialFailure: true, uiAction: DiagnosticUiAction.FEEDBACK });
        expect(safe.details.code).assertEqual(13900012);
        expect(safe.details.drained).assertFalse();
        expect(safe.details.uiAction === undefined).assertTrue();
        test.recorder.mark(context, stage, DiagnosticResult.FAIL, safe.details);
      }
      const ui = normalizeDiagnosticSummary(DiagnosticStage.UI_RESULT, DiagnosticResult.FAIL,
        { uiAction: DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP, reason: DiagnosticReason.SYNC_REJECTED,
          syncStartAccepted: false, partialFailure: true });
      expect(ui.details.uiAction).assertEqual(DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP);
      expect(ui.details.syncStartAccepted).assertFalse();
      expect(ui.details.partialFailure).assertTrue();
      const invalid = normalizeDiagnosticSummary(DiagnosticStage.UI_ACTION, DiagnosticResult.FAIL,
        { uiAction: 'SYNTH_PRIVATE_ROUTE' as DiagnosticUiAction });
      expect(invalid.details.uiAction).assertEqual(DiagnosticUiAction.UNKNOWN);
      test.recorder.mark(context, DiagnosticStage.UI_ACTION, DiagnosticResult.FAIL, invalid.details);
      expect(test.sink.lines.every((line: string) => line.indexOf('SYNTH_') < 0)).assertTrue();
    });

    it('sync_zero_is_none_but_other_domains_and_stages_reject_zero', 0, () => {
      expect(classifyDiagnosticError(DiagnosticStage.SYNC_STATE, DiagnosticErrorDomain.SYNC, 0).reason)
        .assertEqual(DiagnosticReason.NONE);
      expect(normalizeDiagnosticSummary(DiagnosticStage.SYNC_STATE, DiagnosticResult.OK,
        { errorDomain: DiagnosticErrorDomain.SYNC, code: 0, reason: DiagnosticReason.UNAVAILABLE }).details.reason)
        .assertEqual(DiagnosticReason.NONE);
      for (const domain of [DiagnosticErrorDomain.APP, DiagnosticErrorDomain.FS, DiagnosticErrorDomain.CACHE,
        DiagnosticErrorDomain.CRYPTO, DiagnosticErrorDomain.UNKNOWN]) {
        expect(normalizeDiagnosticCode(DiagnosticStage.SYNC_STATE, domain, 0)).assertEqual('UNKNOWN');
      }
      expect(normalizeDiagnosticCode(DiagnosticStage.SYNC_START, DiagnosticErrorDomain.SYNC, 0)).assertEqual('UNKNOWN');
      expect(classifyDiagnosticError(DiagnosticStage.FS_CLOSE, DiagnosticErrorDomain.FS, 13900041).reason)
        .assertEqual(DiagnosticReason.NO_SPACE);
    });

    it('account_error_wrapper_preserves_only_business_codes_and_fixed_message', 0, () => {
      for (const code of [HuaweiAccountErrorCode.ERROR_CODE_USER_CANCEL, HuaweiAccountErrorCode.ERROR_CODE_REQUEST_REFUSE,
        HuaweiAccountErrorCode.ERROR_CODE_LOGIN_OUT, HuaweiAccountErrorCode.ERROR_CODE_NETWORK_ERROR,
        HuaweiAccountErrorCode.ERROR_CODE_INTERNAL_ERROR, HuaweiAccountErrorCode.ERROR_CODE_SYSTEM_SERVICE]) {
        const safe = normalizeHuaweiAccountLoginError(code);
        expect(safe.code).assertEqual(code);
        expect(safe.message).assertEqual('Huawei account authorization failed');
      }
      expect(HuaweiAccountManager.isUserCancel(normalizeHuaweiAccountLoginError(1001502012).code)).assertTrue();
      expect(HuaweiAccountManager.getLoginErrorResource(normalizeHuaweiAccountLoginError(1001500002).code) === null)
        .assertTrue();
      expect(normalizeHuaweiAccountLoginError(987654321).code).assertEqual(0);
      expect(normalizeHuaweiAccountLoginError(undefined).code).assertEqual(0);
      expect(normalizeHuaweiAccountLoginError(Number.NaN).code).assertEqual(0);
    });

    it('clock_sink_and_thread_failures_do_not_escape', 0, () => {
      const test = new DiagnosticFixture();
      test.thread.main = false;
      expect(test.recorder.enable()).assertFalse();
      const background = test.recorder.begin(DiagnosticKind.HISTORY);
      expect(background.op).assertEqual(0);
      test.recorder.fail(background, DiagnosticStage.HISTORY_END, DiagnosticErrorDomain.APP, null);
      expect(test.sink.lines.length).assertEqual(0);
      test.thread.main = true;
      test.recorder.enable();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      test.sink.fail = true;
      test.recorder.mark(context, DiagnosticStage.BACKUP_BEGIN, DiagnosticResult.BEGIN);
      test.sink.fail = false;
      test.clock.value = 1000;
      expect(test.recorder.isEnabled()).assertTrue();
      test.clock.value = 999;
      test.recorder.mark(context, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      expect(test.recorder.isEnabled()).assertFalse();
      test.clock.fail = true;
      expect(test.recorder.enable()).assertFalse();
      expect(test.sink.lines.length).assertEqual(0);
    });

    it('bounded_contexts_release_and_elapsed_buckets_do_not_expose_exact_time', 0, () => {
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const context = test.recorder.begin(DiagnosticKind.BACKUP);
      for (let index = 0; index < 15; index++) { test.recorder.begin(DiagnosticKind.BACKUP); }
      expect(test.recorder.begin(DiagnosticKind.BACKUP).op).assertEqual(0);
      test.clock.value = 100;
      test.recorder.mark(context, DiagnosticStage.BACKUP_BEGIN, DiagnosticResult.BEGIN);
      expect(test.sink.lines[0].indexOf('elapsed=LT_1S') >= 0).assertTrue();
      test.clock.value = 1000;
      test.recorder.mark(context, DiagnosticStage.ENCRYPT_END, DiagnosticResult.OK);
      expect(test.sink.lines[1].indexOf('elapsed=LT_10S') >= 0).assertTrue();
      test.clock.value = 60000;
      test.recorder.mark(context, DiagnosticStage.BACKUP_END, DiagnosticResult.OK);
      expect(test.sink.lines[2].indexOf('elapsed=GE_60S') >= 0).assertTrue();
      test.recorder.end(context);
      expect(test.recorder.begin(DiagnosticKind.BACKUP).op > 0).assertTrue();
    });

    it('progress_and_batch_failures_are_representative_not_per_item', 0, () => {
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const cache = test.recorder.begin(DiagnosticKind.CACHE);
      for (let index = 0; index < 1000; index++) {
        test.recorder.mark(cache, DiagnosticStage.CACHE_PROGRESS, DiagnosticResult.PENDING,
          { uriMatches: false, state: index % 2 === 0 ? DiagnosticState.RUNNING : DiagnosticState.IDLE });
      }
      expect(test.sink.lines.length).assertEqual(1);
      const history = test.recorder.begin(DiagnosticKind.HISTORY);
      for (let index = 0; index < 100; index++) {
        test.recorder.mark(history, DiagnosticStage.READ_END, DiagnosticResult.OK, { contentNonEmpty: true });
      }
      expect(test.sink.lines.length).assertEqual(1);
      for (const reason of [DiagnosticReason.IO_ERROR, DiagnosticReason.TIMEOUT, DiagnosticReason.INVALID_FORMAT]) {
        test.recorder.mark(history, DiagnosticStage.READ_END, DiagnosticResult.FAIL, { reason: reason });
      }
      expect(test.sink.lines.length).assertEqual(3);
      expect(test.sink.lines[1].indexOf('item=1') >= 0).assertTrue();
      expect(test.sink.lines[2].indexOf('item=2') >= 0).assertTrue();
    });

    it('operation_and_session_limits_reserve_a_truncation_event', 0, () => {
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const stages: DiagnosticStage[] = [DiagnosticStage.BACKUP_BEGIN, DiagnosticStage.ENCRYPT_END,
        DiagnosticStage.FS_OPEN, DiagnosticStage.FS_WRITE, DiagnosticStage.FS_CLOSE, DiagnosticStage.FS_VERIFY,
        DiagnosticStage.WRITE_END, DiagnosticStage.PUBLISH_END, DiagnosticStage.BACKUP_END];
      const reasons: DiagnosticReason[] = [DiagnosticReason.UNKNOWN, DiagnosticReason.IO_ERROR,
        DiagnosticReason.INVALID_ARGUMENT, DiagnosticReason.EMPTY_CONTENT, DiagnosticReason.SHORT_WRITE];
      for (let index = 0; index < 8; index++) {
        const context = test.recorder.begin(DiagnosticKind.BACKUP);
        for (const stage of stages) {
          for (const reason of reasons) {
            test.recorder.mark(context, stage, DiagnosticResult.FAIL, { reason: reason });
          }
        }
        test.recorder.finish(context);
        expect(test.sink.lines.length).assertEqual((index + 1) * 32);
      }
      expect(test.sink.lines.length).assertEqual(256);
      expect(test.sink.lines[255].indexOf('truncated=true') >= 0).assertTrue();
    });

    it('taskpool_summaries_remain_bounded_and_replay_checks_generation', 0, () => {
      const summaries: DiagnosticSummary[] = [];
      appendDiagnosticSummary(summaries, DiagnosticStage.READ_END, DiagnosticResult.OK);
      expect(summaries.length).assertEqual(0);
      for (const reason of [DiagnosticReason.IO_ERROR, DiagnosticReason.TIMEOUT, DiagnosticReason.INVALID_FORMAT]) {
        appendDiagnosticSummary(summaries, DiagnosticStage.READ_END, DiagnosticResult.FAIL, { reason: reason });
      }
      expect(summaries.length).assertEqual(2);
      expect(summaries[1].details.truncated).assertTrue();
      const test = new DiagnosticFixture();
      test.recorder.enable();
      const context = test.recorder.begin(DiagnosticKind.HISTORY);
      test.recorder.disable(); test.recorder.enable();
      test.recorder.replay(context, summaries);
      expect(test.sink.lines.length).assertEqual(2);
      expect(test.sink.lines.every((line: string) => line.indexOf('op=') < 0 && line.indexOf('item=') < 0)).assertTrue();
    });
  });
}

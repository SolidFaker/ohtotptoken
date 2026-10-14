import { describe, it, expect } from '@ohos/hypium';
import { CloudBackupDiagnostics, IconPackZipGateReject } from 'common';
import { IconPackImportDiag } from '../main/ets/utils/IconPackImportDiag';

/**
 * IconPackImportDiag 的 LocalUnit 覆盖（该文件此前不在 LocalUnit 分母内）。
 *
 * 边界说明：helper 经 CloudBackupDiagnostics 门面输出，LocalUnit 无法观察 hilog 行内容，
 * 原因映射/白名单数值码的正确性由 scripts/icon-pack-import-guard.test.mjs 以真实
 * HilogDiagnosticSink 捕获断言（10/10）。本套件锁定 LocalUnit 可观察的安全契约：
 * - 禁读 .message/.stack/.cause/toString/toJSON（哨兵计数器为零）；
 * - .code 只经 guardedCode 受保护读取一次；getter 抛错被吞、如实 UNKNOWN；
 * - 门控枚举全量扫描、cleanup/rematch/成功/end 生命周期均不向调用方抛错
 *   （诊断永不影响导入业务路径）。
 * 门面在 LocalUnit 是否可 enable 不影响上述契约（禁用时 mark 走摘要路径，同样无输出）。
 */

class CodedImportError {
  code: number;
  constructor(code: number) {
    this.code = code;
  }
}

class CodelessImportError {
  hasNoCode: boolean = true;
}

/** code 受保护读取一次且返回白名单数值；禁止成员一旦被触碰即计违规。 */
class CountingHostileError {
  codeReads: number = 0;
  forbiddenReads: number = 0;
  get code(): number {
    this.codeReads++;
    return 13900005;
  }
  get message(): string {
    this.forbiddenReads++;
    return 'SYNTH_PICKER_PRIVATE_PATH';
  }
  get stack(): string {
    this.forbiddenReads++;
    return 'SYNTH_STACK_TEXT';
  }
  get cause(): string {
    this.forbiddenReads++;
    return 'SYNTH_NESTED_SECRET';
  }
  toString(): string {
    this.forbiddenReads++;
    return 'SYNTH_SERIALIZED_SECRET';
  }
  toJSON(): string {
    this.forbiddenReads++;
    return 'SYNTH_JSON_SECRET';
  }
}

class ThrowingCodeError {
  get code(): number {
    throw new Error('SYNTH_CODE_GETTER_REFUSED');
  }
  get message(): string {
    return 'SYNTH_MESSAGE_TEXT';
  }
}

const GATE_REASONS: IconPackZipGateReject[] = [
  IconPackZipGateReject.UNKNOWN, IconPackZipGateReject.NOT_ZIP_OR_DAMAGED,
  IconPackZipGateReject.TOO_LARGE_TOTAL, IconPackZipGateReject.MISSING_PACK_META,
  IconPackZipGateReject.INVALID_PACK_META, IconPackZipGateReject.DUPLICATE_NAME_VERSION,
  IconPackZipGateReject.ENTRY_OVERFLOW, IconPackZipGateReject.FILE_TOO_LARGE,
  IconPackZipGateReject.UNSAFE_ENTRY_PATH, IconPackZipGateReject.IO_ERROR,
];

function newDiag(): IconPackImportDiag {
  return IconPackImportDiag.begin();
}

export default function IconPackImportDiagTest() {
  describe('IconPackImportDiagTest', () => {
    it('failed_fixed_whitelisted_code_completes_without_throw', 0, () => {
      CloudBackupDiagnostics.enable();
      const diag = newDiag();
      let completed = false;
      diag.failed(new CodedImportError(13900005));
      diag.failed(new CodedImportError(13900012));
      diag.failed(new CodedImportError(13900002));
      diag.failed(new CodelessImportError());
      diag.failed(undefined);
      diag.failed(null);
      completed = true;
      diag.end();
      expect(completed).assertTrue();
    });

    it('hostile_error_reads_code_once_and_never_forbidden_members', 0, () => {
      const diag = newDiag();
      const hostile = new CountingHostileError();
      diag.failed(hostile);
      expect(hostile.codeReads).assertEqual(1);
      expect(hostile.forbiddenReads).assertEqual(0);
      const cleanupHostile = new CountingHostileError();
      diag.cleanupFailed(cleanupHostile);
      expect(cleanupHostile.codeReads).assertEqual(1);
      expect(cleanupHostile.forbiddenReads).assertEqual(0);
      const rematchHostile = new CountingHostileError();
      diag.rematchFailed(rematchHostile);
      expect(rematchHostile.codeReads).assertEqual(1);
      expect(rematchHostile.forbiddenReads).assertEqual(0);
      diag.end();
    });

    it('throwing_code_getter_is_swallowed_as_unknown_without_escape', 0, () => {
      const diag = newDiag();
      let completed = false;
      diag.failed(new ThrowingCodeError());
      diag.cleanupFailed(new ThrowingCodeError());
      diag.rematchFailed(new ThrowingCodeError());
      completed = true;
      diag.end();
      expect(completed).assertTrue();
    });

    it('gate_reason_enum_sweep_completes_without_throw', 0, () => {
      const diag = newDiag();
      for (const reason of GATE_REASONS) {
        diag.gateRejected(reason);
      }
      diag.end();
      expect(GATE_REASONS.length).assertEqual(10);
    });

    it('cleanup_and_rematch_semantics_run_after_gate_rejection_like_production_order', 0, () => {
      const diag = newDiag();
      diag.gateRejected(IconPackZipGateReject.UNSAFE_ENTRY_PATH);
      diag.cleanupFailed(new CodedImportError(13900005));
      diag.gateRejected(IconPackZipGateReject.MISSING_PACK_META);
      diag.rematchFailed(new CodedImportError(13900012));
      diag.end();
      expect(true).assertTrue();
    });

    it('success_end_and_repeated_end_do_not_throw_or_block_next_cycle', 0, () => {
      const diag = newDiag();
      diag.succeeded();
      diag.end();
      diag.end();
      const next = newDiag();
      next.succeeded();
      next.failed(new CodedImportError(13900005));
      next.end();
      // 门面剩余时间语义在 LocalUnit 可能不可用（返回 0），只要求非负且不抛。
      expect(CloudBackupDiagnostics.remainingTimeMs() >= 0).assertTrue();
    });
  });
}

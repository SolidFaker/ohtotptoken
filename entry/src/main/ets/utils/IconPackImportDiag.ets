import { BusinessError } from '@kit.BasicServicesKit';
import {
  CloudBackupDiagnostics, DiagnosticArtifact, DiagnosticContext, DiagnosticErrorDomain,
  DiagnosticKind, DiagnosticReason, DiagnosticResult, DiagnosticStage, IconPackZipGateReject
} from 'common';

/**
 * 图标包导入/清理/重匹配诊断 helper：输出只经 common CloudBackupDiagnostics 门面，
 * 输入只有白名单数字码或固定枚举；本文件不读取、不落任何原始异常文本（.message/.stack/.cause
 * 与 JSON 序列化均不出现），未知码如实记 UNKNOWN，不用占位值伪装。
 */

/** 门控固定枚举 → 诊断固定原因（白名单映射）。 */
function importReasonOf(reason: IconPackZipGateReject): DiagnosticReason {
  switch (reason) {
    case IconPackZipGateReject.NOT_ZIP_OR_DAMAGED:
    case IconPackZipGateReject.MISSING_PACK_META:
    case IconPackZipGateReject.INVALID_PACK_META:
    case IconPackZipGateReject.UNSAFE_ENTRY_PATH:
      return DiagnosticReason.INVALID_FORMAT;
    case IconPackZipGateReject.IO_ERROR:
      return DiagnosticReason.IO_ERROR;
    case IconPackZipGateReject.TOO_LARGE_TOTAL:
    case IconPackZipGateReject.FILE_TOO_LARGE:
    case IconPackZipGateReject.ENTRY_OVERFLOW:
    case IconPackZipGateReject.DUPLICATE_NAME_VERSION:
    default:
      return DiagnosticReason.INVALID_ARGUMENT;
  }
}

/** 白名单数字码提取：只读 .code 并以 typeof 收窄；getter 异常或非数字按未知处理。 */
function guardedCode(error: Object | undefined | null): number | undefined {
  if (error === undefined || error === null) {
    return undefined;
  }
  try {
    const candidate = (error as BusinessError).code;
    return typeof candidate === 'number' ? candidate : undefined;
  } catch (_) {
    return undefined;
  }
}

/**
 * 导入链路诊断生命周期：begin → succeeded / gateRejected|failed|cleanupFailed|rematchFailed → end。
 * 三类失败用固定 DiagnosticReason 区分：门控拒绝按枚举映射、清理失败固定 PARTIAL_FAILURE、
 * 重匹配失败固定 IO_ERROR。
 */
export class IconPackImportDiag {
  private readonly context: DiagnosticContext;

  private constructor(context: DiagnosticContext) {
    this.context = context;
  }

  static begin(): IconPackImportDiag {
    return new IconPackImportDiag(CloudBackupDiagnostics.begin(DiagnosticKind.ICON));
  }

  /** 门控拒绝：固定枚举映射固定原因，不携带路径或文本。 */
  gateRejected(reason: IconPackZipGateReject): void {
    CloudBackupDiagnostics.mark(this.context, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
      { artifact: DiagnosticArtifact.ICON, reason: importReasonOf(reason) });
  }

  /** 普通失败：只输出白名单数字码；未知码如实 UNKNOWN。 */
  failed(error: Object | undefined | null): void {
    CloudBackupDiagnostics.fail(this.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.FS, guardedCode(error));
  }

  /** 清理失败：数字码 + 固定 PARTIAL_FAILURE 标记，解压残留可见且可归因。 */
  cleanupFailed(error: Object | undefined | null): void {
    CloudBackupDiagnostics.fail(this.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.FS, guardedCode(error));
    CloudBackupDiagnostics.mark(this.context, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
      { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.PARTIAL_FAILURE });
  }

  /** 重匹配失败：固定 IO_ERROR 原因，与导入失败区分。 */
  rematchFailed(error: Object | undefined | null): void {
    CloudBackupDiagnostics.fail(this.context, DiagnosticStage.ICON_IO, DiagnosticErrorDomain.FS, guardedCode(error));
    CloudBackupDiagnostics.mark(this.context, DiagnosticStage.ICON_IO, DiagnosticResult.FAIL,
      { artifact: DiagnosticArtifact.ICON, reason: DiagnosticReason.IO_ERROR });
  }

  succeeded(): void {
    CloudBackupDiagnostics.mark(this.context, DiagnosticStage.ICON_IO, DiagnosticResult.OK,
      { artifact: DiagnosticArtifact.ICON });
  }

  end(): void {
    CloudBackupDiagnostics.end(this.context);
  }
}

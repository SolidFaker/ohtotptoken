import { process } from '@kit.ArkTS';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 独立的技术诊断通道。不要传入业务对象、文件标识或任意文本；不要在 TaskPool 中调用 facade。
export enum DiagnosticKind {
  UNKNOWN = 'UNKNOWN', BACKUP = 'BACKUP', HISTORY = 'HISTORY', RESTORE = 'RESTORE',
  DELETE = 'DELETE', CLEAR = 'CLEAR', CACHE = 'CACHE', SYNC = 'SYNC', ICON = 'ICON',
  DEVICE_INFO = 'DEVICE_INFO', CRYPTO = 'CRYPTO', UI = 'UI'
}
export enum DiagnosticStage {
  UNKNOWN = 'UNKNOWN', DEVICE_INFO = 'DEVICE_INFO', BACKUP_BEGIN = 'BACKUP_BEGIN',
  ENCRYPT_END = 'ENCRYPT_END', WRITE_END = 'WRITE_END', PUBLISH_END = 'PUBLISH_END', BACKUP_END = 'BACKUP_END',
  POST_PUBLISH_VERIFY = 'POST_PUBLISH_VERIFY',
  PUBLICATION_GUARD = 'PUBLICATION_GUARD', PUBLICATION_CLEANUP = 'PUBLICATION_CLEANUP',
  FS_OPEN = 'FS_OPEN', FS_WRITE = 'FS_WRITE', FS_CLOSE = 'FS_CLOSE', FS_VERIFY = 'FS_VERIFY',
  HISTORY_BEGIN = 'HISTORY_BEGIN', CACHE_ADMIT = 'CACHE_ADMIT', CACHE_START = 'CACHE_START',
  CACHE_PROGRESS = 'CACHE_PROGRESS', CACHE_END = 'CACHE_END', CACHE_STOP = 'CACHE_STOP', CACHE_DRAIN = 'CACHE_DRAIN',
  READ_END = 'READ_END', HEADER_PARSE = 'HEADER_PARSE', HISTORY_END = 'HISTORY_END',
  CLEAR_BEGIN = 'CLEAR_BEGIN', DELETE_GUARD = 'DELETE_GUARD', UNLINK_BEGIN = 'UNLINK_BEGIN',
  UNLINK_END = 'UNLINK_END', DELETE_END = 'DELETE_END', CLEAR_END = 'CLEAR_END',
  ICON_IO = 'ICON_IO', ICON_CLEAR = 'ICON_CLEAR', SYNC_START = 'SYNC_START', SYNC_STATE = 'SYNC_STATE',
  CRYPTO_RESULT = 'CRYPTO_RESULT', HEADER_VALIDATE = 'HEADER_VALIDATE', UI_ACTION = 'UI_ACTION',
  UI_RESULT = 'UI_RESULT', UI_REFRESH = 'UI_REFRESH', RESTORE_END = 'RESTORE_END',
  FS_PREPARE = 'FS_PREPARE', FS_STAGE = 'FS_STAGE', FS_ENCODE = 'FS_ENCODE', FS_STAGE_MOVE = 'FS_STAGE_MOVE',
  TEMP_CLEANUP = 'TEMP_CLEANUP', RESTORE_BEGIN = 'RESTORE_BEGIN', RESTORE_DECRYPT = 'RESTORE_DECRYPT',
  RESTORE_VALIDATE = 'RESTORE_VALIDATE', ACCOUNT_STATE = 'ACCOUNT_STATE', ACCOUNT_AUTHORIZE = 'ACCOUNT_AUTHORIZE',
  ACCOUNT_INIT = 'ACCOUNT_INIT', TIME_PARSE = 'TIME_PARSE'
}
export enum DiagnosticResult {
  UNKNOWN = 'UNKNOWN', BEGIN = 'BEGIN', OK = 'OK', FAIL = 'FAIL', BLOCKED = 'BLOCKED',
  CANCELLED = 'CANCELLED', PENDING = 'PENDING'
}
export enum DiagnosticReason {
  UNKNOWN = 'UNKNOWN', NONE = 'NONE', IO_ERROR = 'IO_ERROR', INVALID_ARGUMENT = 'INVALID_ARGUMENT',
  NOT_FOUND = 'NOT_FOUND', NO_SPACE = 'NO_SPACE', TIMEOUT = 'TIMEOUT', CANCELLED = 'CANCELLED',
  INFLIGHT_UNCONFIRMED = 'INFLIGHT_UNCONFIRMED', BUSY = 'BUSY', INVALID_FORMAT = 'INVALID_FORMAT',
  EMPTY_CONTENT = 'EMPTY_CONTENT', IDENTITY_UNAVAILABLE = 'IDENTITY_UNAVAILABLE', NAME_UNAVAILABLE = 'NAME_UNAVAILABLE',
  URI_MISMATCH = 'URI_MISMATCH', SHORT_WRITE = 'SHORT_WRITE', SYNC_REJECTED = 'SYNC_REJECTED',
  PARTIAL_FAILURE = 'PARTIAL_FAILURE', UNAVAILABLE = 'UNAVAILABLE', TRUNCATED = 'TRUNCATED',
  DECRYPT_FAILED = 'DECRYPT_FAILED', NOT_READY = 'NOT_READY', NOT_SIGNED_IN = 'NOT_SIGNED_IN', ENCODING_FAILED = 'ENCODING_FAILED',
  MISMATCH = 'MISMATCH'
}
export enum DiagnosticErrorDomain {
  UNKNOWN = 'UNKNOWN', FS = 'FS', CACHE = 'CACHE', SYNC = 'SYNC', CRYPTO = 'CRYPTO', APP = 'APP'
}
export enum DiagnosticLocation { UNKNOWN = 'UNKNOWN', LOCAL = 'LOCAL', CLOUD = 'CLOUD', BOTH = 'BOTH' }
export enum DiagnosticState {
  UNKNOWN = 'UNKNOWN', IDLE = 'IDLE', RUNNING = 'RUNNING', COMPLETED = 'COMPLETED', FAILED = 'FAILED', STOPPED = 'STOPPED'
}
export enum DiagnosticMode {
  UNKNOWN = 'UNKNOWN', LEGACY = 'LEGACY', ENCRYPTED = 'ENCRYPTED', STRING = 'STRING',
  ARRAY_BUFFER = 'ARRAY_BUFFER', TYPED_ARRAY = 'TYPED_ARRAY'
}
export enum DiagnosticScope { UNKNOWN = 'UNKNOWN', ALL = 'ALL', DEVICE = 'DEVICE', SAME_NAME = 'SAME_NAME', SINGLE = 'SINGLE' }
export enum DiagnosticArtifact { UNKNOWN = 'UNKNOWN', TOKEN = 'TOKEN', ICON = 'ICON' }
export enum DiagnosticSource { UNKNOWN = 'UNKNOWN', INITIAL = 'INITIAL', CACHED = 'CACHED', RETRY = 'RETRY', FALLBACK = 'FALLBACK' }
export enum DiagnosticUiAction { UNKNOWN = 'UNKNOWN', FEEDBACK = 'FEEDBACK', UNKNOWN_SOURCE_CLEANUP = 'UNKNOWN_SOURCE_CLEANUP' }
export enum DiagnosticElapsed {
  LT_100MS = 'LT_100MS', LT_1S = 'LT_1S', LT_10S = 'LT_10S', LT_60S = 'LT_60S', GE_60S = 'GE_60S', UNAVAILABLE = 'UNAVAILABLE'
}

export interface DiagnosticDetails {
  reason?: DiagnosticReason;
  errorDomain?: DiagnosticErrorDomain;
  code?: number | string;
  item?: number;
  location?: DiagnosticLocation;
  state?: DiagnosticState;
  mode?: DiagnosticMode;
  scope?: DiagnosticScope;
  artifact?: DiagnosticArtifact;
  source?: DiagnosticSource;
  uiAction?: DiagnosticUiAction;
  identityAvailable?: boolean;
  nameAvailable?: boolean;
  uriMatches?: boolean;
  contentNonEmpty?: boolean;
  writeComplete?: boolean;
  headerParsed?: boolean;
  unlinkAttempted?: boolean;
  alreadyAbsent?: boolean;
  syncStartAccepted?: boolean;
  partialFailure?: boolean;
  drained?: boolean;
  truncated?: boolean;
}
export interface DiagnosticSummary {
  stage: DiagnosticStage;
  result: DiagnosticResult;
  details: DiagnosticDetails;
}
export interface DiagnosticSink { write(line: string): void; }
export interface DiagnosticClock { now(): number; }
export interface DiagnosticThread { isMainThread(): boolean; }

export class DiagnosticContext {
  readonly op: number;
  readonly kind: DiagnosticKind;
  readonly generation: number;
  constructor(op: number, kind: DiagnosticKind, generation: number) {
    this.op = op;
    this.kind = kind;
    this.generation = generation;
  }
}

const KINDS: DiagnosticKind[] = [DiagnosticKind.UNKNOWN, DiagnosticKind.BACKUP, DiagnosticKind.HISTORY,
  DiagnosticKind.RESTORE, DiagnosticKind.DELETE, DiagnosticKind.CLEAR, DiagnosticKind.CACHE, DiagnosticKind.SYNC,
  DiagnosticKind.ICON, DiagnosticKind.DEVICE_INFO, DiagnosticKind.CRYPTO, DiagnosticKind.UI];
const STAGES: DiagnosticStage[] = [DiagnosticStage.UNKNOWN, DiagnosticStage.DEVICE_INFO, DiagnosticStage.BACKUP_BEGIN,
  DiagnosticStage.ENCRYPT_END, DiagnosticStage.WRITE_END, DiagnosticStage.PUBLISH_END, DiagnosticStage.BACKUP_END,
  DiagnosticStage.POST_PUBLISH_VERIFY, DiagnosticStage.PUBLICATION_GUARD, DiagnosticStage.PUBLICATION_CLEANUP,
  DiagnosticStage.FS_OPEN, DiagnosticStage.FS_WRITE, DiagnosticStage.FS_CLOSE, DiagnosticStage.FS_VERIFY,
  DiagnosticStage.HISTORY_BEGIN, DiagnosticStage.CACHE_ADMIT, DiagnosticStage.CACHE_START, DiagnosticStage.CACHE_PROGRESS,
  DiagnosticStage.CACHE_END, DiagnosticStage.CACHE_STOP, DiagnosticStage.CACHE_DRAIN, DiagnosticStage.READ_END,
  DiagnosticStage.HEADER_PARSE, DiagnosticStage.HISTORY_END, DiagnosticStage.CLEAR_BEGIN, DiagnosticStage.DELETE_GUARD,
  DiagnosticStage.UNLINK_BEGIN, DiagnosticStage.UNLINK_END, DiagnosticStage.DELETE_END, DiagnosticStage.CLEAR_END,
  DiagnosticStage.ICON_IO, DiagnosticStage.ICON_CLEAR, DiagnosticStage.SYNC_START, DiagnosticStage.SYNC_STATE,
  DiagnosticStage.CRYPTO_RESULT, DiagnosticStage.HEADER_VALIDATE, DiagnosticStage.UI_ACTION, DiagnosticStage.UI_RESULT,
  DiagnosticStage.UI_REFRESH, DiagnosticStage.RESTORE_END, DiagnosticStage.FS_PREPARE, DiagnosticStage.FS_STAGE,
  DiagnosticStage.FS_ENCODE, DiagnosticStage.FS_STAGE_MOVE, DiagnosticStage.TEMP_CLEANUP, DiagnosticStage.RESTORE_BEGIN,
  DiagnosticStage.RESTORE_DECRYPT, DiagnosticStage.RESTORE_VALIDATE, DiagnosticStage.ACCOUNT_STATE,
  DiagnosticStage.ACCOUNT_AUTHORIZE, DiagnosticStage.ACCOUNT_INIT, DiagnosticStage.TIME_PARSE];
const RESULTS: DiagnosticResult[] = [DiagnosticResult.UNKNOWN, DiagnosticResult.BEGIN, DiagnosticResult.OK,
  DiagnosticResult.FAIL, DiagnosticResult.BLOCKED, DiagnosticResult.CANCELLED, DiagnosticResult.PENDING];
const REASONS: DiagnosticReason[] = [DiagnosticReason.UNKNOWN, DiagnosticReason.NONE, DiagnosticReason.IO_ERROR,
  DiagnosticReason.INVALID_ARGUMENT, DiagnosticReason.NOT_FOUND, DiagnosticReason.NO_SPACE, DiagnosticReason.TIMEOUT,
  DiagnosticReason.CANCELLED, DiagnosticReason.INFLIGHT_UNCONFIRMED, DiagnosticReason.BUSY, DiagnosticReason.INVALID_FORMAT,
  DiagnosticReason.EMPTY_CONTENT, DiagnosticReason.IDENTITY_UNAVAILABLE, DiagnosticReason.NAME_UNAVAILABLE,
  DiagnosticReason.URI_MISMATCH, DiagnosticReason.SHORT_WRITE, DiagnosticReason.SYNC_REJECTED,
  DiagnosticReason.PARTIAL_FAILURE, DiagnosticReason.UNAVAILABLE, DiagnosticReason.TRUNCATED,
  DiagnosticReason.DECRYPT_FAILED, DiagnosticReason.NOT_READY, DiagnosticReason.NOT_SIGNED_IN, DiagnosticReason.ENCODING_FAILED,
  DiagnosticReason.MISMATCH];
const LOCATIONS: DiagnosticLocation[] = [DiagnosticLocation.UNKNOWN, DiagnosticLocation.LOCAL, DiagnosticLocation.CLOUD, DiagnosticLocation.BOTH];
const STATES: DiagnosticState[] = [DiagnosticState.UNKNOWN, DiagnosticState.IDLE, DiagnosticState.RUNNING,
  DiagnosticState.COMPLETED, DiagnosticState.FAILED, DiagnosticState.STOPPED];
const SCOPES: DiagnosticScope[] = [DiagnosticScope.UNKNOWN, DiagnosticScope.ALL, DiagnosticScope.DEVICE,
  DiagnosticScope.SAME_NAME, DiagnosticScope.SINGLE];
const ARTIFACTS: DiagnosticArtifact[] = [DiagnosticArtifact.UNKNOWN, DiagnosticArtifact.TOKEN, DiagnosticArtifact.ICON];
const SOURCES: DiagnosticSource[] = [DiagnosticSource.UNKNOWN, DiagnosticSource.INITIAL, DiagnosticSource.CACHED,
  DiagnosticSource.RETRY, DiagnosticSource.FALLBACK];
const UI_ACTIONS: DiagnosticUiAction[] = [DiagnosticUiAction.UNKNOWN, DiagnosticUiAction.FEEDBACK,
  DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP];
const IO_MODES: DiagnosticMode[] = [DiagnosticMode.UNKNOWN, DiagnosticMode.STRING, DiagnosticMode.ARRAY_BUFFER, DiagnosticMode.TYPED_ARRAY];
const FORMAT_MODES: DiagnosticMode[] = [DiagnosticMode.UNKNOWN, DiagnosticMode.LEGACY, DiagnosticMode.ENCRYPTED];
const FS_STAGES: DiagnosticStage[] = [DiagnosticStage.FS_OPEN, DiagnosticStage.FS_WRITE, DiagnosticStage.FS_CLOSE,
  DiagnosticStage.FS_VERIFY, DiagnosticStage.WRITE_END, DiagnosticStage.PUBLISH_END, DiagnosticStage.READ_END,
  DiagnosticStage.POST_PUBLISH_VERIFY, DiagnosticStage.PUBLICATION_GUARD, DiagnosticStage.PUBLICATION_CLEANUP,
  DiagnosticStage.UNLINK_BEGIN, DiagnosticStage.UNLINK_END, DiagnosticStage.ICON_IO, DiagnosticStage.ICON_CLEAR,
  DiagnosticStage.HISTORY_END, DiagnosticStage.FS_PREPARE, DiagnosticStage.FS_STAGE,
  DiagnosticStage.FS_STAGE_MOVE, DiagnosticStage.TEMP_CLEANUP];
const CACHE_STAGES: DiagnosticStage[] = [DiagnosticStage.CACHE_ADMIT, DiagnosticStage.CACHE_START,
  DiagnosticStage.CACHE_PROGRESS, DiagnosticStage.CACHE_END, DiagnosticStage.CACHE_STOP, DiagnosticStage.CACHE_DRAIN];
const SYNC_STAGES: DiagnosticStage[] = [DiagnosticStage.SYNC_START, DiagnosticStage.SYNC_STATE];
const CRYPTO_STAGES: DiagnosticStage[] = [DiagnosticStage.ENCRYPT_END, DiagnosticStage.CRYPTO_RESULT,
  DiagnosticStage.HEADER_VALIDATE, DiagnosticStage.HEADER_PARSE, DiagnosticStage.RESTORE_DECRYPT,
  DiagnosticStage.RESTORE_VALIDATE];
const ITEM_STAGES: DiagnosticStage[] = [DiagnosticStage.FS_OPEN, DiagnosticStage.FS_WRITE, DiagnosticStage.FS_CLOSE,
  DiagnosticStage.FS_VERIFY, DiagnosticStage.CACHE_ADMIT, DiagnosticStage.CACHE_START, DiagnosticStage.CACHE_PROGRESS,
  DiagnosticStage.CACHE_END, DiagnosticStage.CACHE_STOP, DiagnosticStage.CACHE_DRAIN, DiagnosticStage.READ_END,
  DiagnosticStage.HEADER_PARSE, DiagnosticStage.DELETE_GUARD, DiagnosticStage.UNLINK_BEGIN, DiagnosticStage.UNLINK_END,
  DiagnosticStage.ICON_IO, DiagnosticStage.ICON_CLEAR, DiagnosticStage.HEADER_VALIDATE];
const SESSION_MS: number = 600000;
const MAX_CONTEXTS: number = 16;
const MAX_OPERATION_EVENTS: number = 32;
const MAX_SESSION_EVENTS: number = 256;
const MAX_SUMMARIES: number = 32;
const MAX_OP: number = 2147483647;

function normalizedStage(stage: DiagnosticStage): DiagnosticStage {
  return STAGES.indexOf(stage) >= 0 ? stage : DiagnosticStage.UNKNOWN;
}
function normalizedReason(reason?: DiagnosticReason): DiagnosticReason {
  return reason !== undefined && REASONS.indexOf(reason) >= 0 ? reason : DiagnosticReason.UNKNOWN;
}
function isFailure(result: DiagnosticResult): boolean {
  return result === DiagnosticResult.FAIL || result === DiagnosticResult.BLOCKED || result === DiagnosticResult.CANCELLED;
}
function normalizedDomain(stage: DiagnosticStage, domain?: DiagnosticErrorDomain): DiagnosticErrorDomain {
  if (domain === DiagnosticErrorDomain.FS && FS_STAGES.indexOf(stage) >= 0) { return domain; }
  if (domain === DiagnosticErrorDomain.CACHE && CACHE_STAGES.indexOf(stage) >= 0) { return domain; }
  if (domain === DiagnosticErrorDomain.SYNC && SYNC_STAGES.indexOf(stage) >= 0) { return domain; }
  if (domain === DiagnosticErrorDomain.CRYPTO && CRYPTO_STAGES.indexOf(stage) >= 0) { return domain; }
  if (domain === DiagnosticErrorDomain.APP && stage !== DiagnosticStage.UNKNOWN) { return domain; }
  return DiagnosticErrorDomain.UNKNOWN;
}

// SDK @ohos.file.fs.d.ts: close, mkdir/access, mkdtemp, moveFile(mode=1), open/read/write/stat/unlink/rmdir。
// 13900001 是 EPERM；EACCES 是 13900012。未列出的码不通过，包括 SDK 的笼统 Unknown error。
function fileCodeAllowed(stage: DiagnosticStage, code: number): boolean {
  if (code === 13900020) { return true; }
  switch (stage) {
    case DiagnosticStage.FS_CLOSE:
      return [13900004, 13900005, 13900008, 13900025, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.FS_STAGE:
      return [13900001, 13900002, 13900008, 13900011, 13900012, 13900013, 13900015,
        13900018, 13900025, 13900028, 13900030, 13900033, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.PUBLICATION_GUARD:
    case DiagnosticStage.FS_PREPARE:
      return [13900001, 13900002, 13900005, 13900008, 13900011, 13900012, 13900013, 13900015,
        13900018, 13900023, 13900025, 13900028, 13900030, 13900033, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.FS_STAGE_MOVE:
    case DiagnosticStage.PUBLISH_END:
      return [13900001, 13900002, 13900008, 13900011, 13900012, 13900013, 13900014, 13900015,
        13900016, 13900018, 13900019, 13900025, 13900027, 13900028, 13900032, 13900033, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.FS_WRITE:
    case DiagnosticStage.WRITE_END:
      return [13900001, 13900004, 13900005, 13900008, 13900010, 13900013, 13900024,
        13900025, 13900034, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.FS_OPEN:
      return [13900001, 13900002, 13900004, 13900008, 13900012, 13900015,
        13900018, 13900025, 13900027, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.FS_VERIFY:
      return [13900002, 13900004, 13900005, 13900008, 13900012, 13900018].indexOf(code) >= 0;
    case DiagnosticStage.READ_END:
    case DiagnosticStage.HISTORY_END:
    case DiagnosticStage.ICON_IO:
      // Aggregated open/read/close (+ list/stat or icon write) boundaries.
      return [13900001, 13900002, 13900004, 13900005, 13900008, 13900012, 13900018,
        13900025, 13900041].indexOf(code) >= 0;
    case DiagnosticStage.PUBLICATION_CLEANUP:
    case DiagnosticStage.TEMP_CLEANUP:
    case DiagnosticStage.UNLINK_BEGIN:
    case DiagnosticStage.UNLINK_END:
    case DiagnosticStage.ICON_CLEAR:
      return [13900001, 13900002, 13900005, 13900008, 13900011, 13900012, 13900013,
        13900014, 13900018, 13900019, 13900027, 13900030, 13900032, 13900033].indexOf(code) >= 0;
    default: return false;
  }
}

// cloudSync.d.ts: cache start/stop, FileSync.start, SyncProgress.error (ErrorType 0..8)。
// 不转换字符串或读取异常属性。
export function normalizeDiagnosticCode(stage: DiagnosticStage, domain: DiagnosticErrorDomain,
  code?: number | string): number | string {
  if (typeof code !== 'number' || !Number.isInteger(code)) { return 'UNKNOWN'; }
  const safeDomain = normalizedDomain(stage, domain);
  if (safeDomain === DiagnosticErrorDomain.FS && fileCodeAllowed(stage, code)) { return code; }
  if (safeDomain === DiagnosticErrorDomain.CACHE &&
    (stage === DiagnosticStage.CACHE_START || stage === DiagnosticStage.CACHE_END) &&
    (code === 401 || code === 13600001 || code === 13900002 || code === 13900025 || code === 14000002)) { return code; }
  if (safeDomain === DiagnosticErrorDomain.CACHE && stage === DiagnosticStage.CACHE_STOP &&
    (code === 401 || code === 13600001 || code === 13900002 || code === 14000002)) { return code; }
  if (safeDomain === DiagnosticErrorDomain.CACHE &&
    (stage === DiagnosticStage.CACHE_PROGRESS || stage === DiagnosticStage.CACHE_END) && code >= 1 && code <= 5) { return code; }
  if (safeDomain === DiagnosticErrorDomain.SYNC && stage === DiagnosticStage.SYNC_START &&
    (code === 401 || code === 13600001 || code === 22400001 || code === 22400002 || code === 22400003)) { return code; }
  if (safeDomain === DiagnosticErrorDomain.SYNC && stage === DiagnosticStage.SYNC_STATE && code >= 0 && code <= 8) { return code; }
  return 'UNKNOWN';
}

export function classifyDiagnosticError(stage: DiagnosticStage, domain: DiagnosticErrorDomain,
  error: Object | undefined | null): DiagnosticDetails {
  // 原始 Error/BusinessError/Proxy 一律不读取任何属性；避免 getter、toJSON、toString 的副作用。
  const code = normalizeDiagnosticCode(stage, domain, typeof error === 'number' ? error : undefined);
  let reason = DiagnosticReason.UNKNOWN;
  if (typeof code === 'number' && normalizedDomain(stage, domain) === DiagnosticErrorDomain.FS) {
    reason = DiagnosticReason.IO_ERROR;
  }
  if (code === 0) { reason = DiagnosticReason.NONE; }
  if (code === 13900002) { reason = DiagnosticReason.NOT_FOUND; }
  if (code === 13900020 || code === 14000002 || code === 401) { reason = DiagnosticReason.INVALID_ARGUMENT; }
  if (code === 13900025 || code === 13900041) { reason = DiagnosticReason.NO_SPACE; }
  if (code === 13600001 || code === 22400001 || code === 22400002 || code === 22400003) { reason = DiagnosticReason.UNAVAILABLE; }
  if (typeof code === 'number' && code >= 1 && code <= 8) { reason = DiagnosticReason.UNAVAILABLE; }
  return { reason: reason, errorDomain: normalizedDomain(stage, domain), code: code };
}

// 每阶段进一步收紧字段。此处只复制已批准的基本值，从不展开/序列化调用方对象。
function normalizeDetails(stage: DiagnosticStage, input?: DiagnosticDetails): DiagnosticDetails {
  const output: DiagnosticDetails = {};
  if (input === undefined || input === null) { return output; }
  output.reason = normalizedReason(input.reason);
  if (input.errorDomain !== undefined || input.code !== undefined) {
    output.errorDomain = normalizedDomain(stage, input.errorDomain);
    output.code = normalizeDiagnosticCode(stage, output.errorDomain, input.code);
    if (output.code === 0) { output.reason = DiagnosticReason.NONE; }
  }
  if (ITEM_STAGES.indexOf(stage) >= 0 && (input.item === 1 || input.item === 2)) { output.item = input.item; }
  if (stage === DiagnosticStage.DEVICE_INFO || stage === DiagnosticStage.BACKUP_BEGIN || stage === DiagnosticStage.HEADER_PARSE) {
    if (typeof input.identityAvailable === 'boolean') { output.identityAvailable = input.identityAvailable; }
    if (typeof input.nameAvailable === 'boolean') { output.nameAvailable = input.nameAvailable; }
  }
  if (stage === DiagnosticStage.DEVICE_INFO && input.source !== undefined) {
    output.source = SOURCES.indexOf(input.source) >= 0 ? input.source : DiagnosticSource.UNKNOWN;
  }
  if ((stage === DiagnosticStage.UI_ACTION || stage === DiagnosticStage.UI_RESULT || stage === DiagnosticStage.UI_REFRESH) &&
    input.uiAction !== undefined) {
    output.uiAction = UI_ACTIONS.indexOf(input.uiAction) >= 0 ? input.uiAction : DiagnosticUiAction.UNKNOWN;
  }
  if (ITEM_STAGES.indexOf(stage) >= 0 && input.location !== undefined) {
    output.location = LOCATIONS.indexOf(input.location) >= 0 ? input.location : DiagnosticLocation.UNKNOWN;
  }
  if ((CACHE_STAGES.indexOf(stage) >= 0 || stage === DiagnosticStage.SYNC_STATE) && input.state !== undefined) {
    output.state = STATES.indexOf(input.state) >= 0 ? input.state : DiagnosticState.UNKNOWN;
  }
  if (FS_STAGES.indexOf(stage) >= 0 && input.mode !== undefined) {
    output.mode = IO_MODES.indexOf(input.mode) >= 0 ? input.mode : DiagnosticMode.UNKNOWN;
  } else if (CRYPTO_STAGES.indexOf(stage) >= 0 && input.mode !== undefined) {
    output.mode = FORMAT_MODES.indexOf(input.mode) >= 0 ? input.mode : DiagnosticMode.UNKNOWN;
  }
  if (CACHE_STAGES.indexOf(stage) >= 0 && typeof input.uriMatches === 'boolean') { output.uriMatches = input.uriMatches; }
  if ((stage === DiagnosticStage.CACHE_DRAIN || stage === DiagnosticStage.CACHE_STOP || stage === DiagnosticStage.DELETE_GUARD ||
    stage === DiagnosticStage.ICON_IO || stage === DiagnosticStage.PUBLICATION_GUARD ||
    stage === DiagnosticStage.PUBLICATION_CLEANUP) &&
    typeof input.drained === 'boolean') { output.drained = input.drained; }
  if ((FS_STAGES.indexOf(stage) >= 0 || CRYPTO_STAGES.indexOf(stage) >= 0) && typeof input.contentNonEmpty === 'boolean') {
    output.contentNonEmpty = input.contentNonEmpty;
  }
  if ((stage === DiagnosticStage.FS_WRITE || stage === DiagnosticStage.FS_CLOSE || stage === DiagnosticStage.FS_VERIFY ||
    stage === DiagnosticStage.WRITE_END || stage === DiagnosticStage.PUBLISH_END) && typeof input.writeComplete === 'boolean') {
    output.writeComplete = input.writeComplete;
  }
  if ((CRYPTO_STAGES.indexOf(stage) >= 0 || stage === DiagnosticStage.FS_VERIFY || stage === DiagnosticStage.READ_END ||
    stage === DiagnosticStage.ICON_CLEAR || stage === DiagnosticStage.POST_PUBLISH_VERIFY) &&
    typeof input.headerParsed === 'boolean') { output.headerParsed = input.headerParsed; }
  if (stage === DiagnosticStage.CLEAR_BEGIN || stage === DiagnosticStage.DELETE_GUARD || stage === DiagnosticStage.UNLINK_BEGIN ||
    stage === DiagnosticStage.UNLINK_END || stage === DiagnosticStage.CLEAR_END || stage === DiagnosticStage.DELETE_END ||
    stage === DiagnosticStage.ICON_CLEAR) {
    if (input.scope !== undefined) { output.scope = SCOPES.indexOf(input.scope) >= 0 ? input.scope : DiagnosticScope.UNKNOWN; }
    if (typeof input.unlinkAttempted === 'boolean') { output.unlinkAttempted = input.unlinkAttempted; }
    if (typeof input.alreadyAbsent === 'boolean') { output.alreadyAbsent = input.alreadyAbsent; }
  }
  if (stage === DiagnosticStage.SYNC_START || stage === DiagnosticStage.PUBLISH_END || stage === DiagnosticStage.BACKUP_END ||
    stage === DiagnosticStage.CLEAR_END || stage === DiagnosticStage.DELETE_END || stage === DiagnosticStage.UI_RESULT ||
    stage === DiagnosticStage.PUBLICATION_CLEANUP) {
    if (typeof input.syncStartAccepted === 'boolean') { output.syncStartAccepted = input.syncStartAccepted; }
  }
  if (stage === DiagnosticStage.BACKUP_END || stage === DiagnosticStage.HISTORY_END || stage === DiagnosticStage.CLEAR_END ||
    stage === DiagnosticStage.DELETE_END || stage === DiagnosticStage.ICON_CLEAR || stage === DiagnosticStage.UI_RESULT ||
    stage === DiagnosticStage.RESTORE_END || stage === DiagnosticStage.PUBLICATION_GUARD ||
    stage === DiagnosticStage.PUBLICATION_CLEANUP) {
    if (typeof input.partialFailure === 'boolean') { output.partialFailure = input.partialFailure; }
  }
  if (stage === DiagnosticStage.ICON_IO || stage === DiagnosticStage.ICON_CLEAR || stage === DiagnosticStage.SYNC_START ||
    stage === DiagnosticStage.SYNC_STATE) {
    if (input.artifact !== undefined) { output.artifact = ARTIFACTS.indexOf(input.artifact) >= 0 ? input.artifact : DiagnosticArtifact.UNKNOWN; }
  }
  if (input.truncated === true) { output.truncated = true; }
  return output;
}

export function normalizeDiagnosticSummary(stage: DiagnosticStage, result: DiagnosticResult,
  details?: DiagnosticDetails): DiagnosticSummary {
  try {
    const safeStage = normalizedStage(stage);
    return { stage: safeStage, result: RESULTS.indexOf(result) >= 0 ? result : DiagnosticResult.UNKNOWN,
      // 第二次仅检查本函数创建的普通对象，避免外部 accessor 在重复读取间改变值。
      details: normalizeDetails(safeStage, normalizeDetails(safeStage, details)) };
  } catch (_) {
    return { stage: DiagnosticStage.UNKNOWN, result: DiagnosticResult.UNKNOWN, details: {} };
  }
}

// TaskPool 可用纯函数：最多两种代表失败，不返回成功清单或原始异常。
export function appendDiagnosticSummary(summaries: DiagnosticSummary[], stage: DiagnosticStage,
  result: DiagnosticResult, details?: DiagnosticDetails): void {
  try {
    if (summaries.length > 2) { summaries.length = 2; }
    if (!isFailure(result)) { return; }
    const safe = normalizeDiagnosticSummary(stage, result, details);
    for (let index = 0; index < Math.min(summaries.length, 2); index++) {
      const previous = summaries[index];
      if (previous.stage === safe.stage && previous.details.reason === safe.details.reason) { return; }
    }
    if (summaries.length >= 2) { summaries[1].details.truncated = true; return; }
    if (ITEM_STAGES.indexOf(safe.stage) >= 0) { safe.details.item = summaries.length + 1; }
    summaries.push(safe);
  } catch (_) { /* 诊断永不影响业务返回。 */ }
}

function elapsedBucket(milliseconds: number): DiagnosticElapsed {
  if (!Number.isFinite(milliseconds) || milliseconds < 0) { return DiagnosticElapsed.UNAVAILABLE; }
  if (milliseconds < 100) { return DiagnosticElapsed.LT_100MS; }
  if (milliseconds < 1000) { return DiagnosticElapsed.LT_1S; }
  if (milliseconds < 10000) { return DiagnosticElapsed.LT_10S; }
  if (milliseconds < 60000) { return DiagnosticElapsed.LT_60S; }
  return DiagnosticElapsed.GE_60S;
}

function detailFields(details: DiagnosticDetails): string[] {
  const fields: string[] = [];
  if (details.item !== undefined) { fields.push(`item=${details.item}`); }
  if (details.errorDomain !== undefined) { fields.push(`errorDomain=${details.errorDomain}`); }
  if (details.code !== undefined) { fields.push(`code=${details.code}`); }
  if (details.location !== undefined) { fields.push(`location=${details.location}`); }
  if (details.state !== undefined) { fields.push(`state=${details.state}`); }
  if (details.mode !== undefined) { fields.push(`mode=${details.mode}`); }
  if (details.scope !== undefined) { fields.push(`scope=${details.scope}`); }
  if (details.artifact !== undefined) { fields.push(`artifact=${details.artifact}`); }
  if (details.source !== undefined) { fields.push(`source=${details.source}`); }
  if (details.uiAction !== undefined) { fields.push(`uiAction=${details.uiAction}`); }
  if (details.identityAvailable !== undefined) { fields.push(`identityAvailable=${details.identityAvailable}`); }
  if (details.nameAvailable !== undefined) { fields.push(`nameAvailable=${details.nameAvailable}`); }
  if (details.uriMatches !== undefined) { fields.push(`uriMatches=${details.uriMatches}`); }
  if (details.contentNonEmpty !== undefined) { fields.push(`contentNonEmpty=${details.contentNonEmpty}`); }
  if (details.writeComplete !== undefined) { fields.push(`writeComplete=${details.writeComplete}`); }
  if (details.headerParsed !== undefined) { fields.push(`headerParsed=${details.headerParsed}`); }
  if (details.unlinkAttempted !== undefined) { fields.push(`unlinkAttempted=${details.unlinkAttempted}`); }
  if (details.alreadyAbsent !== undefined) { fields.push(`alreadyAbsent=${details.alreadyAbsent}`); }
  if (details.syncStartAccepted !== undefined) { fields.push(`syncStartAccepted=${details.syncStartAccepted}`); }
  if (details.partialFailure !== undefined) { fields.push(`partialFailure=${details.partialFailure}`); }
  if (details.drained !== undefined) { fields.push(`drained=${details.drained}`); }
  if (details.truncated === true) { fields.push('truncated=true'); }
  return fields;
}

class OperationState {
  context: DiagnosticContext;
  op: number;
  kind: DiagnosticKind;
  start: number;
  emitted: number = 0;
  exhausted: boolean = false;
  seen: Set<string> = new Set<string>();
  representatives: string[] = [];
  batchTruncated: boolean = false;
  mismatchSeen: boolean = false;
  constructor(context: DiagnosticContext, start: number) {
    this.context = context; this.op = context.op; this.kind = context.kind; this.start = start;
  }
}
class SummaryStamp {
  key: string;
  at: number;
  constructor(key: string, at: number) { this.key = key; this.at = at; }
}
class MainDiagnosticThread implements DiagnosticThread {
  isMainThread(): boolean { return process.pid > 0 && process.pid === process.tid; }
}
class UptimeDiagnosticClock implements DiagnosticClock {
  // SDK TimeType.STARTUP 包含深度休眠；不使用 Date.now() 或不含休眠的 ACTIVE。
  now(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false); }
}
class HilogDiagnosticSink implements DiagnosticSink {
  write(line: string): void { hilog.info(0xFF00, 'CloudBackupDiag', '%{public}s', line); }
}

// 测试只注入这三个窄端口，不替换全局时钟或依赖 LocalUnit 系统 API stub。
export class CloudBackupDiagnosticRecorder {
  private sink: DiagnosticSink;
  private clock: DiagnosticClock;
  private thread: DiagnosticThread;
  private enabled: boolean = false;
  private generation: number = 0;
  private nextOp: number = 0;
  private sessionStart: number = 0;
  private sessionEvents: number = 0;
  private lastNow: number = -1;
  private operations: OperationState[] = [];
  private summaries: SummaryStamp[] = [];

  constructor(sink: DiagnosticSink, clock: DiagnosticClock, thread: DiagnosticThread) {
    this.sink = sink; this.clock = clock; this.thread = thread;
  }

  private onMainThread(): boolean {
    try { return this.thread.isMainThread() === true; } catch (_) { return false; }
  }
  private invalidate(): void {
    this.enabled = false;
    this.generation++;
    this.operations = [];
  }
  private now(): number {
    try {
      const now = this.clock.now();
      if (typeof now !== 'number' || !Number.isFinite(now) || now < 0 || now < this.lastNow) {
        this.invalidate(); return -1;
      }
      this.lastNow = now;
      if (this.enabled && now - this.sessionStart >= SESSION_MS) { this.invalidate(); }
      return now;
    } catch (_) { this.invalidate(); return -1; }
  }
  enable(): boolean {
    if (!this.onMainThread()) { return false; }
    this.invalidate();
    const now = this.now();
    if (now < 0) { return false; }
    this.enabled = true;
    this.sessionStart = now;
    this.sessionEvents = 0;
    return true;
  }
  disable(): void { if (this.onMainThread()) { this.invalidate(); } }
  isEnabled(): boolean { return this.remainingTimeMs() > 0; }
  remainingTimeMs(): number {
    if (!this.onMainThread()) { return 0; }
    const now = this.now();
    return now >= 0 && this.enabled ? Math.max(0, SESSION_MS - (now - this.sessionStart)) : 0;
  }
  begin(kind: DiagnosticKind): DiagnosticContext {
    const safeKind = KINDS.indexOf(kind) >= 0 ? kind : DiagnosticKind.UNKNOWN;
    if (!this.onMainThread()) { return new DiagnosticContext(0, safeKind, -1); }
    const now = this.now();
    if (!this.enabled || now < 0 || this.operations.length >= MAX_CONTEXTS || this.nextOp >= MAX_OP ||
      this.sessionEvents >= MAX_SESSION_EVENTS) { return new DiagnosticContext(0, safeKind, -1); }
    const context = new DiagnosticContext(++this.nextOp, safeKind, this.generation);
    this.operations.push(new OperationState(context, now));
    return context;
  }
  private write(line: string): void {
    try { this.sink.write(line); } catch (_) { /* 不回退到原始日志。 */ }
  }
  private summary(kind: DiagnosticKind, stage: DiagnosticStage, result: DiagnosticResult,
    reason: DiagnosticReason, now: number): void {
    if (!isFailure(result) || now < 0) { return; }
    this.summaries = this.summaries.filter((stamp: SummaryStamp) => now - stamp.at < SESSION_MS);
    const key = `${kind}|${stage}|${reason}`;
    if (this.summaries.length >= MAX_SUMMARIES ||
      this.summaries.some((stamp: SummaryStamp) => stamp.key === key && now - stamp.at < 60000)) { return; }
    this.summaries.push(new SummaryStamp(key, now));
    this.write(`v=1 kind=${kind} stage=${stage} result=${result} reason=${reason}`);
  }
  mark(context: DiagnosticContext, stage: DiagnosticStage, result: DiagnosticResult, details?: DiagnosticDetails): void {
    try {
      if (!this.onMainThread()) { return; }
      const now = this.now();
      if (now < 0) { return; }
      const suppliedKind = context.kind;
      const safeKind = KINDS.indexOf(suppliedKind) >= 0 ? suppliedKind : DiagnosticKind.UNKNOWN;
      const safeStage = normalizedStage(stage);
      const safeResult = RESULTS.indexOf(result) >= 0 ? result : DiagnosticResult.UNKNOWN;
      const operation = this.operations.find((candidate: OperationState) => candidate.context === context);
      if (!this.enabled || context.generation !== this.generation || operation === undefined) {
        // 关闭时不构造详细事件；过期/旧 generation 只可进入独立的摘要限额。
        this.summary(safeKind, safeStage, safeResult, normalizedReason(details?.reason), now);
        return;
      }
      if (operation.exhausted || this.sessionEvents >= MAX_SESSION_EVENTS) { return; }
      const batch = operation.kind === DiagnosticKind.HISTORY || operation.kind === DiagnosticKind.CLEAR || operation.kind === DiagnosticKind.ICON;
      if (batch && ITEM_STAGES.indexOf(safeStage) >= 0 && !isFailure(safeResult)) { return; }
      // 构造异常直接进入外层 catch 丢弃，不把损坏边界伪装成业务 UNKNOWN 事件。
      const safe: DiagnosticSummary = { stage: safeStage, result: safeResult,
        details: normalizeDetails(safeStage, normalizeDetails(safeStage, details)) };
      // 槽号由诊断内部按失败类别分配，不接受调用者提供的扫描序号。
      safe.details.item = undefined;
      if (safeStage === DiagnosticStage.CACHE_PROGRESS && safe.details.uriMatches === false) {
        if (operation.mismatchSeen) { return; }
        operation.mismatchSeen = true;
      }
      if (batch && ITEM_STAGES.indexOf(safeStage) >= 0 && isFailure(safeResult)) {
        const category = `${safe.details.reason}|${safe.details.errorDomain}|${safe.details.code}`;
        let representative = operation.representatives.indexOf(category);
        if (representative < 0) {
          if (operation.representatives.length >= 2) { operation.batchTruncated = true; return; }
          operation.representatives.push(category);
          representative = operation.representatives.length - 1;
        }
        safe.details.item = representative + 1;
      }
      if (operation.batchTruncated && ITEM_STAGES.indexOf(safeStage) < 0) { safe.details.truncated = true; }
      const reason = normalizedReason(safe.details.reason);
      const fields = detailFields(safe.details);
      // 默认摘要不是逐项清单；详细模式也不能通过变化的进度/附加位枚举文件。
      let fingerprint = `${safe.stage}|${safe.result}|${reason}|${fields.join(' ')}`;
      if (batch && ITEM_STAGES.indexOf(safeStage) >= 0) {
        fingerprint = `${safe.stage}|${safe.details.item}|${reason}`;
      } else if (safeStage === DiagnosticStage.CACHE_PROGRESS) {
        fingerprint = `${safe.stage}|${safe.details.state}|${safe.details.uriMatches}`;
      }
      if (operation.seen.has(fingerprint)) { return; }
      operation.seen.add(fingerprint);
      const elapsed = elapsedBucket(now - operation.start);
      if (operation.emitted >= MAX_OPERATION_EVENTS - 1 || this.sessionEvents >= MAX_SESSION_EVENTS - 1) {
        operation.exhausted = true;
        operation.emitted++;
        this.sessionEvents++;
        this.write(`v=1 op=${operation.op} kind=${operation.kind} stage=UNKNOWN result=UNKNOWN reason=TRUNCATED elapsed=${elapsed} truncated=true`);
        return;
      }
      operation.emitted++;
      this.sessionEvents++;
      const suffix = fields.length > 0 ? ` ${fields.join(' ')}` : '';
      this.write(`v=1 op=${operation.op} kind=${operation.kind} stage=${safe.stage} result=${safe.result} reason=${reason} elapsed=${elapsed}${suffix}`);
    } catch (_) { /* 任意诊断构造失败均丢弃，不影响业务。 */ }
  }
  fail(context: DiagnosticContext, stage: DiagnosticStage, domain: DiagnosticErrorDomain,
    error: Object | undefined | null): void {
    this.mark(context, stage, DiagnosticResult.FAIL, classifyDiagnosticError(stage, domain, error));
  }
  replay(context: DiagnosticContext, summaries: DiagnosticSummary[]): void {
    try {
      for (let index = 0; index < Math.min(summaries.length, 2); index++) {
        const summary = summaries[index];
        if (isFailure(summary.result)) { this.mark(context, summary.stage, summary.result, summary.details); }
      }
    } catch (_) { /* 后台结果仍需在当前 generation 中重新校验。 */ }
  }
  finish(context: DiagnosticContext): void {
    if (!this.onMainThread()) { return; }
    this.operations = this.operations.filter((operation: OperationState) => operation.context !== context);
  }
  end(context: DiagnosticContext): void { this.finish(context); }
}

export class CloudBackupDiagnostics {
  private static recorder: CloudBackupDiagnosticRecorder = new CloudBackupDiagnosticRecorder(
    new HilogDiagnosticSink(), new UptimeDiagnosticClock(), new MainDiagnosticThread());
  static enable(): boolean { return CloudBackupDiagnostics.recorder.enable(); }
  static disable(): void { CloudBackupDiagnostics.recorder.disable(); }
  static isEnabled(): boolean { return CloudBackupDiagnostics.recorder.isEnabled(); }
  static remainingTimeMs(): number { return CloudBackupDiagnostics.recorder.remainingTimeMs(); }
  static begin(kind: DiagnosticKind): DiagnosticContext { return CloudBackupDiagnostics.recorder.begin(kind); }
  static mark(context: DiagnosticContext, stage: DiagnosticStage, result: DiagnosticResult, details?: DiagnosticDetails): void {
    CloudBackupDiagnostics.recorder.mark(context, stage, result, details);
  }
  static fail(context: DiagnosticContext, stage: DiagnosticStage, domain: DiagnosticErrorDomain,
    error: Object | undefined | null): void { CloudBackupDiagnostics.recorder.fail(context, stage, domain, error); }
  static replay(context: DiagnosticContext, summaries: DiagnosticSummary[]): void { CloudBackupDiagnostics.recorder.replay(context, summaries); }
  static finish(context: DiagnosticContext): void { CloudBackupDiagnostics.recorder.finish(context); }
  static end(context: DiagnosticContext): void { CloudBackupDiagnostics.recorder.end(context); }
}

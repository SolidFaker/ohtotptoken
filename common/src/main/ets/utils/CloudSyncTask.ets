import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer, util } from '@kit.ArkTS';
import {
  CloudBackupRecord, CloudBackupMetadataStatus, CloudBackupIdentityStatus,
} from './CloudBackupCrypto';
import { isBackupBase64, parseCloudBackupHeaderJson } from './CloudBackupMetadata';
import {
  DiagnosticContext, DiagnosticSummary, DiagnosticStage, DiagnosticResult, DiagnosticReason, DiagnosticErrorDomain,
  appendDiagnosticSummary,
} from './CloudBackupDiagnostics';
import { formatRecordDate, parseBackupTimestamp } from './CommonUtils';
import { fileIoDiagnosticCode } from './StoragePorts';

export interface CloudBackupTaskHistory {
  records: CloudBackupRecord[];
  diagnostics: DiagnosticSummary[];
  complete: boolean;
}

@Concurrent
export async function checkCloudBackupRecords(cloudDir: string): Promise<number> {
  try {
    const files = fs.listFileSync(cloudDir);
    return files.filter((name: string): boolean => /^otp_backup_-?\d+\.enc(?![\s\S])/.test(name) &&
      Number.isSafeInteger(parseBackupTimestamp(name))).length;
  } catch (_) {
    return -1;
  }
}

/** 调用方持有 HISTORY 许可；仅真实在途任务阻断读取，预缓存失败与文件位置不是读取禁令。 */
@Concurrent
export async function loadBackupHistoryRecords(cloudDir: string, readBlocked: boolean = false,
  _context?: DiagnosticContext): Promise<CloudBackupTaskHistory> {
  const result: CloudBackupTaskHistory = { records: [], diagnostics: [], complete: true };
  const MAX_HISTORY_FILE_SIZE = 64 * 1024 * 1024;
  const base64 = new util.Base64Helper();
  try {
    const names = fs.listFileSync(cloudDir);
    for (const name of names) {
      if (!/^otp_backup_-?\d+\.enc(?![\s\S])/.test(name)) continue;
      const timestamp = parseBackupTimestamp(name);
      if (!Number.isSafeInteger(timestamp)) continue;
      try {
        const path = `${cloudDir}/${name}`;
        const stat = await fs.stat(path);
        const record: CloudBackupRecord = {
          id: name, timestamp: timestamp, date: formatRecordDate(timestamp), tokenCount: 0,
          size: stat.size, encrypted: true, deviceId: '', deviceName: '', location: stat.location,
          metadataStatus: readBlocked || stat.location === 2 ?
            CloudBackupMetadataStatus.PENDING : CloudBackupMetadataStatus.READ_FAILED,
          identityStatus: CloudBackupIdentityStatus.ID_MISSING, tokenCountKnown: false,
        };
        if (readBlocked) {
          result.records.push(record);
          continue;
        }
        let content: string | undefined = undefined;
        try {
          if (!Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size > MAX_HISTORY_FILE_SIZE) {
            throw new Error('HISTORY_READ_LIMIT');
          }
          const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
          try {
            const bytes = new Uint8Array(stat.size);
            let offset = 0;
            while (offset < bytes.byteLength) {
              const chunk = new ArrayBuffer(Math.min(bytes.byteLength - offset, 65536));
              const length = fs.readSync(file.fd, chunk, { offset: offset });
              if (!Number.isInteger(length) || length <= 0 || length > chunk.byteLength) {
                throw new Error('HISTORY_SHORT_READ');
              }
              bytes.set(new Uint8Array(chunk, 0, length), offset);
              offset += length;
            }
            content = buffer.from(bytes).toString('utf-8');
          } finally {
            fs.closeSync(file);
          }
        } catch (error) {
          content = undefined;
          record.metadataStatus = CloudBackupMetadataStatus.READ_FAILED;
          appendDiagnosticSummary(result.diagnostics, DiagnosticStage.READ_END, DiagnosticResult.FAIL,
            { reason: DiagnosticReason.IO_ERROR, errorDomain: DiagnosticErrorDomain.FS, code: fileIoDiagnosticCode(error) });
        }
        if (content !== undefined) {
          let invalid = false;
          try {
            const segments = content.split('.');
            if (segments.length !== 3 || segments.some((segment: string): boolean => segment.length === 0) ||
              !isBackupBase64(segments[0])) {
              invalid = true;
              throw new Error('HEADER_FORMAT');
            }
            const decoded = base64.decodeSync(segments[0]);
            const headerJson = buffer.from(decoded).toString('utf-8');
            if (decoded.byteLength === 0 || headerJson.length === 0) throw new Error('HEADER_DECODE_UNAVAILABLE');
            const parsed = parseCloudBackupHeaderJson(headerJson);
            if (!parsed.valid || parsed.header === undefined) {
              invalid = true;
              throw new Error('HEADER_FORMAT');
            }
            const header = parsed.header;
            record.deviceId = header.deviceId;
            record.deviceName = header.deviceName;
            record.size = header.size;
            record.tokenCount = header.tokenCount;
            record.tokenCountKnown = true;
            record.metadataStatus = CloudBackupMetadataStatus.VALID;
            record.identityStatus = parsed.identityStatus;
          } catch (_) {
            record.metadataStatus = !invalid ? CloudBackupMetadataStatus.READ_FAILED :
              stat.location === 2 ? CloudBackupMetadataStatus.PENDING :
                stat.location === 1 || stat.location === 3 ? CloudBackupMetadataStatus.INVALID : CloudBackupMetadataStatus.READ_FAILED;
            appendDiagnosticSummary(result.diagnostics, DiagnosticStage.HEADER_PARSE, DiagnosticResult.FAIL,
              { reason: invalid ? DiagnosticReason.INVALID_FORMAT : DiagnosticReason.DECRYPT_FAILED,
                headerParsed: false, contentNonEmpty: content.length > 0 });
          }
        }
        result.records.push(record);
      } catch (error) {
        result.complete = false;
        appendDiagnosticSummary(result.diagnostics, DiagnosticStage.READ_END, DiagnosticResult.FAIL,
          { reason: DiagnosticReason.IO_ERROR, errorDomain: DiagnosticErrorDomain.FS, code: fileIoDiagnosticCode(error) });
      }
    }
  } catch (error) {
    result.complete = false;
    appendDiagnosticSummary(result.diagnostics, DiagnosticStage.HISTORY_END, DiagnosticResult.FAIL,
      { reason: DiagnosticReason.IO_ERROR, errorDomain: DiagnosticErrorDomain.FS, code: fileIoDiagnosticCode(error) });
  }
  result.records.sort((a: CloudBackupRecord, b: CloudBackupRecord): number => b.timestamp - a.timestamp);
  return result;
}

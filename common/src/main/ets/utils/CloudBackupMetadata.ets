import {
  CloudBackupCryptoMode,
  CloudBackupIdentityStatus,
  CloudBackupTokenHeader
} from './CloudBackupCrypto';

/** 只校验已解码 JSON，不访问文件、时钟、设备或 Base64 系统 API。 */
export interface CloudBackupHeaderParseResult {
  valid: boolean;
  header?: CloudBackupTokenHeader;
  identityStatus: CloudBackupIdentityStatus;
}

/** 历史占位值不具有设备归属含义。 */
export function normalizeCloudBackupDeviceId(value: string): string {
  const trimmed = value.trim();
  return trimmed.toLowerCase() === 'unknown_odid' ? '' : trimmed;
}

export function normalizeCloudBackupDeviceName(value: string): string {
  const trimmed = value.trim();
  return trimmed.toLowerCase() === 'unknown device' || trimmed.toLowerCase() === 'unknown' ? '' : trimmed;
}

export function getCloudBackupIdentityStatus(deviceId: string, deviceName: string): CloudBackupIdentityStatus {
  if (normalizeCloudBackupDeviceId(deviceId).length === 0) {
    return CloudBackupIdentityStatus.ID_MISSING;
  }
  return normalizeCloudBackupDeviceName(deviceName).length > 0 ?
    CloudBackupIdentityStatus.COMPLETE : CloudBackupIdentityStatus.NAME_MISSING;
}

/** 位置仅描述副本驻留情况，不表示本次同步已完成。 */
export function normalizeCloudBackupLocation(location: number): number {
  return location === 1 || location === 2 || location === 3 ? location : 0;
}

function invalidHeader(): CloudBackupHeaderParseResult {
  return { valid: false, identityStatus: CloudBackupIdentityStatus.ID_MISSING };
}

function isNonNegativeInteger(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/** 先校验编码形式，SDK 解码异常或空输出不能作为文件损坏证据。 */
export function isBackupBase64(value: string): boolean {
  return value.length > 0 &&
    /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?(?![\s\S])/.test(value);
}

/** AES-128 salt/IV 的规范 base64 长度为 24，末尾两个填充位。 */
function isEncodedKeyBytes(value: string): boolean {
  return /^[A-Za-z0-9+/]{21}[AQgw]==$/.test(value);
}

/**
 * 校验支持的 v1 mock/v2 加密头部，并仅拷贝已核实的字段。
 * 缺少旧设备字段是有效元数据的独立身份状态；其他已存在字段类型错误则拒绝。
 * valid 只表示头部结构，不表示正文完整性或签名正确，恢复仍须验证/解密。
 * 空文本在这里无效；只有调用方确认完整本地读取成功后，才可据此标记 INVALID。
 * 云占位/下载失败必须由调用方保留 PENDING/READ_FAILED，不能以本结果推断云端损坏。
 */
export function parseCloudBackupHeaderJson(text: string): CloudBackupHeaderParseResult {
  try {
    // 此断言只允许读取候选字段；下面每个持久化字段仍必须通过运行时检查。
    const candidate = JSON.parse(text) as CloudBackupTokenHeader;
    if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
      return invalidHeader();
    }
    if ((candidate.version !== 1 && candidate.version !== 2) ||
      (candidate.mode !== CloudBackupCryptoMode.NONE && candidate.mode !== CloudBackupCryptoMode.HUAWEI_ACCOUNT) ||
      typeof candidate.salt !== 'string' || typeof candidate.iv !== 'string' ||
      !isNonNegativeInteger(candidate.tokenCount) || !isNonNegativeInteger(candidate.size) ||
      !isNonNegativeInteger(candidate.timestamp)) {
      return invalidHeader();
    }
    const legacy = candidate.salt.startsWith('mock_salt_');
    if (legacy) {
      if (candidate.iv.length === 0) {
        return invalidHeader();
      }
    } else if (candidate.version !== 2 || candidate.mode !== CloudBackupCryptoMode.HUAWEI_ACCOUNT ||
      !isEncodedKeyBytes(candidate.salt) || !isEncodedKeyBytes(candidate.iv)) {
      return invalidHeader();
    }
    if ((candidate.deviceId !== undefined && candidate.deviceId !== null && typeof candidate.deviceId !== 'string') ||
      (candidate.deviceName !== undefined && candidate.deviceName !== null && typeof candidate.deviceName !== 'string')) {
      return invalidHeader();
    }
    const deviceId = typeof candidate.deviceId === 'string' ? normalizeCloudBackupDeviceId(candidate.deviceId) : '';
    const deviceName = typeof candidate.deviceName === 'string' ? normalizeCloudBackupDeviceName(candidate.deviceName) : '';
    const header: CloudBackupTokenHeader = {
      version: candidate.version,
      mode: candidate.mode,
      salt: candidate.salt,
      iv: candidate.iv,
      tokenCount: candidate.tokenCount,
      size: candidate.size,
      timestamp: candidate.timestamp,
      deviceId: deviceId,
      deviceName: deviceName,
    };
    return { valid: true, header: header, identityStatus: getCloudBackupIdentityStatus(deviceId, deviceName) };
  } catch (_) {
    return invalidHeader();
  }
}

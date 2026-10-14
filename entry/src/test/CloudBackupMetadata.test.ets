import { describe, it, expect } from '@ohos/hypium';
import {
  BackupCryptoEngine, Base64Codec, CloudBackupCrypto, CloudBackupCryptoMode,
  CloudBackupIdentityStatus, CloudBackupMetadataStatus, CloudBackupTokenHeader, CloudBackupTokenError,
  getCloudBackupIdentityStatus, normalizeCloudBackupDeviceId, normalizeCloudBackupLocation,
  parseCloudBackupHeaderJson
} from 'common';

function validHeader(): CloudBackupTokenHeader {
  return {
    version: 2, mode: CloudBackupCryptoMode.HUAWEI_ACCOUNT,
    salt: 'MDEyMzQ1Njc4OWFiY2RlZg==', iv: 'MDEyMzQ1Njc4OWFiY2RlZg==',
    tokenCount: 0, size: 0, timestamp: 0, deviceId: 'fixture-device', deviceName: 'Fixture Model'
  };
}

/** 只检查注入的解码边界，不调用 LocalUnit 的 Base64Helper/TextDecoder。 */
class HeaderOnlyCodec implements Base64Codec {
  headerJson: string = JSON.stringify(validHeader());
  fail: boolean = false;
  decodeCalls: number = 0;
  encodeText(text: string): string { return text; }
  decodeText(_text: string): string {
    this.decodeCalls++;
    if (this.fail) { throw new Error('synthetic decode failure'); }
    return this.headerJson;
  }
  encodeBytes(_bytes: Uint8Array): string { throw new Error('not used'); }
  decodeBytes(_text: string): Uint8Array { throw new Error('not used'); }
}

class UnusedBackupEngine implements BackupCryptoEngine {
  randomBytes(_length: number): Uint8Array { throw new Error('not used'); }
  async sha256Hex(_text: string): Promise<string> { throw new Error('not used'); }
  async aesCbcEncrypt(_data: Uint8Array, _key: string, _salt: Uint8Array, _iv: Uint8Array): Promise<Uint8Array> {
    throw new Error('not used');
  }
  async aesCbcDecrypt(_data: Uint8Array, _key: string, _salt: Uint8Array, _iv: Uint8Array): Promise<Uint8Array> {
    throw new Error('not used');
  }
}

export default function cloudBackupMetadataTest(): void {
  describe('cloudBackupMetadataTest', () => {
    it('valid_zero_count_is_known_metadata_with_complete_identity', 0, () => {
      const parsed = parseCloudBackupHeaderJson(JSON.stringify(validHeader()));
      expect(parsed.valid).assertTrue();
      expect(parsed.header?.tokenCount).assertEqual(0);
      expect(parsed.header?.timestamp).assertEqual(0);
      expect(parsed.identityStatus).assertEqual(CloudBackupIdentityStatus.COMPLETE);
    });

    it('missing_name_keeps_valid_count_and_device_id', 0, () => {
      const text = JSON.stringify(validHeader()).replace(',"deviceName":"Fixture Model"', '');
      const parsed = parseCloudBackupHeaderJson(text);
      expect(parsed.valid).assertTrue();
      expect(parsed.identityStatus).assertEqual(CloudBackupIdentityStatus.NAME_MISSING);
      expect(parsed.header?.deviceName).assertEqual('');
      expect(parsed.header?.tokenCount).assertEqual(0);
      expect(parsed.header?.deviceId).assertEqual('fixture-device');
    });

    it('missing_null_and_placeholder_identity_never_become_current_device', 0, () => {
      const base = JSON.stringify(validHeader());
      for (const text of [base.replace('"deviceId":"fixture-device",', ''),
        base.replace('"deviceId":"fixture-device"', '"deviceId":null'),
        base.replace('fixture-device', ' unknown_odid '), base.replace('fixture-device', '  ')]) {
        const parsed = parseCloudBackupHeaderJson(text);
        expect(parsed.valid).assertTrue();
        expect(parsed.header?.deviceId).assertEqual('');
        expect(parsed.identityStatus).assertEqual(CloudBackupIdentityStatus.ID_MISSING);
      }
    });

    it('normalizes_identity_whitespace_without_changing_file_protocol', 0, () => {
      const header = validHeader();
      header.deviceId = '  fixture-device  ';
      header.deviceName = '  合成测试设备  ';
      const parsed = parseCloudBackupHeaderJson(JSON.stringify(header));
      expect(parsed.header?.deviceId).assertEqual('fixture-device');
      expect(parsed.header?.deviceName).assertEqual('合成测试设备');
      expect(normalizeCloudBackupDeviceId(' UNKNOWN_ODID ')).assertEqual('');
    });

    it('unknown_name_has_separate_identity_state', 0, () => {
      for (const name of ['', '  ', 'Unknown Device', 'unknown']) {
        expect(getCloudBackupIdentityStatus('fixture-device', name)).assertEqual(CloudBackupIdentityStatus.NAME_MISSING);
      }
      expect(getCloudBackupIdentityStatus('', '')).assertEqual(CloudBackupIdentityStatus.ID_MISSING);
    });

    it('invalid_json_shapes_and_empty_content_are_rejected', 0, () => {
      for (const text of ['', ' ', 'null', '[]', '[{}]', 'true', '3', '"header"', '{}', '{']) {
        expect(parseCloudBackupHeaderJson(text).valid).assertFalse();
      }
      // 空完整本地内容和不可用云内容由读取调用方映射，不在纯解析器中猜测 I/O 状态。
      expect(CloudBackupMetadataStatus.INVALID).assertEqual('INVALID');
      expect(CloudBackupMetadataStatus.READ_FAILED).assertEqual('READ_FAILED');
      expect(CloudBackupMetadataStatus.PENDING).assertEqual('PENDING');
    });

    it('unsupported_version_mode_and_encryption_fields_are_rejected', 0, () => {
      const base = JSON.stringify(validHeader());
      const invalid: string[] = [base.replace('"version":2', '"version":99'),
        base.replace('"version":2', '"version":"2"'), base.replace('"mode":1', '"mode":9'),
        base.replace('"mode":1', '"mode":0'), base.replace('"version":2', '"version":1'),
        base.replace('"salt":"MDEyMzQ1Njc4OWFiY2RlZg=="', '"salt":false'),
        base.replace('"iv":"MDEyMzQ1Njc4OWFiY2RlZg=="', '"iv":"bad"')];
      for (const text of invalid) { expect(parseCloudBackupHeaderJson(text).valid).assertFalse(); }
    });

    it('count_size_timestamp_require_nonnegative_safe_integer_numbers', 0, () => {
      const base = JSON.stringify(validHeader());
      for (const field of ['tokenCount', 'size', 'timestamp']) {
        for (const value of ['-1', '0.5', '"0"', 'null', 'true', '1e400', '9007199254740992']) {
          const text = base.replace(`"${field}":0`, `"${field}":${value}`);
          expect(parseCloudBackupHeaderJson(text).valid).assertFalse();
        }
      }
    });

    it('existing_identity_fields_with_non_string_types_are_invalid', 0, () => {
      const base = JSON.stringify(validHeader());
      expect(parseCloudBackupHeaderJson(base.replace('"fixture-device"', '5')).valid).assertFalse();
      expect(parseCloudBackupHeaderJson(base.replace('"Fixture Model"', '{}')).valid).assertFalse();
    });

    it('legacy_mock_header_remains_readable_with_missing_identity', 0, () => {
      const header = validHeader();
      header.version = 1;
      header.mode = CloudBackupCryptoMode.NONE;
      header.salt = 'mock_salt_fixture';
      header.iv = 'bGVnYWN5LWl2';
      header.deviceId = '';
      header.deviceName = '';
      const parsed = parseCloudBackupHeaderJson(JSON.stringify(header));
      expect(parsed.valid).assertTrue();
      expect(parsed.header?.version).assertEqual(1);
      expect(parsed.identityStatus).assertEqual(CloudBackupIdentityStatus.ID_MISSING);
    });

    it('location_mapping_is_independent_from_metadata_and_sync_success', 0, () => {
      for (const location of [1, 2, 3]) { expect(normalizeCloudBackupLocation(location)).assertEqual(location); }
      for (const location of [0, -1, 4, NaN, Infinity]) { expect(normalizeCloudBackupLocation(location)).assertEqual(0); }
    });

    it('crypto_header_parser_uses_injected_decode_and_runtime_validation', 0, () => {
      const codec = new HeaderOnlyCodec();
      const crypto = CloudBackupCrypto.useEngineForTest(new UnusedBackupEngine(), codec);
      expect(crypto.parseTokenHeader('ZW5jb2RlZA==.payload.signature').deviceId).assertEqual('fixture-device');
      expect(codec.decodeCalls).assertEqual(1);
      codec.headerJson = '{"version":2}';
      let rejected = false;
      try { crypto.parseTokenHeader('ZW5jb2RlZA==.payload.signature'); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
    });

    it('crypto_parser_separates_native_decode_unavailability_from_invalid_encoding', 0, () => {
      for (const empty of [false, true]) {
        const codec = new HeaderOnlyCodec();
        codec.fail = !empty;
        codec.headerJson = '';
        const crypto = CloudBackupCrypto.useEngineForTest(new UnusedBackupEngine(), codec);
        let code = 0;
        try { crypto.parseTokenHeader('ZW5jb2RlZA==.payload.signature'); } catch (error) {
          if (error instanceof CloudBackupTokenError) code = error.code;
        }
        expect(code).assertEqual(3);
        expect(codec.decodeCalls).assertEqual(1);
      }
      const codec = new HeaderOnlyCodec();
      codec.fail = true;
      const crypto = CloudBackupCrypto.useEngineForTest(new UnusedBackupEngine(), codec);
      for (const header of ['*invalid*', 'ZW5jb2RlZA==\n', 'a===', 'abc']) {
        let code = 0;
        try { crypto.parseTokenHeader(`${header}.payload.signature`); } catch (error) {
          if (error instanceof CloudBackupTokenError) code = error.code;
        }
        expect(code).assertEqual(1);
      }
      expect(codec.decodeCalls).assertEqual(0);
    });

    it('crypto_parser_rejects_decode_failure_and_empty_segments', 0, () => {
      const codec = new HeaderOnlyCodec();
      const crypto = CloudBackupCrypto.useEngineForTest(new UnusedBackupEngine(), codec);
      codec.fail = true;
      for (const token of ['ZW5jb2RlZA==.payload.signature', '.payload.signature', 'encoded..signature', 'encoded.payload.']) {
        let rejected = false;
        try { crypto.parseTokenHeader(token); } catch (_) { rejected = true; }
        expect(rejected).assertTrue();
      }
    });
  });
}

import { describe, it, expect, afterEach } from '@ohos/hypium';
import {
  base32Encode, decodeLocalBackupBase32, identifyLocalBackup, LocalBackupKind, LocalBackupSource,
  parseLocalBackupPayload, PreparedLocalBackup, TokenGroup, TokenGroupStore, useCryptoEngineForTest,
  resetCryptoEngineForTest, encodeLocalBackup, TokenBackup
} from 'common';
import {
  legacyLocalBackupText, LocalBackupCryptoFake, localBackupPayload, localBackupText, localBackupToken
} from './fakes/LocalBackupFakes';

export default function localBackupFormatTest(): void {
  describe('LocalBackupFormatTest', () => {
    afterEach(() => { resetCryptoEngineForTest(); });

    it('content_wins_over_name_and_accepts_layout_whitespace', 0, () => {
      const text = localBackupText();
      expect(identifyLocalBackup(text, 'renamed.bak').kind).assertEqual(LocalBackupKind.PLAIN);
      const formatted = '\uFEFF' + text.toLowerCase().match(/.{1,7}/g)!.join(' -\r\n');
      expect(identifyLocalBackup(formatted, 'renamed.txt').kind).assertEqual(LocalBackupKind.PLAIN);
    });

    it('migration_unknown_and_cloud_formats_do_not_fall_back', 0, () => {
      expect(identifyLocalBackup(' otpauth://totp/synthetic?secret=X\nunknown', 'x.bak').kind).assertEqual(LocalBackupKind.MIGRATION);
      for (const version of [0, 1, 3, 99]) {
        const frame = new Uint8Array(64);
        frame.set([79, 84, 80, version]);
        expect(identifyLocalBackup(base32Encode(frame), 'x.bak').kind).assertEqual(LocalBackupKind.UNSUPPORTED);
      }
      expect(identifyLocalBackup(base32Encode(new Uint8Array([79, 84, 80, 2])), 'x.bak').kind).assertEqual(LocalBackupKind.UNSUPPORTED);
      expect(identifyLocalBackup('header.cipher.tag', 'x.bak').kind).assertEqual(LocalBackupKind.UNSUPPORTED);
      expect(identifyLocalBackup('!!', 'x.bak').kind).assertEqual(LocalBackupKind.UNSUPPORTED);
      expect(identifyLocalBackup(base32Encode(new Uint8Array(16)), 'x.json').kind).assertEqual(LocalBackupKind.UNSUPPORTED);
      expect(identifyLocalBackup(base32Encode(new Uint8Array(16)), 'x.BAK').kind).assertEqual(LocalBackupKind.LEGACY_CANDIDATE);
    });

    it('legacy_ciphertext_starting_with_json_punctuation_remains_candidate', 0, () => {
      for (const first of [123, 91]) {
        const bytes = new Uint8Array(32);
        bytes.fill(255);
        bytes[0] = first;
        expect(identifyLocalBackup(base32Encode(bytes), 'synthetic.bak').kind).assertEqual(LocalBackupKind.LEGACY_CANDIDATE);
        expect(identifyLocalBackup(base32Encode(bytes), 'synthetic.json').kind).assertEqual(LocalBackupKind.UNSUPPORTED);
      }
    });

    it('rejects_noncanonical_base32_without_changing_secret_decoder', 0, () => {
      for (const text of ['A', 'AAA', 'AAAAAA', 'MZ======', 'MY=====', 'MY======!', 'MY=AA']) {
        let failed = false;
        try { decodeLocalBackupBase32(text); } catch (_) { failed = true; }
        expect(failed).assertTrue();
      }
      expect(decodeLocalBackupBase32('MY').length).assertEqual(1);
    });

    it('all_types_optional_fields_groups_and_duplicate_semantics', 0, () => {
      const payload = localBackupPayload();
      payload.configs[0].TokenFavorite = true;
      const duplicate = localBackupToken('totp');
      duplicate.TokenName = 'last';
      payload.configs.push(duplicate);
      payload.groups.push(new TokenGroup('__all__', 'ignored'));
      payload.groups.push(new TokenGroup('synthetic-group', 'ignored duplicate'));
      const parsed = parseLocalBackupPayload(JSON.stringify(payload));
      expect(parsed.configs.length).assertEqual(4);
      expect(parsed.configs[0].TokenName).assertEqual('last');
      expect(parsed.configs[0].TokenFavorite).assertTrue();
      expect(parsed.groups.length).assertEqual(1);
      expect(parsed.groups[0].name).assertEqual('合成分组');
      expect(parsed.groups[0].color).assertEqual(0xFFFFFFFF);
      const historical = JSON.stringify(payload).replace(/,"TokenGroupId":""/g, '')
        .replace(/,"TokenFavorite":(?:true|false)/g, '').replace(/,"TokenExternalCode":""/g, '');
      expect(parseLocalBackupPayload(historical).configs[0].TokenFavorite).assertFalse();
    });

    it('pre_uuid_historical_backup_generates_identifiers_once_in_private_snapshot', 0, () => {
      const text = JSON.stringify(localBackupPayload()).replace(/"TokenUUID":"[^"]+",?/g, '');
      let generated = 0;
      const prepared = PreparedLocalBackup.fromText(text, false, () => `synthetic-generated-${++generated}`);
      expect(prepared.tokenCount).assertEqual(4);
      expect(generated).assertEqual(4);
      expect(prepared.takeForCommit().configs[0].TokenUUID).assertEqual('synthetic-generated-1');
      expect(generated).assertEqual(4);
      let rejected = false;
      try { parseLocalBackupPayload(text, () => ''); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
      rejected = false;
      try { parseLocalBackupPayload(text, () => 'collision'); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
    });

    it('any_invalid_token_or_group_rejects_whole_payload', 0, () => {
      const json = JSON.stringify(localBackupPayload());
      const invalid = [json.replace('"TokenSecret":"JBSWY3DPEHPK3PXP"', '"TokenSecret":42'),
        json.replace('"TokenType":0', '"TokenType":4'),
        json.replace('"TokenPeriod":30', '"TokenPeriod":0'),
        json.replace('"TokenFavorite":false', '"TokenFavorite":"yes"'),
        json.replace('"name":" 合成分组 "', '"name":false'),
        json.replace('"TokenCounter":0', '"TokenCounter":-1'),
        json.replace('"TokenGroupId":""', '"TokenGroupId":[]')];
      for (const text of invalid) {
        let failed = false;
        try { parseLocalBackupPayload(text); } catch (_) { failed = true; }
        expect(failed).assertTrue();
      }
    });

    it('v2_renamed_and_v0_original_extension_prepare_with_original_password', 0, async () => {
      const engine = new LocalBackupCryptoFake();
      useCryptoEngineForTest(engine);
      TokenGroupStore.getInstance().state.groups = [];
      const backup = new TokenBackup(1, [localBackupToken()]);
      const v2 = await encodeLocalBackup(backup, true, 'synthetic-password');
      const source = new LocalBackupSource(v2, 'renamed.txt');
      expect(source.kind).assertEqual(LocalBackupKind.PASSWORD_V2);
      expect((await source.prepare('synthetic-password')).tokenCount).assertEqual(1);
      const legacy = await legacyLocalBackupText(engine, JSON.stringify(backup), 'old');
      expect((await new LocalBackupSource(legacy, 'old.bak').prepare('old')).tokenCount).assertEqual(1);
      let wrong = false;
      try { await source.prepare('wrong'); } catch (_) { wrong = true; }
      expect(wrong).assertTrue();
      source.dispose();
    });

    it('snapshot_is_private_single_use_and_source_mutations_cannot_change_it', 0, () => {
      const payload = localBackupPayload();
      const prepared = PreparedLocalBackup.fromText(JSON.stringify(payload));
      payload.configs[0].TokenName = 'modified-after-prepare';
      expect(prepared.takeForCommit().configs[0].TokenName).assertEqual('Synthetic account');
      let failed = false;
      try { prepared.takeForCommit(); } catch (_) { failed = true; }
      expect(failed).assertTrue();
    });
  });
}

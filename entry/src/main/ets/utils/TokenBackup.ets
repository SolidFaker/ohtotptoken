import { readFileContent, writeFileContent,writeFileContentCheckHashEqual } from "./FileUtils";
import { TokenConfig } from "./TokenConfig";
import { base32Decode, base32Encode, intArrayToString, stringToIntArray } from "./TokenUtils";
import { decryptFile, encryptFile } from "./CryptoUtils";
import { JSON } from "@kit.ArkTS";
import { promptAction } from "@kit.ArkUI";
import { fileUri } from "@kit.CoreFileKit";

const TOKEN_BACKUP_MAGIC = 0x55aaeebb;

export class TokenBackup {
  magic: number;
  version: number;
  configs: Array<TokenConfig>;

  constructor(version: number, configs: Array<TokenConfig>) {
    this.magic = TOKEN_BACKUP_MAGIC;
    this.version = version;
    this.configs = configs;
  }
}

export async function saveBackupToFile(file_uri: string, backup: TokenBackup, do_encrypt: boolean = false, password: string = ''): Promise<void> {
  const backup_json = JSON.stringify(backup);
  const backup_raw = do_encrypt ? await encryptFile(backup_json, password) : stringToIntArray(backup_json);
  const b32_encoded = base32Encode(backup_raw);
  await writeFileContentCheckHashEqual(file_uri, b32_encoded);
}

export async function restoreFromBackup(file_uri: string, is_encrypt: boolean = false, password: string = ''): Promise<TokenBackup> {
  const file_content = await readFileContent(file_uri);
  const b32_decoded = base32Decode(file_content);
  const backup_string = is_encrypt ? await decryptFile(b32_decoded, password) : intArrayToString(b32_decoded.buffer as ArrayBuffer);
  const backup: TokenBackup = JSON.parse(backup_string) as TokenBackup;
  return new Promise((resolve, reject) => {
    if (backup.magic === TOKEN_BACKUP_MAGIC) {
      resolve(backup)
    } else {
      reject('invalid backup file')
    }
  });
}

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, HashMap, HashSet, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { otpType, TokenConfig } from './TokenConfig';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { readFileContent } from './FileUtils';
import { fileIo } from '@kit.CoreFileKit';
import { AppPreference } from './AppPreference';

const RFC4648 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const RFC4648_HEX = '0123456789ABCDEFGHIJKLMNOPQRSTUV';
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

export type Base32Variant = 'RFC3548' | 'RFC4648' | 'RFC4648-HEX' | 'Crockford';

export type HMACAlgorithm = 'SHA1' | 'SHA224' | 'SHA256' | 'SHA384' | 'SHA512' | 'SM3' | 'MD5';

function readChar(alphabet: string, char: string): number {
  const idx = alphabet.indexOf(char);

  if (idx === -1) {
    throw new Error('Invalid character found: ' + char);
  }

  return idx;
}

function genSymKeyByData(symKeyData: Uint8Array) {
  let symKeyBlob: cryptoFramework.DataBlob = { data: symKeyData };
  let aesGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
  let symKey = aesGenerator.convertKeySync(symKeyBlob);
  return symKey;
}

function doHmacBySync(steps: number, algorithm: HMACAlgorithm, message: string): Uint8Array {
  const byteLen = 8;
  let byteArray = new Uint8Array(byteLen);
  let tmp = steps; // wired TS feature
  for (let i = 0; i < byteLen; i++) {
    byteArray[byteLen - i-1] = tmp & 0xff;
    tmp = tmp >> 8;
  }
  let key = genSymKeyByData(base32Decode(message));
  let mac = cryptoFramework.createMac(algorithm);
  mac.initSync(key);
  mac.updateSync({ data: byteArray });
  let macResult = mac.doFinalSync();
  return macResult.data;
}

export async function ScanBarCode(): Promise<string> {
  if (canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
    if (canIUse('SystemCapability.Multimedia.Scan.Core')) {
      let options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: true,
        enableAlbum: true
      };
      let context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
      return scanBarcode.startScanForResult(context, options).then((result: scanBarcode.ScanResult) => {
        return result.originalValue;
      });
    }
  }
  return '';
}

export function generateOTP(conf: TokenConfig, steps: number): number {
  try {
    let hash = doHmacBySync(steps, conf.TokenAlgorithm, conf.TokenSecret);
    const offset = hash[hash.length - 1] & 0xF;
    let truncatedHash = 0;
    for (let i = 0; i < 4; i++) {
      truncatedHash <<= 8;
      truncatedHash |= hash[offset + i];
    }
    truncatedHash &= 0x7FFFFFFF;
    return truncatedHash % Math.pow(10, conf.TokenDigits);
  } catch (err) {
    return 0;
  }
}

export function convertToken2URI(conf: TokenConfig): string {
  let prefix = 'otpauth://';
  let otp_type = conf.TokenType == otpType.HOTP ? 'hotp' : 'totp';
  let label = conf.TokenIssuer + ':' + conf.TokenName;
  let period_or_counter = conf.TokenType == otpType.HOTP ? ('&counter=' + conf.TokenCounter) : ('&period=' + conf.TokenPeriod);
  return prefix + otp_type + '/' + label + '?'
    + 'secret=' + conf.TokenSecret + '&issuer=' + conf.TokenIssuer
    + '&digits=' + conf.TokenDigits
    + period_or_counter;
}

export function generateFileNameWithDate(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0'); // 月份从0开始，所以加1
  const day = String(now.getDate()).padStart(2, '0');
  const hours = String(now.getHours()).padStart(2, '0');
  const minutes = String(now.getMinutes()).padStart(2, '0');
  const seconds = String(now.getSeconds()).padStart(2, '0');

  const fileName = `${year}${month}${day}${hours}${minutes}${seconds}`;
  return fileName;
}

export function intArrayToString(input: ArrayBuffer): string {
  return buffer.from(input).toString()
}

export function stringToIntArray(input: string): Uint8Array {
  // 原写法会导致数据中有中文（或其他由多字节编码的字符）时，截断
  // return Uint8Array.from(input, c => c.charCodeAt(0))
  return new Uint8Array(buffer.from(input).buffer)
}
/**
 * 字符串转字符数组
 *
 */
export function stringToArray(input: string): Uint8Array {
  return new Uint8Array(buffer.from(input, 'utf-8').buffer);
}

export function base32Encode(
  input: Uint8Array,
  variant: Base32Variant = 'RFC4648',
): string {
  let alphabet: string;
  let defaultPadding: boolean;

  switch (variant) {
    case 'RFC3548':
    case 'RFC4648':
      alphabet = RFC4648;
      defaultPadding = true;
      break;
    case 'RFC4648-HEX':
      alphabet = RFC4648_HEX;
      defaultPadding = true;
      break;
    case 'Crockford':
      alphabet = CROCKFORD;
      defaultPadding = false;
      break;
  // eslint-disable-next-line @typescript-eslint/switch-exhaustiveness-check
    default:
      throw new Error(`Unknown base32 variant: ${variant as string}`);
  }

  const padding = defaultPadding;
  const length = input.byteLength;
  const view = new Uint8Array(input);

  let bits = 0;
  let value = 0;
  let output = '';

  for (let i = 0; i < length; i++) {
    value = (value << 8) | view[i]!;
    bits += 8;

    while (bits >= 5) {
      output += alphabet[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }

  if (bits > 0) {
    output += alphabet[(value << (5 - bits)) & 31];
  }

  if (padding) {
    while (output.length % 8 !== 0) {
      output += '=';
    }
  }

  return output;
}

export function base32Decode(input: string, variant: Base32Variant = 'RFC4648'): Uint8Array {
  let alphabet: string;
  let cleanedInput: string;

  switch (variant) {
    case 'RFC3548':
    case 'RFC4648':
      alphabet = RFC4648;
      cleanedInput = input.toUpperCase().replace(/=+$/, '');
      break;
    case 'RFC4648-HEX':
      alphabet = RFC4648_HEX;
      cleanedInput = input.toUpperCase().replace(/=+$/, '');
      break;
    case 'Crockford':
      alphabet = CROCKFORD;
      cleanedInput = input.toUpperCase().replace(/O/g, '0').replace(/[IL]/g, '1');
      break;
  // eslint-disable-next-line @typescript-eslint/switch-exhaustiveness-check
    default:
      throw new Error(`Unknown base32 variant: ${variant as string}`);
  }

  const length = cleanedInput.length;

  let bits = 0;
  let value = 0;

  let index = 0;
  const output = new Uint8Array(((length * 5) / 8) | 0);

  for (let i = 0; i < length; i++) {
    value = (value << 5) | readChar(alphabet, cleanedInput[i]!);
    bits += 5;

    if (bits >= 8) {
      output[index++] = (value >>> (bits - 8)) & 255;
      bits -= 8;
    }
  }

  return output;
}

export function copyText(text: string, msg: string = '') {
  const pasteboardData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  const systemPasteboard = pasteboard.getSystemPasteboard();
  systemPasteboard.setData(pasteboardData);
  if (msg !== undefined && msg !== '') {
    promptAction.showToast({ message: msg });
  }
}

export class OTPDefaultIconPack {
  public name: string = "Default";
  public issuers: Array<string> =
    ['1and1', '1password', '23andme', 'adafruit', 'adguard', 'adobe', 'airbnb', 'airbrake', 'airtable', 'allegropl',
      'alwaysdata', 'amazon', 'amazonwebservices', 'angellist', 'animebytes', 'anonaddy', 'apache', 'apple', 'appveyor',
      'arenanet', 'atlantic_net', 'atlassian', 'avm', 'backblaze', 'battlenet', 'betterment', 'binance', 'bitbucket',
      'bitcoin', 'bitdefender', 'bitfinex', 'bitmex', 'bitpanda', 'bitstamp', 'bittrex', 'bitwala', 'bitwarden',
      'blockchain_info', 'bugcrowd', 'cexio', 'church_tools', 'cisco', 'cloudflare', 'cloud_download', 'cobranded',
      'codegiant', 'coinbase', 'coinjar', 'computerbase', 'connectwise_manage', 'cozycloud', 'crowdin', 'dashlane',
      'debian', 'degiro', 'denic', 'deutsche_bahn', 'diaspora', 'digidentity', 'digital_ocean', 'discord', 'discourse',
      'disroot', 'docker', 'docusign', 'dreamhost', 'dropbox', 'drupal', 'electronic_arts', 'email', 'epic_games', 'etsy',
      'eveonline', 'evernote', 'facebook', 'faceit', 'fanatical', 'fastmail', 'figma', 'fingerprint', 'finnair',
      'firefox', 'flight_takeoff', 'floatplane', 'forti', 'friendica', 'fritz', 'gamepad', 'gandi', 'git', 'gitea', 'github',
      'gitlab', 'gmx', 'godaddy', 'gogs', 'google', 'govuk', 'grav', 'greenhost', 'hackerone', 'heroku', 'hetzner',
      'hitbtc', 'hmrc', 'home_assistant', 'hover', 'humblebundle', 'hurricane_electric', 'ibm', 'iconomi', 'ifttt', 'ing',
      'instagram', 'inwx', 'itchio', 'jagex', 'jetbrains', 'joomla', 'keeper', 'kickstarter', 'kraken', 'kucoin',
      'lastpass', 'librenms', 'lichess', 'linkedin', 'linode', 'liqui', 'livelyme', 'lobsters', 'localbitcoins',
      'localmonero', 'login_gov', 'logmein', 'mailbox', 'mailchimp', 'mailcow', 'mailgun', 'mailru', 'mapbox', 'mastodon',
      'matomo', 'mega', 'mercadolibre', 'microsoft', 'microsoft_teams', 'migadu', 'miles_and_more', 'mint', 'miraheze',
      'mixer', 'mongodb', 'mvpsnet', 'namecheap', 'namecom', 'nas', 'netcup', 'nextcloud', 'nintendo', 'no_starch_press',
      'npm', 'oculus', 'office', 'okta', 'online', 'openvz', 'opnsense', 'orcid', 'origin', 'ovh', 'packet',
      'parsecgaming', 'passwordstate', 'patreon', 'paypal', 'paysafecard', 'paywithprivacy', 'pcloud', 'phabricator',
      'phpmyadmin', 'pluralsight', 'plurk', 'posteo', 'pretix', 'prey', 'private_internet_access', 'protonmail',
      'proxmox', 'pushover', 'pypi', 'python_anywhere', 'rackspace', 'reddit', 'revolt', 'ripe_ncc', 'ripio', 'robinhood',
      'rocketbeanstv', 'rockstar', 'rss', 'sap', 'scaleway', 'school', 'sciebo', 'sentry', 'sevdesk', 'skrill', 'slack',
      'snapchat', 'sophos', 'sourceforge', 'squarespace', 'standardnotes', 'starcitizen', 'steam', 'stripe', 'sync',
      'synology', 'teahub', 'teamviewer', 'terminal', 'tencent_cloud_services', 'todoalojamiento', 'transip', 'trello',
      'tumblr', 'turbotax', 'tutanota', 'tuwien_ac_at', 'twilio', 'twitch', 'twitter', 'uber', 'ubisoft', 'ubnt',
      'ubuntu_one', 'unity', 'uphold', 'usaa', 'vagrant_cloud', 'vexxhost', 'vk', 'vultr', 'wallabag', 'wallet',
      'wargaming', 'wasabi', 'weclapp', 'wikimedia', 'wordpress', 'workplace', 'xero', 'xerox', 'xing', 'yandex_money',
      'zapier', 'zendesk', 'zoho', 'zoom', 'feishu'];

  private default_icon_pack_set: HashSet<string> = new HashSet();

  public default_icon_pack_path: HashSet<string> = new HashSet();

  public getIconPathByIssuer(issuer: string): string {
    const normal_issuer = issuer.toLowerCase().replaceAll(' ', '_');
    if (this.default_icon_pack_set.has(normal_issuer)) {
      return 'rawfile://icons/token_image_' + normal_issuer + '.svg';
    }
    return '';
  }

  public constructor() {
    for (let issuer of this.issuers) {
      this.default_icon_pack_set.add(issuer);
      this.default_icon_pack_path.add('rawfile://icons/token_image_' + issuer.toLowerCase() + '.svg');
    }
  }
}

export class UserAddedIconPack {
  public name: string = "User Added";
  public user_icon_path: string = '';
  public icon_path: string[] = [];
  public latest_icon_path: string = '';

  public initIconPack(path: string): void {
    this.user_icon_path = path;
    if (fs.accessSync(path) === false) {
      fs.mkdirSync(path);
    }
    fs.listFile(path).then((files) => {
      files.forEach((file) => {
        this.icon_path.push("file://" + this.user_icon_path + "/" + file);
      })
    });
  }

  public addIcon(file: fileIo.File): void {
    this.latest_icon_path = "file://" + this.user_icon_path + "/" + file.name;
    this.icon_path.push(this.latest_icon_path);
    fs.copyFileSync(file.fd, this.user_icon_path + "/" + file.name);
  }

  public removeIcon(path: string): void {
    this.icon_path = this.icon_path.filter(_ => _ !== path);
    fs.unlink(path.slice(7));
  }

  public constructor() {}
}

export class TokenIconPacks {
  public static default_icon_pack: OTPDefaultIconPack = new OTPDefaultIconPack();
  public static aegis_icon_packs: AegisIconPack[] = [];
  public static user_added_icon_packs: UserAddedIconPack = new UserAddedIconPack();
  public static selected_icon_pack: number = AppPreference.getPreference('app_appearance_icon_pack_selected') as number ?? 0;

  public static async addUserIconPack(path: string): Promise<void> {
    TokenIconPacks.user_added_icon_packs.initIconPack(path);
  }

  public static async addAegisIconPack(path: string): Promise<void> {
    const icon_path_json = path + "/pack.json";
    if (!fileIo.accessSync(icon_path_json)) {
      promptAction.showToast({ message: $r('app.string.toast_icon_pack_invalid') });
      return Promise.reject(new Error("invalid aegis icon pack"));
    }
    if (TokenIconPacks.aegis_icon_packs.filter(pack => pack.on_device_path === path).length > 0) {
      promptAction.showToast({ message: $r('app.string.toast_icon_pack_already_installed') });
      return;
    }
    return readFileContent(icon_path_json).then((val) => {
      let pack: AegisIconPack = new AegisIconPack();
      const tmp = JSON.parse(val) as AegisIconPack;
      pack.uuid = tmp.uuid;
      pack.name = tmp.name ?? 'invalid';
      pack.version = tmp.version ?? 0;
      pack.icons = tmp.icons ?? [];
      pack.on_device_path = path;
      pack.buildUpHashMap();
      TokenIconPacks.aegis_icon_packs.push(pack);

    })
  }

  public static async removeAegisIconPack(icon_pack: AegisIconPack): Promise<void> {
    TokenIconPacks.aegis_icon_packs = TokenIconPacks.aegis_icon_packs.filter(pack => pack.on_device_path !== icon_pack.on_device_path);
    return fileIo.rmdir(icon_pack.on_device_path);
  }

  public static getIconByIssuer(issuer: string): string {
    if (TokenIconPacks.selected_icon_pack === 0) {
      const icon_path = TokenIconPacks.default_icon_pack.getIconPathByIssuer(issuer);
      return icon_path;
    } else {
      const index = (TokenIconPacks.selected_icon_pack - 1) % TokenIconPacks.aegis_icon_packs.length;
      if (TokenIconPacks.aegis_icon_packs.length === 0) {
        return '';
      }
      const icon_path = TokenIconPacks.aegis_icon_packs[index].getIconPathByIssuer(issuer);
      return icon_path;
    }
  }
}

export class AegisIcon {
  public filename: string = '';
  public category: string = '';
  public issuer: string[] = [];
  public icon_pack_path: HashSet<string> = new HashSet();
}

export class AegisIconPack {
  public on_device_path: string = '';
  public uuid: string = '';
  public name: string = '';
  public version: number = 0;
  public icons: AegisIcon[] = [];

  private aegis_icon_pack_set: HashMap<string, string> = new HashMap();

  public buildUpHashMap(): void {
    for (let i = 0; i < this.icons.length; i++) {
      this.icons[i].icon_pack_path = new HashSet();
      for (let issuer of this.icons[i].issuer) {
        this.aegis_icon_pack_set.set(issuer.toLowerCase(), this.icons[i].filename);
        this.icons[i].icon_pack_path.add('file://' + this.on_device_path + "/" + this.icons[i].filename);
      }
    }
  }

  public getIconPathByIssuer(issuer: string): string {
    const key = issuer.toLowerCase();
    if (this.aegis_icon_pack_set.hasKey(key)) {
      return 'file://' + this.on_device_path + "/" + this.aegis_icon_pack_set.get(key);
    }
    return '';
  }

  public constructor() {
  }

}

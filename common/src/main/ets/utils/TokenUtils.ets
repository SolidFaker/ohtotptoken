import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, HashMap, HashSet, taskpool, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { otpType, TokenConfig } from './TokenConfig';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { readFileContent } from './FileUtils';
import { fileIo } from '@kit.CoreFileKit';
import { AppPreference, EVENT_NAMES, BUILTIN_DEFAULT_PACK_ID } from './AppPreference';
import { showSnackBar, SnackBarNotifyType } from './SnackBar';
import { generateIconThumbnails } from './IconThumbnailTask';

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

/**
 * HOTP 计数器 → 8 字节大端。
 *
 * 旧实现用 `tmp >> 8`（有符号 32 位右移），counter > 2^31 时高位变成 0xFF，
 * 与卡片端 `setUint32` 截断低 32 位得到的结果各不相同，且都不符合 RFC 4226。
 */
export function counterToBytes64(counter: number): Uint8Array {
  const byteLen = 8;
  const byteArray = new Uint8Array(byteLen);
  let value: bigint = BigInt(Math.floor(counter)) & 0xffffffffffffffffn;
  for (let i = byteLen - 1; i >= 0; i--) {
    byteArray[i] = Number(value & 0xffn);
    value = value >> 8n;
  }
  return byteArray;
}

function doHmacBySync(steps: number, algorithm: HMACAlgorithm, message: string): Uint8Array {
  let byteArray = counterToBytes64(steps);
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
      // context 必须调用时现取:模块顶层捕获时 AppStorage 尚未注入 appContext
      const appCtx = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!appCtx) {
        throw new Error('appContext not ready');
      }
      let options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: true,
        enableAlbum: true
      };
      return scanBarcode.startScanForResult(appCtx, options).then((result: scanBarcode.ScanResult) => {
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

export function base32Encode(
  input: Uint8Array|null|undefined,
  variant: Base32Variant = 'RFC4648',
): string {
  if (input===null||input===undefined) {
    return "";
  }
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

  // 与卡片端 CardOTPUtils.base32Decode 保持一致：
  // 容忍粘贴带入的空格/连字符，并跳过不在字母表内的字符。
  // 此前对非法字符直接抛错，导致 generateOTP 返回 0、界面显示 000000，
  // 而同一 secret 在桌面卡片上却能出码（两端行为不一致）。
  let filtered = '';
  for (let i = 0; i < cleanedInput.length; i++) {
    const ch = cleanedInput.charAt(i);
    if (ch !== ' ' && ch !== '-' && alphabet.indexOf(ch) >= 0) {
      filtered += ch;
    }
  }

  const length = filtered.length;

  let bits = 0;
  let value = 0;

  let index = 0;
  const output = new Uint8Array(((length * 5) / 8) | 0);

  for (let i = 0; i < length; i++) {
    value = (value << 5) | readChar(alphabet, filtered[i]!);
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
    showSnackBar(msg, SnackBarNotifyType.INFO);
  }
}

export class OTPDefaultIconPack {
  public name: string = "Default";
  public issuers: Array<string> =
    ['1and1', '1password', '23andme', 'adafruit', 'adguard', 'adobe', 'airbnb', 'airbrake', 'airtable', 'allegropl',
      'alwaysdata', 'amazon', 'amazonwebservices', 'angellist', 'animebytes', 'anonaddy', 'apache', 'apple', 'appveyor',
      'arenanet', 'atlantic_net', 'atlassian', 'avm', 'backblaze', 'battlenet', 'betterment', 'binance', 'bitbucket',
      'bitcoin', 'bitdefender', 'bitfinex', 'bitmex', 'bitpanda', 'bitstamp', 'bittrex', 'bitwala', 'bitwarden',
      'blockchain_info', 'bugcrowd', 'cadence', 'cexio', 'church_tools', 'cisco', 'cloudflare', 'cloud_download', 'cobranded',
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
      'zapier', 'zendesk', 'zoho', 'zoom', 'feishu', 'nexus_mods'];

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
  public name: string = '';
  public user_icon_path: string = '';
  public icon_path: string[] = [];
  public latest_icon_path: string = '';
  public raster_icons: Set<string> = new Set();

  private ensureName(): void {
    if (this.name === '') {
      const ctx = AppStorage.get<common.UIAbilityContext>('appContext');
      if (ctx) {
        this.name = ctx.resourceManager.getStringSync($r('app.string.dialog_icon_select_custom').id);
      }
    }
  }

  private isRasterFile(path: string): boolean {
    const lower = path.toLowerCase();
    return !lower.endsWith('.svg');
  }

  public async initIconPack(path: string): Promise<void> {
    this.ensureName();
    this.user_icon_path = path;
    if (fs.accessSync(path) === false) {
      fs.mkdirSync(path);
    }

    this.icon_path = [];
    this.raster_icons.clear();
    const files = await fs.listFile(path);
    for (const file of files) {
      const localPath = this.user_icon_path + "/" + file;
      if (!fs.statSync(localPath).isFile()) {
        continue;
      }
      const fullPath = "file://" + localPath;
      this.icon_path.push(fullPath);
      if (this.isRasterFile(file)) {
        this.raster_icons.add(fullPath);
      }
    }
  }

  public addIcon(file: fileIo.File): void {
    this.latest_icon_path = "file://" + this.user_icon_path + "/" + file.name;
    this.icon_path.push(this.latest_icon_path);
    if (this.isRasterFile(file.name)) {
      this.raster_icons.add(this.latest_icon_path);
    }
    fs.copyFileSync(file.fd, this.user_icon_path + "/" + file.name);
  }

  /**
   * 通过路径添加已复制的图标（用于裁剪后的图标和直接复制的小图标）
   * 与 addIcon(fileIo.File) 不同，此方法跳过文件复制，直接注册路径
   * @param iconPath 已存在于用户图标目录的文件路径（file://前缀）
   */
  public addIconByPath(iconPath: string): void {
    this.latest_icon_path = iconPath;
    if (this.icon_path.findIndex(_ => _ === iconPath) < 0) {
      this.icon_path.push(iconPath);
    }
    if (this.isRasterFile(iconPath)) {
      this.raster_icons.add(iconPath);
    }
  }

  public removeIcon(path: string): void {
    this.icon_path = this.icon_path.filter(_ => _ !== path);
    this.raster_icons.delete(path);
    fs.unlink(path.slice(7));
  }

  public constructor() {}
}

export class TokenIconPacks {
  public static default_icon_pack: OTPDefaultIconPack = new OTPDefaultIconPack();
  public static aegis_icon_packs: AegisIconPack[] = [];
  public static user_added_icon_packs: UserAddedIconPack = new UserAddedIconPack();
  public static enabled_packs: string[] = [BUILTIN_DEFAULT_PACK_ID];
  private static packByUuid: Map<string, AegisIconPack> = new Map();
  private static pickerPreviewPathBySource: Map<string, string> = new Map();

  public static getPickerPreviewPath(path: string): string {
    const builtInPrefix = 'rawfile://icons/';
    if (path.startsWith(builtInPrefix) && path.toLowerCase().endsWith('.svg')) {
      const fileName = path.slice(builtInPrefix.length, -4);
      // cadence 仅提供 SVG 原图，没有对应的内置 PNG 缩略图。
      if (fileName === 'token_image_cadence') {
        return path;
      }
      return `rawfile://icon_thumbnails/${fileName}.png`;
    }
    return TokenIconPacks.pickerPreviewPathBySource.get(path) ?? path;
  }

  public static async preparePickerPreviewPaths(paths: string[]): Promise<void> {
    const sourcePaths: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (const path of paths) {
      if (path.startsWith('file://') && !seen.has(path)) {
        seen.add(path);
        sourcePaths.push(path);
      }
    }
    if (sourcePaths.length === 0) {
      return;
    }

    const ctx = AppStorage.get<common.UIAbilityContext>('appContext');
    if (!ctx) {
      return;
    }
    const cacheDir = ctx.filesDir + '/icon_thumbnails';
    try {
      const previewPaths = await taskpool.execute(generateIconThumbnails, sourcePaths, cacheDir) as string[];
      for (let index = 0; index < sourcePaths.length; index++) {
        const previewPath = previewPaths[index];
        if (previewPath) {
          TokenIconPacks.pickerPreviewPathBySource.set(sourcePaths[index], previewPath);
        }
      }
    } catch (_) {
      // Keep the original paths as a functional fallback when thumbnail generation fails.
    }
  }

  public static removePickerPreviewPath(path: string): void {
    const previewPath = TokenIconPacks.pickerPreviewPathBySource.get(path);
    TokenIconPacks.pickerPreviewPathBySource.delete(path);
    if (previewPath?.startsWith('file://')) {
      const localPath = previewPath.slice(7);
      if (fileIo.accessSync(localPath)) {
        fileIo.unlink(localPath).catch(() => {});
      }
    }
  }

  private static rebuildPackMap(): void {
    TokenIconPacks.packByUuid.clear();
    for (const pack of TokenIconPacks.aegis_icon_packs) {
      if (pack.uuid) {
        TokenIconPacks.packByUuid.set(pack.uuid, pack);
      }
    }
  }

  public static async addUserIconPack(path: string): Promise<void> {
    await TokenIconPacks.user_added_icon_packs.initIconPack(path);
    await TokenIconPacks.preparePickerPreviewPaths(TokenIconPacks.user_added_icon_packs.icon_path);
  }

  public static async addAegisIconPack(path: string): Promise<void> {
    const icon_path_json = path + "/pack.json";
    if (!fileIo.accessSync(icon_path_json)) {
      let pack: AegisIconPack = new AegisIconPack();
      pack.invalid = true;
      pack.on_device_path = path;
      TokenIconPacks.aegis_icon_packs.push(pack);
      TokenIconPacks.rebuildPackMap();
      return;
    }
    if (TokenIconPacks.aegis_icon_packs.some(pack => pack.on_device_path === path)) {
      showSnackBar($r('app.string.toast_icon_pack_already_installed'), SnackBarNotifyType.WARNING);
      return;
    }
    return readFileContent(icon_path_json).then((val) => {
      let pack: AegisIconPack = new AegisIconPack();
      const tmp = JSON.parse(val) as AegisIconPack;
      if (!tmp || !tmp.name) {
        throw new Error('Invalid icon pack JSON');
      }
      const fallbackUuid = `${tmp.name ?? 'pack'}_${path.split('/').pop()}`;
      const rawUuid = String(tmp.uuid ?? fallbackUuid);
      pack.uuid = rawUuid.startsWith('__builtin_') ? 'ext_' + rawUuid : rawUuid;
      pack.name = tmp.name ?? 'invalid';
      pack.version = tmp.version ?? 0;
      pack.icons = tmp.icons ?? [];
      pack.on_device_path = path;
      pack.buildUpHashMap();
      TokenIconPacks.aegis_icon_packs.push(pack);
      TokenIconPacks.rebuildPackMap();
      const previewPaths: string[] = [];
      for (const icon of pack.icons) {
        for (const iconPath of icon.icon_pack_path) {
          previewPaths.push(iconPath);
        }
      }
      return TokenIconPacks.preparePickerPreviewPaths(previewPaths);
    })
  }

  public static async removeAegisIconPack(icon_pack: AegisIconPack): Promise<void> {
    for (const icon of icon_pack.icons) {
      for (const iconPath of icon.icon_pack_path) {
        TokenIconPacks.removePickerPreviewPath(iconPath);
      }
    }
    TokenIconPacks.enabled_packs = TokenIconPacks.enabled_packs.filter(id => id !== icon_pack.uuid);
    if (TokenIconPacks.enabled_packs.length === 0) {
      TokenIconPacks.enabled_packs = [BUILTIN_DEFAULT_PACK_ID];
    }
    AppPreference.saveEnabledPacks(TokenIconPacks.enabled_packs);
    TokenIconPacks.aegis_icon_packs = TokenIconPacks.aegis_icon_packs.filter(
      pack => pack.on_device_path !== icon_pack.on_device_path
    );
    TokenIconPacks.rebuildPackMap();
    return fileIo.rmdir(icon_pack.on_device_path);
  }

  public static getIconByIssuer(issuer: string): string {
    if (!issuer) {
      return '';
    }
    for (const packId of TokenIconPacks.enabled_packs) {
      if (packId === BUILTIN_DEFAULT_PACK_ID) {
        const icon = TokenIconPacks.default_icon_pack.getIconPathByIssuer(issuer);
        if (icon !== '') return icon;
      } else {
        const pack = TokenIconPacks.packByUuid.get(packId);
        if (pack && !pack.invalid) {
          const icon = pack.getIconPathByIssuer(issuer);
          if (icon !== '') return icon;
        }
      }
    }
    return '';
  }

  private static isAutoResolvedPath(path: string): boolean {
    if (path === '') return true;
    if (path.startsWith('rawfile://')) return true;
    if (path.startsWith('file://')) {
      const userPrefix = 'file://' + TokenIconPacks.user_added_icon_packs.user_icon_path + '/';
      return !path.startsWith(userPrefix);
    }
    return false;
  }

  public static rematchTokens(tokens: TokenConfig[]): TokenConfig[] {
    const changed: TokenConfig[] = [];
    for (const token of tokens) {
      const oldIconPath = token.TokenIconPath ?? '';
      if (!TokenIconPacks.isAutoResolvedPath(oldIconPath)) continue;
      const newIconPath = TokenIconPacks.getIconByIssuer(token.TokenIssuer);
      if (newIconPath !== oldIconPath) {
        token.TokenIconPath = newIconPath || undefined;
        changed.push(token);
      }
    }
    return changed;
  }

  public static notifyChanged(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('appContext');
    ctx?.eventHub.emit(EVENT_NAMES.ICON_PACK_CHANGED);
  }
}

export class AegisIcon {
  public filename: string = '';
  public category: string = '';
  public issuer: string[] = [];
  public icon_pack_path: HashSet<string> = new HashSet();
}

export class AegisIconPack {
  public invalid = false;
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

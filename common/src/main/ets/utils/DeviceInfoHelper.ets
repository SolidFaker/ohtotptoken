import { deviceInfo } from '@kit.BasicServicesKit';
import { normalizeCloudBackupDeviceId, normalizeCloudBackupDeviceName } from './CloudBackupMetadata';
import {
  CloudBackupDiagnostics, DiagnosticKind, DiagnosticResult, DiagnosticSource, DiagnosticStage
} from './CloudBackupDiagnostics';

const DEVICE_INFO_KEY = 'cached_device_info';
const UNKNOWN_DEVICE_NAME = 'Unknown Device';

export interface DeviceInfoData {
  odid: string;
  deviceType: string;
  manufacture: string;
  brand: string;
  marketName: string;
  productSeries: string;
  productModel: string;
  softwareModel: string;
  hardwareModel: string;
  abiList: string;
  securityPatchTag: string;
  displayVersion: string;
  osReleaseType: string;
  osFullName: string;
  distributionOSName: string;
  distributionOSVersion: string;
  distributionOSApiVersion: number;
  distributionOSReleaseType: string;
}

export enum DeviceInfoField {
  ODID, DEVICE_TYPE, MANUFACTURE, BRAND, MARKET_NAME, PRODUCT_SERIES, PRODUCT_MODEL,
  SOFTWARE_MODEL, HARDWARE_MODEL, ABI_LIST, SECURITY_PATCH, DISPLAY_VERSION, OS_RELEASE_TYPE,
  OS_FULL_NAME, DISTRIBUTION_NAME, DISTRIBUTION_VERSION, DISTRIBUTION_RELEASE_TYPE
}

/** 每次只访问一个系统 getter，某字段失败不能使其他必要字段失效。 */
export interface DeviceInfoSource {
  readText(field: DeviceInfoField): string;
  readApiVersion(): number;
}

export interface DeviceInfoCache {
  get(): DeviceInfoData | null;
  set(value: DeviceInfoData): void;
}

class NativeDeviceInfoSource implements DeviceInfoSource {
  readText(field: DeviceInfoField): string {
    switch (field) {
      case DeviceInfoField.ODID: return deviceInfo.ODID;
      case DeviceInfoField.DEVICE_TYPE: return deviceInfo.deviceType;
      case DeviceInfoField.MANUFACTURE: return deviceInfo.manufacture;
      case DeviceInfoField.BRAND: return deviceInfo.brand;
      case DeviceInfoField.MARKET_NAME: return deviceInfo.marketName;
      case DeviceInfoField.PRODUCT_SERIES: return deviceInfo.productSeries;
      case DeviceInfoField.PRODUCT_MODEL: return deviceInfo.productModel;
      case DeviceInfoField.SOFTWARE_MODEL: return deviceInfo.softwareModel;
      case DeviceInfoField.HARDWARE_MODEL: return deviceInfo.hardwareModel;
      case DeviceInfoField.ABI_LIST: return deviceInfo.abiList;
      case DeviceInfoField.SECURITY_PATCH: return deviceInfo.securityPatchTag;
      case DeviceInfoField.DISPLAY_VERSION: return deviceInfo.displayVersion;
      case DeviceInfoField.OS_RELEASE_TYPE: return deviceInfo.osReleaseType;
      case DeviceInfoField.OS_FULL_NAME: return deviceInfo.osFullName;
      case DeviceInfoField.DISTRIBUTION_NAME: return deviceInfo.distributionOSName;
      case DeviceInfoField.DISTRIBUTION_VERSION: return deviceInfo.distributionOSVersion;
      case DeviceInfoField.DISTRIBUTION_RELEASE_TYPE: return deviceInfo.distributionOSReleaseType;
      default: return '';
    }
  }

  readApiVersion(): number {
    return deviceInfo.distributionOSApiVersion;
  }
}

class AppDeviceInfoCache implements DeviceInfoCache {
  get(): DeviceInfoData | null {
    return AppStorage.get<DeviceInfoData>(DEVICE_INFO_KEY) ?? null;
  }

  set(value: DeviceInfoData): void {
    AppStorage.setOrCreate(DEVICE_INFO_KEY, value);
  }
}

class MemoryDeviceInfoCache implements DeviceInfoCache {
  private value: DeviceInfoData | null = null;

  get(): DeviceInfoData | null { return this.value; }
  set(value: DeviceInfoData): void { this.value = value; }
}

function emptyDeviceInfo(): DeviceInfoData {
  return {
    odid: '', deviceType: 'unknown', manufacture: 'unknown', brand: 'unknown',
    marketName: UNKNOWN_DEVICE_NAME, productSeries: 'unknown', productModel: 'unknown',
    softwareModel: 'unknown', hardwareModel: 'unknown', abiList: 'unknown', securityPatchTag: 'unknown',
    displayVersion: 'unknown', osReleaseType: 'unknown', osFullName: 'unknown',
    distributionOSName: 'unknown', distributionOSVersion: 'unknown', distributionOSApiVersion: 0,
    distributionOSReleaseType: 'unknown'
  };
}

/** 设备信息单例。只记录技术可用性，绝不输出身份、名称或原始异常。 */
export class DeviceInfoHelper {
  private static instance: DeviceInfoHelper | null = null;
  private cachedDeviceInfo: DeviceInfoData | null = null;
  private initialized: boolean = false;
  private readonly source: DeviceInfoSource;
  private readonly cache: DeviceInfoCache;

  private constructor(source: DeviceInfoSource, cache: DeviceInfoCache) {
    this.source = source;
    this.cache = cache;
  }

  static getInstance(): DeviceInfoHelper {
    if (!DeviceInfoHelper.instance) {
      DeviceInfoHelper.instance = new DeviceInfoHelper(new NativeDeviceInfoSource(), new AppDeviceInfoCache());
    }
    return DeviceInfoHelper.instance;
  }

  /** 独立实例不污染全局单例；测试不调用系统 getter/AppStorage。 */
  static createForTest(source: DeviceInfoSource, cache?: DeviceInfoCache): DeviceInfoHelper {
    return new DeviceInfoHelper(source, cache !== undefined ? cache : new MemoryDeviceInfoCache());
  }

  private readText(field: DeviceInfoField, fallback: string = 'unknown'): string {
    try {
      const value = this.source.readText(field);
      return typeof value === 'string' && value.trim().length > 0 ? value.trim() : fallback;
    } catch (_) {
      return fallback;
    }
  }

  private readApiVersion(): number {
    try {
      const value = this.source.readApiVersion();
      return Number.isSafeInteger(value) && value >= 0 ? value : 0;
    } catch (_) {
      return 0;
    }
  }

  private readRequired(data: DeviceInfoData): void {
    data.odid = normalizeCloudBackupDeviceId(this.readText(DeviceInfoField.ODID, ''));
    const marketName = normalizeCloudBackupDeviceName(this.readText(DeviceInfoField.MARKET_NAME, ''));
    const productModel = normalizeCloudBackupDeviceName(this.readText(DeviceInfoField.PRODUCT_MODEL, ''));
    data.productModel = productModel.length > 0 ? productModel : 'unknown';
    data.marketName = marketName.length > 0 ? marketName :
      (productModel.length > 0 ? productModel : UNKNOWN_DEVICE_NAME);
  }

  private store(data: DeviceInfoData): void {
    // 系统缓存失败也不能丢失本实例已经读取到的必要字段。
    this.cachedDeviceInfo = data;
    try {
      this.cache.set(data);
    } catch (_) {
      // 缓存不是读取成功的前置条件。
    }
  }

  private report(data: DeviceInfoData, source: DiagnosticSource): void {
    const context = CloudBackupDiagnostics.begin(DiagnosticKind.DEVICE_INFO);
    CloudBackupDiagnostics.mark(context, DiagnosticStage.DEVICE_INFO, DiagnosticResult.OK, {
      source: source,
      identityAvailable: normalizeCloudBackupDeviceId(data.odid).length > 0,
      nameAvailable: normalizeCloudBackupDeviceName(data.marketName).length > 0,
    });
    CloudBackupDiagnostics.end(context);
  }

  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }
    const data = emptyDeviceInfo();
    this.readRequired(data);
    data.deviceType = this.readText(DeviceInfoField.DEVICE_TYPE);
    data.manufacture = this.readText(DeviceInfoField.MANUFACTURE);
    data.brand = this.readText(DeviceInfoField.BRAND);
    data.productSeries = this.readText(DeviceInfoField.PRODUCT_SERIES);
    data.softwareModel = this.readText(DeviceInfoField.SOFTWARE_MODEL);
    data.hardwareModel = this.readText(DeviceInfoField.HARDWARE_MODEL);
    data.abiList = this.readText(DeviceInfoField.ABI_LIST);
    data.securityPatchTag = this.readText(DeviceInfoField.SECURITY_PATCH);
    data.displayVersion = this.readText(DeviceInfoField.DISPLAY_VERSION);
    data.osReleaseType = this.readText(DeviceInfoField.OS_RELEASE_TYPE);
    data.osFullName = this.readText(DeviceInfoField.OS_FULL_NAME);
    data.distributionOSName = this.readText(DeviceInfoField.DISTRIBUTION_NAME);
    data.distributionOSVersion = this.readText(DeviceInfoField.DISTRIBUTION_VERSION);
    data.distributionOSReleaseType = this.readText(DeviceInfoField.DISTRIBUTION_RELEASE_TYPE);
    data.distributionOSApiVersion = this.readApiVersion();
    this.store(data);
    this.initialized = true;
    this.report(data, DiagnosticSource.INITIAL);
  }

  /** 创建备份前只重试必要读取；返回 false 时不得制造“本设备”归属。 */
  refreshRequiredInfo(): boolean {
    const data = this.getDeviceInfo();
    this.readRequired(data);
    this.store(data);
    this.report(data, DiagnosticSource.RETRY);
    return data.odid.length > 0;
  }

  getDeviceInfo(): DeviceInfoData {
    if (this.cachedDeviceInfo !== null) {
      return this.cachedDeviceInfo;
    }
    try {
      const cached = this.cache.get();
      if (cached !== null) {
        cached.odid = typeof cached.odid === 'string' ? normalizeCloudBackupDeviceId(cached.odid) : '';
        const marketName = typeof cached.marketName === 'string' ? normalizeCloudBackupDeviceName(cached.marketName) : '';
        const model = typeof cached.productModel === 'string' ? normalizeCloudBackupDeviceName(cached.productModel) : '';
        cached.marketName = marketName || model || UNKNOWN_DEVICE_NAME;
        this.cachedDeviceInfo = cached;
        this.report(cached, DiagnosticSource.CACHED);
        return cached;
      }
    } catch (_) {
      // 缓存不可用则返回未初始化状态，创建前仍能重新读取系统必要字段。
    }
    const fallback = emptyDeviceInfo();
    this.report(fallback, DiagnosticSource.FALLBACK);
    return fallback;
  }

  getDeviceId(): string {
    return normalizeCloudBackupDeviceId(this.getDeviceInfo().odid);
  }

  getDeviceName(): string {
    return normalizeCloudBackupDeviceName(this.getDeviceInfo().marketName) || UNKNOWN_DEVICE_NAME;
  }

  isPc(): boolean {
    return this.getDeviceInfo().deviceType === '2in1';
  }

  isPcOrTablet(): boolean {
    const type = this.getDeviceInfo().deviceType;
    return type === '2in1' || type === 'tablet';
  }

  isInitialized(): boolean {
    return this.initialized;
  }
}

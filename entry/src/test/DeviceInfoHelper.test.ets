import { describe, it, expect } from '@ohos/hypium';
import { DeviceInfoCache, DeviceInfoData, DeviceInfoField, DeviceInfoHelper, DeviceInfoSource } from 'common';

class FixtureDeviceSource implements DeviceInfoSource {
  values: Map<DeviceInfoField, string> = new Map();
  failures: Set<DeviceInfoField> = new Set();
  reads: DeviceInfoField[] = [];
  failVersion: boolean = false;

  constructor() {
    this.values.set(DeviceInfoField.ODID, ' fixture-device ');
    this.values.set(DeviceInfoField.MARKET_NAME, ' Fixture Market ');
    this.values.set(DeviceInfoField.PRODUCT_MODEL, ' Fixture Model ');
    this.values.set(DeviceInfoField.DEVICE_TYPE, '2in1');
  }

  readText(field: DeviceInfoField): string {
    this.reads.push(field);
    if (this.failures.has(field)) { throw new Error('synthetic getter failure'); }
    return this.values.get(field) ?? '';
  }

  readApiVersion(): number {
    if (this.failVersion) { throw new Error('synthetic version failure'); }
    return 23;
  }
}

class FixtureInfoCache implements DeviceInfoCache {
  data: DeviceInfoData | null = null;
  failGet: boolean = false;
  failSet: boolean = false;

  get(): DeviceInfoData | null {
    if (this.failGet) { throw new Error('synthetic cache read failure'); }
    return this.data;
  }

  set(data: DeviceInfoData): void {
    if (this.failSet) { throw new Error('synthetic cache write failure'); }
    this.data = data;
  }
}

export default function deviceInfoHelperTest(): void {
  describe('deviceInfoHelperTest', () => {
    it('required_fields_survive_unrelated_getter_and_version_failures', 0, async () => {
      const source = new FixtureDeviceSource();
      source.failures.add(DeviceInfoField.OS_FULL_NAME);
      source.failures.add(DeviceInfoField.DISTRIBUTION_NAME);
      source.failures.add(DeviceInfoField.SOFTWARE_MODEL);
      source.failVersion = true;
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      expect(helper.getDeviceId()).assertEqual('fixture-device');
      expect(helper.getDeviceName()).assertEqual('Fixture Market');
      expect(helper.getDeviceInfo().osFullName).assertEqual('unknown');
      expect(helper.getDeviceInfo().distributionOSApiVersion).assertEqual(0);
      expect(helper.isInitialized()).assertTrue();
    });

    it('market_name_failure_falls_back_to_trimmed_product_model', 0, async () => {
      const source = new FixtureDeviceSource();
      source.failures.add(DeviceInfoField.MARKET_NAME);
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      expect(helper.getDeviceName()).assertEqual('Fixture Model');
      expect(helper.getDeviceId()).assertEqual('fixture-device');
    });

    it('whitespace_market_name_uses_model_and_missing_names_do_not_block_identity', 0, async () => {
      const source = new FixtureDeviceSource();
      source.values.set(DeviceInfoField.MARKET_NAME, ' \t ');
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      expect(helper.getDeviceName()).assertEqual('Fixture Model');
      source.failures.add(DeviceInfoField.PRODUCT_MODEL);
      expect(helper.refreshRequiredInfo()).assertTrue();
      expect(helper.getDeviceName()).assertEqual('Unknown Device');
    });

    it('odid_failure_does_not_prevent_name_initialization', 0, async () => {
      const source = new FixtureDeviceSource();
      source.failures.add(DeviceInfoField.ODID);
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      expect(helper.getDeviceName()).assertEqual('Fixture Market');
      expect(helper.getDeviceId()).assertEqual('');
      expect(helper.refreshRequiredInfo()).assertFalse();
    });

    it('unknown_odid_and_whitespace_are_never_valid_identity', 0, async () => {
      for (const value of ['', ' ', 'unknown_odid', ' UNKNOWN_ODID ']) {
        const source = new FixtureDeviceSource();
        source.values.set(DeviceInfoField.ODID, value);
        const helper = DeviceInfoHelper.createForTest(source);
        await helper.init();
        expect(helper.getDeviceId()).assertEqual('');
        expect(helper.refreshRequiredInfo()).assertFalse();
      }
    });

    it('creation_retry_refreshes_only_required_getters_and_recovers_identity', 0, async () => {
      const source = new FixtureDeviceSource();
      source.failures.add(DeviceInfoField.ODID);
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      source.failures.delete(DeviceInfoField.ODID);
      source.reads = [];
      expect(helper.refreshRequiredInfo()).assertTrue();
      expect(source.reads.length).assertEqual(3);
      expect(source.reads[0]).assertEqual(DeviceInfoField.ODID);
      expect(source.reads[1]).assertEqual(DeviceInfoField.MARKET_NAME);
      expect(source.reads[2]).assertEqual(DeviceInfoField.PRODUCT_MODEL);
    });

    it('failed_retry_does_not_reuse_old_identity_as_new_valid_read', 0, async () => {
      const source = new FixtureDeviceSource();
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      source.failures.add(DeviceInfoField.ODID);
      expect(helper.refreshRequiredInfo()).assertFalse();
      expect(helper.getDeviceId()).assertEqual('');
    });

    it('cache_failures_do_not_erase_in_memory_required_fields', 0, async () => {
      const source = new FixtureDeviceSource();
      const cache = new FixtureInfoCache();
      cache.failGet = true;
      cache.failSet = true;
      const helper = DeviceInfoHelper.createForTest(source, cache);
      expect(helper.getDeviceId()).assertEqual('');
      await helper.init();
      expect(helper.getDeviceId()).assertEqual('fixture-device');
      expect(helper.getDeviceName()).assertEqual('Fixture Market');
      expect(helper.refreshRequiredInfo()).assertTrue();
    });

    it('legacy_cached_placeholder_is_normalized_and_name_uses_model', 0, async () => {
      const cache = new FixtureInfoCache();
      const source = new FixtureDeviceSource();
      const seed = DeviceInfoHelper.createForTest(source, cache);
      await seed.init();
      const data = seed.getDeviceInfo();
      data.odid = 'unknown_odid';
      data.marketName = 'Unknown Device';
      const helper = DeviceInfoHelper.createForTest(source, cache);
      expect(helper.getDeviceId()).assertEqual('');
      expect(helper.getDeviceName()).assertEqual('Fixture Model');
    });

    it('init_is_cached_and_device_type_helpers_need_no_system_enum', 0, async () => {
      const source = new FixtureDeviceSource();
      const helper = DeviceInfoHelper.createForTest(source);
      await helper.init();
      const count = source.reads.length;
      await helper.init();
      expect(source.reads.length).assertEqual(count);
      expect(helper.isPc()).assertTrue();
      expect(helper.isPcOrTablet()).assertTrue();
      helper.getDeviceInfo().deviceType = 'tablet';
      expect(helper.isPc()).assertFalse();
      expect(helper.isPcOrTablet()).assertTrue();
      helper.getDeviceInfo().deviceType = 'phone';
      expect(helper.isPcOrTablet()).assertFalse();
    });
  });
}

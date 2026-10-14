import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import iconPackImportGateDeviceTest from '../test/IconPackImportGate.test';

export default class IconPackImportGateTestRunner implements TestRunner {
  onPrepare(): void {}

  onRun(): void {
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(),
      abilityDelegatorRegistry.getArguments(), iconPackImportGateDeviceTest);
  }
}

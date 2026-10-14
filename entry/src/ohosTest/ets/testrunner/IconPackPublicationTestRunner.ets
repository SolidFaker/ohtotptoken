import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import iconPackPublicationDeviceTest from '../test/IconPackPublication.test';

/** 仅注册自有合成夹具，不导入会初始化令牌、账号或启动生产页面的综合套件。 */
export default class IconPackPublicationTestRunner implements TestRunner {
  onPrepare(): void {}

  onRun(): void {
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(),
      abilityDelegatorRegistry.getArguments(), iconPackPublicationDeviceTest);
  }
}

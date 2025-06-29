import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
/**
 * 节流 在规定的时间内，只执行一次
 *
 */
export function throttle(func: (event: ClickEvent) => void, delay?: number) {
  let inThrottle: boolean;
  return (event: ClickEvent) => {
    if (!inThrottle) {
      func(event);
      inThrottle = true;
      setTimeout(() => inThrottle = false, delay ? delay : 1000);
    }
  };
}
/**
 * 唤起系统浏览器打开网页
 *
 */
export function startBrowsableAbility(context: common.UIAbilityContext,url:string): void {
  let want: Want = {
    action: 'ohos.want.action.viewData',
    entities: ['entity.system.browsable'],
    uri: url,
    parameters: {
      'ohos.ability.params.showDefaultPicker': true
    }
  };
  context.startAbility(want)
    .then(() => {
      console.error('Start browsableAbility successfully.');
    })
    .catch((err: BusinessError) => {
      console.error(`Failed to startAbility. Code: ${err.code}, message: ${err.message}`);
    });
}
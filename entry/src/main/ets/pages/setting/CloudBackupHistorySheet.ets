import { HdsNavigation, ScrollEffectType } from '@kit.UIDesignKit';
import { ROUTE_NAMES } from 'common';
import { MaterialSheetStyle } from '../../components/MaterialSheetStyle';
import { MaterialTheme } from '../../components/MaterialTheme';
import { ShowCloudBackupHistoryPage } from '../ShowCloudBackupHistoryPage';

export function cloudBackupHistorySheetOptions(): SheetOptions {
  const options = MaterialSheetStyle.options();
  options.backgroundColor = $r('app.color.window_background');
  return options;
}

/** 历史面板独立导航栈只属于本面板，关闭时清栈，返回不能弹出底层云备份面板。 */
@ComponentV2
export struct CloudBackupHistorySheet {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event onClose: () => void = () => {};
  private pageInfos: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // 面板随 bindSheet 自底部弹出，内容页去动画推入，避免沉浸光感下侧滑转场残留。
    this.pageInfos.pushPathByName(ROUTE_NAMES.ShowCloudBackupHistoryPage, null, false);
  }

  aboutToDisappear(): void {
    this.pageInfos.clear();
  }

  @Builder
  Destination(name: string, _param: Object) {
    if (name === ROUTE_NAMES.ShowCloudBackupHistoryPage) {
      ShowCloudBackupHistoryPage({
        scrollEffectType: this.scrollEffectType,
        inMaterialSheet: true,
        sheetRoot: true,
        onCloseSheet: () => this.onClose()
      })
    }
  }

  build() {
    HdsNavigation(this.pageInfos) {
    }
    .id('cloud-backup-history-sheet')
    .width('100%').height('100%')
    .hideNavBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.Destination)
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }
}

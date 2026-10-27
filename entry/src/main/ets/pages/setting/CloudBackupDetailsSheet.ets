import { HdsNavigation, ScrollEffectType } from '@kit.UIDesignKit';
import { ROUTE_NAMES } from 'common';
import { MaterialSheetStyle } from '../../components/MaterialSheetStyle';
import { MaterialTheme } from '../../components/MaterialTheme';
import { ShowCloudSyncDetailsPage } from '../ShowCloudSyncDetailsPage';

export function cloudBackupDetailsSheetOptions(): SheetOptions {
  const options = MaterialSheetStyle.options();
  options.backgroundColor = $r('app.color.window_background');
  return options;
}

/** 独立导航栈只属于本面板，历史返回不能弹出底层备份页面。 */
@ComponentV2
export struct CloudBackupDetailsSheet {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event onClose: () => void = () => {};
  private pageInfos: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.pageInfos.pushPathByName(ROUTE_NAMES.ShowCloudSyncDetailsPage, null, false);
  }

  aboutToDisappear(): void {
    this.pageInfos.clear();
  }

  @Builder
  Destination(name: string, _param: Object) {
    if (name === ROUTE_NAMES.ShowCloudSyncDetailsPage) {
      ShowCloudSyncDetailsPage({
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
    .id('cloud-backup-details-sheet')
    .width('100%').height('100%')
    .hideNavBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.Destination)
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }
}

import { HdsNavDestination, HdsNavigation, ScrollEffectType } from '@kit.UIDesignKit';
import { ROUTE_NAMES } from 'common';
// [冷启动优化] 反馈及其 ArkWeb 依赖仅在用户打开反馈/网页时加载。
import lazy { FeedbackSheet } from './FeedbackSheet';
import { MaterialSheetStyle } from '../../components/MaterialSheetStyle';
import { MaterialTheme } from '../../components/MaterialTheme';
import { ShowCloudSyncDetailsPage } from '../ShowCloudSyncDetailsPage';
import { ShowCloudBackupHistoryPage } from '../ShowCloudBackupHistoryPage';

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

  private backFromFeedback(): boolean {
    this.pageInfos.pop();
    return true;
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
    } else if (name === ROUTE_NAMES.ShowCloudBackupHistoryPage) {
      ShowCloudBackupHistoryPage({ scrollEffectType: this.scrollEffectType, inMaterialSheet: true })
    } else if (name === ROUTE_NAMES.SettingFeedback) {
      // 反馈网页使用独立内栈及组件既有 WebPage builder，不与面板 Navigation 双绑定。
      HdsNavDestination() {
        Column() {
          Button($r('app.string.cloud_backup_feedback_back'))
            .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%')
            .onClick(() => { this.backFromFeedback(); })
          FeedbackSheet({ scrollEffectType: this.scrollEffectType, embedded: true })
            .layoutWeight(1)
        }
        .width('100%').height('100%')
      }
      .hideTitleBar(true)
      .onBackPressed(() => this.backFromFeedback())
      .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
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

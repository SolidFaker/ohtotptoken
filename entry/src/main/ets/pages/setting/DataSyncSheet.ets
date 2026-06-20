import { SubItemToggle } from '../../components/SubItemToggle'
import { AppStorageV2 } from '@kit.ArkUI';
import { AppPreference, SettingValue, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES } from '../../utils/AppPreference';
import { SubItemButton } from '../../components/SubItemButton';
import { SettingItem } from '../../components/SettingItem';
import { SubItemDivider } from '../../components/SubItemDivider';
import { AppWindowInfo } from '../../entryability/EntryAbility';
import { common } from '@kit.AbilityKit';
import { PermissionManager } from '../../utils/PermissionManager';
import { throttle } from '../../utils/UiUtils';
import { ShowDataSyncDetailsPage } from '../ShowDataSyncDetailsPage';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

@Preview
@ComponentV2
export struct DataSyncSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local RdbSyncEnable: SettingValue = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;

  aboutToAppear(): void {
    this.RdbSyncEnable = AppPreference.getPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE);
    this.appCtx.eventHub.on(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, this.updateDATASYNCPermissions);
  }

  updateDATASYNCPermissions(isAccess: boolean) {
    if (!isAccess) {
      this.RdbSyncEnable = false;
      AppPreference.setPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE, false);
    }
  }

  aboutToDisappear() {
    this.appCtx.eventHub.off(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, this.updateDATASYNCPermissions);
  }

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.ShowDataSyncDetailsPage) {
      ShowDataSyncDetailsPage({ scrollEffectType: this.scrollEffectType })
    }
  }

  build() {
    Column() {
      HdsNavigation(this.pageInfos) {
        Column() {
          List({ scroller: this.sheetScroller, space: 10 }) {
            ListItem() {
              SettingItem({ title: "" }) {
                SubItemToggle({
                  icon: $r('sys.symbol.link'),
                  title: $r('app.string.data_rdb_sync'),
                  isOn: this.RdbSyncEnable as boolean,
                  description: $r('app.string.data_rdb_sync_des'),
                  onChange: (IsOn: boolean) => {
                    if (IsOn) {
                      PermissionManager.getInstance().reqPermissionsFromUser(this.appCtx);
                    }
                    this.RdbSyncEnable = IsOn;
                    AppPreference.setPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE, IsOn);
                  }
                })

                SubItemDivider()

                SubItemButton({
                  symbol: $r('sys.symbol.arrow_counterclockwise_clock'),
                  text: $r('app.string.data_rdb_sync_details')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.ShowDataSyncDetailsPage, null);
                  }, 1000))
              }
            }
            .padding({ left: 10, right: 10 })
          }
          .clip(false)
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .backgroundColor($r('app.color.window_background'))
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.window_background'))
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.window_background'))
      .mode(NavigationMode.Stack)
      .navDestination(this.navDestinationBuilder)
      .bindToScrollable([this.sheetScroller])
      .titleMode(HdsNavigationTitleMode.MODAL)
      .titleBar({
        enableComponentSafeArea: true,
        style: {
          originalStyle: {
            contentStyle: {
              titleStyle: {
                mainTitleColor: $r('sys.color.font_primary'),
                subTitleColor: $r('sys.color.font_secondary')
              },
              backIconStyle: {
                iconColor: $r('sys.color.icon_primary')
              }
            },
          },
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: this.scrollEffectType
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: {
            mainTitle: $r('app.string.data_sync'),
          },
        }
      })
    }
  }
}

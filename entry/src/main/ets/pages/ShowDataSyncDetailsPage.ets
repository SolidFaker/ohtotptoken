import { AppStorageV2 } from '@kit.ArkUI';
import { TopNavigationView } from '../components/TopNavigationView';
import { SettingItem } from '../components/SettingItem';
import { AppPreference, SettingValue, PREF_KEYS } from '../utils/AppPreference';
import { SubItemButton } from '../components/SubItemButton';
import { TokenStore } from '../utils/TokenStore';
import { SubItemDivider } from '../components/SubItemDivider';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { DeviceInfoHelper,DeviceInfoData } from '../utils/DeviceInfoHelper';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { CommonConstants } from '../utils/CommonConstants';
import { showSnackBar, SnackBarNotifyType } from '../utils/HdsSnackBarUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ShowDataSyncDetailsPage';
const DOMAIN = 0xFF00;

@Entry
@Preview
@ComponentV2
export struct ShowDataSyncDetailsPage {
  pageInfos: NavPathStack | null = null;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local AppDbKVSyncTime: SettingValue = '';
  @Local Is_loaded: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local deviceName: string = '';
  @Local deviceId: string = '';

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.AppDbKVSyncTime = AppPreference.getPreference(PREF_KEYS.DB_KV_SYNC_TIME);
    if (this.AppDbKVSyncTime == '' || this.AppDbKVSyncTime == null) {
      this.AppDbKVSyncTime = 'invalid';
    }

    const deviceInfo:DeviceInfoData = DeviceInfoHelper.getInstance().getDeviceInfo();
    this.deviceName = deviceInfo.marketName;
    this.deviceId = deviceInfo.odid;
  }

  build() {
    HdsNavDestination() {
      Column() {
        RelativeContainer() {
          Stack() {
            if (this.Is_loaded) {
              Column() {
                LoadingProgress()
                  .color(Color.White)
                  .width(80).height(80)
                Text('Loading..')
                  .fontSize(16)
                  .fontColor(Color.White)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#40000000')
              .justifyContent(FlexAlign.Center)
            } else {
              List({ space: 10, scroller: this.scroller }) {
                // 顶部避让
                ListItem()
                  .height(CommonConstants.AVOID_TOP_BASE_HEIGHT)

                ListItem() {
                  SettingItem({ title: $r('app.string.data_dev_info') }) {
                    Row() {
                      Text(this.deviceName)
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .padding(10)

                    SubItemDivider()

                    Row() {
                      Text(this.deviceId)
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .padding(10)
                  }

                }
                .padding({ left: 10, right: 10 })

                ListItem() {
                  SettingItem({ title: $r('app.string.data_kv_sync_time') }) {
                    Row() {
                      Text(this.AppDbKVSyncTime as string)
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .padding(10)

                    SubItemDivider()

                    SubItemButton({
                      symbol: $r('sys.symbol.arrow_clockwise'),
                      text: $r('app.string.data_kv_sync_manual'),
                      description: $r('app.string.data_kv_sync_manual_des')
                    })
                      .onClick(() => {
                        this.Is_loaded=true;
                        TokenStore.getInstance().DataSync().then(()=>{
                          setTimeout(() => {
                            this.Is_loaded = false;
                            AppPreference.setPreference(PREF_KEYS.DB_KV_SYNC_TIME, new Date().toISOString());
                            this.AppDbKVSyncTime = AppPreference.getPreference(PREF_KEYS.DB_KV_SYNC_TIME);
                          }, 1500);
                        }).catch((err: Error) => {
                          this.Is_loaded = false;
                          hilog.error(DOMAIN, TAG, `DataSync failed: ${err.message}`);
                          showSnackBar($r('app.string.cloud_sync_start_failed'), SnackBarNotifyType.WARNING);
                        });
                      })
                  }
                }
                .padding({ left: 10, right: 10 })

              }
              .chainAnimation(AppPreference.getPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE) as boolean)
              .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
              .scrollBar(BarState.Off)
              .backgroundColor($r('app.color.window_background'))
              .width('100%')
              .height('100%')
            }
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.window_background'))
    }
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
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
          mainTitle: $r('app.string.data_rdb_sync_details'),
        },
      }
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}
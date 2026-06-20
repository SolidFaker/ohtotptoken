import { SettingItem } from '../../components/SettingItem';
import { AppWindowInfo } from '../../entryability/EntryAbility';
import { bundleManager } from '@kit.AbilityKit';
import { AppStorageV2, curves } from '@kit.ArkUI';
import { showSnackBar, SnackBarNotifyType } from '../../utils/HdsSnackBarUtils';
import { AppPreference, PREF_KEYS } from '../../utils/AppPreference';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

@Preview
@ComponentV2
export struct AboutSheet {
  @Require @Param scrollEffectStyle: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local debug_mode_is_on: boolean = AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();
  private str_about_app: string = '';
  private str_opensource_leg: string = '';
  private debug_mode_counter: number = 0;

  aboutToAppear(): void {
    let bundleInfo = AppStorage.get<bundleManager.BundleInfo>("BundleInfo");
    this.str_about_app =
      "Github: OHOTP/ohtotptoken\n" +
      "E-mail: enbinli@outlook.com\n" +
      "Contributors: @Solidfaker, @eveloki, @lsxuan12138, @TomStilson, @tomygin, @wulongshe\n" +
      "Bundle Name: " + bundleInfo?.name + "\n" +
      "Version: " + bundleInfo?.versionName + "\n" +
      "Version Code: " + bundleInfo?.versionCode;
    this.str_opensource_leg =
      "Github: paolostivanin/libcotp\n" +
      "Github: Netthaw/TOTP-MCU\n" +
      "Github: ss23/fortitoken-mobile-registration\n" +
      "Github: iamhyc/Aigis\n" +
      "Github: andOTP/andOTP - Icons";
  }

  build() {
    Column() {
      HdsNavigation() {
        List({ scroller: this.sheetScroller, space: 10 }) {
          ListItem() {
            SettingItem({ title: "" }) {
              Text(this.str_about_app)
                .fontSize(10)
                .fontColor($r('app.color.str_gray'))
                .padding(10)
            }
          }
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            if (!this.debug_mode_is_on) {
              setTimeout(() => {
                this.debug_mode_counter = 0;
              }, 2000);
              if (this.debug_mode_counter > 7) {
                this.window.uiContext?.animateTo({ curve: curves.springMotion() }, () => {
                  this.debug_mode_is_on = true;
                  AppPreference.setPreference('app_debug_mode_on', true);
                  showSnackBar('DEBUG MODE ON', SnackBarNotifyType.INFO);
                })

              }
              this.debug_mode_counter++;
            }
          })

          ListItem() {
            SettingItem({ title: "" }) {
              Text(this.str_opensource_leg)
                .fontSize(10)
                .fontColor($r('app.color.str_gray'))
                .padding(10)
            }
          }
          .padding({ left: 10, right: 10 })

          ListItemGroup() {
            ListItem() {
              Row() {
                Hyperlink('https://beian.miit.gov.cn/', '粤ICP备2020075515号-2A')
                  .height(10)
                  .padding({ left: 10 })
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .padding({ left: 10, right: 10 })
          }
        }
        .clip(false)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .backgroundColor($r('app.color.window_background'))
        .layoutWeight(1)
      }
      .mode(NavigationMode.Stack)
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
            scrollEffectType: this.scrollEffectStyle
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: {
            mainTitle: $r('app.string.setting_about'),
          },
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.window_background'))
  }
}

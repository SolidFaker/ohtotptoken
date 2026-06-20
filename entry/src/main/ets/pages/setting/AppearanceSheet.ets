import { BusinessError } from '@kit.BasicServicesKit';
import { showSnackBar, SnackBarNotifyType } from '../../utils/HdsSnackBarUtils';
import { SubItemToggle } from '../../components/SubItemToggle'
import { AppStorageV2, curves } from '@kit.ArkUI';
import { AppPreference, SettingColorMode, SettingTopEffectType, SettingBottomTabsType, TokenPreference, AVAILABLE_TOP_EFFECT_TYPES, AVAILABLE_BOTTOM_TABS_TYPES, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES } from '../../utils/AppPreference';
import { SubItemButton } from '../../components/SubItemButton';
import { SettingItem } from '../../components/SettingItem';
import { SubItemDivider } from '../../components/SubItemDivider';
import { SubItemSelect } from '../../components/SubItemSelect';
import { SubItemEnumSelect } from '../../components/SubItemEnumSelect';
import { SubItemIconManager } from '../../components/SubItemIconManager';
import { AppWindowInfo } from '../../entryability/EntryAbility';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { throttle } from '../../utils/UiUtils';
import { AppearancePage } from '../AppearancePage';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

@Preview
@ComponentV2
export struct AppearanceSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local debug_mode_is_on: boolean = AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.AppearancePage) {
      AppearancePage({scrollEffectType: this.scrollEffectType})
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
                  icon: $r('sys.symbol.chevron_up_2_circle'),
                  title: $r('app.string.show_next_token'),
                  isOn: AppPreference.getPreference(PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE) as boolean,
                  description: $r('app.string.show_next_token_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE, IsOn);
                    this.token_preference.app_appearance_show_next_token_enable = IsOn;
                  }
                })

                SubItemDivider()

                if (this.debug_mode_is_on) {
                  SubItemToggle({
                    icon: $r('sys.symbol.gearshape'),
                    title: $r('app.string.debug_mode'),
                    isOn: AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean,
                    description: $r('app.string.debug_mode_des'),
                    onChange: (IsOn: boolean) => {
                      this.window.uiContext?.animateTo({ curve: curves.springMotion() }, () => {
                        this.debug_mode_is_on = IsOn;
                      })
                      AppPreference.setPreference(PREF_KEYS.DEBUG_MODE_ON, IsOn);
                    }
                  })

                  SubItemDivider()
                }

                SubItemSelect({
                  icon: $r('sys.symbol.dark'),
                  title: $r('app.string.setting_color_mode'),
                  values: [$r('app.string.setting_color_mode_system'), $r('app.string.setting_color_mode_dark'),
                    $r('app.string.setting_color_mode_light'),],
                  description: $r('app.string.setting_color_mode_desc'),
                  selected: AppPreference.getPreference(PREF_KEYS.APPEARANCE_COLOR_MODE) as number ??
                    SettingColorMode.System,
                  onChange: (index: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_COLOR_MODE, index);
                    const color_map: Map<SettingColorMode, ConfigurationConstant.ColorMode> = new Map([
                      [SettingColorMode.System, ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET],
                      [SettingColorMode.Dark, ConfigurationConstant.ColorMode.COLOR_MODE_DARK],
                      [SettingColorMode.Light, ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT],
                    ]);
                    this.appCtx.getApplicationContext().setColorMode(color_map.get(index));
                  }
                })

                SubItemDivider()

                SubItemEnumSelect({
                  icon: $r('sys.symbol.slider_horizontal_2'),
                  title: $r('app.string.setting_top_effect_type'),
                  options: AVAILABLE_TOP_EFFECT_TYPES,
                  description: $r('app.string.setting_top_effect_type_desc'),
                  selected: AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE) as number ??
                    SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR,
                  onChange: (value: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE, value);
                    if (this.appCtx.eventHub != undefined) {
                      this.appCtx.eventHub.emit(EVENT_NAMES.TOP_EFFECT_TYPE_CHANGED);
                    }
                  }
                })

                SubItemDivider()

                SubItemIconManager()

                SubItemDivider()

                SubItemButton({
                  symbol: $r("sys.symbol.paintpalette"),
                  text: $r('app.string.customize_appearance')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.AppearancePage, null);
                  }, 1000))

                SubItemDivider()
              }
            }
            .padding({ left: 10, right: 10 })
          }
          .clip(false)
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, {alwaysEnabled: true})
          .backgroundColor($r('app.color.window_background'))
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.window_background'))
      }
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
            mainTitle: $r('app.string.app_appearance'),
          },
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.window_background'))
  }
}

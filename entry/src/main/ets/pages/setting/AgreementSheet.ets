import { SubItemButton } from '../../components/SubItemButton';
import { SettingItem } from '../../components/SettingItem';
import { SubItemDivider } from '../../components/SubItemDivider';
import { throttle } from '../../utils/UiUtils';
import { ROUTE_NAMES } from '../../utils/AppPreference';
import { WebPage, WebPageParams } from '../WebPage';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

@Preview
@ComponentV2
export struct AgreementSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  private sheetScroller: Scroller = new Scroller();

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.WebPage) {
      WebPage({ scrollEffectType: this.scrollEffectType, pageParams: param as WebPageParams })
    }
  }

  build() {
    Column() {
      HdsNavigation(this.pageInfos) {
        Column() {
          List({ scroller: this.sheetScroller, space: 10 }) {
            ListItem() {
              SettingItem({ title: "" }) {
                SubItemButton({ symbol: $r("sys.symbol.person_shield"), text: $r('app.string.privacy_statement') })
                  .onClick(throttle((event) => {
                    const privacyUrl = AppStorage.get("AppPrivacyManageInfoUrl") as string;
                    this.pageInfos.pushPathByName(ROUTE_NAMES.WebPage,
                      new WebPageParams(privacyUrl, $r('app.string.privacy_statement')));
                  }, 1000))

                SubItemDivider()

                SubItemButton({
                  symbol: $r("sys.symbol.doc_plaintext_and_pencil"),
                  text: $r('app.string.user_agreement')
                })
                  .onClick(throttle((event) => {
                    const privacyUrl = AppStorage.get("AppUserAgreementUrl") as string;
                    this.pageInfos.pushPathByName(ROUTE_NAMES.WebPage,
                      new WebPageParams(privacyUrl,
                        $r('app.string.user_agreement')));
                  }, 1000))

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
            mainTitle: $r('app.string.setting_agreement_statement'),
          },
        }
      })
    }
  }
}

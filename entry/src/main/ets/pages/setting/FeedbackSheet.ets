import { SubItemButton } from '../../components/SubItemButton';
import { SettingItem } from '../../components/SettingItem';
import { common } from '@kit.AbilityKit';
import { throttle, startBrowsableAbility } from '../../utils/UiUtils';
import { ROUTE_NAMES, EXTERNAL_URLS } from '../../utils/AppPreference';
import { WebPage, WebPageParams } from '../WebPage';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { SubItemDivider } from '../../components/SubItemDivider';

@Preview
@ComponentV2
export struct FeedbackSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  private sheetScroller: Scroller = new Scroller();
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;

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
                SubItemButton({
                  symbol: $r("sys.symbol.doc_plaintext"),
                  text: $r('app.string.feedback_survey')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.WebPage,
                      new WebPageParams(EXTERNAL_URLS.FEEDBACK_SURVEY, $r('app.string.feedback_survey')));
                  }, 1000))

                SubItemDivider()

                SubItemButton({
                  icon: $r('app.media.github_logo'),
                  text: $r('app.string.feedback_github')
                })
                  .onClick(throttle((event) => {
                    startBrowsableAbility(this.appCtx, EXTERNAL_URLS.FEEDBACK_GITHUB);
                  }, 1000))
                //
                // SubItemDivider()
                //
                // SubItemButton({
                //   symbol: $r('sys.symbol.exclamationmark_triangle'),
                //   text: $r('app.string.feedback_urgent')
                // })
                //   .onClick(throttle((event) => {
                //
                //   }, 1000))
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
            mainTitle: $r('app.string.setting_feedback'),
          },
        }
      })
    }
  }
}

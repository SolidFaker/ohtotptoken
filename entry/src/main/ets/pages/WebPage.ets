import { webview } from '@kit.ArkWeb';
import { CommonConstants } from '../utils/CommonConstants';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

@ObservedV2
export class WebPageParams {
  url: string = '';
  title: ResourceStr = '';

  constructor(url: string, title: ResourceStr) {
    this.url = url;
    this.title = title;
  }
}

@Entry
@ComponentV2
export struct WebPage {
  pageInfos: NavPathStack | null = null;
  @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param pageParams: WebPageParams = new WebPageParams('', '');
  @Local webViewController: webview.WebviewController = new webview.WebviewController();

  build() {
    HdsNavDestination() {
      Column() {
        Web({ controller: this.webViewController, src: this.pageParams.url })
          .darkMode(WebDarkMode.Auto)
          .domStorageAccess(true)
          .zoomAccess(true)
          .mixedMode(MixedMode.All)
          .cacheMode(CacheMode.Default)
          .javaScriptAccess(true)
          .width(CommonConstants.FULL_PERCENT)
          .height(CommonConstants.FULL_PERCENT)
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('app.color.window_background'))
    }
    .titleMode(HdsNavDestinationTitleMode.MODAL)
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
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: this.pageParams.title,
        },
      }
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}

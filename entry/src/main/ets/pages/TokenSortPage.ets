import { TokenItem } from "../components/TokenItem";
import { AppPreference, TokenPreference, EVENT_NAMES } from "../utils/AppPreference";
import { TokenConfig } from "../utils/TokenConfig";
import { TokenStore } from "../utils/TokenStore";
import { GenericDataSource } from "../utils/GenericDataSource";
import { AppWindowInfo } from "../entryability/EntryAbility";
import { AppStorageV2 } from "@kit.ArkUI";
import { common } from "@kit.AbilityKit";
import { CommonConstants } from "../utils/CommonConstants";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from "@kit.UIDesignKit";

let tkStore = TokenStore.getInstance();

@Preview
@ComponentV2
export struct TokenSortPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local dataSource: GenericDataSource<TokenConfig> = new GenericDataSource([]);

  private sortListScroller: Scroller = new Scroller();

  // 使用 AppStorage 获取 context
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onTokenChangedHandler: () => void = () => {};

  aboutToAppear(): void {
    this.onTokenChangedHandler = () => this.loadTokens();
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    this.loadTokens();
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
  }

  private async loadTokens(): Promise<void> {
    this.tokens = await tkStore.getTokens();
    this.dataSource.updateData(this.tokens);
  }

  build() {
    HdsNavDestination() {
      Column() {
        List({ space: this.token_preference.app_appearance_item_space, scroller: this.sortListScroller }) {
          LazyForEach(this.dataSource, (token: TokenConfig, index: number) => {
            ListItem() {
              TokenItem({
                Config: token,
                sortMode: true,
                Update: async (conf_new): Promise<boolean> => {
                  try {
                    await tkStore.updateToken(conf_new);
                    return true;
                  } catch (e) {
                    hilog.error(0, 'TokenSortPage', `Update failed: ${e}`);
                    return false;
                  }
                }
              })
            }
          }, (item: TokenConfig) => {
            return item.TokenUUID
          })
            .onMove((from: number, to: number) => {
              setTimeout(() => tkStore.updateTokenRank(from, to), 500);
            })

        }
        .clip(false)
        .alignListItem(ListItemAlign.Center)
        .lanes({ minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width })
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .contentEndOffset(this.window.AvoidBottomHeight)
      }
      .backgroundColor($r('app.color.window_background'))
      .width('100%')
      .height('100%')
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
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
          backgroundStyle: {
            maskExtraHeight: 0
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            maskExtraHeight: 0
          }
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
          mainTitle: $r('app.string.token_sort_page_title'),
        },
      }
    })
    .bindToScrollable([this.sortListScroller])
  }
}

import { TokenItem } from "../components/TokenItem";
import { FortiConfigDialog } from "../dialogs/FortiConfigDialog";
import { TOTPConfigDialog } from "../dialogs/OTPConfigDialog";
import { QRCodeDialog } from "../dialogs/QRCodeDialog";
import { SteamConfigDialog } from "../dialogs/SteamConfigDialog";
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from "../utils/AppPreference";
import { otpType, TokenConfig, TokenConfigVM } from "../utils/TokenConfig";
import { TokenStore } from "../utils/TokenStore";
import { convertToken2URI } from "../utils/TokenUtils";
import { AppStorageV2 } from "@kit.ArkUI";
import { AppWindowInfo } from "../entryability/EntryAbility";
import { GenericDataSource } from "../utils/GenericDataSource";
import { showSnackBar, SnackBarNotifyType } from "../utils/HdsSnackBarUtils";
import { common } from "@kit.AbilityKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  BottomBuilderShowType,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from "@kit.UIDesignKit";
import { CommonConstants } from "../utils/CommonConstants";

let tkStore = TokenStore.getInstance();

function toVMs(tokens: TokenConfig[]): TokenConfigVM[] {
  return tokens.map(t => new TokenConfigVM(t));
}

@Preview
@ComponentV2
export struct TokenSearchPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local tokens: TokenConfig[] = [];
  @Local dataSource: GenericDataSource<TokenConfigVM> = new GenericDataSource([]);
  @Local tokenSearchText: string = '';
  @Local token_copy_guide_popup: boolean = false;

  private searchListScroller: Scroller = new Scroller();
  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;
  private dialog_qrcode?: CustomDialogController;
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onTokenChangedHandler: () => void = () => {};
  private onSingleTokenUpdatedHandler: (token: TokenConfig) => void = () => {};

  aboutToAppear(): void {
    this.onTokenChangedHandler = () => this.loadTokens();
    this.onSingleTokenUpdatedHandler = (token: TokenConfig) => this.handleTokenSingleUpdated(token);
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
    if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
      this.token_copy_guide_popup = true;
    }
    this.loadTokens();
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_CHANGED, this.onTokenChangedHandler);
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
  }

  private async loadTokens(): Promise<void> {
    this.tokens = await tkStore.getTokens();
    this.filterCurrentTokens(this.tokenSearchText);
  }

  private filterCurrentTokens(filterWord: string): void {
    const keyword = filterWord.trim().toLowerCase();
    if (keyword.length === 0) {
      this.dataSource.updateData(toVMs(this.tokens));
      return;
    }
    const filtered = this.tokens.filter((token) => {
      return token.TokenIssuer.toLowerCase().indexOf(keyword) >= 0 ||
        token.TokenName.toLowerCase().indexOf(keyword) >= 0;
    });
    this.dataSource.updateData(toVMs(filtered));
  }

  private handleTokenSingleUpdated(token: TokenConfig): void {
    const tokenIndex = this.tokens.findIndex((item: TokenConfig) => item.TokenUUID === token.TokenUUID);
    if (tokenIndex >= 0) {
      this.tokens[tokenIndex] = token;
    }
    const index = this.dataSource.findIndex((vm: TokenConfigVM) => vm.config.TokenUUID === token.TokenUUID);
    if (index >= 0) {
      const vm = this.dataSource.getData(index);
      vm.config = token;
      vm.refreshObjId();
      this.dataSource.updateItem(index, vm);
    }
  }

  private async updateSingleToken(conf: TokenConfig, toast: boolean): Promise<boolean> {
    try {
      await tkStore.updateToken(conf);
      if (toast) {
        showSnackBar($r('app.string.toast_token_update', conf.TokenIssuer, conf.TokenName), SnackBarNotifyType.SUCCESS);
      }
      return true;
    } catch (e) {
      hilog.error(0, 'TokenSearchPage', `updateSingleToken failed: ${e}`);
      return false;
    }
  }

  @Builder
  SearchBottomBuilder() {
    Column() {
      Search({
        placeholder: $r('app.string.token_search_placeholder'),
        value: this.tokenSearchText
      })
        .width('100%')
        .height(40)
        .onChange((value: string) => {
          this.tokenSearchText = value;
          this.filterCurrentTokens(value);
        })
        .onSubmit((value: string) => {
          this.tokenSearchText = value;
          this.filterCurrentTokens(value);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  build() {
    HdsNavDestination() {
      Column() {
        List({ space: this.token_preference.app_appearance_item_space, scroller: this.searchListScroller }) {
          if (this.dataSource.totalCount() === 0) {
            ListItem() {
              Text(this.tokenSearchText.trim().length > 0 ? $r('app.string.app_token_list_search_msg') :
              $r('app.string.app_guide_msg'))
                .textAlign(TextAlign.Center)
                .fontSize(20)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ top: 80 })
            }
          }

          LazyForEach(this.dataSource, (vm: TokenConfigVM) => {
            ListItem() {
              TokenItem({
                Config: vm.config,
                Update: async (conf_new): Promise<boolean> => {
                  return await this.updateSingleToken(conf_new, false);
                }
              })
                .bindPopup(this.token_copy_guide_popup && vm.config.TokenUUID === this.dataSource.getData(0)?.config.TokenUUID, {
                  placement: Placement.Left,
                  message: this.getUIContext().getHostContext()?.resourceManager
                    .getStringSync($r('app.string.token_copy_guide_popup').id),
                  onStateChange: (e) => {
                    if (!e.isVisible) {
                      this.token_copy_guide_popup = false;
                    }
                  },
                  primaryButton: {
                    value: this.getUIContext().getHostContext()?.resourceManager
                      .getStringSync($r('app.string.token_copy_guide_popup_Confirm').id),
                    action: () => {
                      if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
                        AppPreference.setPreference(PREF_KEYS.SHOW_GUIDE_TIPS, false);
                      }
                      this.token_copy_guide_popup = false;
                    }
                  }
                })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.TokenItemSwipeEnd(vm);
                },
              }
            })
          }, (vm: TokenConfigVM) => vm.objid)
        }
        .clip(false)
        .alignListItem(ListItemAlign.Center)
        .lanes({ minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width })
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .contentStartOffset(this.window.AvoidTopHeight + CommonConstants.AVOID_TOP_WITH_SEARCHBAR_HEIGHT)
        .contentEndOffset(this.window.AvoidBottomHeight)
      }
      .backgroundColor($r('app.color.window_background'))
      .width('100%')
      .height('100%')
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType,
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.app_ua_search_token'),
        },
        bottomBuilder: {
          builder: (): void => this.SearchBottomBuilder(),
          height: 56,
          showType: BottomBuilderShowType.DIRECTLY_SHOW,
        },
      }
    })
    .bindToScrollable([this.searchListScroller])
  }

  showQRCodeDialog(conf: TokenConfig): void {
    this.dialog_qrcode = new CustomDialogController({
      builder: QRCodeDialog({
        content: convertToken2URI(conf),
        winSize: this.window.Size
      })
    });
    this.dialog_qrcode.open();
  }

  @Builder
  TokenItemSwipeEnd(vm: TokenConfigVM) {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.qrcode'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Orange)
      .padding(10)
      .onClick(() => {
        this.showQRCodeDialog(vm.config);
      })

      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.square_and_pencil_fill'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Gray)
      .padding(10)
      .onClick(() => {
        if (vm.config.TokenType === otpType.TOTP || vm.config.TokenType === otpType.HOTP ||
          vm.config.TokenType === undefined) {
          this.dialog_totp_config = new CustomDialogController({
            builder: TOTPConfigDialog({
              conf_json: JSON.stringify(vm.config),
              confirm: async (new_conf): Promise<boolean> => {
                const md: TokenConfig = JSON.parse(new_conf);
                return await this.updateSingleToken(md, true);
              }
            })
          })
          this.dialog_totp_config.open()
        } else if (vm.config.TokenType === otpType.Forti) {
          this.dialog_forti_config = new CustomDialogController({
            builder: FortiConfigDialog({
              conf_json: JSON.stringify(vm.config),
              confirm: async (new_conf): Promise<boolean> => {
                const md: TokenConfig = JSON.parse(new_conf);
                return await this.updateSingleToken(md, true);
              }
            })
          })
          this.dialog_forti_config.open()
        } else if (vm.config.TokenType === otpType.Steam) {
          this.dialog_steam_config = new CustomDialogController({
            builder: SteamConfigDialog({
              conf_json: JSON.stringify(vm.config),
              confirm: async (new_conf): Promise<boolean> => {
                const md: TokenConfig = JSON.parse(new_conf);
                return await this.updateSingleToken(md, true);
              }
            })
          })
          this.dialog_steam_config.open()
        }
      })

      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.trash_fill'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Red)
      .padding(10)
      .onClick(async () => {
        AlertDialog.show({
          message: $r('app.string.alert_remove_confirm_msg', vm.config.TokenName),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          primaryButton: {
            defaultFocus: false,
            value: $r('app.string.dialog_btn_cancel'),
            action: () => {
              return;
            }
          },
          secondaryButton: {
            value: $r('app.string.dialog_btn_confirm'),
            fontColor: Color.Red,
            action: async () => {
              tkStore.deleteToken(vm.config.TokenUUID);
            }
          }
        })
      })
    }
    .margin({ left: 10 })
  }
}

import { TokenItem } from "../components/TokenItem";
import { FortiConfigDialog } from "../dialogs/FortiConfigDialog";
import { TOTPConfigDialog } from "../dialogs/OTPConfigDialog";
import { QRCodeDialog } from "../dialogs/QRCodeDialog";
import { SteamConfigDialog } from "../dialogs/SteamConfigDialog";
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from "../utils/AppPreference";
import { otpType, TokenConfig, TokenConfigVM } from "../utils/TokenConfig";
import { TokenStore } from "../utils/TokenStore";
import { convertToken2URI } from "../utils/TokenUtils";
import { AppStorageV2, curves, window } from "@kit.ArkUI";
import { AppWindowInfo } from "../entryability/EntryAbility";
import { CommonConstants } from "../utils/CommonConstants";
import { GenericDataSource } from "../utils/GenericDataSource";
import { showSnackBar, SnackBarNotifyType } from "../utils/HdsSnackBarUtils";
import { common } from "@kit.AbilityKit";
import { hilog } from "@kit.PerformanceAnalysisKit";

let tkStore = TokenStore.getInstance();

/** 将纯数据 TokenConfig[] 转为带刷新标识的 ViewModel 数组，供 LazyForEach 消费 */
function toVMs(tokens: TokenConfig[]): TokenConfigVM[] {
  return tokens.map(t => new TokenConfigVM(t));
}

@Preview
@ComponentV2
export struct TokenListPage {
  @Require @Param Tokens: TokenConfig[] = [];
  @Require @Param appBottomAvoidHeight: number = 0;
  @Require @Param appTopAvoidHeight: number = 0;
  @Require @Param appWindowSize: window.Size = { width: 0, height: 0 };
  @Require @Param TabBarVisible: boolean = true;
  @Param listScroller: Scroller = new Scroller();
  @Event updateTokenConfig: (conf: TokenConfig, toast: boolean) => Promise<boolean> = async () => false;
  @Event updateTokenConfigs: (tokens: Array<TokenConfig>) => void = () => {};

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local token_copy_guide_popup: boolean = false;

  @Local dataSource: GenericDataSource<TokenConfigVM> = new GenericDataSource([]);

  /** 全量刷新：父组件 Tokens 变化时重建整个 ViewModel 数组 */
  @Monitor("Tokens")
  onTokensChange(monitor: IMonitor): void {
    this.dataSource.updateData(toVMs(monitor.value()?.now as TokenConfig[]));
  }

  @Local token_list_search_result: TokenConfigVM[] = [];
  @Local token_list_search_visible: boolean = false;
  @Local token_list_search_enable: boolean = false;
  @Local token_list_search_str: string = '';
  @Local id_list: string[] = ['search_bar', 'search_blur_anchor'];

  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;
  private dialog_qrcode?: CustomDialogController;
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private toggleSearchHandler: () => void = () => {};
  private onSingleTokenUpdatedHandler: (token: TokenConfig) => void = () => {};

  async filterCurrentTokens(filter_word: string): Promise<void> {
    if (filter_word.length === 0) {
      this.token_list_search_enable = false;
      this.dataSource.updateData(toVMs(this.Tokens));
      return;
    }
    this.token_list_search_enable = true;
    const lower_filter_word = filter_word.toLowerCase();
    const filtered = this.Tokens.filter((token) => {
      return token.TokenIssuer.toLowerCase().indexOf(lower_filter_word) >= 0 || token.TokenName.toLowerCase().indexOf(lower_filter_word) >= 0
    });
    this.token_list_search_result = toVMs(filtered);
    this.dataSource.updateData(this.token_list_search_result);
  }

  aboutToAppear(): void {
    this.dataSource = new GenericDataSource(toVMs(this.Tokens));
    if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
      this.token_copy_guide_popup = true;
    }
    this.onSingleTokenUpdatedHandler = (token: TokenConfig) => this.handleTokenSingleUpdated(token);
    this.appCtx.eventHub?.on(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
  }

  onDidBuild(): void {
    this.toggleSearchHandler = () => { this.toggleTokenSearchByTitleBar() };
    this.appCtx.eventHub?.on(EVENT_NAMES.TOGGLE_TOKEN_SEARCH, this.toggleSearchHandler);
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TOGGLE_TOKEN_SEARCH, this.toggleSearchHandler);
    this.appCtx.eventHub?.off(EVENT_NAMES.TOKEN_SINGLE_UPDATED, this.onSingleTokenUpdatedHandler);
  }

  private toggleTokenSearchByTitleBar(): void {
    const nextVisible = !this.token_list_search_visible;
    this.window.uiContext?.animateTo({ duration: 250, curve: curves.springMotion() }, () => {
      this.token_list_search_visible = nextVisible;
      if (!this.token_list_search_visible) {
        this.token_list_search_str = '';
        this.token_list_search_enable = false;
      }
    })
    if (nextVisible) {
      setTimeout(() => {
        focusControl.requestFocus(this.id_list[0])
      }, 180)
    } else {
      setTimeout(() => {
        focusControl.requestFocus(this.id_list[1])
      }, 100)
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
      hilog.error(0, 'TokenListPage', `updateSingleToken failed: ${e}`);
      return false;
    }
  }

  /**
   * 单条 Token 精准刷新（由 TOKEN_SINGLE_UPDATED 事件驱动）。
   *
   * 流程：替换 vm.config 引用 + 刷新 objid → updateItem 触发 notifyDataChange
   * → LazyForEach 检测到 key 变化 → 销毁旧行并创建新行 → aboutToAppear 重新初始化。
   *
   * 对于尚未加载到 LazyForEach 可视区域的 Token（滚动范围之外），
   * 底层数组已在 TokenStore 中更新，下次滚动至此处时会自然使用新数据。
   */
  private handleTokenSingleUpdated(token: TokenConfig): void {
    const index = this.dataSource.findIndex((vm: TokenConfigVM) => vm.config.TokenUUID === token.TokenUUID);
    if (index >= 0) {
      const vm = this.dataSource.getData(index);
      vm.config = token;
      vm.refreshObjId();
      this.dataSource.updateItem(index, vm);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Button('')
        .id(this.id_list[1])
        .focusable(true)
        .width(1)
        .height(1)
        .opacity(0)
        .position({ x: 0, y: 0 })
      if (this.Tokens.length === 0) {
        Row() {
          Text(this.token_list_search_enable ? $r('app.string.app_token_list_search_msg') :
          $r('app.string.app_guide_msg'))
            .textAlign(TextAlign.Center)
            .fontSize(20)
            .width('100%')
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .height('100%')

      }
      Column() {
        List({ space: this.token_preference.app_appearance_item_space, initialIndex: 0, scroller: this.listScroller }) {
          ListItemGroup() {
            ListItem() {
              Column() {
                Row()
                  .height(this.TabBarVisible ? CommonConstants.AVOID_TOP_BASE_HEIGHT + this.appTopAvoidHeight : this.appTopAvoidHeight)
                  .width('100%')
                
                Stack({ alignContent: Alignment.End }) {
                  TextInput({
                    placeholder: $r('app.string.token_search_placeholder'),
                    text: this.token_list_search_str
                  })
                    .id(this.id_list[0])
                    .onChange((value) => {
                      this.token_list_search_str = value;
                      this.filterCurrentTokens(this.token_list_search_str);
                    })
                    .onSubmit(() => {
                      this.filterCurrentTokens(this.token_list_search_str);
                    })
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(20)
                    .fontWeight(FontWeight.Medium)
                    .fontColor([$r('app.color.item_fg')])
                    .padding({ right: 10 })
                    .onClick(() => {
                      this.toggleTokenSearchByTitleBar();
                    })
                }
                .padding({ left: 10, right: 10, top: this.token_list_search_visible || this.token_list_search_enable ? 10 : 0 })
                .width('100%')
                .height(this.token_list_search_visible || this.token_list_search_enable ? 56 : 0)
                .opacity(this.token_list_search_visible || this.token_list_search_enable ? 1 : 0)
                .translate({
                  x: 0,
                  y: this.token_list_search_visible || this.token_list_search_enable ? 0 : -12
                })
                .clip(true)
              }
            }
          }

          // key = vm.objid：变更 objid 后 LazyForEach 视为"新数据"，销毁旧组件并创建新实例
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
                      this.token_copy_guide_popup = false
                    }
                  },
                  primaryButton: {
                    value: this.getUIContext().getHostContext()?.resourceManager
                      .getStringSync($r('app.string.token_copy_guide_popup_Confirm').id),
                    action: () => {
                      if (AppPreference.getPreference(PREF_KEYS.SHOW_GUIDE_TIPS) as boolean) {
                        AppPreference.setPreference(PREF_KEYS.SHOW_GUIDE_TIPS, false)
                      }
                      this.token_copy_guide_popup = false;
                    }
                  }
                })

            }
            .swipeAction({
              end: {
                builder: () => {
                  this.TokenItemSwipeEnd(vm)
                },
              }
            })
          }, (vm: TokenConfigVM) => vm.objid) // keyGenerator: objid 变化 = 组件重建
        }
        .contentEndOffset(this.TabBarVisible ? (80 + this.appBottomAvoidHeight) : (20 + this.appBottomAvoidHeight))
        .alignListItem(ListItemAlign.Center)
        .lanes({ minLength: 400, maxLength: this.token_preference.app_appearance_item_max_width })
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .chainAnimation(this.token_preference.app_appearance_chain_animation_enable)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      .alignItems(HorizontalAlign.Center)
    }
  }

  showQRCodeDialog(conf: TokenConfig): void {
    this.dialog_qrcode = new CustomDialogController({
      builder: QRCodeDialog({
        content: convertToken2URI(conf),
        winSize: this.appWindowSize
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

      if (this.TabBarVisible) {
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
      }

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
              return
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

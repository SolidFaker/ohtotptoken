import { BusinessError } from '@kit.BasicServicesKit';
import { nowUnixSeconds, otpType, TokenConfig } from 'common';
import { convertToken2URI, copyText, generateOTP } from 'common';
import { SteamUtils } from 'common';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from 'common';
import { AppStorageV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { QRCodeDialog } from 'uikit';
import { AppWindowInfo } from 'common';
import { TokenStore } from 'common';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { AppFonts } from 'common';
import { ArcTokenIcon } from './ArcTokenIcon';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 手表端验证码字号上限: 手表屏幕小, 手机端同步的字号(默认 30)过大, 封顶 22 */
const WATCH_TOKEN_FONT_SIZE_MAX = 22;

let current_token_hide_map: Map<string, boolean> = new Map();
let tkStore = TokenStore.getInstance();

@Preview
@ComponentV2
export struct ArcTokenItem {
  @Require @Param Config: TokenConfig = new TokenConfig();
  @Event Update: (conf: TokenConfig) => Promise<boolean> = async () => false;

  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  @Local TokenNumber: string = '000000';
  @Local TokenNumberNext: string = '000000';
  @Local TokenCounter: string = '0';
  @Local TokenLeftPeriod: number = 0;
  @Local btn_hotp_clicked: number = 0;
  @Local TokenHide: boolean = current_token_hide_map[this.Config.TokenUUID] ?? true;

  /**
   * 隐藏令牌设置开启时重置本令牌为隐藏态.
   *
   * TokenHide 是 @Local 状态(默认隐藏, 用户点击验证码后切换为显示并缓存到
   * current_token_hide_map). 若用户此前手动显示了验证码, 手机端同步"隐藏令牌"
   * 设置开启后 TokenHide 残留 false, 显示逻辑 (TokenHide && enable) 为 false
   * 导致设置不生效——监听设置变化, 开启时统一回到隐藏态.
   */
  @Monitor('token_preference.app_safety_hide_token_enable')
  onHideTokenEnableChanged(monitor: IMonitor): void {
    if (this.token_preference.app_safety_hide_token_enable) {
      this.TokenHide = true;
    }
  }

  @Local menu_icon_trash: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.trash')).fontSize('22vp').fontColor([Color.Red]);
  @Local menu_icon_qrcode: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.qrcode')).fontSize('22vp');
  @Local menu_icon_copy: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.doc_text_on_doc_text')).fontSize('22vp');

  private token_steps: number = 0;
  // 使用 AppStorage 获取 context，避免在 aboutToAppear（build 之前）调用 getUIContext()
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onTimestampChangedHandler: (timestamp: number, force: boolean) => void = () => {};

  @Computed
  get is_dark_mode() {
    return this.window.ColorMode == ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  @Computed
  get token_color_normal() {
    return this.is_dark_mode ?
    this.token_preference.app_appearance_token_color_dark : this.token_preference.app_appearance_token_color;
  }

  @Computed
  get token_color_expiring() {
    return this.is_dark_mode ?
    this.token_preference.app_appearance_token_next_color_dark : this.token_preference.app_appearance_token_next_color;
  }

  @Computed
  get hotp_next_btn_color() {
    return this.is_dark_mode ?
      this.token_preference.app_appearance_token_counter_dark_color_end :
      this.token_preference.app_appearance_token_counter_dark_color_end;
  }

  @Computed
  get token_color_change_threshold() {
    return this.token_preference.app_appearance_token_counter_next_margin;
  }

  @Computed
  get token_progress_color_normal(): LinearGradient {
    return new LinearGradient(
      [
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_dark_color_start :
          this.token_preference.app_appearance_token_counter_light_color_start,
          offset: 0
        },
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_dark_color_end :
          this.token_preference.app_appearance_token_counter_light_color_end,
          offset: 1
        },
      ]);
  }

  @Computed
  get token_progress_color_near_next(): LinearGradient {
    return new LinearGradient(
      [
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_next_dark_color_start :
          this.token_preference.app_appearance_token_counter_next_light_color_start,
          offset: 0
        },
        {
          color: this.is_dark_mode ?
          this.token_preference.app_appearance_token_counter_next_dark_color_end :
          this.token_preference.app_appearance_token_counter_next_light_color_end,
          offset: 1
        },
      ]);
  }

  aboutToAppear(): void {
    this.onTimestampChangedHandler = (timestamp: number, force: boolean) => this.onTimestampChanged(timestamp, force);
    this.appCtx.eventHub?.on(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
    this.updateToken();
  }

  // 清理事件监听，防止组件销毁后监听器泄漏
  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.TIMESTAMP_CHANGED, this.onTimestampChangedHandler);
  }

  onTimestampChanged(timestamp: number, force: boolean): void {
    if (this.Config.TokenType !== otpType.HOTP) {
      this.token_steps = Math.floor(timestamp / this.Config.TokenPeriod);
      this.TokenLeftPeriod = this.Config.TokenPeriod - timestamp % this.Config.TokenPeriod;
      if (this.TokenLeftPeriod == this.Config.TokenPeriod || force) {
        this.updateTOTPToken();
      }
    }
  }

  updateToken() {
    if (this.Config === undefined) {
      return;
    }
    if (this.Config.TokenType == otpType.HOTP) {
      this.updateHOTPToken();
    } else {
      const timestamp = nowUnixSeconds();
      this.onTimestampChanged(timestamp, true);
    }
  }

  updateHOTPToken() {
    this.TokenCounter = this.Config.TokenCounter.toString();
    this.TokenNumber = generateOTP(this.Config, this.Config.TokenCounter).toString().padStart(this.Config.TokenDigits, '0');
    this.TokenNumberNext = generateOTP(this.Config, this.Config.TokenCounter + 1).toString().padStart(this.Config.TokenDigits, '0');
  }

  updateTOTPToken() {
    let int_code = generateOTP(this.Config, this.token_steps);
    let int_code_next = generateOTP(this.Config, this.token_steps + 1);
    if (this.Config.TokenType === otpType.Steam) {
      this.TokenNumber = SteamUtils.SteamTokenFromTOTP(int_code);
      this.TokenNumberNext = SteamUtils.SteamTokenFromTOTP(int_code_next);
    } else {
      this.TokenNumber = int_code.toString().padStart(this.Config.TokenDigits, '0');
      this.TokenNumberNext = int_code_next.toString().padStart(this.Config.TokenDigits, '0');
    }
  }

  build() {
    Row({ space: 10 }) {
      ArcTokenIcon({ issuer: this.Config.TokenIssuer })
      // 手表屏幕小: 不显示用户名/主机名, 内容区占据图标后全部剩余空间

      if (AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON)) {
        Text(this.Config.RankScore.toString())
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .maxLines(1)
          .fontSize(30)
      }

      if (this.TokenHide && this.token_preference.app_safety_hide_token_enable) {
        // 隐藏验证码时显示名称与主机名(替代遮罩, 便于识别令牌), 点击仍可切回显示
        // (手表小屏用名称识别令牌; 保留 dev 侧 responseRegion 扩大点击热区)
        Column() {
          Text(this.Config.TokenName)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffe0e0e0')
          Text(this.Config.TokenIssuer)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .fontSize(12)
            .fontColor($r('app.color.str_gray'))
        }
        // 与验证码区一致的居中布局: 占据图标后全部剩余空间
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .responseRegion({
          x: 0,
          y: -20,
          width: '100%',
          height: 48
        })
        .onClick(() => {
          this.TokenHide = !this.TokenHide;
          current_token_hide_map[this.Config.TokenUUID] = false;
        })

      } else {
        Column() {
          Text(this.TokenNumber)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .maxLines(1)
            .fontColor('#ffe0e0e0')
            .fontSize(Math.min(this.token_preference.app_appearance_token_font_size, WATCH_TOKEN_FONT_SIZE_MAX))
            .fontWeight(this.token_preference.app_appearance_token_font_weight)
            .fontFamily(AppFonts.CODE_FONT)
          if (this.Config.TokenType == otpType.HOTP) {
            Text(this.TokenCounter + (this.token_preference.app_appearance_show_next_token_enable ? ":" + this.TokenNumberNext : ""))
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .maxLines(1)
              .fontColor($r('app.color.str_gray'))
              .fontSize(10)
          } else if (this.token_preference.app_appearance_show_next_token_enable) {
            Text(this.TokenNumberNext)
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .maxLines(1)
              .fontColor($r('app.color.str_gray'))
              .fontSize(10)
              .fontFamily(AppFonts.CODE_FONT)
          }
        }
        // 验证码区: 占据图标后全部剩余空间, 当前令牌与下一令牌水平居中相互对齐
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          if (this.token_preference.app_safety_hide_token_enable) {
            this.TokenHide = !this.TokenHide;
            current_token_hide_map[this.Config.TokenUUID] = true;
          }
        })

        if (this.Config.TokenType == otpType.HOTP) {
          SymbolGlyph($r('sys.symbol.lock_filled_arrow_counterclockwise'))
            .fontColor([this.hotp_next_btn_color])
            .fontSize(40)
            .fontWeight(FontWeight.Medium)
            .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
              this.btn_hotp_clicked)
            .onClick(() => {
              this.btn_hotp_clicked++;
              this.Config.TokenCounter++;
              this.Update(this.Config)
              this.updateHOTPToken();
            })
        } else {
          Stack() {
            Text(this.TokenLeftPeriod.toString())
            Progress({ value: this.TokenLeftPeriod, total: this.Config.TokenPeriod, type: ProgressType.Ring })
              .style({ strokeWidth: 8 })
              .width(40)
              .height(40)
              .color(this.TokenLeftPeriod <= this.token_color_change_threshold ?
                this.token_progress_color_near_next :
                this.token_progress_color_normal)
          }
        }
      }
    }
    .borderRadius(40)
    .padding(10)
    .justifyContent(FlexAlign.SpaceBetween)
    .width('100%')
    .height(this.token_preference.app_appearance_item_height)
    .backgroundColor('#20e0e0e0')
    .bindContextMenu(this.TokenRightCtxMenu, ResponseType.RightClick, { enableArrow: true })
  }

  @Builder
  QRCodeDialogBuilder(): void {
    QRCodeDialog({
      content: convertToken2URI(this.Config),
      winSize: this.window.Size
    })
  }

  private openQRCodeDialog(): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => {
        this.QRCodeDialogBuilder();
      }
    }).catch((error: BusinessError) => {
      hilog.error(error.code, 'ArcTokenItem', `open QR code dialog failed: ${error.message}`);
    });
  }

  @Builder
  TokenRightCtxMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: this.menu_icon_copy, content: $r('app.string.token_right_menu_copy') })
        .onClick(() => {
          copyText(this.TokenNumber, `${this.TokenNumber} copied`);
        })
        .accessibilityText($r('app.string.token_right_menu_copy'))
      MenuItem({ symbolStartIcon: this.menu_icon_qrcode, content: $r('app.string.token_right_menu_show_qrcode') })
        .onClick(() => {
          this.openQRCodeDialog();
        })
        .accessibilityText($r('app.string.token_right_menu_show_qrcode'))
      MenuItem({ symbolStartIcon: this.menu_icon_trash, content: $r('app.string.token_right_menu_delete') })
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            title: $r('app.string.alert_remove_title', this.Config.TokenIssuer),
            subtitle: this.Config.TokenName,
            message: $r('app.string.alert_remove_confirm_msg'),
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
              value: $r('app.string.dialog_btn_delete'),
              fontColor: Color.Red,
              action: async () => {
                tkStore.deleteToken(this.Config.TokenUUID);
              }
            }
          })

        })
        .contentFontColor(Color.Red)
        .accessibilityText($r('app.string.token_right_menu_delete'))
    }
  }
}

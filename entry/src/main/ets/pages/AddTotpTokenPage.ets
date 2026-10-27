import { MaterialTheme } from '../components/MaterialTheme';
import { TokenGroupSelect } from '../components/TokenGroupSelect';
import { AppWindowInfo, EVENT_NAMES, HMACAlgorithm, otpType, ROUTE_NAMES, ScanBarCode, showSnackBar,
  SnackBarNotifyType, TokenConfig } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, HdsNavDestination, ScrollEffectType } from '@kit.UIDesignKit';

import { AddTokenActionButton, AddTokenHeader, AddTokenPageParams, ADD_TOKEN_BOTTOM_ACTION_INSET, ADD_TOKEN_PAGE_INSET,
  ADD_TOKEN_SECTION_PADDING, ADD_TOKEN_SECTION_RADIUS,
  AddTokenSectionTitle, AddTokenTextField } from '../components/AddTokenForm';
import { PageScaffold } from '../components/PageScaffold';
import { IconPickerPageParams } from './IconPickerPage';
import { ResponsiveTokenEditStore, TokenSwitchPerf, TokenSwitchTrace } from '../utils/TokenSwitchPerf';

@Entry
@Preview
@ComponentV2
export struct AddTotpTokenPage {
  @Require @Param saveToken: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Param pageParams: AddTokenPageParams = new AddTokenPageParams();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event onExitFullScreen: () => void = () => {};
  @Event onBackToPlaceholder: () => void = () => {};

  @Local secret: string = '';
  @Local issuer: string = '';
  @Local accountName: string = '';
  @Local algorithm: HMACAlgorithm = 'SHA1';
  @Local digits: number = 6;
  @Local tokenType: otpType = otpType.TOTP;
  @Local period: number = 30;
  @Local counter: number = 0;
  @Local iconPath: string = '';
  @Local groupId: string = '';
  @Local isSaving: boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private pageInfos: NavPathStack | null = null;
  private scroller: Scroller = new Scroller();
  private activeEditConfig?: TokenConfig = undefined;
  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onResponsiveTokenSelectedHandler: (config: TokenConfig, trace: TokenSwitchTrace) => void = () => {};

  private readonly algorithms: HMACAlgorithm[] = ['SHA1', 'SHA224', 'SHA256', 'SHA384', 'SHA512', 'SM3', 'MD5'];

  private applyEditConfig(editConfig: TokenConfig): void {
    this.activeEditConfig = editConfig;
    this.secret = editConfig.TokenSecret;
    this.issuer = editConfig.TokenIssuer;
    this.accountName = editConfig.TokenName;
    this.algorithm = editConfig.TokenAlgorithm;
    this.digits = editConfig.TokenDigits;
    this.tokenType = editConfig.TokenType ?? otpType.TOTP;
    this.period = editConfig.TokenPeriod;
    this.counter = editConfig.TokenCounter;
    this.iconPath = editConfig.TokenIconPath ?? '';
    this.groupId = editConfig.TokenGroupId ?? '';
  }

  aboutToAppear(): void {
    const responsiveStore = ResponsiveTokenEditStore.getInstance();
    const switchTrace = this.pageParams.responsiveEdit ? responsiveStore.currentTrace() : this.pageParams.switchTrace;
    TokenSwitchPerf.mark(switchTrace, 'aboutToAppear');
    this.onResponsiveTokenSelectedHandler = (config: TokenConfig, trace: TokenSwitchTrace): void => {
      this.applyEditConfig(config);
      TokenSwitchPerf.reusedReady(trace, this.getUIContext());
    };
    if (this.pageParams.responsiveEdit) {
      this.appCtx.eventHub?.on(EVENT_NAMES.RESPONSIVE_TOKEN_SELECTION_CHANGED,
        this.onResponsiveTokenSelectedHandler);
    }
    const editConfig = this.pageParams.responsiveEdit ?
      (responsiveStore.currentConfig() ?? this.pageParams.editConfig) : this.pageParams.editConfig;
    if (editConfig !== undefined) {
      this.applyEditConfig(editConfig);
    } else if (this.pageParams.initialUri !== '') {
      this.applyOtpAuthUri(this.pageParams.initialUri);
    }
  }

  aboutToDisappear(): void {
    if (this.pageParams.responsiveEdit) {
      this.appCtx.eventHub?.off(EVENT_NAMES.RESPONSIVE_TOKEN_SELECTION_CHANGED,
        this.onResponsiveTokenSelectedHandler);
    }
  }

  private openIconPicker(): void {
    this.pageInfos?.pushPathByName(ROUTE_NAMES.IconPickerPage,
      new IconPickerPageParams(this.issuer, this.iconPath, (path: string) => this.iconPath = path));
  }

  private scanCode(): void {
    ScanBarCode().then((code: string) => {
      this.applyOtpAuthUri(code);
    }).catch((err: BusinessError) => {
      if (err.code !== 1000500002) {
        showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      }
    });
  }

  private applyOtpAuthUri(uriValue: string): void {
    let otpUrl: url.URL;
    try {
      otpUrl = url.URL.parseURL(uriValue);
    } catch (error) {
      hilog.error(0, 'AddTotpTokenPage', `Invalid OTPAuth URL: ${JSON.stringify(error)}`);
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }
    if (otpUrl.protocol !== 'otpauth:') {
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }

    const host = otpUrl.host.toLowerCase();
    if (host === 'totp') {
      this.tokenType = otpType.TOTP;
    } else if (host === 'hotp') {
      this.tokenType = otpType.HOTP;
    } else {
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
      return;
    }

    const label = decodeURIComponent(otpUrl.pathname.replace(/^\//, ''));
    const separator = label.indexOf(':');
    if (separator >= 0) {
      this.issuer = label.slice(0, separator).trim();
      this.accountName = label.slice(separator + 1).trim();
    } else if (label !== '') {
      this.accountName = label;
    }

    const params = new url.URLParams(otpUrl.search);
    this.secret = params.get('secret') ?? this.secret;
    this.issuer = params.get('issuer') ?? this.issuer;
    this.period = this.parsePositiveInt(params.get('period'), 30);
    this.counter = this.parseNonNegativeInt(params.get('counter'), 0);
    this.digits = this.parsePositiveInt(params.get('digits'), 6);
    const algorithm = (params.get('algorithm') ?? 'SHA1').toUpperCase() as HMACAlgorithm;
    if (this.algorithms.includes(algorithm)) {
      this.algorithm = algorithm;
    }
  }

  private parsePositiveInt(value: string | null, fallback: number): number {
    const parsed = Number.parseInt(value ?? '');
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
  }

  private parseNonNegativeInt(value: string | null, fallback: number): number {
    const parsed = Number.parseInt(value ?? '');
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
  }

  private canSave(): boolean {
    return this.secret.trim() !== '' && this.issuer.trim() !== '' && this.accountName.trim() !== '' && !this.isSaving;
  }

  private async submit(): Promise<void> {
    if (!this.canSave()) {
      return;
    }
    this.isSaving = true;
    const conf = new TokenConfig(this.secret.trim(), this.tokenType, this.issuer.trim(), this.accountName.trim(),
      this.algorithm, this.period, this.digits, this.counter, this.activeEditConfig?.RankScore ?? 0);
    if (this.activeEditConfig !== undefined) {
      conf.TokenUUID = this.activeEditConfig.TokenUUID;
    }
    conf.TokenIconPath = this.iconPath;
    conf.TokenGroupId = this.groupId;
    const ok = await this.saveToken(conf);
    this.isSaving = false;
    if (ok && !(this.window.AllowSplit && this.pageParams.editConfig !== undefined)) {
      this.pageInfos?.pop();
    }
  }

  private navigateBack(): void {
    if (this.window.AllowSplit && this.pageParams.editConfig !== undefined) {
      this.onBackToPlaceholder();
      return;
    }
    this.pageInfos?.pop();
  }

  build() {
    HdsNavDestination() {
      HdsNavigation() {
        PageScaffold() {
        Column() {
          List({ space: 12, scroller: this.scroller }) {
            ListItem() {
              AddTokenHeader({
                issuer: this.issuer,
                iconPath: this.iconPath,
                onIconClick: () => this.openIconPicker()
              })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 12 })


            ListItem() {
              AddTokenSectionTitle({ text: $r('app.string.add_token_account_section') })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 8 })

            ListItem() {
              Column({ space: 14 }) {
                AddTokenTextField({
                  label: $r('app.string.dialog_cfg_tk_secret'),
                  value: this.secret,
                  inputType: InputType.Password,
                  onChange: (value: string) => this.secret = value
                })
                Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                AddTokenTextField({
                  label: $r('app.string.dialog_cfg_tk_issuer'),
                  value: this.issuer,
                  onChange: (value: string) => this.issuer = value
                })
                Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                AddTokenTextField({
                  label: $r('app.string.dialog_cfg_tk_name'),
                  value: this.accountName,
                  onChange: (value: string) => this.accountName = value
                })
                Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                TokenGroupSelect({ groupId: this.groupId, onChange: (id: string) => this.groupId = id })
              }
              .padding(ADD_TOKEN_SECTION_PADDING)
              .width('100%')
              .borderRadius(ADD_TOKEN_SECTION_RADIUS)
              .backgroundColor($r('app.color.item_bg'))
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })

            ListItem() {
              AddTokenSectionTitle({ text: $r('app.string.add_token_advanced_section') })
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET, top: 8 })

            ListItem() {
              Column({ space: 16 }) {
                Row({ space: 12 }) {
                  Text($r('app.string.add_token_type'))
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                    .layoutWeight(1)
                  Select([
                    { value: 'TOTP' },
                    { value: 'HOTP' }
                  ])
                    .selected(this.tokenType === otpType.HOTP ? 1 : 0)
                    .value(this.tokenType === otpType.HOTP ? 'HOTP' : 'TOTP')
                    .menuSystemMaterial(MaterialTheme.systemMaterial())
                    .onSelect((index: number) => this.tokenType = index === 1 ? otpType.HOTP : otpType.TOTP)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                Row({ space: 12 }) {
                  Text($r('app.string.dialog_cfg_tk_alg'))
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                    .layoutWeight(1)
                  Select([
                    { value: 'SHA1' },
                    { value: 'SHA224' },
                    { value: 'SHA256' },
                    { value: 'SHA384' },
                    { value: 'SHA512' },
                    { value: 'SM3' },
                    { value: 'MD5' }
                  ])
                    .selected(this.algorithms.indexOf(this.algorithm))
                    .value(this.algorithm)
                    .menuSystemMaterial(MaterialTheme.systemMaterial())
                    .onSelect((_: number, value: string) => this.algorithm = value as HMACAlgorithm)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                Row({ space: 12 }) {
                  Text($r('app.string.dialog_cfg_tk_digits'))
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                    .layoutWeight(1)
                  Select([
                    { value: '4' },
                    { value: '6' },
                    { value: '8' }
                  ])
                    .selected(this.digits === 4 ? 0 : this.digits === 8 ? 2 : 1)
                    .value(this.digits.toString())
                    .menuSystemMaterial(MaterialTheme.systemMaterial())
                    .onSelect((_: number, value: string) => this.digits = Number.parseInt(value))
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                Divider().color($r('sys.color.comp_divider')).strokeWidth(0.5)
                if (this.tokenType === otpType.TOTP) {
                  Column({ space: 8 }) {
                    Row() {
                      Text($r('app.string.dialog_cfg_tk_timeout'))
                        .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
                      Text(`${this.period}s`).fontSize(13).fontColor($r('sys.color.font_secondary'))
                    }
                    .width('100%').justifyContent(FlexAlign.SpaceBetween)
                    Slider({ min: 1, max: 60, value: this.period, step: 1, style: SliderStyle.InSet })
                      .width('100%')
                      .onChange((value: number) => this.period = Math.round(value))
                  }
                } else {
                  AddTokenTextField({
                    label: $r('app.string.dialog_cfg_tk_counter'),
                    value: this.counter.toString(),
                    maxLength: 16,
                    onChange: (value: string) => this.counter = this.parseNonNegativeInt(value, 0)
                  })
                }
              }
              .padding(ADD_TOKEN_SECTION_PADDING)
              .width('100%')
              .borderRadius(ADD_TOKEN_SECTION_RADIUS)
              .backgroundColor($r('app.color.item_bg'))
            }
            .padding({ left: ADD_TOKEN_PAGE_INSET, right: ADD_TOKEN_PAGE_INSET })

            ListItem().height(this.window.AvoidBottomHeight + 16)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(false)

          AddTokenActionButton({
            text: this.isSaving ? $r('app.string.add_token_saving') : $r('app.string.add_token_save'),
            loading: this.isSaving,
            buttonEnabled: this.canSave(),
            action: () => this.submit()
          })
          .width('100%')
          .padding({
            left: ADD_TOKEN_PAGE_INSET,
            right: ADD_TOKEN_PAGE_INSET,
            top: 10,
            bottom: ADD_TOKEN_BOTTOM_ACTION_INSET
          })
        }
        .width('100%')
        .height('100%')
      }
    }
    .backgroundColor($r('app.color.window_background'))
    .mode(NavigationMode.Stack)
    .hideBackButton(false)
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            backIconStyle: MaterialTheme.navigationIconStyle(),
            menuStyle: MaterialTheme.navigationIconStyle()
          }
        },
        scrollEffectStyle: MaterialTheme.navigationScrollStyle(),
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectType },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        backIcon: {
          label: $r('app.string.dialog_btn_cancel'),
          icon: $r('sys.symbol.chevron_left'),
          action: () => this.navigateBack()
        },
        title: { mainTitle: this.pageParams.editConfig === undefined ?
          $r('app.string.tab_token_add_key') : $r('app.string.edit_token_title') },
        menu: {
          value: this.window.IsPc ? [] : [{
            content: {
              label: $r('app.string.add_token_scan'),
              icon: $r('sys.symbol.qrcode'),
              isEnabled: true,
              action: () => this.scanCode()
            }
          }]
        }
      }
    })
    .bindToScrollable([this.scroller])
    }
    .clip(false)
    .hideTitleBar(true)
    .backgroundColor($r('app.color.window_background'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
      const switchTrace = this.pageParams.responsiveEdit ?
        ResponsiveTokenEditStore.getInstance().currentTrace() : this.pageParams.switchTrace;
      TokenSwitchPerf.routeReady(switchTrace, this.getUIContext());
    })
    .onShown(() => TokenSwitchPerf.mark(this.pageParams.responsiveEdit ?
      ResponsiveTokenEditStore.getInstance().currentTrace() : this.pageParams.switchTrace, 'shown'))
    .onWillDisappear(() => {
      TokenSwitchPerf.mark(this.pageParams.switchTrace, 'willDisappear');
      this.onExitFullScreen();
    })
    .onBackPressed(() => {
      if (this.window.AllowSplit && this.pageParams.editConfig !== undefined) {
        this.onBackToPlaceholder();
        return true;
      }
      return false;
    })
  }
}

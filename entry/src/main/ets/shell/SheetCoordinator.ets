import { dialogSystemMaterial } from 'common';
import { TokenImportHandler } from '../utils/BackupImportOperation';
import { common } from '@kit.AbilityKit';
import { TokenConfig } from 'common';
// [冷启动优化] 各 Sheet 仅在用户点击对应入口时触发模块评估
import lazy { BackupAndMigrationSheet } from '../pages/setting/BackupAndMigrationSheet'
import lazy { SecuritySheet } from '../pages/setting/SecuritySheet'
import lazy { AppearanceSheet } from '../pages/setting/AppearanceSheet'
import lazy { DeveloperOptionsSheet } from '../pages/setting/DeveloperOptionsSheet'
import lazy { DataSyncSheet } from '../pages/setting/DataSyncSheet'
import lazy { AgreementSheet } from '../pages/setting/AgreementSheet'
import lazy { AboutSheet } from '../pages/setting/AboutSheet'
import lazy { FeedbackSheet } from '../pages/setting/FeedbackSheet'
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppPreference, AppWindowInfo, TokenPreference, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import lazy { HuaweiAccountManager, HuaweiUserInfo, HuaweiAccountLoginError } from 'common';
import { MaterialSheetStyle } from '../components/MaterialSheetStyle';
import { MaterialTheme } from '../components/MaterialTheme';
import { SettingItem } from '../components/SettingItem';
import { SubItemButton } from '../components/SubItemButton';
import { SubItemDivider } from '../components/SubItemDivider';
import { SETTING_PAGE_INSET, SETTING_ROW_PADDING } from '../components/SettingStyle';

/**
 * Sheet 协调器(Task 3.1)
 *
 * 承载"我的"页签的全部内容:华为账号卡片 + 8 个设置入口,
 * 以及 9 个 bindSheet(账号/备份/安全/外观/开发者选项/数据同步/协议/反馈/关于)的可见性状态与内容。
 * 华为账号 UI 状态与登录/登出流程内聚在本组件;
 * Index 侧在账号初始化完成、分布式登出等时机通过 EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED 广播,
 * 本组件监听后重新同步,保证 SheetCoordinator 懒构建时序下状态依然正确。
 */
@ComponentV2
export struct SheetCoordinator {
  @Require @Param tokens: TokenConfig[] = [];
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Require @Param scroller: Scroller = new Scroller();
  @Require @Param bottomAvoidHeight: number = 0;
  @Require @Param wideMode: boolean = false;
  @Require @Param active: boolean = false;
  @Require @Param pageInfos: NavPathStack = new NavPathStack();
  @Param selectedRoute: ROUTE_NAMES = ROUTE_NAMES.SettingAbout;
  @Param detailOnlyRoute: string = '';
  @Param localBackupHostActive: boolean = true;
  @Event onLocalExecutionChange: (executing: boolean) => void = () => {};
  @Event onSelectRoute: (route: ROUTE_NAMES) => void = () => {};
  /** 备份恢复完成回调(由 Index 提供:批量更新 Token 并重新排序) */
  @Require @Param backupReload: TokenImportHandler = async () => {};
  /** 开发者选项：生成并持久化 100 个随机测试令牌 */
  @Event addTestTokens: () => Promise<boolean> = async () => false;
  /** 开发者选项：移除生成的测试令牌 */
  @Event removeTestTokens: () => Promise<boolean> = async () => false;

  @Local isBackupSheetVisible: boolean = false;
  @Local isUriImportPageVisible: boolean = false;
  @Local isLocalBackupExecuting: boolean = false;
  @Local isSafetySheetVisible: boolean = false;
  @Local isAppearanceSheetVisible: boolean = false;
  @Local isDeveloperOptionsSheetVisible: boolean = false;
  @Local isDataSyncSheetVisible: boolean = false;
  @Local isAgreementSheetVisible: boolean = false;
  @Local isAboutSheetVisible: boolean = false;
  @Local isFeedbackSheetVisible: boolean = false;
  @Local isAccountSheetVisible: boolean = false;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local huaweiUser: HuaweiUserInfo | null = null;
  @Local debug_mode_is_on: boolean = AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onAccountStateChanged: () => void = () => {};

  aboutToAppear(): void {
    // 初始同步一次(华为账号管理器为单例,可能尚未 init 完成,后续靠事件再同步)
    this.syncHuaweiAccountState();
    this.onAccountStateChanged = () => {
      this.syncHuaweiAccountState();
    };
    this.appCtx.eventHub?.on(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED, this.onAccountStateChanged);
    if (this.detailOnlyRoute === '' && this.active && this.wideMode) {
      this.openSettingDetail(this.selectedRoute);
    }
  }

  @Monitor('wideMode')
  onWideModeChanged(monitor: IMonitor): void {
    const isWide = monitor.value()?.now as boolean;
    if (this.detailOnlyRoute !== '' || !this.active) {
      return;
    }
    if (isWide) {
      this.openSettingDetail(this.selectedRoute);
    } else {
      this.pageInfos.clear();
    }
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED, this.onAccountStateChanged);
  }

  private syncHuaweiAccountState(): void {
    this.isHuaweiLoggedIn = HuaweiAccountManager.getInstance().userLogin;
    this.huaweiUser = HuaweiAccountManager.getInstance().userAccount;
  }

  private updateDebugMode(isOn: boolean): void {
    this.debug_mode_is_on = isOn;
    this.appCtx.eventHub?.emit(EVENT_NAMES.DEBUG_MODE_CHANGED, isOn);
    if (!isOn) {
      this.isDeveloperOptionsSheetVisible = false;
      if (this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingDeveloper) {
        this.openSettingDetail(ROUTE_NAMES.SettingAbout);
      }
    }
  }

  private openSettingDetail(route: ROUTE_NAMES): void {
    this.onSelectRoute(route);
    const paths = this.pageInfos.getAllPathName();
    if (paths.length === 0) {
      this.pageInfos.pushPathByName(route, null, false);
    } else if (paths[paths.length - 1] !== route) {
      this.pageInfos.replacePathByName(route, null, false);
    }
  }

  private async triggerHuaweiLogin(): Promise<void> {
    try {
      await HuaweiAccountManager.getInstance().login(this.getUIContext());
      this.syncHuaweiAccountState();
      if (this.wideMode) {
        this.openSettingDetail(ROUTE_NAMES.SettingAccount);
      } else {
        this.isAccountSheetVisible = true;
      }
    } catch (error) {
      this.syncHuaweiAccountState();
      const loginError = error as HuaweiAccountLoginError;
      if (HuaweiAccountManager.isUserCancel(loginError.code)) {
        return;
      }
      const errorMsg = HuaweiAccountManager.getLoginErrorResource(loginError.code);
      if (errorMsg) {
        showSnackBar(errorMsg, SnackBarNotifyType.ERROR);
      }
    }
  }

  private confirmHuaweiLogin(): void {
    HuaweiAccountManager.getInstance().selectHuaweiAccountToLogin();
    this.syncHuaweiAccountState();
    this.isAccountSheetVisible = false;
    showSnackBar($r('app.string.huawei_account_login_success'), SnackBarNotifyType.SUCCESS);
  }

  private showLogoutConfirmDialog(): void {
    const cloudBackupEnabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
    const msg = cloudBackupEnabled
      ? $r('app.string.huawei_account_logout_cloud_backup_msg')
      : $r('app.string.huawei_account_logout_confirm_msg');
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: $r('app.string.huawei_account_logout_confirm_title'),
      message: msg,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      gridCount: 4,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            HuaweiAccountManager.getInstance().logout().then(() => {
              this.syncHuaweiAccountState();
              this.isAccountSheetVisible = false;
              AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
              AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
            });
          }
        },
        {
          value: $r('app.string.dialog_btn_cancel'),
          action: () => {}
        },
      ],
      cancel: () => {},
    });
  }

  private backupSheetOptions(): SheetOptions {
    const options = MaterialSheetStyle.options();
    // 原生材质无效果时保留实体背板；材质有效时由系统处理底色。
    options.backgroundColor = $r('app.color.window_background');
    options.showClose = !this.isUriImportPageVisible && !this.isLocalBackupExecuting;
    options.onWillDismiss = (action: DismissSheetAction): void => {
      if (this.isLocalBackupExecuting) {
        showSnackBar($r('app.string.local_backup_processing'), SnackBarNotifyType.INFO);
      } else if (!this.isUriImportPageVisible) {
        action.dismiss();
      }
    };
    options.onWillSpringBackWhenDismiss = (action: SpringBackAction): void => {
      if (this.isLocalBackupExecuting || this.isUriImportPageVisible) { action.springBack(); }
    };
    options.keyboardAvoidMode = SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL;
    return options;
  }

  @Builder
  BackupAndMigrationSheetBuilder(embedded: boolean) {
    BackupAndMigrationSheet({
      Tokens: this.tokens,
      scrollEffectStyle: this.scrollEffectType,
      embedded: embedded,
      hostActive: this.localBackupHostActive,
      backupReload: this.backupReload,
      onUriImportVisibilityChange: (visible: boolean) => this.isUriImportPageVisible = visible,
      onLocalExecutionChange: (executing: boolean) => {
        this.isLocalBackupExecuting = executing;
        this.onLocalExecutionChange(executing);
      }
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  SecuritySheetBuilder(embedded: boolean) {
    SecuritySheet({
      scrollEffectStyle: this.scrollEffectType,
      embedded: embedded
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  AppearanceSheetBuilder(embedded: boolean) {
    AppearanceSheet({
      scrollEffectType: this.scrollEffectType,
      embedded: embedded
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  DeveloperOptionsSheetBuilder(embedded: boolean) {
    DeveloperOptionsSheet({
      scrollEffectType: this.scrollEffectType,
      embedded: embedded,
      debugModeChanged: (isOn: boolean) => this.updateDebugMode(isOn),
      addTestTokens: () => this.addTestTokens(),
      removeTestTokens: () => this.removeTestTokens()
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  DataSyncSheetBuilder(embedded: boolean) {
    DataSyncSheet({
      scrollEffectType: this.scrollEffectType,
      embedded: embedded
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  AgreementSheetBuilder(embedded: boolean) {
    AgreementSheet({
      scrollEffectType: this.scrollEffectType,
      embedded: embedded
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  AboutSheetBuilder(embedded: boolean) {
    AboutSheet({
      scrollEffectStyle: this.scrollEffectType,
      embedded: embedded,
      debugModeChanged: (isOn: boolean) => this.updateDebugMode(isOn)
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  FeedbackSheetBuilder(embedded: boolean) {
    FeedbackSheet({
      scrollEffectType: this.scrollEffectType,
      embedded: embedded
    })
      .height('100%')
      .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
  }

  @Builder
  AccountSheetBuilder() {
    Column() {
      Column() {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill_1'))
          .fontSize($r('sys.float.Display_L'))
          .fontColor([$r('sys.color.icon_emphasize')])
          .aspectRatio(1)

        Text(this.isHuaweiLoggedIn ?
          $r('app.string.huawei_account_current') :
          $r('app.string.huawei_account_select_title'))
          .fontSize($r('sys.float.Title_M'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .margin({ top: $r('sys.float.padding_level10') })

        if (this.huaweiUser) {
          if (this.huaweiUser.avatarUri !== '') {
            Image(this.huaweiUser.avatarUri)
              .draggable(false)
              .width(85)
              .height(85)
              .borderRadius('50%')
              .margin({ top: 40 })
          } else if (this.huaweiUser.nickname !== '') {
            Text(this.huaweiUser.nickname.length > 0 ?
              this.huaweiUser.nickname.substring(this.huaweiUser.nickname.length - 1) : '')
              .width(85)
              .height(85)
              .borderRadius('50%')
              .backgroundColor($r('sys.color.ohos_id_color_tertiary'))
              .linearGradient({
                colors: [
                  [$r('sys.color.ohos_id_color_tertiary'), 0.0],
                  [$r('sys.color.ohos_id_color_foreground_contrary'), 1.0]
                ]
              })
              .fontColor($r('sys.color.font_on_primary'))
              .fontSize($r('sys.float.Title_M'))
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Center)
              .margin({ top: 40 })
          }

          Text(this.huaweiUser.nickname)
            .margin({ top: $r('sys.float.padding_level12') })
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
        }
      }
      .margin({ top: $r('sys.float.padding_level16') })

      Blank();

      Button(this.isHuaweiLoggedIn ?
        $r('app.string.huawei_account_logout') :
        $r('app.string.huawei_account_select_to_login'))
        .type(ButtonType.Capsule)
        .fontSize($r('sys.float.Body_L'))
        .role(this.isHuaweiLoggedIn ? ButtonRole.ERROR : ButtonRole.NORMAL)
        .buttonStyle(this.isHuaweiLoggedIn ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
        .width('100%')
        .margin({ bottom: $r('sys.float.padding_level24') })
        .onClick(() => {
          if (this.isHuaweiLoggedIn) {
            this.showLogoutConfirmDialog();
          } else {
            this.confirmHuaweiLogin();
          }
        })
    }
    .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })
    .width('100%')
    .height('100%')
    .foregroundBlurStyle(this.window.BackgroundBlurActive ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }

  @Builder
  AccountDetailBuilder() {
    HdsNavigation() {
      this.AccountSheetBuilder()
    }
    .clip(false)
    .backgroundColor($r('app.color.window_background'))
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            backIconStyle: MaterialTheme.navigationIconStyle(),
            menuStyle: MaterialTheme.navigationIconStyle()
          }
        },
        scrollEffectStyle: MaterialTheme.navigationScrollStyle()
      },
      content: {
        title: {
          mainTitle: $r('app.string.huawei_account_current')
        }
      }
    })
  }

  @Builder
  SettingEntryList() {
    List({ space: 10, scroller: this.scroller }) {
      // 华为账号登录卡片：与设置子项共用 SettingItem 分组卡片表面
      ListItem() {
        SettingItem({ title: '' }) {
          ListItem() {
            Row({ space: 16 }) {
              if (this.isHuaweiLoggedIn && this.huaweiUser && this.huaweiUser.avatarUri !== '') {
                Image(this.huaweiUser.avatarUri)
                  .draggable(false)
                  .width(48)
                  .height(48)
                  .borderRadius($r('sys.float.corner_radius_level12'))
              } else if (this.isHuaweiLoggedIn && this.huaweiUser && this.huaweiUser.nickname !== '') {
                Text(this.huaweiUser.nickname.length > 0 ?
                  this.huaweiUser.nickname.substring(this.huaweiUser.nickname.length - 1) : '')
                  .width(48)
                  .height(48)
                  .borderRadius($r('sys.float.corner_radius_level12'))
                  .backgroundColor($r('sys.color.ohos_id_color_tertiary'))
                  .linearGradient({
                    colors: [
                      [$r('sys.color.ohos_id_color_tertiary'), 0.0],
                      [$r('sys.color.ohos_id_color_foreground_contrary'), 1.0]
                    ]
                  })
                  .fontColor($r('sys.color.font_on_primary'))
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .textAlign(TextAlign.Center)
              } else {
                SymbolGlyph($r('sys.symbol.person_crop_circle_fill_1'))
                  .fontSize(48)
                  .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
              }

              Column({ space: 4 }) {
                Text(this.isHuaweiLoggedIn && this.huaweiUser ?
                  this.huaweiUser.nickname : $r('app.string.huawei_account_login'))
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingAccount ?
                    $r('sys.color.interactive_active') : $r('sys.color.ohos_id_color_text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(this.isHuaweiLoggedIn ?
                  $r('app.string.huawei_account_current') :
                  $r('app.string.huawei_account_login_desc'))
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(SETTING_ROW_PADDING)
            .alignItems(VerticalAlign.Center)
          }
          // 与其余设置项一致：业务选中态使用背板，按压和鼠标悬浮仅高亮。
          .hoverEffect(HoverEffect.Highlight)
          .selected(this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingAccount)
          .stateStyles({
            normal: {
              .backgroundColor(Color.Transparent)
            },
            selected: {
              .backgroundColor($r('app.color.itemActivated'))
            },
            pressed: {
              .backgroundColor($r('sys.color.interactive_pressed'))
            },
            clicked: {
              .backgroundColor($r('sys.color.interactive_pressed'))
            }
          })
          .borderRadius($r('sys.float.corner_radius_level8'))
          .accessibilitySelected(this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingAccount)
          .onClick(() => {
            if (!this.isHuaweiLoggedIn) {
              this.triggerHuaweiLogin();
            } else if (this.wideMode) {
              this.openSettingDetail(ROUTE_NAMES.SettingAccount);
            } else {
              this.isAccountSheetVisible = true;
            }
          })
          .bindSheet($$this.isAccountSheetVisible, this.AccountSheetBuilder(),
            MaterialSheetStyle.options(SheetSize.MEDIUM))
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

      // 数据管理：备份与迁移、数据同步属于同一数据生命周期分类
      ListItem() {
        SettingItem({ title: $r('app.string.setting_group_data_management') }) {
          SubItemButton({
            symbol: $r('sys.symbol.save'),
            text: $r('app.string.setting_backup'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingBackup
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingBackup);
              } else {
                this.isBackupSheetVisible = true;
              }
            })
            .bindSheet($$this.isBackupSheetVisible, this.BackupAndMigrationSheetBuilder(false),
              this.backupSheetOptions())

          // 左侧跳过行边距 16vp、图标 20vp 和图文间距 10vp，与标题对齐。
          SubItemDivider({ insetLeft: 46 })

          SubItemButton({
            symbol: $r('sys.symbol.link'),
            text: $r('app.string.data_sync'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingDataSync
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingDataSync);
              } else {
                this.isDataSyncSheetVisible = true;
              }
            })
            .bindSheet($$this.isDataSyncSheetVisible, this.DataSyncSheetBuilder(false),
              MaterialSheetStyle.options())
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

      // 应用设置
      ListItem() {
        SettingItem({ title: $r('app.string.setting_group_app_settings') }) {
          SubItemButton({
            symbol: $r('sys.symbol.staroflife_rectangle'),
            text: $r('app.string.setting_safety'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingSecurity
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingSecurity);
              } else {
                this.isSafetySheetVisible = true;
              }
            })
            .bindSheet($$this.isSafetySheetVisible, this.SecuritySheetBuilder(false),
              MaterialSheetStyle.options())

          SubItemDivider({ insetLeft: 46 })

          SubItemButton({
            symbol: $r('sys.symbol.chevron_up_2_circle'),
            text: $r('app.string.app_appearance'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingAppearance
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingAppearance);
              } else {
                this.isAppearanceSheetVisible = true;
              }
            })
            .bindSheet($$this.isAppearanceSheetVisible, this.AppearanceSheetBuilder(false),
              MaterialSheetStyle.options())

          if (this.debug_mode_is_on) {
            SubItemDivider({ insetLeft: 46 })

            SubItemButton({
              symbol: $r('sys.symbol.wrench_and_screwdriver'),
              text: $r('app.string.setting_group_developer_options'),
              selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingDeveloper
            })
              .onClick(() => {
                if (this.wideMode) {
                  this.openSettingDetail(ROUTE_NAMES.SettingDeveloper);
                } else {
                  this.isDeveloperOptionsSheetVisible = true;
                }
              })
              .bindSheet($$this.isDeveloperOptionsSheetVisible, this.DeveloperOptionsSheetBuilder(false),
                MaterialSheetStyle.options())
          }
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

      // 支持与关于
      ListItem() {
        SettingItem({ title: $r('app.string.setting_group_support_about') }) {
          SubItemButton({
            symbol: $r('sys.symbol.person_shield'),
            text: $r('app.string.setting_agreement_statement'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingAgreement
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingAgreement);
              } else {
                this.isAgreementSheetVisible = true;
              }
            })
            .bindSheet($$this.isAgreementSheetVisible, this.AgreementSheetBuilder(false),
              MaterialSheetStyle.options())

          SubItemDivider({ insetLeft: 46 })

          SubItemButton({
            symbol: $r('sys.symbol.envelope'),
            text: $r('app.string.setting_feedback'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingFeedback
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingFeedback);
              } else {
                this.isFeedbackSheetVisible = true;
              }
            })
            .bindSheet($$this.isFeedbackSheetVisible, this.FeedbackSheetBuilder(false),
              MaterialSheetStyle.options())

          SubItemDivider({ insetLeft: 46 })

          SubItemButton({
            symbol: $r('sys.symbol.info_circle'),
            text: $r('app.string.setting_about'),
            selected: this.wideMode && this.selectedRoute === ROUTE_NAMES.SettingAbout
          })
            .onClick(() => {
              if (this.wideMode) {
                this.openSettingDetail(ROUTE_NAMES.SettingAbout);
              } else {
                this.isAboutSheetVisible = true;
              }
            })
            .bindSheet($$this.isAboutSheetVisible, this.AboutSheetBuilder(false),
              MaterialSheetStyle.options())
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
    }
    .clip(false)
    // 宽屏使用侧边页签，无需再为底部 HdsTabs 预留 80vp。
    .contentEndOffset((this.wideMode ? 16 : 80) + this.bottomAvoidHeight)
    .chainAnimation(this.token_preference.app_appearance_chain_animation_enable)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .backgroundColor($r('app.color.window_background'))
  }

  build() {
    if (this.detailOnlyRoute === ROUTE_NAMES.SettingAccount) {
      this.AccountDetailBuilder()
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingBackup) {
      this.BackupAndMigrationSheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingDataSync) {
      this.DataSyncSheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingSecurity) {
      this.SecuritySheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingAppearance) {
      this.AppearanceSheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingDeveloper) {
      this.DeveloperOptionsSheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingAgreement) {
      this.AgreementSheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingFeedback) {
      this.FeedbackSheetBuilder(true)
    } else if (this.detailOnlyRoute === ROUTE_NAMES.SettingAbout) {
      this.AboutSheetBuilder(true)
    } else {
      this.SettingEntryList()
    }
  }
}

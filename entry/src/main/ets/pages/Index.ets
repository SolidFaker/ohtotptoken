import { bundleManager,common } from '@kit.AbilityKit';
import { base32Encode, nowUnixSeconds, otpType, TokenConfig, TokenBatchProgressCallback, dialogSystemMaterial } from 'common';
import { TokenBatchOperation } from '../utils/TokenBatchOperation';
import { TokenProgressDialog, TokenProgressDialogParams } from '../dialogs/TokenProgressDialog';
import { importBackupWithProgress } from '../utils/BackupImportOperation';
import { util, url } from '@kit.ArkTS';
// [冷启动优化] 文件 I/O 仅在 deferredInit 中使用
import lazy { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppPreference, SettingTopEffectType, SettingBottomTabsType, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES, BUILTIN_DEFAULT_PACK_ID } from 'common';
// [冷启动优化] privacyManager 仅在 deferredInit 的 GetPrivacyManageInfo 中使用
import lazy { privacyManager } from '@kit.StoreKit';
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit';
import CommonEventManager from '@ohos.commonEventManager';
import { TokenStore, TokenGroupState, TokenGroupStore, ALL_TOKEN_GROUPS, FAVORITE_TOKEN_GROUP } from 'common';
// [冷启动优化] 权限检查仅在 deferredInit 中使用
import lazy { PermissionManager } from 'common';
// [冷启动优化] 拖拽弹框仅在 onDragEnter 时触发
import lazy { DropFilesDialog } from '../dialogs/DropFilesDialog';
// [冷启动优化] 加密导入弹框仅在文件拖入 .bak 时触发
import lazy { EncryptionPassWordDialog } from '../dialogs/EncryptionPassWordDialog';
// [冷启动优化] 备份恢复仅在文件拖入时触发
// [冷启动优化] TokenIconPacks 仅在 deferredInit 中使用，ScanBarCode 仅在扫码时使用
import lazy { TokenIconPacks, ScanBarCode } from 'common';
// [冷启动优化] 云备份管理器仅在 deferredInit 中使用
import lazy { CloudBackupManager } from 'common';
import { AppWindowInfo } from 'common';
// [冷启动优化] AppLockOverlay 导入 @kit.CryptoArchitectureKit + @kit.UserAuthenticationKit，
// bindContentCover 的 Builder 仅在 isAppLockOverlayVisible=true 时评估
import lazy { AppLockOverlay } from './AppLockOverlay';
import { AdvancedDialogV2Button, AlertDialogV2, AppStorageV2, ComponentContent } from '@kit.ArkUI';
import { TokenGroupMoveDialog } from '../dialogs/TokenGroupMoveDialog';
import { TokenMultiSelectPage } from './TokenMultiSelectPage';
import { CommonConstants } from 'common';
import { ScrollEffectType } from '@kit.UIDesignKit';
// [冷启动优化] Google Auth 解码仅在扫描迁移链接时使用
// [冷启动优化] Google Auth 迁移解析（含手写 protobuf codec）仅在扫码时使用
import lazy { decodeGoogleAuthMigration, GA_MIGRATION_EMPTY, GA_MIGRATION_PARSE_FAILED,
  GoogleAuthMigrationResult, resetGoogleAuthBatch } from 'common';
// [冷启动优化] 华为账号管理器仅在 deferredInit 中初始化
import lazy { HuaweiAccountManager, CloudBackupDiagnostics, DiagnosticKind, DiagnosticStage,
  DiagnosticResult, DiagnosticReason, DiagnosticErrorDomain } from 'common';
import lazy { IconPackCloudBackup } from 'common';
import { DlpAntiPeepManager } from 'common';
import { AppShell } from '../shell/AppShell';
import { AddTokenPageParams } from '../components/AddTokenForm';
import { HomeTabs } from '../shell/HomeTabs';
// [冷启动优化] SheetCoordinator("我的"页签 + 8 个 Sheet)仅在用户切换到"我的"Tab 时触发模块评估
import lazy { SheetCoordinator } from '../shell/SheetCoordinator';
import { NFCReadDialog } from '../dialogs/NFCReadDialog';
import { NfcSessionTokens } from '../oath/NfcSessionTokens';
import { SteamConfirmationsPageParams } from './SteamConfirmationsPage';
import { NfcOathReader, NfcSupportStatus } from '../oath/NfcOathReader';
import { OathReadResult } from '../oath/OathApplet';
import { ResponsiveTokenEditStore, TokenSwitchPerf } from '../utils/TokenSwitchPerf';

const TAG = 'PrivacySubscribe';

class AddTotpRouteParams {
  initialUri: string;

  constructor(initialUri: string) {
    this.initialUri = initialUri;
  }
}


/** 将SettingTopEffectType映射到ScrollEffectType(自 common/AppPreference 迁入,
 *  枚举值为 UIDesignKit 运行时符号,手表端不可用,仅手机端使用) */
const SCROLL_EFFECT_TYPE_MAP: Map<SettingTopEffectType, ScrollEffectType> = new Map([
  [SettingTopEffectType.COMMON_BLUR, ScrollEffectType.COMMON_BLUR],
  [SettingTopEffectType.GRADUAL_BLUR, ScrollEffectType.GRADUAL_BLUR],
  [SettingTopEffectType.GRADIENT_BLUR, ScrollEffectType.GRADIENT_BLUR],
  [SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR, ScrollEffectType.IMMERSIVE_GRADIENT_BLUR],
]);

let tkStore = TokenStore.getInstance();

enum TokenListSortMode {
  DEFAULT,
  USERNAME_ASCENDING,
  TOKEN_NAME_ASCENDING,
  USERNAME_DESCENDING,
  TOKEN_NAME_DESCENDING
}

@Builder
function TokenAddMenuBuilder(host: Index) {
  Menu() {
    MenuItem({ content: $r('app.string.app_scan_code') })
      .onClick(() => {
        host.start_quick_scan();
      })
      .accessibilityText($r('app.string.app_scan_code'))
    MenuItem({ content: $r('app.string.tab_token_add_key') })
      .onClick(() => {
        host.openTotpAddPage();
      })
      .accessibilityText($r('app.string.tab_token_add_key'))
    MenuItem({ content: $r('app.string.tab_token_add_forti_key') })
      .onClick(() => {
        host.openFortiAddPage();
      })
      .accessibilityText($r('app.string.tab_token_add_forti_key'))
    MenuItem({ content: $r('app.string.tab_token_add_stream_key') })
      .onClick(() => {
        host.openSteamAddPage();
      })
      .accessibilityText($r('app.string.tab_token_add_stream_key'))
    MenuItem({ content: $r('app.string.menu_add_nfc_read') })
      .onClick(() => {
        host.openNfcReadDialog();
      })
      .accessibilityText($r('app.string.menu_add_nfc_read'))
  }
  .systemMaterial(dialogSystemMaterial())
}

@Builder
function TokenActionsMenuBuilder(host: Index) {
  Menu() {
    MenuItem({
      content: $r('app.string.app_ua_add_token'),
      builder: TokenAddMenuBuilder.bind(host, host)
    })
      .accessibilityText($r('app.string.app_ua_add_token'))
    MenuItem({
      content: $r('app.string.menu_token_sort_method'),
      // 子菜单延迟构建时必须绑定组件上下文，不能以普通函数直接调用全局 @Builder。
      builder: TokenSortMenuBuilder.bind(host, host)
    })
      .accessibilityText($r('app.string.menu_token_sort_method'))
    MenuItem({ content: $r('app.string.menu_token_multi_select') })
      .enabled(!host.multiSelectMode && host.displayTokens.length > 0)
      .onClick(() => host.openMultiSelectPage())
      .accessibilityText($r('app.string.menu_token_multi_select'))
    MenuItem({ content: $r('app.string.token_group_manage') })
      .onClick(() => host.openGroupManagement())
      .accessibilityText($r('app.string.token_group_manage'))
  }
  .width(host.getTokenActionsMenuWidth())
  // 使用原生内嵌展开，让添加和排序选项在各自入口下方显示。
  .subMenuExpandingMode(SubMenuExpandingMode.EMBEDDED_EXPAND)
  .systemMaterial(dialogSystemMaterial())
}

@Builder
function TokenSortMenuBuilder(host: Index) {
  Menu() {
    MenuItem({ content: $r('app.string.menu_token_sort_default') })
      .selected(host.tokenSortMode === TokenListSortMode.DEFAULT)
      .selectIcon(true)
      .onClick(() => {
        host.setTokenSortMode(TokenListSortMode.DEFAULT);
      })
      .accessibilityText($r('app.string.menu_token_sort_default'))
    MenuItem({ content: $r('app.string.menu_token_sort_username_ascending') })
      .selected(host.tokenSortMode === TokenListSortMode.USERNAME_ASCENDING)
      .selectIcon(true)
      .onClick(() => {
        host.setTokenSortMode(TokenListSortMode.USERNAME_ASCENDING);
      })
      .accessibilityText($r('app.string.menu_token_sort_username_ascending'))
    MenuItem({ content: $r('app.string.menu_token_sort_token_name_ascending') })
      .selected(host.tokenSortMode === TokenListSortMode.TOKEN_NAME_ASCENDING)
      .selectIcon(true)
      .onClick(() => {
        host.setTokenSortMode(TokenListSortMode.TOKEN_NAME_ASCENDING);
      })
      .accessibilityText($r('app.string.menu_token_sort_token_name_ascending'))
    MenuItem({ content: $r('app.string.menu_token_sort_username_descending') })
      .selected(host.tokenSortMode === TokenListSortMode.USERNAME_DESCENDING)
      .selectIcon(true)
      .onClick(() => {
        host.setTokenSortMode(TokenListSortMode.USERNAME_DESCENDING);
      })
      .accessibilityText($r('app.string.menu_token_sort_username_descending'))
    MenuItem({ content: $r('app.string.menu_token_sort_token_name_descending') })
      .selected(host.tokenSortMode === TokenListSortMode.TOKEN_NAME_DESCENDING)
      .selectIcon(true)
      .onClick(() => {
        host.setTokenSortMode(TokenListSortMode.TOKEN_NAME_DESCENDING);
      })
      .accessibilityText($r('app.string.menu_token_sort_token_name_descending'))
  }
  .systemMaterial(dialogSystemMaterial())
}

@Entry
@ComponentV2
struct Index {
  @Local CurrentTokens: TokenConfig[] = [];
  @Local groupState: TokenGroupState = TokenGroupStore.getInstance().state;
  @Local groupSidebarOpen: boolean = false;

  onBackPress(): boolean {
    if (this.multiSelectMode && !this.isAppLockOverlayVisible) {
      if (!this.multiSelectBusy) {
        this.exitMultiSelect();
      }
      return true;
    }
    if (this.groupSidebarOpen && !this.isAppLockOverlayVisible) {
      this.groupSidebarOpen = false;
      return true;
    }
    return false;
  }

  @Computed
  get displayTokens(): TokenConfig[] {
    if (this.groupState.selectedId === ALL_TOKEN_GROUPS) {
      return this.CurrentTokens;
    }
    if (this.groupState.selectedId === FAVORITE_TOKEN_GROUP) {
      return this.CurrentTokens.filter(token => token.TokenType !== otpType.NFC_external && token.TokenFavorite === true);
    }
    return this.CurrentTokens.filter(token => {
      const id = token.TokenType === otpType.NFC_external ? '' : (token.TokenGroupId ?? '');
      const knownId = this.groupState.groups.some(group => group.id === id) ? id : '';
      return knownId === this.groupState.selectedId;
    });
  }

  private selectGroup(id: string): void {
    if (this.multiSelectBusy) {
      return;
    }
    if (id === this.groupState.selectedId) {
      return;
    }
    this.exitMultiSelect();
    this.groupState.selectedId = id;
    this.tokenListScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    if (this.selectedTokenUUID !== '' &&
      !this.displayTokens.some(token => token.TokenUUID === this.selectedTokenUUID)) {
      this.selectedTokenUUID = '';
      this.pageInfos.clear();
    }
  }
  @Local multiSelectMode: boolean = false;
  @Local multiSelectBusy: boolean = false;
  @Local selectedTokenIds: string[] = [];

  private multiSelectListScroller: Scroller = new Scroller();

  openMultiSelectPage(): void {
    if (this.multiSelectMode || this.displayTokens.length === 0) {
      return;
    }
    this.selectedTokenIds = [];
    this.selectedTokenUUID = '';
    this.pageInfos.clear();
    this.groupSidebarOpen = false;
    this.currentHomeTabIndex = 0;
    this.multiSelectMode = true;
    this.openFullScreenRoute(ROUTE_NAMES.TokenMultiSelectPage, null);
  }

  private exitMultiSelect(): void {
    const paths = this.pageInfos.getAllPathName();
    if (paths[paths.length - 1] === ROUTE_NAMES.TokenMultiSelectPage) {
      this.pageInfos.pop();
    }
    this.multiSelectMode = false;
    this.selectedTokenIds = [];
  }

  @Monitor('displayTokens')
  reconcileMultiSelection(): void {
    if (!this.multiSelectBusy) {
      this.selectedTokenIds = this.selectedTokenIds.filter(id =>
        this.displayTokens.some(token => token.TokenUUID === id));
    }
  }

  private toggleTokenSelection(conf: TokenConfig): void {
    if (!this.multiSelectBusy) {
      this.selectedTokenIds = this.selectedTokenIds.includes(conf.TokenUUID) ?
        this.selectedTokenIds.filter(id => id !== conf.TokenUUID) : [...this.selectedTokenIds, conf.TokenUUID];
    }
  }

  private selectAllTokens(): void {
    if (!this.multiSelectBusy) {
      this.selectedTokenIds = this.displayTokens.every(token => this.selectedTokenIds.includes(token.TokenUUID)) ?
        [] : this.displayTokens.map(token => token.TokenUUID);
    }
  }

  private async applyMultiAction(action: string, groupId: string = ''): Promise<void> {
    if (this.multiSelectBusy || TokenBatchOperation.isBusy() || !this.multiSelectMode) {
      return;
    }
    const selectedIds = new Set(this.selectedTokenIds);
    const selected = this.displayTokens.filter(token => selectedIds.has(token.TokenUUID));
    if (selected.length === 0) {
      return;
    }
    // 在写入前一次性确定目标状态，避免逐条更新触发列表刷新后改变操作方向。
    const favorite = !selected.every(token =>
      token.TokenType !== otpType.NFC_external && token.TokenFavorite === true);
    this.multiSelectBusy = true;
    const failed: string[] = [];
    const localIds = selected.filter(token => token.TokenType !== otpType.NFC_external).map(token => token.TokenUUID);
    const externalIds = selected.filter(token => token.TokenType === otpType.NFC_external).map(token => token.TokenUUID);
    try {
      if (action === 'delete' || action === 'favorite') {
        try {
          if (localIds.length > 0) {
            await TokenBatchOperation.run(this, action === 'delete' ?
              $r('app.string.token_batch_delete_title') : $r('app.string.token_batch_favorite_title'), async (report) => {
              if (action === 'delete') {
                await tkStore.deleteTokens(localIds, report);
              } else {
                await tkStore.setTokensFavorite(localIds, favorite, report);
              }
            });
          }
        } catch (_) {
          // 本地 KV 事务失败整批保留；NFC 会话操作独立处理。
          failed.push(...localIds);
        }
        if (action === 'delete') {
          NfcSessionTokens.getInstance().removeMany(externalIds);
        } else {
          failed.push(...externalIds);
        }
      } else {
        failed.push(...externalIds);
        for (const uuid of localIds) {
          try {
            await tkStore.moveTokenToGroup(uuid, groupId);
          } catch (_) {
            failed.push(uuid);
          }
        }
      }
    } finally {
      this.multiSelectBusy = false;
    }
    this.selectedTokenIds = failed.filter(id => this.displayTokens.some(token => token.TokenUUID === id));
    if (failed.length === 0) {
      this.exitMultiSelect();
      showSnackBar($r('app.string.token_multi_success', selected.length), SnackBarNotifyType.SUCCESS);
    } else {
      showSnackBar($r('app.string.token_multi_failed', failed.length), SnackBarNotifyType.WARNING);
    }
  }

  @Builder
  buildTokenProgressDialog(params: TokenProgressDialogParams) {
    TokenProgressDialog({ params: params })
  }

  private confirmMultiDelete(): void {
    if (this.multiSelectBusy || this.selectedTokenIds.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => this.MultiDeleteDialog()
    }).catch(() => {
      showSnackBar($r('app.string.token_multi_failed', this.selectedTokenIds.length), SnackBarNotifyType.ERROR);
    });
  }

  @Builder
  MultiDeleteDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.token_multi_delete_title', this.selectedTokenIds.length),
      content: $r('app.string.alert_remove_confirm_msg'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_btn_cancel')
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_btn_delete'),
        role: ButtonRole.ERROR,
        action: () => { this.applyMultiAction('delete'); }
      })
    })
  }

  @Builder
  MultiGroupDialog(onPick: (id: string) => void, onClose: () => void) {
    TokenGroupMoveDialog({ onConfirm: onPick, onClose: onClose })
  }

  private openMultiGroupDialog(): void {
    if (this.multiSelectBusy || this.selectedTokenIds.length === 0) {
      return;
    }
    let dialogId: number = -1;
    const onClose = (): void => {
      if (dialogId !== -1) {
        this.getUIContext().getPromptAction().closeCustomDialog(dialogId);
      }
    };
    this.getUIContext().getPromptAction().openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => this.MultiGroupDialog((id: string) => {
        onClose();
        this.applyMultiAction('group', id);
      }, onClose)
    }).then(id => { dialogId = id; }).catch(() => {
      showSnackBar($r('app.string.token_group_error'), SnackBarNotifyType.ERROR);
    });
  }

  @Local tokenSortMode: TokenListSortMode = TokenListSortMode.DEFAULT;
  @Local token_loading: Boolean = true;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  @Local tokenListScroller: Scroller = new Scroller();
  @Local settingEntryScroller: Scroller = new Scroller();
  @Local currentHomeTabIndex: number = 0;
  @Local selectedTokenUUID: string = '';
  @Local selectedSettingRoute: ROUTE_NAMES = ROUTE_NAMES.SettingAbout;
  @Local businessSplitEnabled: boolean = true;
  @Local CurrentTokensCount: number = 0;
  @Local scrollEffectVersion: number = 0;
  @Local bottomTabsTypeVersion: number = 0;
  @Local isAppLockOverlayVisible: boolean = false;
  pageInfos: NavPathStack = new NavPathStack();

  /**
   * 获取当前的滚动效果类型
   * 根据用户设置的顶部效果类型映射到对应的ScrollEffectType
   */
  @Computed
  get currentScrollEffectType(): ScrollEffectType {
    // 依赖scrollEffectVersion以触发重新计算
    const _ = this.scrollEffectVersion;
    const topEffectType = AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE) as SettingTopEffectType;
    return SCROLL_EFFECT_TYPE_MAP.get(topEffectType) ?? ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  }

  /**
   * 获取当前的底部页签类型
   * 根据用户设置的底部页签类型（悬浮/平铺）驱动 HomeTabs 重建
   */
  @Computed
  get currentBottomTabsType(): SettingBottomTabsType {
    // 依赖bottomTabsTypeVersion以触发重新计算
    const _ = this.bottomTabsTypeVersion;
    return AppPreference.getPreference(PREF_KEYS.APPEARANCE_BOTTOM_TABS_TYPE) as SettingBottomTabsType;
  }

  private appIsInit = false;
  private appIsShow = false;
  private icon_pack_dir = this.appCtx.filesDir + "/icon_packs";
  private user_icon_dir = this.appCtx.filesDir + "/user_icons";
  private DropFilesDialogIsOpen:boolean = false;
  // 存储 setInterval ID 以便在 aboutToDisappear 中清理
  private timestampIntervalId: number = -1;

  private readonly eventId = 'usual.event.PRIVACY_STATE_CHANGED';
  // 订阅者信息, 用于保存创建成功的订阅者对象，后续使用其完成订阅及退订的动作
  private subscriber: CommonEventManager.CommonEventSubscriber | undefined = undefined;
  // 事件列表
  private subscribeInfo: CommonEventManager.CommonEventSubscribeInfo = {
    events: [this.eventId]
  };
  //拖拽文件弹框
  private DropFilesDialogController: CustomDialogController | null = null;

  private createDropFilesDialog(): CustomDialogController {
    return new CustomDialogController({
    systemMaterial: dialogSystemMaterial(),
    builder: DropFilesDialog({}),
    cancel: () => {},
    autoCancel: true,
    openAnimation:({
      delay: 0,
      duration: 200, // 动画时长
      curve: Curve.EaseInOut, // 动画曲线
    }),
    closeAnimation:({
      delay: 0,
      duration: 200, // 动画时长
      curve: Curve.EaseInOut, // 动画曲线
    }),
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      hilog.info(0, 'Index', "reason=" + JSON.stringify(dismissDialogAction.reason))
      hilog.info(0, 'Index', "dialog onWillDismiss")
      this.DropFilesDialogIsOpen=false;
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss()
      }
      if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss()
      }
    },
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -20 },
    gridCount: 4,
    customStyle: false,
    cornerRadius: 10,
    });
  }

  private backup_select_uri: string = '';
  private readonly sortTokenMenuTargetId: string = 'token_right_menu_sort';
  private dialog_nfc_read?: CustomDialogController;

  // [性能打点] hiTraceMeter 用于 DevEco Profiler 冷启动分析，搜索 "H:" 前缀查看各阶段耗时
  aboutToAppear(): void {
    // 异步打点：覆盖整个 aboutToAppear 到首帧数据就绪（token_loading=false）
    hiTraceMeter.startTrace('H:aboutToAppear', 1);

    // 同步打点：6 个 eventHub 监听器注册耗时（预期 <1ms）
    hiTraceMeter.startTrace('H:aboutToAppear.eventHub', 1);
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.on(EVENT_NAMES.KV_STORE_SYNC_COMPLETE, () => {
        AppPreference.setPreference(PREF_KEYS.DB_KV_SYNC_TIME,new Date().toISOString());
      });
      this.appCtx.eventHub.on(EVENT_NAMES.RDB_STORE_SYNC_COMPLETE, () => {});
      this.appCtx.eventHub.on(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, (isAccess: boolean) => {
        if (!isAccess) {
          AppPreference.setPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE, false);
          AppPreference.setPreference(PREF_KEYS.DB_RDS_CLOUD_SYNC_ENABLE, false);
        }
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_QUICK_SCAN, () => {
        this.start_quick_scan();
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_CARD_CONFIG, () => {
        this.openFullScreenRoute(ROUTE_NAMES.TokenCardConfigPage, null);
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_TOKEN_SORT, () => {
        this.openFullScreenRoute(ROUTE_NAMES.TokenSortPage, null);
      });
      // Steam 交易确认列表：由令牌右键菜单触发
      this.appCtx.eventHub.on(EVENT_NAMES.OPEN_STEAM_CONFIRMATIONS, (conf: TokenConfig) => {
        this.openFullScreenRoute(ROUTE_NAMES.SteamConfirmationsPage,
          new SteamConfirmationsPageParams(conf));
      });
      // NFC 外部令牌变更事件：合并刷新（本地令牌 + 会话级 NFC 令牌）
      this.appCtx.eventHub.on(EVENT_NAMES.NFC_EXTERNAL_TOKENS_CHANGED, () => this.refreshDisplayTokens());
      this.appCtx.eventHub.on(EVENT_NAMES.FILE_DROP, (uri: string) => {
        this.backup_select_uri = uri;
        if (this.backup_select_uri.endsWith('.bak')) {
          this.openEncryptionPasswordDialog();
        } else if (this.backup_select_uri.endsWith('.json')) {
          importBackupWithProgress(this, uri, false, '', async (tokens, report) => {
            await this.updateTokenConfigs(tokens, report);
          });
        }
        setTimeout(() => {
          this.DropFilesDialogIsOpen = false;
          this.DropFilesDialogController?.close();
        }, 250)
      });
    }
    hiTraceMeter.finishTrace('H:aboutToAppear.eventHub', 1);

    // 异步打点：TokenStore 初始化（KV 数据库打开 + ASSET 迁移）
    let stepReached = 0;
    hiTraceMeter.startTrace('H:aboutToAppear.initTokenStore', 1);
    tkStore.initTokenStore().then(() => {
      stepReached = 1;
      hiTraceMeter.finishTrace('H:aboutToAppear.initTokenStore', 1);

      // 异步打点：从 TokenStore 读取全部 Token 列表
      hiTraceMeter.startTrace('H:aboutToAppear.getTokens', 1);
      if (this.appCtx.eventHub != undefined) {
        this.appCtx.eventHub.on(EVENT_NAMES.TOKEN_CHANGED, () => this.onTokenChanged());
        this.appCtx.eventHub.on(EVENT_NAMES.TOP_EFFECT_TYPE_CHANGED, () => {
          this.scrollEffectVersion++;
        });
        this.appCtx.eventHub.on(EVENT_NAMES.BOTTOM_TABS_TYPE_CHANGED, () => {
          this.bottomTabsTypeVersion++;
        });
      }
      return tkStore.getTokens();
    }).then((tokens) => {
      stepReached = 2;
      hiTraceMeter.finishTrace('H:aboutToAppear.getTokens', 1);

      this.CurrentTokens = this.sortDisplayTokens([...tokens, ...NfcSessionTokens.getInstance().getTokens()]);
      this.CurrentTokensCount = tokens.length;
      this.token_loading = false;
      this.appIsInit = true;
      // 首帧数据已就绪，结束 aboutToAppear 打点
      hiTraceMeter.finishTrace('H:aboutToAppear', 1);

      setTimeout(() => this.deferredInit(), 0);
    }).catch((err: BusinessError) => {
      // 根据 stepReached 判断失败阶段，仅 finish 已 start 的 trace
      if (stepReached >= 1) {
        hiTraceMeter.finishTrace('H:aboutToAppear.getTokens', 1);
      } else {
        hiTraceMeter.finishTrace('H:aboutToAppear.initTokenStore', 1);
      }
      hiTraceMeter.finishTrace('H:aboutToAppear', 1);
      this.token_loading = false;
      hilog.error(err.code, TAG, `aboutToAppear init failed: ${err.message}`);
    });

    this.timestampIntervalId = setInterval(() => {
      if (this.appCtx != undefined && this.appIsShow)
        if (this.appCtx.eventHub != undefined)
          this.updateTimestamp();
    }, 1000);
  }

  // [冷启动优化] 非首帧必要的初始化操作，由 aboutToAppear 中 setTimeout(0) 延迟调用
  // 包含：华为账号、权限检查、文件 I/O、隐私订阅等，均不阻塞首帧渲染
  // [性能打点] deferredInit 整体耗时 + 华为账号初始化子阶段耗时
  private deferredInit(): void {
    hiTraceMeter.startTrace('H:deferredInit', 1);

    // 异步打点：华为账号初始化（含网络请求，是 deferredInit 中最耗时操作）
    hiTraceMeter.startTrace('H:deferredInit.accountInit', 1);
    HuaweiAccountManager.getInstance().init().then(() => {
      hiTraceMeter.finishTrace('H:deferredInit.accountInit', 1);
      // 账号 UI 状态由 SheetCoordinator 持有，广播事件通知其重新同步
      if (this.appCtx.eventHub != undefined) {
        this.appCtx.eventHub.emit(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED);
      }
      CloudBackupManager.getInstance().checkAndAutoBackup();
    }).catch(() => {
      hiTraceMeter.finishTrace('H:deferredInit.accountInit', 1);
      const diagnostic = CloudBackupDiagnostics.begin(DiagnosticKind.SYNC);
      CloudBackupDiagnostics.mark(diagnostic, DiagnosticStage.ACCOUNT_INIT, DiagnosticResult.FAIL,
        { reason: DiagnosticReason.UNAVAILABLE, errorDomain: DiagnosticErrorDomain.APP });
      CloudBackupDiagnostics.end(diagnostic);
    });

    this.subscribeDistributedAccountLogout();
    PermissionManager.getInstance().verifyPermissionsAndPushEvent();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).then((bundleInfo) => {
      AppStorage.setOrCreate("BundleInfo", bundleInfo);
    });
    AppStorage.setOrCreate("AppPrivacyManageInfoUrl",
      'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=1537746898868267328');
    AppStorage.setOrCreate("AppUserAgreementUrl",
      'https://yylx.duan.red/user-agreement-zh-cn.html');
    fs.access(this.icon_pack_dir).then((res) => {
      if (!res) {
        fs.mkdir(this.icon_pack_dir);
      } else {
        if (TokenIconPacks.aegis_icon_packs.length === 0) {
          this.refreshIconPack();
        }
      }
    });

    // 图标包云端自动恢复：检查云端是否有更新的备份，如有则静默恢复并合并
    this.checkAndRestoreIconPacks();

    // [冷启动优化] FortiToken 证书文件从同步读取改为异步读取，避免阻塞主线程
    let cer_path = this.appCtx.filesDir + "/fmt.ks"
    fs.access(cer_path, fs.AccessModeType.EXIST).then((exist) => {
      if (!exist) {
        fs.open(cer_path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE).then((cer_file) => {
          this.appCtx.resourceManager.getRawFileContent('ftm.ks').then((arr) => {
            fs.write(cer_file.fd, arr.buffer).then(() => {
              hilog.info(0, 'Index', 'store fmt.ks to cache dir')
            }).catch((err: BusinessError) => {
              hilog.error(err.code, 'Index', `${err.message}`)
            }).finally(() => {
              // 确保文件描述符在写入完成或失败后关闭，防止资源泄漏
              fs.close(cer_file);
            })
          }).catch((err: BusinessError) => {
            hilog.error(err.code, 'Index', `getRawFileContent failed: ${err.message}`)
            // 读取失败时也需要关闭文件描述符
            fs.close(cer_file);
          })
        })
      }
    })
    this.GetPrivacyManageInfo();
    // deferredInit 同步部分结束（异步任务仍在后台执行）
    hiTraceMeter.finishTrace('H:deferredInit', 1);
  }

  //region 导入
  @Builder
  EncryptionPasswordDialogBuilder(): void {
    EncryptionPassWordDialog({
      confirm: (password: string) => {
        importBackupWithProgress(this, this.backup_select_uri, true, password, async (tokens, report) => {
          await this.updateTokenConfigs(tokens, report);
        });
      }
    })
  }

  private openEncryptionPasswordDialog(): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => {
        this.EncryptionPasswordDialogBuilder();
      },
      autoCancel: true,
      alignment: DialogAlignment.Center
    }).catch((error: BusinessError) => {
      hilog.error(error.code, 'Index', `open password dialog failed: ${error.message}`);
    });
  }

  async refreshIconPack(): Promise<void> {
    await TokenIconPacks.addUserIconPack(this.user_icon_dir);
    try {
      const paths = await fs.listFile(this.icon_pack_dir);
      for (const path of paths) {
        try {
          await TokenIconPacks.addAegisIconPack(this.icon_pack_dir + "/" + path);
        } catch (err) {
          hilog.error(0, 'Index', `Failed to load icon pack ${path}: ${JSON.stringify(err)}`);
        }
      }
    } catch (err) {
      hilog.warn(0, 'Index', `Failed to list icon packs: ${JSON.stringify(err)}`);
    }
    if (!AppPreference.hasEnabledPacksMigrated()) {
      const selected = AppPreference.getLegacySelectedPack();
      if (selected === 0) {
        TokenIconPacks.enabled_packs = [BUILTIN_DEFAULT_PACK_ID];
      } else {
        const index = selected - 1;
        if (index >= 0 && index < TokenIconPacks.aegis_icon_packs.length) {
          const uuid = TokenIconPacks.aegis_icon_packs[index].uuid;
          TokenIconPacks.enabled_packs = uuid ? [uuid] : [BUILTIN_DEFAULT_PACK_ID];
        } else {
          TokenIconPacks.enabled_packs = [BUILTIN_DEFAULT_PACK_ID];
        }
      }
      AppPreference.saveEnabledPacks(TokenIconPacks.enabled_packs);
    } else {
      TokenIconPacks.enabled_packs = AppPreference.loadEnabledPacks();
    }
    this.appCtx.eventHub.emit(EVENT_NAMES.ICON_PACK_CHANGED);
  }

  /**
   * 图标包自动恢复入口，委托给 IconPackCloudBackup.checkAndAutoRestore()
   * 内部通过状态机保证不会与备份/清理操作冲突
   */
  private async checkAndRestoreIconPacks(): Promise<void> {
    try {
      // 冷启动时 deferredInit 并行触发账号 init 与本入口：userLogin 由 init 的
      // 异步偏好读取写回，不等它则登录态检查恒为 false，自动恢复被静默跳过。
      await HuaweiAccountManager.getInstance().init();
      await IconPackCloudBackup.getInstance().checkAndAutoRestore();
    } catch (err) {
      hilog.error(0xFF00, 'Index', `checkAndRestoreIconPacks failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 主密码兼容性检查.如果用户开启了弹窗告知用户废弃
   *
   */
  private checkMasterKeyDeprecation(): void {
    const acknowledged = AppPreference.getPreference(PREF_KEYS.MASTER_KEY_DEPRECATION_ACKNOWLEDGED) as boolean;
    if (acknowledged || !AppPreference.hasDeprecatedMasterKeyPrefs()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: $r('app.string.master_key_deprecation_title'),
      message: $r('app.string.master_key_deprecation_message'),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.master_key_deprecation_acknowledge'),
          action: () => {
            AppPreference.cleanupDeprecatedMasterKeyPrefs();
          }
        },
      ],
    });
  }

  onDidBuild(): void {
    this.checkMasterKeyDeprecation();
  }

  // 清理 setInterval，防止资源泄漏
  aboutToDisappear(): void {
    if (this.timestampIntervalId !== -1) {
      clearInterval(this.timestampIntervalId);
    }
  }

  onPageHide(): void {
    this.appIsShow = false;
    hilog.info(0, TAG, "onPageHide");
  }

  updateTimestamp(): void {
    const timestamp = nowUnixSeconds();
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, false);
    }
  }

  onPageShow(): void {
    this.appIsShow = true;
    // 重置防窥蒙层标志，确保页面进入时能再次响应窥视事件
    DlpAntiPeepManager.getInstance().resetMaskFlag();
    const needShowLock = AppStorage.get<boolean>('app_lock_need_show') ?? false;
    const cardConfigFormId = AppStorage.get<string>('card_config_formId') ?? '';
    if (!needShowLock && cardConfigFormId === '') {
      this.pageInfos.clear();
      this.selectedTokenUUID = '';
      this.businessSplitEnabled = true;
    }
    if (needShowLock && AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE)) {
      this.isAppLockOverlayVisible = true;
    }
    AppStorage.setOrCreate('app_lock_need_show', false);
    const timestamp = nowUnixSeconds();
    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, true);
    //页面打开的时候刷新token
    tkStore.LoadTokenByDataBase().then(() => {
      // 接收同步完成后刷新数据（合并 NFC 外部令牌，保证外部令牌不丢失）
      this.refreshDisplayTokens().then(() => {
        this.token_loading = false;
      });
    });

    if (AppPreference.getPreference(PREF_KEYS.WANT_QUICK_SCAN)) {
      if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit(EVENT_NAMES.START_QUICK_SCAN);
      AppPreference.setPreference(PREF_KEYS.WANT_QUICK_SCAN, false);
    }

    if (cardConfigFormId !== '') {
      const allPaths = this.pageInfos.getAllPathName();
      if (!allPaths.includes(ROUTE_NAMES.TokenCardConfigPage)) {
        this.openFullScreenRoute(ROUTE_NAMES.TokenCardConfigPage, null);
      }
    }
  }

  /**
   * 合并刷新：本地令牌 + 会话级 NFC 外部令牌。
   * 外部令牌不持久化，所有刷新路径（TOKEN_CHANGED / NFC_EXTERNAL_TOKENS_CHANGED /
   * onPageShow / 删除）统一经此方法，保证外部令牌在本地令牌增删后不丢失、不重复。
   */
  async refreshDisplayTokens(): Promise<void> {
    const tokens = [...await tkStore.getTokens(), ...NfcSessionTokens.getInstance().getTokens()];
    this.CurrentTokens = this.sortDisplayTokens(tokens);
  }

  private sortDisplayTokens(tokens: TokenConfig[]): TokenConfig[] {
    if (this.tokenSortMode === TokenListSortMode.DEFAULT) {
      return [...tokens].sort((first: TokenConfig, second: TokenConfig) => {
        if (first.TokenType === otpType.NFC_external && second.TokenType !== otpType.NFC_external) {
          return 1;
        }
        if (first.TokenType !== otpType.NFC_external && second.TokenType === otpType.NFC_external) {
          return -1;
        }
        return first.TokenType === otpType.NFC_external ? 0 : first.RankScore - second.RankScore;
      });
    }
    const sortByUsername = this.tokenSortMode === TokenListSortMode.USERNAME_ASCENDING ||
      this.tokenSortMode === TokenListSortMode.USERNAME_DESCENDING;
    const direction = this.tokenSortMode === TokenListSortMode.USERNAME_ASCENDING ||
      this.tokenSortMode === TokenListSortMode.TOKEN_NAME_ASCENDING ? 1 : -1;
    return [...tokens].sort((first: TokenConfig, second: TokenConfig) => {
      const firstPrimary = (sortByUsername ? first.TokenName : first.TokenIssuer).toLowerCase();
      const secondPrimary = (sortByUsername ? second.TokenName : second.TokenIssuer).toLowerCase();
      const primaryOrder = firstPrimary.localeCompare(secondPrimary);
      if (primaryOrder !== 0) {
        return primaryOrder * direction;
      }
      const firstSecondary = (sortByUsername ? first.TokenIssuer : first.TokenName).toLowerCase();
      const secondSecondary = (sortByUsername ? second.TokenIssuer : second.TokenName).toLowerCase();
      const secondaryOrder = firstSecondary.localeCompare(secondSecondary);
      return secondaryOrder === 0 ? first.RankScore - second.RankScore : secondaryOrder * direction;
    });
  }

  setTokenSortMode(mode: TokenListSortMode): void {
    if (this.tokenSortMode === mode) {
      return;
    }
    this.tokenSortMode = mode;
    this.CurrentTokens = this.sortDisplayTokens(this.CurrentTokens);
  }

  async onTokenChanged(): Promise<void> {
    await this.refreshDisplayTokens();
  }

  async updateTokenConfig(conf: TokenConfig, toast: boolean = true): Promise<boolean> {
    try {
      if (!conf.TokenIconPath) {
        const iconPath = TokenIconPacks.getIconByIssuer(conf.TokenIssuer);
        if (iconPath !== '') {
          conf.TokenIconPath = iconPath;
        }
      }
      const isNew = !this.CurrentTokens.some(t => t.TokenUUID === conf.TokenUUID);
      await tkStore.updateToken(conf);
      if (isNew || this.tokenSortMode !== TokenListSortMode.DEFAULT) {
        await this.refreshDisplayTokens();
      }
      if (toast) {
        showSnackBar($r('app.string.toast_token_update', conf.TokenIssuer, conf.TokenName), SnackBarNotifyType.SUCCESS);
      }
      return true;
    } catch (e) {
      hilog.error(0, 'Index', `updateTokenConfig failed: ${e}`);
      return false;
    }
  }

  @Monitor('CurrentTokens')
  onCurrentTokensChanged(): void {
    if (this.selectedTokenUUID !== '' &&
      !this.CurrentTokens.some((token: TokenConfig) => token.TokenUUID === this.selectedTokenUUID)) {
      this.selectedTokenUUID = '';
      this.pageInfos.clear();
    }
  }

  private tokenEditRoute(conf: TokenConfig): ROUTE_NAMES | undefined {
    if (conf.TokenType === otpType.Forti) {
      return ROUTE_NAMES.AddFortiTokenPage;
    }
    if (conf.TokenType === otpType.Steam) {
      return ROUTE_NAMES.AddSteamTokenPage;
    }
    if (conf.TokenType === otpType.NFC_external) {
      return undefined;
    }
    return ROUTE_NAMES.AddTotpTokenPage;
  }

  private selectTokenForResponsiveEdit(conf: TokenConfig): void {
    const route = this.tokenEditRoute(conf);
    if (route === undefined) {
      this.selectedTokenUUID = '';
      this.pageInfos.clear();
      return;
    }
    const switchTrace = TokenSwitchPerf.begin(conf.TokenUUID, route);
    const paths = this.pageInfos.getAllPathName();
    const currentRoute = paths.length > 0 ? paths[paths.length - 1] : '';
    ResponsiveTokenEditStore.getInstance().select(conf, switchTrace);
    this.selectedTokenUUID = conf.TokenUUID;
    this.businessSplitEnabled = true;

    if (currentRoute === route) {
      TokenSwitchPerf.mark(switchTrace, 'reuseCommitted');
      this.appCtx.eventHub?.emit(EVENT_NAMES.RESPONSIVE_TOKEN_SELECTION_CHANGED, conf, switchTrace);
      return;
    }

    const params = new AddTokenPageParams('', conf, switchTrace, true);
    // 分栏切换详情无需转场；手机 Stack 模式保留系统页面滑入动画。
    const animated = !this.window.AllowSplit;
    if (paths.length === 0) {
      this.pageInfos.pushPathByName(route, params, animated);
    } else {
      this.pageInfos.replacePathByName(route, params, animated);
    }
    TokenSwitchPerf.mark(switchTrace, 'routeCommitted');
  }

  /**
   * 单双栏变化时修复令牌选中态与详情栈之间的对应关系。
   * 正常切换会保留现有路径；仅在路径意外为空时按稳定 UUID 恢复详情。
   */
  private reconcileTokenRouteForNavigationMode(mode: NavigationMode): void {
    if (this.currentHomeTabIndex !== 0 || !this.businessSplitEnabled || this.selectedTokenUUID === '') {
      return;
    }
    const selectedToken = this.CurrentTokens.find((token: TokenConfig) =>
      token.TokenUUID === this.selectedTokenUUID);
    if (selectedToken === undefined || this.tokenEditRoute(selectedToken) === undefined) {
      this.selectedTokenUUID = '';
      this.pageInfos.clear();
      return;
    }
    if ((mode === NavigationMode.Split || mode === NavigationMode.Stack) &&
      this.pageInfos.getAllPathName().length === 0) {
      this.selectTokenForResponsiveEdit(selectedToken);
    }
  }

  private openFullScreenRoute(name: ROUTE_NAMES, param: Object | null): void {
    this.groupSidebarOpen = false;
    this.pageInfos.pushPathByName(name, param);
    this.businessSplitEnabled = false;
  }

  private async addTestTokens(): Promise<boolean> {
    if (!AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON)) {
      return false;
    }
    const tokens: TokenConfig[] = [];
    for (let i = 0; i < 100; i++) {
      const secret = base32Encode(util.generateRandomBinaryUUID()).substring(0, 26);
      const issuer = `Test-${util.generateRandomUUID().substring(0, 8)}`;
      const name = `User-${util.generateRandomUUID().substring(0, 8)}`;
      tokens.push(new TokenConfig(secret, otpType.TOTP, issuer, name));
    }
    const success = await this.updateTokenConfigs(tokens);
    hilog.info(0xFF00, 'DeveloperOptions',
      `Added ${tokens.length} test tokens, result=${success}, storeCount=${(await tkStore.getTokens()).length}`);
    return success;
  }

  private async removeTestTokens(): Promise<boolean> {
    if (!AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON)) {
      return false;
    }
    const testTokens = (await tkStore.getTokens()).filter(token => token.TokenIssuer.startsWith('Test-'));
    if (testTokens.length === 0) {
      showSnackBar($r('app.string.toast_no_test_tokens'), SnackBarNotifyType.INFO);
      return true;
    }

    try {
      await TokenBatchOperation.run(this, $r('app.string.token_batch_delete_title'), async (report) => {
        await tkStore.deleteTokens(testTokens.map(token => token.TokenUUID), report);
      });
      showSnackBar($r('app.string.toast_test_tokens_removed', testTokens.length), SnackBarNotifyType.SUCCESS);
      return true;
    } catch (error) {
      hilog.error(0, 'DeveloperOptions', `Failed to remove test tokens: ${error}`);
      showSnackBar($r('app.string.toast_test_tokens_removed', 0), SnackBarNotifyType.WARNING);
      return false;
    }
  }

  private async persistImportedTokens(tokens: TokenConfig[], report: TokenBatchProgressCallback): Promise<void> {
    for (const token of tokens) {
      if (token.TokenUUID === undefined) {
        token.TokenUUID = util.generateRandomUUID();
      }
    }
    await tkStore.updateTokens(tokens, report);
  }

  async updateTokenConfigs(tokens: Array<TokenConfig>, report?: TokenBatchProgressCallback): Promise<boolean> {
    if (report) {
      // URI/备份页面已经打开 Dialog：沿用它的进度通道，异常交还调用方，保留输入供重试。
      await this.persistImportedTokens(tokens, report);
      return true;
    }
    if (TokenBatchOperation.isBusy()) {
      return false;
    }
    try {
      await TokenBatchOperation.run(this, $r('app.string.token_batch_import_title'),
        async (observer) => { await this.persistImportedTokens(tokens, observer); });
      showSnackBar($r('app.string.toast_multi_token_update', tokens.length), SnackBarNotifyType.SUCCESS);
      return true;
    } catch (e) {
      hilog.error(0, 'Index', `updateTokenConfigs: transaction failed: ${e}`);
      showSnackBar($r('app.string.token_batch_import_failed'), SnackBarNotifyType.ERROR);
      return false;
    }
  }

  private subscribeDistributedAccountLogout(): void {
    const subscribeInfo: CommonEventManager.CommonEventSubscribeInfo = {
      events: [
        CommonEventManager.Support.COMMON_EVENT_DISTRIBUTED_ACCOUNT_LOGOUT,
      ],
    };
    CommonEventManager.createSubscriber(subscribeInfo).then((subscriber) => {
      CommonEventManager.subscribe(subscriber, (err) => {
        if (!err) {
          HuaweiAccountManager.getInstance().logout().then(() => {
            // 账号 UI 状态由 SheetCoordinator 持有，广播事件通知其重新同步
            if (this.appCtx.eventHub != undefined) {
              this.appCtx.eventHub.emit(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED);
            }
            AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
            AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
          });
        }
      });
    });
  }

  openGroupManagement(): void {
    this.groupSidebarOpen = true;
  }

  getTokenActionsMenuWidth(): number | undefined {
    const uiContext = this.getUIContext();
    const measure = uiContext.getMeasureUtils();
    const labels: Resource[] = [
      $r('app.string.app_ua_add_token'),
      $r('app.string.app_scan_code'),
      $r('app.string.tab_token_add_key'),
      $r('app.string.tab_token_add_forti_key'),
      $r('app.string.tab_token_add_stream_key'),
      $r('app.string.menu_add_nfc_read'),
      $r('app.string.menu_token_sort_method'),
      $r('app.string.menu_token_multi_select'),
      $r('app.string.token_group_manage'),
      $r('app.string.menu_token_sort_default'),
      $r('app.string.menu_token_sort_username_ascending'),
      $r('app.string.menu_token_sort_token_name_ascending'),
      $r('app.string.menu_token_sort_username_descending'),
      $r('app.string.menu_token_sort_token_name_descending')
    ];
    let textWidthPx: number = 0;
    for (const label of labels) {
      const width = measure.measureText({
        textContent: label,
        fontSize: '16fp',
        fontWeight: FontWeight.Medium
      });
      if (!width) {
        return undefined;
      }
      textWidthPx = Math.max(textWidthPx, width);
    }
    // 仅预留原生菜单的非文本空间：外边距8、内嵌缩进24、项内边距32、勾选图标及间距32vp。
    // 每次打开按当前语言和系统字号测量；屏幕最大宽度仍由原生 Menu 约束。
    return Math.ceil(uiContext.px2vp(textWidthPx)) + 8 + 24 + 32 + 32;
  }

  private openTokenSortMenu(): void {
    const uiContext = this.getUIContext();
    const promptAction = uiContext.getPromptAction();
    const contentNode = new ComponentContent(uiContext, wrapBuilder(TokenActionsMenuBuilder), this);
    try {
      promptAction.openMenu(contentNode, { id: this.sortTokenMenuTargetId }, {});
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(err.code, 'Index', `openTokenSortMenu failed: ${err.message}`);
    }
  }

  start_quick_scan() {
    ScanBarCode().then((code) => {
      if (code.startsWith('otpauth-migration://offline?data=')) {
        const data = new url.URLParams(url.URL.parseURL(code).search).get('data');
        const result: GoogleAuthMigrationResult = decodeGoogleAuthMigration(decodeURIComponent(data ?? ''));
        if (result.errorCode === GA_MIGRATION_PARSE_FAILED) {
          showSnackBar($r('app.string.google_auth_migration_invalid'), SnackBarNotifyType.ERROR);
          return;
        }
        if (result.errorCode === GA_MIGRATION_EMPTY) {
          showSnackBar($r('app.string.google_auth_migration_empty'), SnackBarNotifyType.ERROR);
          return;
        }
        if (!result.complete) {
          // 令牌数量多时 Google 会把导出拆成多张二维码，收齐后再落库
          showSnackBar($r('app.string.google_auth_migration_batch', result.batchReceived, result.batchSize),
            SnackBarNotifyType.INFO);
          return;
        }
        this.updateTokenConfigs(result.tokens);
      } else if (code.startsWith('otpauth://')) {
        this.openFullScreenRoute(ROUTE_NAMES.AddTotpTokenPage, new AddTotpRouteParams(code));
      }
    }).catch((err: BusinessError) => {
      // 1000500002: 用户取消扫码, 静默处理
      if (err.code === 1000500002) {
        // 取消时丢弃未收齐的批次，避免下次导入串批
        resetGoogleAuthBatch();
        return;
      }
      hilog.error(0x0000, 'Index', `start_quick_scan failed: ${err.code} ${err.message}`);
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
    });
  }

  openTotpAddPage(): void {
    this.openFullScreenRoute(ROUTE_NAMES.AddTotpTokenPage, new AddTotpRouteParams(''));
  }

  openFortiAddPage(): void {
    this.openFullScreenRoute(ROUTE_NAMES.AddFortiTokenPage, new AddTotpRouteParams(''));
  }

  openSteamAddPage(): void {
    // 必须用 AddTokenPageParams：页面声明的是该类型，传 AddTotpRouteParams 会丢字段
    this.openFullScreenRoute(ROUTE_NAMES.AddSteamTokenPage, new AddTokenPageParams(''));
  }

  openNfcReadDialog(): void {
    // NFC 能力检查不通过：按失败原因分流提示文案并返回，不打开弹窗
    const nfcStatus = NfcOathReader.getInstance().isNfcSupported();
    if (nfcStatus !== NfcSupportStatus.OK) {
      if (nfcStatus === NfcSupportStatus.SWITCH_OFF) {
        showSnackBar($r('app.string.nfc_switch_off'), SnackBarNotifyType.WARNING);
      } else {
        showSnackBar($r('app.string.nfc_unsupported'), SnackBarNotifyType.WARNING);
      }
      return;
    }
    this.dialog_nfc_read = new CustomDialogController({
      systemMaterial: dialogSystemMaterial(),
      builder: NFCReadDialog({
        onSuccess: (result: OathReadResult) => {
          const count = NfcSessionTokens.getInstance().applyResult(result);
          showSnackBar($r('app.string.nfc_read_success', count), SnackBarNotifyType.SUCCESS);
          this.dialog_nfc_read?.close();
        }
      }),
      cancel: () => {},
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      offset: { dx: 0, dy: -20 },
      gridCount: 4,
      customStyle: false,
      cornerRadius: 10,
    });
    this.dialog_nfc_read.open();
  }

  // 准备接入标准化隐私托管
  async GetPrivacyManageInfo(): Promise<void> {
    try {
      let appPrivacyManageInfo: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo type: " + appPrivacyManageInfo["type"]);
      let privacyLinkInfoArray : privacyManager.AppPrivacyLink[] = appPrivacyManageInfo.privacyInfo;
      hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo size = " + privacyLinkInfoArray.length);
      for (let i = 0; i < privacyLinkInfoArray.length; i++) {
        hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo type = " + privacyLinkInfoArray[i]["type"] + ", version = " + privacyLinkInfoArray[i]["versionCode"] + ", url = " + privacyLinkInfoArray[i]["url"]);

      }
      if (privacyLinkInfoArray.length>0) {
        AppStorage.setOrCreate("AppPrivacyManageInfoUrl", privacyLinkInfoArray[0]["url"]);
      }
      if (privacyLinkInfoArray.length>1) {
        AppStorage.setOrCreate("AppUserAgreementUrl", privacyLinkInfoArray[1]["url"]);
      }

    } catch (error) {
      hilog.error(error.code, 'TAG', "GetAppPrivacyManageInfoPublic exception code: " + error.code + ", exception message: " + error.message);
    }

    hilog.info(0, TAG, "subscribe");
    // 创建订阅者
    CommonEventManager.createSubscriber(this.subscribeInfo).then((commonEventSubscriber) => {
      hilog.info(0, TAG, "createSubscriber");
      this.subscriber = commonEventSubscriber;

      // 订阅公共事件
      try {
        CommonEventManager.subscribe(this.subscriber, (err, data) => {
          if (err) {
            hilog.error(err?.code, TAG, `subscribe failed, code is ${err?.code}, message is ${err?.message}`);
            return;
          }

          let result = JSON.parse(data?.data ?? '{}')?.resultType as number;
          if (result === 1) {
            //向用户申请权限
            //PermissionManager.reqPermissionsFromUser(this.appCtx);
          }
        });
      } catch (error) {
        hilog.error(error.code , TAG, "init createSubscriber failed, exception code: " + error.code + ", exception message: " + error.message);
      }
    });
  }

  // [@LocalBuilder] 作为 @BuilderParam 传给 AppShell 时保持 this 指向 Index,
  // 普通 @Builder 会被调用方(AppShell)重绑定 this,导致 this.window 等状态读取为 undefined 引发崩溃
  @LocalBuilder
  AppLockOverlayBuilder() {
    AppLockOverlay({
      onUnlock: () => {
        this.isAppLockOverlayVisible = false;
        // 认证通过后恢复隐私窗口设置到用户偏好
        const privacyMode = AppPreference.getPreference(PREF_KEYS.SAFETY_PRIVACY_ENABLE) as boolean;
        this.window.WindowClass?.setWindowPrivacyMode(privacyMode);
      }
    })
  }

  /**
   * "我的"页签内容(Task 3.1):由 SheetCoordinator 承载全部设置入口与 Sheet
   * [@LocalBuilder] 作为 @BuilderParam 传给 HomeTabs 时保持 this 指向 Index
   */
  @LocalBuilder
  SettingEntryContentBuilder() {
    SheetCoordinator({
      tokens: this.CurrentTokens,
      scrollEffectType: this.currentScrollEffectType,
      scroller: this.settingEntryScroller,
      bottomAvoidHeight: this.window.AvoidBottomHeight,
      wideMode: this.window.AllowSplit,
      active: this.currentHomeTabIndex === 1,
      pageInfos: this.pageInfos,
      selectedRoute: this.selectedSettingRoute,
      onSelectRoute: (route: ROUTE_NAMES) => {
        this.selectedSettingRoute = route;
      },
      backupReload: async (conf, report) => {
        await this.updateTokenConfigs(conf, report);
      },
      addTestTokens: () => this.addTestTokens(),
      removeTestTokens: () => this.removeTestTokens()
    })
  }

  /**
   * 首页内容(Task 3.1):断点 lanes + 双页签,由 HomeTabs 承载。
   * 通过箭头函数传给 AppShell，使 @Builder 保持 Index 的 this 与状态刷新能力。
   */
  @Builder
  MultiSelectPageBuilder() {
    TokenMultiSelectPage({
      scrollEffectType: this.currentScrollEffectType,
      listScroller: this.multiSelectListScroller,
      busy: this.multiSelectBusy,
      content: () => this.HomeContentBuilder(true),
      onExitFullScreen: () => {
        this.multiSelectMode = false;
        this.selectedTokenIds = [];
        this.businessSplitEnabled = true;
      }
    })
  }

  @Builder
  HomeContentBuilder(multiSelect: boolean = false) {
    HomeTabs({
      tokens: this.displayTokens,
      multiSelectMode: multiSelect,
      listStartOffset: multiSelect ? this.window.AvoidTopHeight + CommonConstants.AVOID_TOP_BASE_HEIGHT : 0,
      multiSelectBusy: this.multiSelectBusy,
      selectedTokenIds: this.selectedTokenIds,
      onToggleSelection: (conf: TokenConfig) => this.toggleTokenSelection(conf),
      onSelectAll: () => this.selectAllTokens(),
      onFavoriteSelected: () => { this.applyMultiAction('favorite'); },
      onGroupSelected: () => this.openMultiGroupDialog(),
      onDeleteSelected: () => this.confirmMultiDelete(),
      groupFiltered: this.groupState.selectedId !== ALL_TOKEN_GROUPS,
      window: this.window,
      bottomTabsType: this.currentBottomTabsType,
      currentTabIndex: this.currentHomeTabIndex,
      pageInfos: this.pageInfos,
      updateTokenConfig: (conf: TokenConfig, toast?: boolean) => this.updateTokenConfig(conf, toast),
      updateTokenConfigs: (tokens: Array<TokenConfig>) => this.updateTokenConfigs(tokens),
      tokenListScroller: multiSelect ? this.multiSelectListScroller : this.tokenListScroller,
      settingEntryScroller: this.settingEntryScroller,
      selectedTokenUUID: this.selectedTokenUUID,
      onSelectToken: (conf: TokenConfig) => this.selectTokenForResponsiveEdit(conf),
      onTabChange: (index: number) => {
        this.currentHomeTabIndex = index;
        this.pageInfos.clear();
        if (index === 1) {
          this.selectedTokenUUID = '';
          if (this.window.AllowSplit) {
            this.pageInfos.pushPathByName(this.selectedSettingRoute, null, false);
          }
        }
      },
      settingEntryContent: this.SettingEntryContentBuilder,
    })
  }

  build() {
    Stack() {
      AppShell({
        pageInfos: this.pageInfos,
        isLoading: this.token_loading as boolean,
        blurFlag: this.window.BackgroundBlurActive,
        applockVisible: this.isAppLockOverlayVisible,
        scrollEffectType: this.currentScrollEffectType,
        currentHomeTabIndex: this.currentHomeTabIndex,
        onSelectGroup: (id: string) => this.selectGroup(id),
        groupSidebarOpen: this.groupSidebarOpen,
        $groupSidebarOpen: (open: boolean) => { this.groupSidebarOpen = open; },
        window: this.window,
        businessSplitEnabled: this.businessSplitEnabled,
        tokenListScroller: this.tokenListScroller,
        settingEntryScroller: this.settingEntryScroller,
        openTokenSortMenu: () => this.openTokenSortMenu(),
        sortTokenMenuTargetId: this.sortTokenMenuTargetId,
        onOpenFullScreenRoute: (name: ROUTE_NAMES, param: Object | null) => this.openFullScreenRoute(name, param),
        onExitFullScreenRoute: () => {
          if (this.currentHomeTabIndex === 0) {
            // 手机 Stack 模式返回后不保留仅供分栏详情使用的令牌选中态。
            if (!this.window.AllowSplit) {
              this.selectedTokenUUID = '';
            }
            this.businessSplitEnabled = true;
          }
        },
        onCloseResponsiveTokenEdit: () => {
          this.selectedTokenUUID = '';
          this.pageInfos.clear();
          this.businessSplitEnabled = true;
        },
        onNavBarVisible: () => {
          if (this.currentHomeTabIndex === 0) {
            this.businessSplitEnabled = true;
          }
        },
        onNavigationModeChange: (mode: NavigationMode) => {
          this.reconcileTokenRouteForNavigationMode(mode);
        },
        onDropFile: () => {
          this.DropFilesDialogIsOpen = false;
          this.DropFilesDialogController?.close();
        },
        onDragEnterFile: () => {
          if (!this.DropFilesDialogIsOpen) {
            this.DropFilesDialogIsOpen = true;
            this.DropFilesDialogController = this.createDropFilesDialog();
            this.DropFilesDialogController.open();
          }
        },
        onDragLeaveFile: () => {
          this.DropFilesDialogIsOpen = false;
          this.DropFilesDialogController?.close();
        },
        saveToken: (conf: TokenConfig) => this.updateTokenConfig(conf, true),
        tokens: this.CurrentTokens,
        backupReload: async (conf: TokenConfig[], report?: TokenBatchProgressCallback) => {
          await this.updateTokenConfigs(conf, report);
        },
        addTestTokens: () => this.addTestTokens(),
        removeTestTokens: () => this.removeTestTokens(),
        appLockContent: this.AppLockOverlayBuilder,
        multiSelectPageContent: () => this.MultiSelectPageBuilder(),
        homeContent: () => {
          this.HomeContentBuilder();
        },
      })
    }
  }
}

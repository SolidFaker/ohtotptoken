import { bundleManager,common } from '@kit.AbilityKit';
import { TokenConfig } from '../utils/TokenConfig';
// [冷启动优化] Setting 相关组件：仅在用户切换到"我的"Tab 或打开 Sheet 时才触发模块评估
import lazy { SettingPage } from '../pages/setting/SettingPage'
import lazy { BackupAndMigrationSheet } from '../pages/setting/BackupAndMigrationSheet'
import lazy { SecuritySheet } from '../pages/setting/SecuritySheet'
import lazy { AppearanceSheet } from '../pages/setting/AppearanceSheet'
import lazy { DataSyncSheet } from '../pages/setting/DataSyncSheet'
import lazy { AgreementSheet } from '../pages/setting/AgreementSheet'
import lazy { AboutSheet } from '../pages/setting/AboutSheet'
import lazy { FeedbackSheet } from '../pages/setting/FeedbackSheet'
// [冷启动优化] NavDestination 子页面：仅在用户导航时触发评估
import lazy { TokenCardConfigPage } from './TokenCardConfigPage'
import lazy { TokenSortPage } from './TokenSortPage'
import lazy { TokenSearchPage } from './TokenSearchPage'
import { util, url } from '@kit.ArkTS';
// [冷启动优化] 文件 I/O 仅在 deferredInit 中使用
import lazy { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { showSnackBar, SnackBarNotifyType } from '../utils/HdsSnackBarUtils';
import { AppPreference, TokenPreference, SettingTopEffectType, SettingBottomTabsType, SCROLL_EFFECT_TYPE_MAP, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES, BUILTIN_DEFAULT_PACK_ID } from '../utils/AppPreference';
// [冷启动优化] privacyManager 仅在 deferredInit 的 GetPrivacyManageInfo 中使用
import lazy { privacyManager } from '@kit.StoreKit';
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit';
import CommonEventManager from '@ohos.commonEventManager';
import { TokenStore } from '../utils/TokenStore';
// [冷启动优化] 权限检查仅在 deferredInit 中使用
import lazy { PermissionManager } from '../utils/PermissionManager';
// [冷启动优化] 拖拽弹框仅在 onDragEnter 时触发
import lazy { DropFilesDialog } from '../dialogs/DropFilesDialog';
import { uniformTypeDescriptor } from '@kit.ArkData';
// [冷启动优化] 加密导入弹框仅在文件拖入 .bak 时触发
import lazy { EncryptionPassWordDialog } from '../dialogs/EncryptionPassWordDialog';
// [冷启动优化] 备份恢复仅在文件拖入时触发
import lazy { restoreFromBackup } from '../utils/TokenBackup';
// [冷启动优化] TokenIconPacks 仅在 deferredInit 中使用，ScanBarCode 仅在扫码时使用
import lazy { TokenIconPacks, ScanBarCode } from '../utils/TokenUtils';

// [冷启动优化] 云备份管理器仅在 deferredInit 中使用
import lazy { CloudBackupManager } from '../utils/CloudBackupManager';
import { TokenListPage } from './TokenListPage';
// [冷启动优化] 以下 NavDestination 页面仅在用户导航时触发评估
import lazy { AppearancePage } from './AppearancePage';
import lazy { ShowDataSyncDetailsPage } from './ShowDataSyncDetailsPage';
import lazy { ShowCloudSyncDetailsPage } from './ShowCloudSyncDetailsPage';
import lazy { ShowCloudBackupHistoryPage } from './ShowCloudBackupHistoryPage';
import lazy { ShowCodePage } from './ShowCodePage';
// [冷启动优化] WebPage 导入 @kit.ArkWeb (libwebview_napi.z.so ~10ms)，延迟到用户实际访问网页时
import lazy { WebPage, WebPageParams } from './WebPage';
import { AppWindowInfo } from '../entryability/EntryAbility';
// [冷启动优化] AppLockOverlay 导入 @kit.CryptoArchitectureKit + @kit.UserAuthenticationKit，
// bindContentCover 的 Builder 仅在 isAppLockOverlayVisible=true 时评估
import lazy { AppLockOverlay } from './AppLockOverlay';
import { AppStorageV2, ComponentContent, SymbolGlyphModifier, window } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs,
  ScrollEffectType, HdsListItemCard,
  PrefixIcon,
  IconSize,
  SuffixArrow,
  hdsMaterial} from '@kit.UIDesignKit';
// [冷启动优化] ArcTokenListPage 仅在特定断点 (HEIGHT_MD + WIDTH_XS) 的设备上使用
import lazy { ArcTokenListPage } from './ArcTokenListPage';
import { LengthMetrics } from '@kit.ArkUI';
// [冷启动优化] Google Auth 解码仅在扫描迁移链接时使用
import lazy { decodeProtobuf } from '../utils/GoogleAuthUtils';
// [冷启动优化] 各添加 Token 弹框仅在用户点击添加时触发评估
import lazy { TOTPConfigDialog } from '../dialogs/OTPConfigDialog';
import lazy { FortiConfigDialog } from '../dialogs/FortiConfigDialog';
import lazy { SteamConfigDialog } from '../dialogs/SteamConfigDialog';
import { CommonConstants } from '../utils/CommonConstants';
// [冷启动优化] 华为账号管理器仅在 deferredInit 中初始化
import lazy { HuaweiAccountManager, HuaweiUserInfo, HuaweiAccountLoginError } from '../utils/HuaweiAccountManager';
import lazy { IconPackCloudBackup } from '../utils/IconPackCloudBackup';
import { DlpAntiPeepManager } from '../utils/DlpAntiPeepManager';

const TAG = 'PrivacySubscribe';

let tkStore = TokenStore.getInstance();

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
        host.openTotpAddDialog();
      })
      .accessibilityText($r('app.string.tab_token_add_key'))
    MenuItem({ content: $r('app.string.tab_token_add_forti_key') })
      .onClick(() => {
        host.openFortiAddDialog();
      })
      .accessibilityText($r('app.string.tab_token_add_forti_key'))
    MenuItem({ content: $r('app.string.tab_token_add_stream_key') })
      .onClick(() => {
        host.openSteamAddDialog();
      })
      .accessibilityText($r('app.string.tab_token_add_stream_key'))
  }
}

@Entry
@ComponentV2
struct Index {
  @Local CurrentTokens: TokenConfig[] = [];
  @Local tab_bar_index: number = 0;
  @Local token_loading: Boolean = true;
  @Local background_blur_flag: Boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  @Local tokenListScroller: Scroller = new Scroller();
  @Local arcTokenListScroller: Scroller = new Scroller();
  @Local settingEntryScroller: Scroller = new Scroller();
  @Local isSettingSheetVisible: boolean = false;
  @Local isBackupSheetVisible: boolean = false;
  @Local isSafetySheetVisible: boolean = false;
  @Local isAppearanceSheetVisible: boolean = false;
  @Local isDataSyncSheetVisible: boolean = false;
  @Local isAgreementSheetVisible: boolean = false;
  @Local isAboutSheetVisible: boolean = false;
  @Local isFeedbackSheetVisible: boolean = false;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local huaweiUser: HuaweiUserInfo | null = null;
  @Local isAccountSheetVisible: boolean = false;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local CurrentTokensCount: number = 0;
  @Local scrollEffectVersion: number = 0;
  @Local isAppLockOverlayVisible: boolean = false;
  // 冷启动优化：Setting Tab 懒加载标志，仅在用户首次切换到"我的"Tab 时构建组件树
  @Local settingTabInitialized: boolean = false;
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

  private appIsInit = false;
  private appIsShow = false;
  private icon_pack_dir = this.appCtx.filesDir + "/icon_packs";
  private user_icon_dir = this.appCtx.filesDir + "/user_icons";
  private DropFilesDialogIsOpen:boolean = false;
  // 存储 setInterval ID 以便在 aboutToDisappear 中清理
  private timestampIntervalId: number = -1;
  // 防止 onPageShow 中重复注册 windowStageEvent 监听器
  private windowStageEventListenerRegistered: boolean = false;

  private readonly eventId = 'usual.event.PRIVACY_STATE_CHANGED';
  // 订阅者信息, 用于保存创建成功的订阅者对象，后续使用其完成订阅及退订的动作
  private subscriber: CommonEventManager.CommonEventSubscriber | undefined = undefined;
  // 事件列表
  private subscribeInfo: CommonEventManager.CommonEventSubscribeInfo = {
    events: [this.eventId]
  };
  //拖拽文件弹框
  private DropFilesDialogController: CustomDialogController | null = new CustomDialogController({
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
  })

  private backup_select_uri: string = '';
  private readonly addTokenMenuTargetId: string = 'app_ua_add_token';
  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;

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
        this.pageInfos.pushPathByName(ROUTE_NAMES.TokenCardConfigPage, null);
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_TOKEN_SORT, () => {
        this.pageInfos.pushPathByName(ROUTE_NAMES.TokenSortPage, null);
      });
      this.appCtx.eventHub.on(EVENT_NAMES.FILE_DROP, (uri: string) => {
        this.backup_select_uri = uri;
        if (this.backup_select_uri.endsWith('.bak')) {
          this.password_input_dialog?.open();
        } else if (this.backup_select_uri.endsWith('.json')) {
          restoreFromBackup(uri).then((backup) => {
            this.updateTokenConfigs(backup.configs).then(() => {
              tkStore.sortTokens();
            });
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
      }
      return tkStore.getTokens();
    }).then((tokens) => {
      stepReached = 2;
      hiTraceMeter.finishTrace('H:aboutToAppear.getTokens', 1);

      this.CurrentTokens = tokens;
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
      this.syncHuaweiAccountState();
      CloudBackupManager.getInstance().checkAndAutoBackup();
    }).catch((err: BusinessError) => {
      hiTraceMeter.finishTrace('H:deferredInit.accountInit', 1);
      hilog.error(err.code, TAG, `deferredInit accountInit failed: ${err.message}`);
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
  private password_input_dialog: CustomDialogController | null = new CustomDialogController({
    builder: EncryptionPassWordDialog({
      cancel: () => {},
      confirm: (password: string) => {
        restoreFromBackup(this.backup_select_uri, true, password).then((backup) => {
          this.updateTokenConfigs(backup.configs).then(() => {
            tkStore.sortTokens();
          });
        });
      },
    }),
    cancel: () => {},
    autoCancel: true,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      hilog.info(0, 'Index', "reason=" + JSON.stringify(dismissDialogAction.reason))
      hilog.info(0, 'Index', "dialog onWillDismiss")
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
  })

  async refreshIconPack(): Promise<void> {
    TokenIconPacks.addUserIconPack(this.user_icon_dir);
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
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
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
    }
    if (needShowLock && AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE)) {
      this.isAppLockOverlayVisible = true;
    }
    AppStorage.setOrCreate('app_lock_need_show', false);
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, true);
    //页面打开的时候刷新token
    tkStore.LoadTokenByDataBase().then(() => {
      // 接收同步完成后刷新数据
      tkStore.getTokens().then((tokens) => {
        this.CurrentTokens = tokens;
        this.token_loading = false;
      });
    });

    let context = this.appCtx as common.UIAbilityContext;
    let windowStage = context.windowStage;
    // 防止每次 onPageShow 重复注册 windowStageEvent 监听器
    if (!this.windowStageEventListenerRegistered && windowStage) {
      windowStage.on("windowStageEvent", (data) => {
        this.background_blur_flag = (
          AppPreference.getPreference(PREF_KEYS.SAFETY_BACKGROUND_BLUR_ENABLE) as boolean &&
          data === window.WindowStageEventType.PAUSED
        );
      })
      this.windowStageEventListenerRegistered = true;
    }

    if (AppPreference.getPreference(PREF_KEYS.WANT_QUICK_SCAN)) {
      if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit(EVENT_NAMES.START_QUICK_SCAN);
      AppPreference.setPreference(PREF_KEYS.WANT_QUICK_SCAN, false);
    }

    if (cardConfigFormId !== '') {
      const allPaths = this.pageInfos.getAllPathName();
      if (!allPaths.includes(ROUTE_NAMES.TokenCardConfigPage)) {
        this.pageInfos.pushPathByName(ROUTE_NAMES.TokenCardConfigPage, null);
      }
    }
  }

  async onTokenChanged(): Promise<void> {
    this.CurrentTokens = await tkStore.getTokens();
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
      if (isNew) {
        this.CurrentTokens = [...(await tkStore.getTokens())];
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

  async updateTokenConfigs(tokens: Array<TokenConfig>): Promise<boolean> {
    let failCount = 0;
    let hasNew = false;
    const existingUuids = new Set(this.CurrentTokens.map(t => t.TokenUUID));
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].TokenUUID === undefined) {
        tokens[i].TokenUUID = util.generateRandomUUID();
      }
      if (!existingUuids.has(tokens[i].TokenUUID)) {
        hasNew = true;
      }
      try {
        await tkStore.updateToken(tokens[i]);
      } catch (e) {
        hilog.error(0, 'Index', `updateTokenConfigs[${i}] failed: ${e}`);
        failCount++;
      }
    }
    if (hasNew) {
      this.CurrentTokens = [...(await tkStore.getTokens())];
    }
    if (failCount === 0) {
      showSnackBar($r('app.string.toast_multi_token_update', tokens.length), SnackBarNotifyType.SUCCESS);
      return true;
    } else {
      hilog.error(0, 'Index', `updateTokenConfigs: ${failCount}/${tokens.length} failed`);
      showSnackBar($r('app.string.toast_multi_token_update', tokens.length - failCount), SnackBarNotifyType.WARNING);
      return false;
    }
  }

  private syncHuaweiAccountState(): void {
    this.isHuaweiLoggedIn = HuaweiAccountManager.getInstance().userLogin;
    this.huaweiUser = HuaweiAccountManager.getInstance().userAccount;
  }

  private async triggerHuaweiLogin(): Promise<void> {
    try {
      const result = await HuaweiAccountManager.getInstance().login(this.getUIContext());
      this.syncHuaweiAccountState();
      this.isAccountSheetVisible = true;
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
            this.syncHuaweiAccountState();
            AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
            AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
          });
        }
      });
    });
  }

  private openAddTokenMenu(): void {
    const uiContext = this.getUIContext();
    const promptAction = uiContext.getPromptAction();
    const contentNode = new ComponentContent(uiContext, wrapBuilder(TokenAddMenuBuilder), this);
    try {
      promptAction.openMenu(contentNode, { id: this.addTokenMenuTargetId }, {});
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(err.code, 'Index', `openAddTokenMenu failed: ${err.message}`);
    }
  }

  start_quick_scan() {
    ScanBarCode().then((code) => {
      if (code.startsWith('otpauth-migration://offline?data=')) {
        const data = new url.URLParams(url.URL.parseURL(code).search).get('data');
        decodeProtobuf(decodeURIComponent(data ?? '')).then((confs) => {
          this.updateTokenConfigs(confs);
        });
      } else if (code.startsWith('otpauth://')) {
        this.dialog_totp_config = new CustomDialogController({
          builder: TOTPConfigDialog({
            scan_code_original_Value: code,
            confirm: async (new_conf): Promise<boolean> => {
              return await this.updateTokenConfig(JSON.parse(new_conf), true)
            }
          })
        })
        this.dialog_totp_config.open()
      }
    });
  }

  openTotpAddDialog(): void {
    this.dialog_totp_config = new CustomDialogController({
      builder: TOTPConfigDialog({
        confirm: async (new_conf): Promise<boolean> => {
          return await this.updateTokenConfig(JSON.parse(new_conf), true)
        }
      })
    })
    this.dialog_totp_config.open()
  }

  openFortiAddDialog(): void {
    this.dialog_forti_config = new CustomDialogController({
      builder: FortiConfigDialog({
        confirm: async (new_conf): Promise<boolean> => {
          return await this.updateTokenConfig(JSON.parse(new_conf), true)
        }
      })
    })
    this.dialog_forti_config.open()
  }

  openSteamAddDialog(): void {
    this.dialog_steam_config = new CustomDialogController({
      builder: SteamConfigDialog({
        confirm: async (new_conf): Promise<boolean> => {
          return await this.updateTokenConfig(JSON.parse(new_conf), true)
        }
      })
    })
    this.dialog_steam_config.open()
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

  @Builder
  SettingSheetBuilder() {
  SettingPage({
      Tokens: this.CurrentTokens,
      appBottomAvoidHeight: this.window.AvoidBottomHeight,
      appTopAvoidHeight: 0,
      scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
      listScroller: this.settingEntryScroller,
      backupReload: async (conf) => {
        await this.updateTokenConfigs(conf);
        tkStore.sortTokens();
      }
    })
      .height('100%')
  }

  @Builder
  BackupAndMigrationSheetBuilder() {
    BackupAndMigrationSheet({
      Tokens: this.CurrentTokens,
      scrollEffectStyle: this.currentScrollEffectType,
      backupReload: async (conf) => {
        await this.updateTokenConfigs(conf);
        tkStore.sortTokens();
      }
    })
      .height('100%')
  }

  @Builder
  SecuritySheetBuilder() {
    SecuritySheet({
      scrollEffectStyle: this.currentScrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AppearanceSheetBuilder() {
    AppearanceSheet({
      scrollEffectType: this.currentScrollEffectType,
    })
      .height('100%')
  }

  @Builder
  DataSyncSheetBuilder() {
    DataSyncSheet({
      scrollEffectType: this.currentScrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AgreementSheetBuilder() {
    AgreementSheet({
      scrollEffectType: this.currentScrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AboutSheetBuilder() {
    AboutSheet({
      scrollEffectStyle: this.currentScrollEffectType,
    })
      .height('100%')
  }

  @Builder
  FeedbackSheetBuilder() {
    FeedbackSheet({
      scrollEffectType: this.currentScrollEffectType,
    })
      .height('100%')
  }

  @Builder
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
              .borderRadius(42.5)
              .margin({ top: 40 })
          } else if (this.huaweiUser.nickname !== '') {
            Text(this.huaweiUser.nickname.length > 0 ?
              this.huaweiUser.nickname.substring(this.huaweiUser.nickname.length - 1) : '')
              .width(85)
              .height(85)
              .borderRadius(42.5)
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
  }

  @Builder
  SettingEntryCardBuilder() {
    List({ space: 10, scroller: this.settingEntryScroller }) {
      // 华为账号登录卡片
      ListItem() {
        Row({ space: 16 }) {
          if (this.isHuaweiLoggedIn && this.huaweiUser && this.huaweiUser.avatarUri !== '') {
            Image(this.huaweiUser.avatarUri)
              .draggable(false)
              .width(48)
              .height(48)
              .borderRadius(24)
          } else if (this.isHuaweiLoggedIn && this.huaweiUser && this.huaweiUser.nickname !== '') {
            Text(this.huaweiUser.nickname.length > 0 ?
              this.huaweiUser.nickname.substring(this.huaweiUser.nickname.length - 1) : '')
              .width(48)
              .height(48)
              .borderRadius(24)
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
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
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
        .padding({ left: 20, right: 20, top: 16, bottom: 16 })
        .alignItems(VerticalAlign.Center)
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
        .onClick(() => {
          if (!this.isHuaweiLoggedIn) {
            this.triggerHuaweiLogin();
          } else {
            this.isAccountSheetVisible = true;
          }
        })
        .bindSheet($$this.isAccountSheetVisible, this.AccountSheetBuilder(), {
          detents: [SheetSize.MEDIUM],
          preferType: SheetType.BOTTOM,
          dragBar: true,
        })
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 备份与迁移入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.save')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.setting_backup')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isBackupSheetVisible = true;
            }
          })
            .bindSheet($$this.isBackupSheetVisible, this.BackupAndMigrationSheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 安全性入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.staroflife_rectangle')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.setting_safety')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isSafetySheetVisible = true;
            }
          })
            .bindSheet($$this.isSafetySheetVisible, this.SecuritySheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 外观与功能入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.chevron_up_2_circle')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.app_appearance')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isAppearanceSheetVisible = true;
            }
          })
            .bindSheet($$this.isAppearanceSheetVisible, this.AppearanceSheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 数据同步入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.link')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.data_sync')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isDataSyncSheetVisible = true;
            }
          })
            .bindSheet($$this.isDataSyncSheetVisible, this.DataSyncSheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 协议与声明入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.person_shield')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.setting_agreement_statement')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isAgreementSheetVisible = true;
            }
          })
            .bindSheet($$this.isAgreementSheetVisible, this.AgreementSheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 建议与反馈入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.envelope')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.setting_feedback')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isFeedbackSheetVisible = true;
            }
          })
            .bindSheet($$this.isFeedbackSheetVisible, this.FeedbackSheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })

      // 关于入口
      ListItem() {
        Column() {
          HdsListItemCard({
            cardPrefixMargin: $r('sys.float.padding_level2'),
            cardSuffixMargin: $r('sys.float.padding_level2'),
            cardBackgroundColor: $r('app.color.item_bg'),
            cardHeight: CommonConstants.SETTING_OPTION_CARD_HEIGHT,
            prefixItem: new PrefixIcon({
              iconSize: IconSize.SYSTEM_ICON,
              iconValue: {
                symbol: $r('sys.symbol.info_circle')
              }
            }),
            textItem: {
              primaryText: {
                text: $r('app.string.setting_about')
              }
            },
            suffixItem: new SuffixArrow({}),
            onClick: () => {
              this.isAboutSheetVisible = true;
            }
          })
            .bindSheet($$this.isAboutSheetVisible, this.AboutSheetBuilder(), {
              detents: [SheetSize.LARGE],
              preferType: SheetType.BOTTOM,
              dragBar: true,
            })
        }
        .padding({
          top: $r('sys.float.padding_level2'),
          bottom: $r('sys.float.padding_level2'),
        })
        .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
        .backgroundColor($r('app.color.item_bg'))
      }
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      })
    }
    .clip(false)
    .chainAnimation(this.token_preference.app_appearance_chain_animation_enable)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .backgroundColor($r('app.color.window_background'))
  }

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.AppearancePage) {
      AppearancePage({ scrollEffectType: this.currentScrollEffectType })
    } else if (name === ROUTE_NAMES.ShowDataSyncDetailsPage) {
      ShowDataSyncDetailsPage({ scrollEffectType: this.currentScrollEffectType })
    } else if (name === ROUTE_NAMES.ShowCloudSyncDetailsPage) {
      ShowCloudSyncDetailsPage({ scrollEffectType: this.currentScrollEffectType })
    } else if (name === ROUTE_NAMES.ShowCloudBackupHistoryPage) {
      ShowCloudBackupHistoryPage({ scrollEffectType: this.currentScrollEffectType })
    } else if (name === ROUTE_NAMES.ShowCodePage) {
      ShowCodePage()
    } else if (name === ROUTE_NAMES.WebPage) {
      WebPage({ scrollEffectType: this.currentScrollEffectType, pageParams: param as WebPageParams })
    } else if (name === ROUTE_NAMES.TokenCardConfigPage) {
      TokenCardConfigPage()
    } else if (name === ROUTE_NAMES.TokenSortPage) {
      TokenSortPage({ scrollEffectType: this.currentScrollEffectType })
    } else if (name === ROUTE_NAMES.TokenSearchPage) {
      TokenSearchPage({ scrollEffectType: this.currentScrollEffectType })
    }
  }

  build() {
    HdsNavigation(this.pageInfos) {
      Stack() {
        if (this.token_loading) {
          Column() {
            LoadingProgress()
              .color(Color.White)
              .width(80).height(80)
            Text('Loading..')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#40000000')
          .justifyContent(FlexAlign.Center)
        } else if (
          (this.window.HeightBreakpoint === HeightBreakpoint.HEIGHT_MD) &&
            this.window.WidthBreakpoint === WidthBreakpoint.WIDTH_XS
        ) {
          ArcTokenListPage({
            Tokens: this.CurrentTokens,
            TabBarVisible: false,
            appBottomAvoidHeight: this.window.AvoidBottomHeight,
            appTopAvoidHeight: this.window.AvoidTopHeight,
            appWindowSize: this.window.Size,
            updateTokenConfig: this.updateTokenConfig,
            updateTokenConfigs: this.updateTokenConfigs,
            listScroller: this.arcTokenListScroller,
          })
        } else if (
          (this.window.HeightBreakpoint === HeightBreakpoint.HEIGHT_MD ||
            this.window.HeightBreakpoint === HeightBreakpoint.HEIGHT_SM) &&
            this.window.WidthBreakpoint === WidthBreakpoint.WIDTH_SM
        ) {
          Column() {
            TokenListPage({
              Tokens: this.CurrentTokens,
              TabBarVisible: false,
              appBottomAvoidHeight: this.window.AvoidBottomHeight,
              appTopAvoidHeight: this.window.AvoidTopHeight,
              appWindowSize: this.window.Size,
              updateTokenConfig: this.updateTokenConfig,
              updateTokenConfigs: this.updateTokenConfigs,
              listScroller: this.tokenListScroller,
            })
          }
          .backgroundColor($r('app.color.window_background'))
        } else {

          Column() {
            HdsTabs({ index: this.tab_bar_index }) {
              TabContent() {
                HdsNavigation() {
                  TokenListPage({
                    Tokens: this.CurrentTokens,
                    TabBarVisible: true,
                    appBottomAvoidHeight: this.window.AvoidBottomHeight,
                    appTopAvoidHeight: this.window.AvoidTopHeight,
                    appWindowSize: this.window.Size,
                    updateTokenConfig: this.updateTokenConfig,
                    updateTokenConfigs: this.updateTokenConfigs,
                    listScroller: this.tokenListScroller,
                  })
                }
                .mode(NavigationMode.Stack)
                .bindToScrollable([this.tokenListScroller])
                .titleMode(HdsNavigationTitleMode.MINI)
                .hideBackButton(true) // 设置mini类型隐藏后退按钮
                .titleBar({
                  avoidLayoutSafeArea: true, // 状态栏安全区沉浸
                  enableComponentSafeArea: true,
                  style: {
                    originalStyle: {
                      contentStyle: {
                        titleStyle: {
                          mainTitleColor: $r('sys.color.font_primary'),
                        },
                        menuStyle: {
                          iconColor: $r('sys.color.icon_primary')
                        },
                      }
                    },
                    scrollEffectOpts: {
                      enableScrollEffect: true,
                      scrollEffectType: this.currentScrollEffectType // 渐变模糊
                    },
                    systemMaterialEffect: {
                      materialType: hdsMaterial.MaterialType.ADAPTIVE,
                      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
                    }
                  },
                  content: {
                    title: {
                      mainTitle: $r('app.string.EntryAbility_label'),
                    },
                    menu: {
                      value: [
                        {
                          content: {
                            label: $r('app.string.app_ua_search_token'),
                            icon: $r('sys.symbol.magnifyingglass'),
                            isEnabled: true,
                            action: () => {
                              this.pageInfos.pushPathByName(ROUTE_NAMES.TokenSearchPage, null);
                            }
                          }
                        },
                        {
                          content: {
                            label: $r('app.string.app_ua_add_token'),
                            icon: $r('sys.symbol.plus'),
                            isEnabled: true,
                            componentId: this.addTokenMenuTargetId,
                            action: () => {
                              this.openAddTokenMenu();
                            }
                          }
                        }
                      ]
                    }
                  }
                })
              }
              .backgroundColor($r('app.color.window_background'))
              .tabBar(BottomTabBarStyle.of(
                {
                  normal: new SymbolGlyphModifier($r('sys.symbol.key_fill')),
                  selected: new SymbolGlyphModifier($r('sys.symbol.key_fill'))
                },
                $r('app.string.tab_token'))
                .verticalAlign(VerticalAlign.Center)
              )
              .tabIndex(0)

              TabContent() {
                // [冷启动优化] Setting Tab 懒加载：仅在用户首次切换到"我的"Tab 时构建组件树，
                // 避免冷启动时一次性构建两个 TabContent 导致首帧 build 耗时增加
                if (this.settingTabInitialized) {
                  HdsNavigation() {
                    this.SettingEntryCardBuilder()
                  }
                  .mode(NavigationMode.Stack)
                  .bindToScrollable([this.settingEntryScroller])
                  .titleMode(HdsNavigationTitleMode.MINI)
                  .hideBackButton(true)
                  .titleBar({
                    avoidLayoutSafeArea: true,
                    enableComponentSafeArea: true,
                    style: {
                      originalStyle: {
                        contentStyle: {
                          titleStyle: {
                            mainTitleColor: $r('sys.color.font_primary'),
                          },
                          menuStyle: {
                            iconColor: $r('sys.color.icon_primary')
                          },
                        },
                      },
                      scrollEffectOpts: {
                        enableScrollEffect: true,
                        scrollEffectType: this.currentScrollEffectType,
                      },
                      systemMaterialEffect: {
                        materialType: hdsMaterial.MaterialType.ADAPTIVE,
                        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
                      }
                    },
                    content: {
                      title: {
                        mainTitle: $r('app.string.tab_me')
                      },
                      menu: {
                        value: []
                      }
                    }
                  })
                }
              }
              .backgroundColor($r('app.color.window_background'))
              .tabBar(BottomTabBarStyle.of(
                {
                  normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1')),
                  selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1')),
                },
                $r('app.string.tab_me'))
                .verticalAlign(VerticalAlign.Center)
              )
              .tabIndex(1)
            }
            .barBackgroundColor($r('app.color.tab_bar_bg'))
            .backgroundColor($r('app.color.window_background'))
            .layoutWeight(1)
            .barOverlap(true)
            .barBackgroundColor(Color.Transparent)
            .barBackgroundBlurStyle(BlurStyle.Regular)
            .barPosition(BarPosition.End)
            .barFloatingStyle({
              barBottomMargin: 28,
              systemMaterialEffect: {
                materialType: hdsMaterial.MaterialType.ADAPTIVE,
                materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
              }
            })
            .vertical(false)
            .barMode(BarMode.Fixed)
            .animationDuration(300)
            .onChange((index) => {
              this.tab_bar_index = index;
              // [冷启动优化] 用户首次切换到 Setting Tab 时触发懒加载构建
              if (index === 1 && !this.settingTabInitialized) {
                this.settingTabInitialized = true;
              }
            })
          }
        }
      }
      .width('100%')
      .height('100%')
      .allowDrop([uniformTypeDescriptor.UniformDataType.FILE])
      .onDrop(() => {
        this.DropFilesDialogIsOpen = false;
        this.DropFilesDialogController?.close();
      })
      .onDragEnter(() => {
        if (!this.DropFilesDialogIsOpen) {
          this.DropFilesDialogIsOpen = true;
          this.DropFilesDialogController?.open();
        }
      })
      .onDragLeave(() => {
        this.DropFilesDialogIsOpen = false;
        this.DropFilesDialogController?.close();
      })
      .foregroundBlurStyle((this.background_blur_flag || this.isAppLockOverlayVisible) ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.navDestinationBuilder)
    .bindContentCover($$this.isAppLockOverlayVisible, this.AppLockOverlayBuilder(), {
      modalTransition: ModalTransition.NONE,
      onWillDismiss: (dismissContentCoverAction: DismissContentCoverAction) => {
      },
    })
  }
}

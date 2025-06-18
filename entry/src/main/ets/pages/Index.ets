import { bundleManager,common } from '@kit.AbilityKit';
import { TokenConfig } from '../utils/TokenConfig';
import { SettingPage } from '../pages/SettingPage'
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction'
import { AppPreference } from '../utils/AppPreference';
import { privacyManager } from '@kit.StoreKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import CommonEventManager from '@ohos.commonEventManager';
import { TokenStore } from '../utils/TokenStore';
import { PermissionManager } from '../utils/PermissionManager';
import { DropFilesDialog } from '../dialogs/DropFilesDialog';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { EncryptionPassWordDialog } from '../dialogs/EncryptionPassWordDialog';
import { restoreFromBackup,saveBackupToFile,TokenBackup } from '../utils/TokenBackup';
import { TokenIconPacks } from '../utils/TokenUtils';
// 申请锁屏下应用敏感数据访问权限
import { screenLockFileManager } from '@kit.AbilityKit';
import { TokenListPage } from './TokenListPage';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { AppStorageV2, router, window } from '@kit.ArkUI';
import { writeFileContent } from '../utils/FileUtils';

const TAG = 'PrivacySubscribe';

let tkStore = TokenStore.getInstance();

@Entry
@ComponentV2
struct Index {
  @Local CurrentTokens: TokenConfig[] = [];
  @Local tab_bar_index: number = 0;
  @Local token_loading: Boolean = true;
  @Local background_blur_flag: Boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;

  private appIsInit = false;
  private appIsShow = false;
  private icon_pack_dir = this.appCtx.filesDir + "/icon_packs";
  private user_icon_dir = this.appCtx.filesDir + "/user_icons";
  private DropFilesDialogIsOpen:boolean = false;

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
      console.info("reason=" + JSON.stringify(dismissDialogAction.reason))
      console.log("dialog onWillDismiss")
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

  aboutToAppear(): void {
    PermissionManager.getInstance().verifyPermissionsAndPushEvent();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).then((bundleInfo) => {
      AppStorage.setOrCreate("BundleInfo", bundleInfo);
    });
    //配置预定义好的来自华为官方的个人隐私条款链接
    AppStorage.setOrCreate("AppPrivacyManageInfoUrl",
      'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=1537746898868267328');

    tkStore.initTokenStore().then(() => {
      if (getContext(this).eventHub!= undefined) getContext(this).eventHub.on('onTokenChanged', () => this.onTokenChanged());
      tkStore.getTokens().then((tokens) => {
        this.CurrentTokens = tokens;
        this.token_loading = false;
        // DEBUG MODE
        tkStore.RestoreByKVCheckAsync().then((n:number)=>{
          if (this.CurrentTokens.length==0 && n>0) {
            router.pushUrl({ url: 'pages/RestoreDataPage' });
          }
        }).catch((err:BusinessError)=>{
          hilog.error(err.code,"RestoreByKVCheckAsync",err.message)
        })
        this.appIsInit=true;
        AppPreference.setPreference("app_db_kv_archive_is_running",false)
      });
    });

    // create icon pack dir
    fs.access(this.icon_pack_dir).then((res) => {
      if (!res) {
        fs.mkdir(this.icon_pack_dir);
      } else {
        if (TokenIconPacks.aegis_icon_packs.length === 0) {
          this.refreshIconPack();
        }
      }
    });

    // save certification for forti token
    let cer_path = getContext(this).filesDir + "/fmt.ks"
    fs.access(cer_path, fs.AccessModeType.EXIST).then((exist) => {
      if (!exist) {
        fs.open(cer_path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE).then((cer_file) => {
          let arr = getContext(this).resourceManager.getRawFileContentSync('ftm.ks')
          fs.write(cer_file.fd, arr.buffer).then((cnt) => {
            console.log('store fmt.ks to cache dir')
          })
            .catch((err:BusinessError) => {
              console.error(`${err.message}`)
            })
        })
      }
    })

    this.GetPrivacyManageInfo();
    // 订阅KV数据库同步完成事件
    if (getContext(this).eventHub!= undefined) getContext(this).eventHub.on('KVStoreSyncComplete',() => {
      AppPreference.setPreference('app_db_kv_sync_time', Date().toString());
    })

    //订阅RDB数据库同步完成事件
    if (getContext(this).eventHub!= undefined) getContext(this).eventHub.on('RDBStoreSyncComplete',() => {
      //todo 接收同步完成后刷新数据
    })

    //订阅权限变更 主页面不需要取消订阅 没有意义
    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.on('DATASYNCPermissionsUpdate', (isAccess: boolean) => {
      if (!isAccess) {
        //如果数据同步权限被关闭 则需要将两个同步都关闭
        AppPreference.setPreference('app_db_rds_sync_enable', false);
        AppPreference.setPreference('app_db_rds_cloud_sync_enable', false);
      }
    })

    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.on('onFileDrop', (uri: string) => {
      this.backup_select_uri = uri;
      if (this.backup_select_uri.endsWith('.bak')) { // 后缀bak为加密包 唤醒加密导入弹窗
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

    // periodically update timestamp for tokens
    setInterval(() => {
      if (this.appCtx != undefined && this.appIsShow)
        if (this.appCtx.eventHub != undefined)
           this.updateTimestamp();
    }, 1000);
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
      console.info("reason=" + JSON.stringify(dismissDialogAction.reason))
      console.log("dialog onWillDismiss")
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
  //endregion

  refreshIconPack(): void {
    TokenIconPacks.addUserIconPack(this.user_icon_dir);
    fs.listFile(this.icon_pack_dir).then((paths) => {
      paths.forEach((path) => {
        TokenIconPacks.addAegisIconPack(this.icon_pack_dir + "/" + path);
      })
    });
  }

  updateTimestamp(): void {
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
    if (getContext(this).eventHub != undefined) {
      getContext(this).eventHub.emit('onTimestampChanged', timestamp, false);
    }
  }

  onPageHide(): void {
    this.appIsShow = false;
    hilog.info(0, TAG, "onPageHide");
    //备份还原场景检测是否有备份数据
    if (this.CurrentTokens.length > 0 && this.appIsInit && !AppPreference.getPreference("app_db_kv_archive_is_running")) {
      //todo需要申请锁屏后读取权限 需要实现后台任务备份
      try {
        AppPreference.setPreference("app_db_kv_archive_is_running",true)
        //申请锁屏后访问加密文件的权限
        let acquireStatus = screenLockFileManager.acquireAccess();
        if (acquireStatus === screenLockFileManager.AccessStatus.ACCESS_GRANTED) {
          hilog.info(0x0000, 'testTag', 'acquireAccess successfully.');
          //let thisContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
          tkStore.BuckupToKVAsync().then((n)=>{
            //tkStore.RestoreByKVAsync();
            //更新存档时间
            if (n>0) {
              AppPreference.setPreference('app_db_kv_archive_time', Date().toString());
            }
          }).catch((err:BusinessError)=>{
            hilog.error(err.code,"BuckupToKVAsync",`${err.message}`)
          }).finally(()=>{
            AppPreference.setPreference("app_db_kv_archive_is_running",false);
          });
        }
        else
        {
          AppPreference.setPreference("app_db_kv_archive_is_running",false);
        }
      } catch (err) {
        let message = (err as BusinessError).message;
        hilog.error(0x0000, 'testTag', 'acquireAccess failed: %{public}s', message);
        AppPreference.setPreference("app_db_kv_archive_is_running",false);
      }

    }
  }

  onPageShow(): void {
    router.clear();
    this.appIsShow = true;
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit('onTimestampChanged', timestamp, true);
    //页面打开的时候刷新token
    tkStore.LoadTokenByDataBase().then(() => {
      // 接收同步完成后刷新数据
      tkStore.getTokens().then((tokens) => {
        this.CurrentTokens = tokens;
        this.token_loading = false;
      });
    });

    let context = getContext(this) as common.UIAbilityContext;
    let windowStage = context.windowStage;
    windowStage.on("windowStageEvent", (data) => {
      this.background_blur_flag = (
        AppPreference.getPreference('app_safety_background_blur_enable') as boolean &&
        data === window.WindowStageEventType.PAUSED
      );
    })
  }

  async onTokenChanged(): Promise<void> {
    this.CurrentTokens = await tkStore.getTokens();
  }

  async updateTokenConfig(conf: TokenConfig, toast: boolean = true): Promise<void> {
    await tkStore.updateToken(conf);
    if (toast) {
      promptAction.showToast({ message: $r('app.string.toast_token_update', conf.TokenIssuer, conf.TokenName) })
    }
  }

  async updateTokenConfigs(tokens: Array<TokenConfig>): Promise<void> {
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].TokenUUID === undefined) {
        tokens[i].TokenUUID = util.generateRandomUUID();
      }
      await this.updateTokenConfig(tokens[i], false);
    }
    promptAction.showToast({ message: $r('app.string.toast_multi_token_update', tokens.length) })
  }

  //准备接入标准化隐私托管
  async GetPrivacyManageInfo(): Promise<void> {
    try {
      let appPrivacyManageInfo: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo type: " + appPrivacyManageInfo["type"]);
      let privacyLinkInfoArray : privacyManager.AppPrivacyLink[] = appPrivacyManageInfo.privacyInfo;
      hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo size = " + privacyLinkInfoArray.length);
      for (let i = 0; i < privacyLinkInfoArray.length; i++) {
        hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo type = " + privacyLinkInfoArray[i]["type"] + ", version = " + privacyLinkInfoArray[i]["versionCode"] + ", url = " + privacyLinkInfoArray[i]["url"]);

      }
      AppStorage.setOrCreate("AppPrivacyManageInfoUrl", privacyLinkInfoArray[0]["url"]);
    } catch (error) {
      hilog.error(0, 'TAG', "GetAppPrivacyManageInfoPublic exception code: " + error.code + ", exception message: " + error.message);
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
            hilog.error(0, TAG, `subscribe failed, code is ${err?.code}, message is ${err?.message}`);
            return;
          }

          let result = JSON.parse(data?.data ?? '{}')?.resultType as number;
          if (result === 1) {
            //向用户申请权限
            //PermissionManager.reqPermissionsFromUser(this.appCtx);
          }
        });
      } catch (error) {
        hilog.error(0, TAG, "init createSubscriber failed, exception code: " + error.code + ", exception message: " + error.message);
      }
    });
  }

  @Builder
  tabBar(text: ResourceStr | string, id: number) {
    Column(){
      Blank()
        .width('100%')
        .height(this.window.AvoidTopHeight)
      Text(text)
        .fontWeight(this.tab_bar_index === id ? 500 : 400)
        .fontColor(this.tab_bar_index === id ? $r('app.color.token_number') : $r('app.color.str_main'))
    }
  }

  build() {
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
          })
        }
        .backgroundColor($r('app.color.window_background'))

      } else {

        Column() {
          Tabs({ index: this.tab_bar_index }) {
            TabContent() {
              TokenListPage({
                Tokens: this.CurrentTokens,
                TabBarVisible: true,
                appBottomAvoidHeight: this.window.AvoidBottomHeight,
                appTopAvoidHeight: this.window.AvoidTopHeight,
                appWindowSize: this.window.Size,
                updateTokenConfig: this.updateTokenConfig,
                updateTokenConfigs: this.updateTokenConfigs,
              })
            }
            .backgroundColor($r('app.color.window_background'))
            .tabBar(this.tabBar($r('app.string.tab_token'), 0))
            .tabIndex(0)

            TabContent() {
              SettingPage({
                Tokens: this.CurrentTokens,
                appBottomAvoidHeight: this.window.AvoidBottomHeight,
                appTopAvoidHeight: this.window.AvoidTopHeight,
                backupReload: async (conf) => {
                  await this.updateTokenConfigs(conf);
                  tkStore.sortTokens();
                }
              })
                .height('100%')
            }
            .backgroundColor($r('app.color.window_background'))
            .tabBar(this.tabBar($r('app.string.tab_setting'), 1))
            .tabIndex(1)
          }
          .barBackgroundColor($r('app.color.tab_bar_bg'))
          .backgroundColor($r('app.color.window_background'))
          .layoutWeight(1)
          .barOverlap(true)
          .barBackgroundColor(Color.Transparent)
          .barBackgroundBlurStyle(BlurStyle.Thin)
          .barHeight(50 + this.window.AvoidTopHeight)
          .barMode(BarMode.Fixed)
          .onChange((index) => {
            this.tab_bar_index = index;
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
    .foregroundBlurStyle(this.background_blur_flag ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.LIGHT,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }

}
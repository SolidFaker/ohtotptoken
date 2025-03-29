import { bundleManager,common } from '@kit.AbilityKit';
import { TokenConfig, otpType } from '../utils/TokenConfig';
import { TOTPConfigDialog } from '../dialogs/OTPConfigDialog';
import { FortiConfigDialog } from '../dialogs/FortiConfigDialog';
import { TokenItem } from '../components/TokenItem';
import { SettingPage } from '../pages/SettingPage'
import { url, util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import promptAction from '@ohos.promptAction'
import { SteamConfigDialog } from '../dialogs/SteamConfigDialog';
import { QRCodeDialog } from '../dialogs/QRCodeDialog';
import { AppPreference, SettingValue } from '../utils/AppPreference';
import { privacyManager } from '@kit.StoreKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import CommonEventManager from '@ohos.commonEventManager';
import { TokenStore } from '../utils/TokenStore';
import { PermissionManager } from '../utils/PermissionManager';
import { DropFilesDialog } from '../dialogs/DropFilesDialog';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { EncryptionPassWordDialog } from '../dialogs/EncryptionPassWordDialog';
import { restoreFromBackup } from '../utils/TokenBackup';
import { ScanBarCode, TokenIconPacks } from '../utils/TokenUtils';
import { decodeProtobuf } from '../utils/GoogleAuthUtils';
import { URIConfigDialog } from '../dialogs/URIConfigDialog';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { userAuth } from '@kit.UserAuthenticationKit';

const TAG = 'PrivacySubscribe';

let tkStore = TokenStore.getInstance();

@Entry
@ComponentV2
struct Index {
  @Local btn_token_add_clicked: number = 0;
  @Local CurrentTokens: TokenConfig[] = [];
  @Local tab_bar_index: number = 0;
  @Local token_loading: Boolean = true;
  @Local token_hide_enable: SettingValue = AppPreference.getAppearance('app_safety_hide_token_enable');
  @Local show_next_token_enable: SettingValue = AppPreference.getAppearance('app_appearance_show_next_token_enable');
  @Local swap_host_user_enable: SettingValue = AppPreference.getAppearance('app_appearance_swap_host_user_enable');
  @Local token_copy_guide_popup: boolean = false;
  @Local app_lock: boolean = AppPreference.getAppearance('app_safety_lock_enable') as boolean;

  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  private appBottomAvoidHeight = AppStorage.get("appBottomAvoidHeight") as number;
  private appTopAvoidHeight = AppStorage.get("appTopAvoidHeight") as number;

  private icon_pack_dir = this.appCtx.cacheDir + "/icon_packs";
  private user_icon_dir = this.appCtx.cacheDir + "/user_icon";

  private dialog_uri_config?: CustomDialogController;
  private dialog_totp_config?: CustomDialogController;
  private dialog_forti_config?: CustomDialogController;
  private dialog_steam_config?: CustomDialogController;
  private dialog_qrcode?: CustomDialogController;
  private DropFilesDialogIsOpen:boolean=false;

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
    AppStorage.setOrCreate("AppPrivacyManageInfoUrl", 'https://www.duan.red/yylx/opt/privacy-statement-zh-cn.htm');

    tkStore.initTokenStore().then(() => {
      if (getContext(this).eventHub!= undefined) getContext(this).eventHub.on('onTokenChanged', () => this.onTokenChanged());
      tkStore.getTokens().then((tokens) => {
        this.CurrentTokens = tokens;
        this.token_loading = false;
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
    let cer_path = getContext(this).cacheDir + "/fmt.ks"
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
      AppPreference.setAppearance('app_db_kv_sync_time', Date().toString());
    })

    //订阅RDB数据库同步完成事件
    if (getContext(this).eventHub!= undefined) getContext(this).eventHub.on('RDBStoreSyncComplete',() => {
      //todo 接收同步完成后刷新数据
    })

    //订阅权限变更 主页面不需要取消订阅 没有意义
    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.on('DATASYNCPermissionsUpdate', (isAccess: boolean) => {
      if (!isAccess) {
        //如果数据同步权限被关闭 则需要将两个同步都关闭
        AppPreference.setAppearance('app_db_rds_sync_enable', false);
        AppPreference.setAppearance('app_db_rds_cloud_sync_enable', false);
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

    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.on('onAppUnlock', () => {
      this.app_lock = false;
    });

    // periodically update timestamp for tokens
    setInterval(() => {
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

  onPageShow(): void {
    this.app_lock = AppPreference.getAppearance('app_safety_lock_enable') as boolean;
    if (this.app_lock) {
      if (AppPreference.getAppearance('app_appearance_auto_unlock_enable')) {
        this.requireUserAuth();
      }
    }
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
    //如果已经点击了我知道了则永远不提示了
    if (this.tab_bar_index == 0 && AppPreference.getAppearance('app_show_guide_tips') as boolean) {
      this.token_copy_guide_popup=true;
    }

  }

  async onTokenChanged(): Promise<void> {
    this.CurrentTokens = await tkStore.getTokens();
  }

  async updateTokenConfig(conf: TokenConfig, toast: boolean = true): Promise<void> {
    await tkStore.updateToken(conf);
    if (toast) {
      promptAction.showToast({message: `token ${conf.TokenIssuer}:${conf.TokenName} updated.`})
    }
  }

  async updateTokenConfigs(tokens: Array<TokenConfig>): Promise<void> {
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].TokenUUID === undefined) {
        tokens[i].TokenUUID = util.generateRandomUUID();
      }
      await this.updateTokenConfig(tokens[i], false);
    }
    promptAction.showToast({message: `${tokens.length} token(s) updated.`})
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
  TokenAddMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.app_scan_code') })
        .onClick(async () => {
          ScanBarCode().then((code) => {
            // google authenticator migration
            if (code.startsWith('otpauth-migration://offline?data=')) {
              const data = new url.URLParams(url.URL.parseURL(code).search).get("data");
              decodeProtobuf(decodeURIComponent(data ?? '')).then((confs) => {
                 this.updateTokenConfigs(confs);
              });
            } else if (code.startsWith('otpauth://')) {
              this.dialog_totp_config = new CustomDialogController({
                builder: TOTPConfigDialog({
                  scan_code_original_Value: code, // 弹窗立刻扫码赋值
                  confirm: (new_conf) => {this.updateTokenConfig(JSON.parse(new_conf))}
                })
              })
              this.dialog_totp_config.open()
            }
          });
        })
        .accessibilityText($r('app.string.app_scan_code'))
      MenuItem({ content: $r('app.string.tab_token_add_key') })
        .onClick(() => {
          this.dialog_totp_config = new CustomDialogController({
            builder: TOTPConfigDialog({
              confirm: (new_conf) => {this.updateTokenConfig(JSON.parse(new_conf))}
            })
          })
          this.dialog_totp_config.open()
        })
        .accessibilityText($r('app.string.tab_token_add_key'))
      MenuItem({ content: $r('app.string.tab_token_add_uri') })
        .onClick(() => {
          this.dialog_uri_config = new CustomDialogController({
            builder: URIConfigDialog({
              confirm: (tokens) => {
                this.updateTokenConfigs(tokens);
              }
            })
          })
          this.dialog_uri_config.open()
        })
        .accessibilityText($r('app.string.tab_token_add_uri'))
      MenuItem({ content: $r('app.string.tab_token_add_forti_key') })
        .onClick(() => {
          this.dialog_forti_config = new CustomDialogController({
            builder: FortiConfigDialog({
              confirm: (new_conf) => {this.updateTokenConfig(JSON.parse(new_conf))}
            })
          })
          this.dialog_forti_config.open()
        })
        .accessibilityText($r('app.string.tab_token_add_forti_key'))
      MenuItem({ content: $r('app.string.tab_token_add_stream_key') })
        .onClick(() => {
          this.dialog_steam_config = new CustomDialogController({
            builder: SteamConfigDialog({
              confirm: (new_conf) => {this.updateTokenConfig(JSON.parse(new_conf))}
            })
          })
          this.dialog_steam_config.open()
        })
        .accessibilityText($r('app.string.tab_token_add_stream_key'))
    }
  }

  convertToken2URI(conf: TokenConfig): string {
    let prefix = 'otpauth://';
    let otp_type = conf.TokenType == otpType.HOTP ? 'hotp' : 'totp';
    let label = conf.TokenIssuer + ':' + conf.TokenName;
    let period_or_counter = conf.TokenType == otpType.HOTP ? ('&counter=' + conf.TokenCounter) : ('&period=' + conf.TokenPeriod);
    return prefix + otp_type + '/' + label + '?'
      + 'secret=' + conf.TokenSecret + '&issuer=' + conf.TokenIssuer
      + '&digits=' + conf.TokenDigits
      + period_or_counter;
  }

  requireUserAuth(): void {
    try {
      const rand = cryptoFramework.createRandom();
      const len: number = 16;
      const randData: Uint8Array = rand?.generateRandomSync(len)?.data;
      // 设置认证参数
      const authParam: userAuth.AuthParam = {
        challenge: randData,
        authType: [userAuth.UserAuthType.PIN, userAuth.UserAuthType.FACE, userAuth.UserAuthType.FINGERPRINT],
        authTrustLevel: userAuth.AuthTrustLevel.ATL3,
      };
      // 配置认证界面
      const widgetParam: userAuth.WidgetParam = {
        title: getContext(this).resourceManager.getStringSync($r('app.string.user_auth_prompt').id)
      };
      // 获取认证对象
      const userAuthInstance = userAuth.getUserAuthInstance(authParam, widgetParam);
      console.info('get userAuth instance success');
      // 订阅认证结果
      userAuthInstance.on('result', {
        onResult(result) {
          console.info(`userAuthInstance callback result: ${JSON.stringify(result)}`);
          // 可在认证结束或其他业务需要场景，取消订阅认证结果
          //let rr:userAuth.UserAuthResult =result;
          if (result.result == userAuth.UserAuthResultCode.SUCCESS) {
            // 判断验证结果是否正确 只有正确验证了才能跳跃到首页
            if (getContext(this).eventHub != undefined) {
              getContext(this).eventHub.emit('onAppUnlock');
            }
          }
          userAuthInstance.off('result');
        }
      });
      console.info('auth on success');
      userAuthInstance.start();
      console.info('auth start success');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`auth catch error. Code is ${err?.code}, message is ${err?.message}`);
    }
  }

  @Builder
  TokenItemStart(conf: TokenConfig, index: number) {
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
        this.dialog_qrcode = new CustomDialogController({
          builder: QRCodeDialog({
            content: this.convertToken2URI(conf)
          })
        });
        this.dialog_qrcode.open();
      })
    }
    .margin({ right: 10 })
    .width(50)
  }

  @Builder
  TokenItemEnd(conf: TokenConfig) {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.trash'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Red)
      .padding(10)
      .onClick(async () => {
        AlertDialog.show({
          message: $r('app.string.alert_remove_confirm_msg', conf.TokenName),
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
              this.CurrentTokens = this.CurrentTokens.filter(_ => _.TokenUUID !== conf.TokenUUID);
              tkStore.deleteToken(conf.TokenUUID);
            }
          }
        })
      })
      Button({ type: ButtonType.Circle }) {
        Text() {
          SymbolSpan($r('sys.symbol.square_and_pencil'))
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
      }
      .backgroundColor(Color.Gray)
      .padding(10)
      .onClick(() => {
        if (conf.TokenType === otpType.TOTP || conf.TokenType === otpType.HOTP || conf.TokenType === undefined) { // default
          this.dialog_totp_config = new CustomDialogController({
            builder: TOTPConfigDialog({
              conf_json: JSON.stringify(conf),
              confirm: (new_conf) => {
                this.updateTokenConfig(JSON.parse(new_conf))
              }
            })
          })
          this.dialog_totp_config.open()
        } else if (conf.TokenType === otpType.Forti) { // forti
          this.dialog_forti_config = new CustomDialogController({
            builder: FortiConfigDialog({
              conf_json: JSON.stringify(conf),
              confirm: (new_conf) => {
                this.updateTokenConfig(JSON.parse(new_conf))
              }
            })
          })
          this.dialog_forti_config.open()
        } else if (conf.TokenType === otpType.Steam) { // steam
          this.dialog_steam_config = new CustomDialogController({
            builder: SteamConfigDialog({
              conf_json: JSON.stringify(conf),
              confirm: (new_conf) => {
                this.updateTokenConfig(JSON.parse(new_conf))
              }
            })
          })
          this.dialog_steam_config.open()
        }
      })
    }
    .margin({ left: 10 })
  }

  @Builder
  tabBar(text: ResourceStr | string, id: number) {
    Column(){
      Blank()
        .width('100%')
        .height(this.appTopAvoidHeight)
      Text(text)
        .fontWeight(this.tab_bar_index === id ? 500 : 400)
        .fontColor(this.tab_bar_index === id ? $r('app.color.token_number') : $r('app.color.str_main'))
    }
  }

  build() {
    Stack() {
      if (this.app_lock) {
        Row() {
          RelativeContainer() {
            Row() {
              Column() {
                SymbolGlyph($r('sys.symbol.lock_fill'))
                  .fontSize(70)
                  .fontWeight(FontWeight.Bold)
                  .fontColor([$r('app.color.str_main')])
                  .alignRules({
                    center: { anchor: '__container__', align: VerticalAlign.Center },
                    middle: { anchor: '__container__', align: HorizontalAlign.Center }
                  })
                  .effectStrategy(2)
                Divider().vertical(false).height(20)
                Text($r('app.string.app_locking'))
                  .fontSize(20)
                Text($r('app.string.app_unlock'))
                  .fontSize(20)
                  .fontColor('#3498db')
                  .offset({ top: '40%' })
                  .textAlign(TextAlign.Center)
              }
            }
            .width('80%')
            .height('80%')
            .alignRules({
              top: {anchor: "__container__", align: VerticalAlign.Top},
              bottom : {anchor : "__container__", align : VerticalAlign.Bottom},
              left: {anchor: "__container__", align: HorizontalAlign.Start},
              right : {anchor : "__container__", align: HorizontalAlign.End},
              bias : {vertical : 0.3}
            })
          }
        }
        .height('100%')
        .onClick(() => {
          this.requireUserAuth();
        })
      } else if (this.token_loading) {
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
      } else {

        Column() {
          Tabs() {
            TabContent() {
              Stack({ alignContent: Alignment.BottomEnd }) {
                if (this.CurrentTokens.length === 0) {
                  Row() {
                    Text($r('app.string.app_guide_msg'))
                      .textAlign(TextAlign.Center)
                      .fontSize(20)
                      .width('100%')
                  }
                  .alignItems(VerticalAlign.Center)
                  .width('100%')
                  .height('100%')

                }
                Column() {

                  List({ space: 10, initialIndex: 0 }) {
                    ListItem() {
                      Row()
                        .height(50 + this.appTopAvoidHeight)
                        .width('100%')
                    }
                    ForEach(this.CurrentTokens, (token: TokenConfig, index: number) => {
                      ListItem() {
                        TokenItem({
                          Config: token,
                          TokenHideEnable: this.token_hide_enable as boolean,
                          ShowNextTokenEnable: this.show_next_token_enable as boolean,
                          SwapHostUserEnable: this.swap_host_user_enable as boolean,
                          Update: async (conf_new) => {
                            this.updateTokenConfig(conf_new, false);
                          }
                        })
                          .bindPopup(this.token_copy_guide_popup && index === 0, {
                            placement: Placement.Left,
                            message: getContext(this).resourceManager.getStringSync($r('app.string.token_copy_guide_popup')).toString(),
                            onStateChange: (e)=> {
                              if (!e.isVisible) {
                                this.token_copy_guide_popup = false
                              }
                            },
                            primaryButton: {
                              value: getContext(this).resourceManager.getStringSync($r('app.string.token_copy_guide_popup_Confirm')).toString(),
                              action: () => {
                                if (AppPreference.getAppearance('app_show_guide_tips') as boolean) {
                                  AppPreference.setAppearance('app_show_guide_tips', false)
                                }
                                this.token_copy_guide_popup = false;
                                console.info('confirm Button click')
                              }
                            }
                          })
                      }
                      .padding({ left: 10, right: 10 })
                      .swipeAction({
                        start: {
                          builder: () => { this.TokenItemStart(token, index) }
                        },
                        end: {
                          builder: () => { this.TokenItemEnd(token) },
                        }
                      })
                    }, (item: TokenConfig) => {
                      return JSON.stringify(item)
                    })
                      .onMove((from, to) => {
                        // wait 500ms for animation done
                        setTimeout(() => tkStore.updateTokenRank(from, to), 500);
                      })
                    ListItem() {
                      Row()
                        .width('100%')
                        .height(this.appBottomAvoidHeight + 40)
                    }
                  }
                  .layoutWeight(1)
                  .width('100%')
                  .height('100%')
                  .chainAnimation(true)
                  .scrollBar(BarState.Off)
                  .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
                }
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.plus'))
                    .fontSize(40)
                    .fontWeight(FontWeight.Bold)
                    .fontColor([Color.White])
                    .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
                      this.btn_token_add_clicked)
                }
                .backgroundColor($r('app.color.token_number'))
                .shadow({ radius: 10, color: $r('app.color.shadow') })
                .margin({ bottom: 10, right: 10 })
                .padding(10)
                .bindMenu(this.TokenAddMenu())
                .onClick(() => {
                  this.btn_token_add_clicked += 1
                })
                .accessibilityText($r('app.string.app_ua_add_token'))
              }

            }
            .backgroundColor($r('app.color.window_background'))
            .tabBar(this.tabBar($r('app.string.tab_token'), 0))
            .tabIndex(0)

            TabContent() {
              SettingPage({
                arrConf: this.CurrentTokens,
                appTopAvoidHeight: this.appTopAvoidHeight,
                appBottomAvoidHeight: this.appBottomAvoidHeight,
                backupReload: async (conf) => {
                  await this.updateTokenConfigs(conf);
                  tkStore.sortTokens();
                },
                updateSettings: (key_name) => {
                  if (key_name === 'app_safety_hide_token_enable') {
                    this.token_hide_enable = AppPreference.getAppearance('app_safety_hide_token_enable');
                  } else if (key_name == 'app_appearance_show_next_token_enable') {
                    this.show_next_token_enable = AppPreference.getAppearance('app_appearance_show_next_token_enable');
                  } else if (key_name == 'app_appearance_swap_host_user_enable') {
                    this.swap_host_user_enable = AppPreference.getAppearance('app_appearance_swap_host_user_enable');
                  }

                }
              })
                .height('100%')

            }
            .backgroundColor($r('app.color.window_background'))
            .tabBar(this.tabBar($r('app.string.tab_setting'), 1))
          }
          .barBackgroundColor($r('app.color.tab_bar_bg'))
          .backgroundColor($r('app.color.window_background'))
          .layoutWeight(1)
          .barOverlap(true)
          .barBackgroundColor(Color.Transparent)
          .barBackgroundBlurStyle(BlurStyle.Thin)
          .barHeight(50 + this.appTopAvoidHeight)
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
    .onDrop((event?: DragEvent, extraParams?: string) => {
      this.DropFilesDialogIsOpen=false;
      this.DropFilesDialogController?.close();
    })
    .onDragEnter((event) => {
      //promptAction.showToast({message: `onDragEnter`})
      //检测到开始拖拽
      if (!this.DropFilesDialogIsOpen) {
        this.DropFilesDialogIsOpen=true;
        this.DropFilesDialogController?.open();
      }
    })
    .onDragLeave((event) => {
      //promptAction.showToast({message: `onDragLeave`})
      //检测到离开拖拽区域
      this.DropFilesDialogIsOpen=false;
      this.DropFilesDialogController?.close();
    })
    .onDragEnd((event)=>{

    })

  }
}
import { TokenConfig } from '../utils/TokenConfig';
import { BusinessError } from '@kit.BasicServicesKit';
import { bundleManager, common, ConfigurationConstant } from '@kit.AbilityKit';
import { convertToken2URI, generateFileNameWithDate } from '../utils/TokenUtils'
import promptAction from '@ohos.promptAction'
import { SubItemToggle } from '../components/SubItemToggle'
import { AppStorageV2, curves, router } from '@kit.ArkUI';
import { AppPreference, SettingColorMode, SettingValue, TokenPreference } from '../utils/AppPreference';
import { SubItemButton } from '../components/SubItemButton';
import { SettingItem } from '../components/SettingItem';
import { userAuth } from '@kit.UserAuthenticationKit';
import { PermissionManager } from '../utils/PermissionManager';
import { EncryptionPassWordDialog } from '../dialogs/EncryptionPassWordDialog';
import { restoreFromBackup, saveBackupToFile, TokenBackup } from '../utils/TokenBackup';
import { showSaveFilePicker, showSelectFilePicker, writeFileContent } from '../utils/FileUtils';
import { throttle } from '../utils/UiUtils';
import { SubItemDivider } from '../components/SubItemDivider';
import { SubItemSelect } from '../components/SubItemSelect';
import { window } from '@kit.ArkUI';
import { SubItemIconManager } from '../components/SubItemIconManager';

@Preview
@ComponentV2
export struct SettingPage {
  @Require @Param Tokens: Array<TokenConfig> = [];
  @Require @Param appBottomAvoidHeight: number = 0;
  @Require @Param appTopAvoidHeight: number = 0;
  @Event backupReload: (conf: Array<TokenConfig>) => void = () => {};

  @Local versionName?: string;
  @Local appName?: string;
  @Local RdbSyncEnable: SettingValue = false;
  @Local RdbCloudSyncEnable: SettingValue = false;
  @Local is_loaded: boolean = false;
  @Local is_master_key_enable: boolean = AppPreference.getPreference('app_use_master_key') as boolean;
  @Local is_master_key_set: boolean = AppPreference.getPreference('app_use_master_key_set') as boolean;

  @Local debug_mode_is_on: boolean = AppPreference.getPreference('app_debug_mode_on') as boolean;


  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;

  //备份时是否为导出模式
  private backup_is_input: boolean = true;
  private backup_select_uri: string = '';
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  private windowClass = AppStorage.get("windowClass") as window.Window;
  private versionCode?: number;
  private str_about_app: string = '';
  private str_opensource_leg: string = '';
  private debug_mode_counter: number = 0;

  aboutToAppear(): void {
    let bundleInfo = AppStorage.get<bundleManager.BundleInfo>("BundleInfo");
    this.versionCode = bundleInfo?.versionCode;
    this.versionName = 'Version:' + bundleInfo?.versionName;
    this.appName = bundleInfo?.name;
    this.RdbSyncEnable = AppPreference.getPreference('app_db_rds_sync_enable');
    this.RdbCloudSyncEnable = AppPreference.getPreference('app_db_rds_cloud_sync_enable');
    //订阅权限变更
    this.appCtx.eventHub.on('DATASYNCPermissionsUpdate', this.updateDATASYNCPermissions);
    this.str_about_app =
      "Github: SolidFaker/ohtotptoken\n" +
      "E-mail: enbinli@outlook.com\n" +
      "Contributors: @Solidfaker, @eveloki, @lsxuan12138, @TomStilson, @tomygin, @wulongshe\n" +
      "Bundle Name: " + bundleInfo?.name + "\n" +
      "Version: " + bundleInfo?.versionName + "\n" +
      "Version Code: " + bundleInfo?.versionCode;
    this.str_opensource_leg =
      "Github: paolostivanin/libcotp\n" +
      "Github: Netthaw/TOTP-MCU\n" +
      "Github: ss23/fortitoken-mobile-registration\n" +
      "Github: iamhyc/Aigis\n" +
      "Github: andOTP/andOTP - Icons";
    this.appCtx.eventHub.on('onMasterKeyPageBack',()=>{
      this.is_master_key_set = AppPreference.getPreference('app_use_master_key_set') as boolean;
    })
  }
  //更新数据同步权限
  updateDATASYNCPermissions(isAccess: boolean) {
    if (!isAccess) {
      //如果数据同步权限被关闭 则需要将两个同步都关闭
      this.RdbSyncEnable = false;
      this.RdbCloudSyncEnable = false;
      AppPreference.setPreference('app_db_rds_sync_enable', false);
      AppPreference.setPreference('app_db_rds_cloud_sync_enable', false);
    }
  }

  //region 加密导入导出
  private password_input_dialog: CustomDialogController | null = new CustomDialogController({
    builder: EncryptionPassWordDialog({
      cancel: () => {},
      confirm: (password: string) => {
        if (this.backup_is_input) { // 如果是导出 就要调用导出加密函数
          showSaveFilePicker([`totp_backup_${generateFileNameWithDate()}.bak`], ['BAK|.bak']).then((uris) => {
            const backup: TokenBackup = new TokenBackup(this.versionCode ?? 0, this.Tokens);
            if (uris[0] !== undefined && uris[0] !== '') {
              saveBackupToFile(uris[0], backup, true, password).then(() => {
                promptAction.showToast({ message: $r('app.string.toast_backup_success') });
              }).catch((reason: BusinessError) => {
                promptAction.showToast({ message: reason.message });
              });
            }
          });
        } else { // 加密导入
          restoreFromBackup(this.backup_select_uri, true, password).then((backup) => {
            this.backupReload(backup.configs);
          });
        }
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

  async callFilePickerSaveMigrationFile(): Promise<void> {
    this.getUIContext().showAlertDialog(
      {
        title: $r('app.string.setting_migration_output'),
        subtitle: $r('app.string.setting_migration_output_des'),
        message: $r('app.string.setting_migration_output_msg'),
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        gridCount: 4,
        offset: { dx: 0, dy: -20 },
        buttonDirection: DialogButtonDirection.HORIZONTAL,
        buttons: [
          {
            value: $r('app.string.setting_migration_confirm'),
            action: () => {
              showSaveFilePicker([`totp_migration_${generateFileNameWithDate()}.txt`], ['TEXT|.txt']).then((uris) => {
                let migration_content: string = '';
                this.Tokens.forEach((token) => {
                  migration_content += convertToken2URI(token) + "\n";
                })
                if (uris[0] !== undefined && uris[0] !== '') {
                  writeFileContent(uris[0], migration_content);
                }
              });
            }
          },
          {
            value: $r('app.string.setting_backup_cancel'),
            enabled: true,
            action: () => {
              console.info('Callback when button3 is clicked')
            }
          },
        ],
        cancel: () => {
          console.info('Closed callbacks')
        },
        onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
          console.info("reason=" + JSON.stringify(dismissDialogAction.reason))
          console.log("dialog onWillDismiss")
          if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
            dismissDialogAction.dismiss()
          }
          if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
            dismissDialogAction.dismiss()
          }
        }
      }
    );
  }

  async callFilePickerSaveFile(): Promise<void> {
    this.getUIContext().showAlertDialog(
      {
        title: $r('app.string.setting_backup_output'),
        subtitle: $r('app.string.setting_backup_output_des'),
        message: $r('app.string.setting_backup_output_msg'),
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        gridCount: 4,
        offset: { dx: 0, dy: -20 },
        buttonDirection: DialogButtonDirection.HORIZONTAL,
        buttons: [
          {
            value: $r('app.string.setting_backup_type_default'),
            action: () => {
              showSaveFilePicker([`totp_backup_${generateFileNameWithDate()}.json`], ['JSON|.json']).then((uris) => {
                const backup: TokenBackup = new TokenBackup(this.versionCode, this.Tokens);
                if (uris[0] !== undefined && uris[0] !== '') {
                  saveBackupToFile(uris[0], backup).then(() => {
                    promptAction.showToast({ message: $r('app.string.toast_backup_success') });
                  }).catch((reason: BusinessError) => {
                    promptAction.showToast({ message: reason.message });
                  });
                }
              });
            }
          },
          {
            value: $r('app.string.setting_backup_type_enc'),
            action: () => {
              this.password_input_dialog?.open();
            }
          },
          {
            value: $r('app.string.setting_backup_cancel'),
            enabled: true,
            action: () => {
              console.info('Callback when button3 is clicked')
            }
          },
        ],
        cancel: () => {
          console.info('Closed callbacks')
        },
        onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
          console.info("reason=" + JSON.stringify(dismissDialogAction.reason))
          console.log("dialog onWillDismiss")
          if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
            dismissDialogAction.dismiss()
          }
          if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
            dismissDialogAction.dismiss()
          }
        }
      }
    );
  }

  async callFilePickerSelectFile(): Promise<void> {
    showSelectFilePicker(1, ['JSON|.json', 'BAK|.bak']).then((uris) => {
      this.backup_select_uri = uris[0];
      if (this.backup_select_uri.endsWith('.bak')) {
        //后缀bak为加密包 唤醒加密导入弹窗
        this.password_input_dialog?.open();
      } else {
        restoreFromBackup(uris[0]).then((backup) => {
          this.backupReload(backup.configs);
        })
      }
    });
  }

  //endregion
  // 在自定义组件即将析构销毁时将dialogController置空
  aboutToDisappear() {
    this.password_input_dialog = null // 将dialogController置空
    this.appCtx.eventHub.off('DATASYNCPermissionsUpdate', this.updateDATASYNCPermissions);
  }

  build() {
    Stack() {
      if (this.is_loaded) {
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
        List({ space: 10 }) {
          ListItemGroup() {
            ListItem() {

            }
            .height(50 + this.appTopAvoidHeight)
          }

          ListItem() {
            SettingItem({ title: $r('app.string.setting_backup') }) {
              SubItemButton({
                symbol: $r('sys.symbol.save'),
                text: $r('app.string.setting_backup_export')
              })
                .onClick(() => {
                  this.backup_is_input = true;
                  this.callFilePickerSaveFile()
                })

              SubItemDivider()

              SubItemButton({
                symbol: $r('sys.symbol.folder'),
                text: $r('app.string.setting_backup_import')
              })
                .onClick(() => {
                  this.backup_is_input = false;
                  this.callFilePickerSelectFile()
                })

              SubItemDivider()

              SubItemButton({
                symbol: $r('sys.symbol.briefcase'),
                text: $r('app.string.setting_migration')
              })
                .onClick(() => {
                  this.callFilePickerSaveMigrationFile()
                })
            }
          }
          .padding({ left: 10, right: 10 })

          ListItem() {
            SettingItem({ title: $r('app.string.setting_safety') }) {
              SubItemToggle({
                icon: $r('sys.symbol.staroflife_rectangle'),
                title: $r('app.string.restore_master_key'),
                isOn: AppPreference.getPreference('app_use_master_key') as boolean,
                description: $r('app.string.restore_master_key_msg'),
                onChange: (IsOn: boolean) => {
                  this.is_master_key_enable=IsOn;
                  AppPreference.setPreference('app_use_master_key', IsOn);
                }
              })
              SubItemButton({
                symbol: $r('sys.symbol.key_shield'),
                text: $r('app.string.restore_master_key_set'),
                description:this.is_master_key_set?$r('app.string.restore_master_key_reset_desc'):$r('app.string.restore_master_key_no_set_desc'),
                descriptionColor:this.is_master_key_set?$r('sys.color.ohos_id_color_text_secondary'):$r('app.color.token_progress_next_color_end')
              })//条件渲染有第一次不生效的bug（虚假机下） 很奇怪
                .visibility(this.is_master_key_enable ? Visibility.Visible : Visibility.None)// 使用显隐控制，启动时即使组件处于隐藏状态，也会创建
                .onClick(throttle((event) => {
                  //this.is_master_key_set=!this.is_master_key_set;
                  router.pushUrl({ url: 'pages/MasterKeyPage' });
                }, 1000))

              SubItemDivider()

              SubItemToggle({
                icon: $r('sys.symbol.hand_raised_hexagon'),
                title: $r('app.string.setting_safety_privacy'),
                isOn: AppPreference.getPreference('app_safety_privacy_enable') as boolean,
                description: $r('app.string.setting_safety_privacy_des'),
                onChange: (IsOn: boolean) => {
                  AppPreference.setPreference('app_safety_privacy_enable', IsOn);
                  try {
                    this.windowClass.setWindowPrivacyMode(IsOn).catch((err: BusinessError) => {
                      console.error(`Failed to set the window to privacy mode. Cause code: ${err.code}, message: ${err.message}`);
                    });
                  } catch (exception) {
                    console.error(`Failed to set the window to privacy mode. Cause code: ${exception.code}, message: ${exception.message}`);
                  }
                }
              })

              SubItemDivider()

              SubItemToggle({
                icon: $r('sys.symbol.key_shield'),
                title: $r('app.string.setting_safety_lock'),
                isOn: AppPreference.getPreference('app_safety_lock_enable') as boolean,
                description: $r('app.string.setting_safety_lock_des'),
                onChange: (IsOn: boolean) => {
                  if (IsOn) {
                    try {
                      userAuth.getAvailableStatus(userAuth.UserAuthType.PIN, userAuth.AuthTrustLevel.ATL1);
                    } catch (err) {
                      const error = err as BusinessError;
                      promptAction.showToast({ message: error.message });
                      return;
                    }
                  }
                  AppPreference.setPreference('app_safety_lock_enable', IsOn);
                }
              })

              SubItemDivider()

              SubItemToggle({
                icon: $r('sys.symbol.eye_slash'),
                title: $r('app.string.setting_hide_token'),
                isOn: AppPreference.getPreference('app_safety_hide_token_enable') as boolean,
                description: $r('app.string.setting_safety_hide_token_des'),
                onChange: (IsOn: boolean) => {
                  AppPreference.setPreference('app_safety_hide_token_enable', IsOn);
                  this.token_preference.app_safety_hide_token_enable = IsOn;
                }
              })

              SubItemDivider()

              SubItemToggle({
                icon: $r('sys.symbol.blur_bar'),
                title: $r('app.string.setting_background_blur'),
                isOn: AppPreference.getPreference('app_safety_background_blur_enable') as boolean,
                description: $r('app.string.setting_background_blur_des'),
                onChange: (IsOn: boolean) => {
                  AppPreference.setPreference('app_safety_background_blur_enable', IsOn);
                }
              })
            }
          }
          .padding({ left: 10, right: 10 })

          ListItem() {
            SettingItem({ title: $r('app.string.app_appearance') }) {
              SubItemToggle({
                icon: $r('sys.symbol.chevron_up_2_circle'),
                title: $r('app.string.show_next_token'),
                isOn: AppPreference.getPreference('app_appearance_show_next_token_enable') as boolean,
                description: $r('app.string.show_next_token_des'),
                onChange: (IsOn: boolean) => {
                  AppPreference.setPreference('app_appearance_show_next_token_enable', IsOn);
                  this.token_preference.app_appearance_show_next_token_enable = IsOn;
                }
              })

              SubItemDivider()

              if (this.debug_mode_is_on) {
                SubItemToggle({
                  icon: $r('sys.symbol.gearshape'),
                  title: $r('app.string.debug_mode'),
                  isOn: AppPreference.getPreference('app_debug_mode_on') as boolean,
                  description: $r('app.string.debug_mode_des'),
                  onChange: (IsOn: boolean) => {
                    animateTo({ curve: curves.springMotion() }, () => {
                      this.debug_mode_is_on = IsOn;
                    })
                    AppPreference.setPreference('app_debug_mode_on', IsOn);
                  }
                })

                SubItemDivider()
              }

              SubItemToggle({
                icon: $r('sys.symbol.face'),
                title: $r('app.string.auto_unlock'),
                isOn: AppPreference.getPreference('app_safety_auto_unlock_enable') as boolean,
                description: $r('app.string.auto_unlock_des'),
                onChange: (IsOn: boolean) => {
                  AppPreference.setPreference('app_safety_auto_unlock_enable', IsOn);
                }
              })

              SubItemDivider()

              SubItemSelect({
                icon: $r('sys.symbol.dark'),
                title: $r('app.string.setting_color_mode'),
                values: [$r('app.string.setting_color_mode_system'), $r('app.string.setting_color_mode_dark'),
                  $r('app.string.setting_color_mode_light'),],
                description: $r('app.string.setting_color_mode_desc'),
                selected: AppPreference.getPreference('app_appearance_color_mode') as number ??
                SettingColorMode.System,
                onChange: (index: number) => {
                  AppPreference.setPreference('app_appearance_color_mode', index);
                  const color_map: Map<SettingColorMode, ConfigurationConstant.ColorMode> = new Map([
                    [SettingColorMode.System, ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET],
                    [SettingColorMode.Dark, ConfigurationConstant.ColorMode.COLOR_MODE_DARK],
                    [SettingColorMode.Light, ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT],
                  ]);
                  this.appCtx.getApplicationContext().setColorMode(color_map.get(index));
                }
              })

              SubItemDivider()

              SubItemIconManager()

              SubItemDivider()

              SubItemButton({
                symbol: $r("sys.symbol.paintpalette"),
                text: $r('app.string.customize_appearance')
              })
                .onClick(throttle((event) => {
                  router.pushUrl({ url: 'pages/AppearancePage' });
                }, 1000))
            }
          }
          .padding({ left: 10, right: 10 })

          ListItem() {
            SettingItem({ title: $r('app.string.data_sync') }) {
              SubItemToggle({
                icon: $r('sys.symbol.link'),
                title: $r('app.string.data_rdb_sync'),
                isOn: this.RdbSyncEnable as boolean,
                description: $r('app.string.data_rdb_sync_des'),
                onChange: (IsOn: boolean) => {
                  if (IsOn) {
                    PermissionManager.getInstance().reqPermissionsFromUser(this.appCtx);
                  }
                  this.RdbSyncEnable = IsOn;
                  AppPreference.setPreference('app_db_rds_sync_enable', IsOn);
                }
              })

              SubItemDivider()

              SubItemToggle({
                icon: $r('sys.symbol.icloud'),
                title: $r('app.string.data_rdb_cloud_sync'),
                isOn: this.RdbCloudSyncEnable as boolean,
                description: $r('app.string.data_rdb_cloud_sync_des'),
                disable: true,
                onChange: (IsOn: boolean) => {
                  if (IsOn) {
                    PermissionManager.getInstance().reqPermissionsFromUser(this.appCtx);
                  }
                  this.RdbCloudSyncEnable = IsOn;
                  AppPreference.setPreference('app_db_rds_cloud_sync_enable', IsOn);
                }
              })
                .visibility(Visibility.None)

              SubItemDivider()
                .visibility(Visibility.None)

              SubItemButton({
                symbol: $r('sys.symbol.arrow_counterclockwise_clock'),
                text: $r('app.string.data_rdb_sync_details')
              })
                .onClick(throttle((event) => {
                  router.pushUrl({ url: 'pages/ShowDataSyncDetailsPage' });
                }, 1000))
            }
          }
          .padding({ left: 10, right: 10 })

          ListItem() {
            SettingItem({ title: $r('app.string.setting_agreement_statement') }) {
              SubItemButton({ symbol: $r("sys.symbol.person_shield"), text: $r('app.string.privacy_statement') })
                .onClick(throttle((event) => {
                    router.pushUrl({ url: 'pages/PrivacyPage' });
                }, 1000))

              SubItemDivider()

              SubItemButton({
                symbol: $r("sys.symbol.doc_plaintext_and_pencil"),
                text: $r('app.string.user_agreement')
              })
                .onClick(throttle((event) => {
                  router.pushUrl({ url: 'pages/AgreementPage' });
                }, 1000))
            }
          }
          .padding({ left: 10, right: 10 })

          ListItem() {
            SettingItem({ title: $r('app.string.setting_about') }) {
              Text(this.str_about_app)
                .fontSize(10)
                .fontColor($r('app.color.str_gray'))
                .padding(10)
            }
          }
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            if (!this.debug_mode_is_on) {
              setTimeout(() => {
                this.debug_mode_counter = 0;
              }, 2000);
              if (this.debug_mode_counter > 7) {
                animateTo({ curve: curves.springMotion() }, () => {
                  this.debug_mode_is_on = true;
                  AppPreference.setPreference('app_debug_mode_on', true);
                  promptAction.showToast({ message: "DEBUG MODE ON" });
                })

              }
              this.debug_mode_counter++;
            }
          })

          ListItem() {
            SettingItem({ title: $r('app.string.setting_opensource_leg') }) {
              Text(this.str_opensource_leg)
                .fontSize(10)
                .fontColor($r('app.color.str_gray'))
                .padding(10)
            }
          }
          .padding({ left: 10, right: 10 })

          ListItemGroup() {
            ListItem() {
              Row() {
                Hyperlink('https://github.com/SolidFaker/ohtotptoken/issues', $r('app.string.app_issue_feedback'))
                  .height(10)
                  .padding({ left: 10 })
                Hyperlink('https://beian.miit.gov.cn/', '粤ICP备2020075515号-2A')
                  .height(10)
                  .padding({ left: 10 })
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
            .padding({ left: 10, right: 10 })
          }

          ListItemGroup() {
            ListItem() {
              Row()
                .width('100%')
                .height(this.appBottomAvoidHeight)
            }
          }
        }
        .chainAnimation(true)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .scrollBar(BarState.Off)
        .backgroundColor($r('app.color.window_background'))
      }
    }
  }
}
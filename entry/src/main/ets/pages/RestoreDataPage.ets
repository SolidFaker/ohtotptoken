import { AppStorageV2, router } from '@kit.ArkUI';
import { TopNavigationView } from '../components/TopNavigationView';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { AppPreference } from '../utils/AppPreference';
import { common } from '@kit.AbilityKit';
import { TokenStore } from '../utils/TokenStore';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { throttle } from '../utils/UiUtils';
import { showSelectFilePicker, readFileContentAndCheckSize } from '../utils/FileUtils';
import { fileIo as fs } from "@kit.CoreFileKit";


@Entry
@ComponentV2
struct RestoreDataPage {
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local isEnabledKDF: boolean = false;//是否启用主密钥 todo 这里还需要补充输入朱密码的UI场景
  @Local isBegin: boolean = false;//是否开始恢复
  @Local isRestoreSuccess: boolean = false;//是否恢复成功
  @Local progress: number = 0;
  @Local masterKey: string = "";//用户设置的主密码
  @Local recoveryKey: string = "";//用户设置的恢复密钥
  @Local recoveryKeyShow: string = "";//用户设置的恢复密钥
  @Local masterKeyErr: boolean= false;//用户设置的主密码错误
  @Local recoveryKeyErr: boolean= false;//用户设置的主恢复密钥错误
  @Local masterKeyInputEnable: boolean= true;//启用主密码输入
  TOAST_BOTTOM: number = 135;
  tkStore = TokenStore.getInstance();
  TimeInterval:number = 0;
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  aboutToAppear(): void {
    this.isBegin = false;
    this.isEnabledKDF=AppPreference.getPreference("app_use_master_key") as boolean;
  }
  restoreData() {
    this.isBegin = true;
    this.progress = 0;
    this.TimeInterval = setInterval(() => {
      if (this.progress < 99) {
        this.progress++;
      } else {
        this.isBegin = false;
        this.progress = 0;
        this.isRestoreSuccess=true;
        clearInterval(this.TimeInterval);
      }
    }, 250);
    if (this.isEnabledKDF)//使用主密码时开始校验主密码
    {
      if (this.masterKeyInputEnable)
      {
        this.tkStore.CheckMasterKeySync(this.masterKey).then((req=>{
          if (req) {
            this.masterKeyErr=false;
            this.GoRestore();
          }
          else {
            this.masterKeyErr=true;
            this.StopRestore('app.string.restore_data','app.string.restore_master_key_err_msg');
          }
        }));
      }
      else
      {
        this.tkStore.CheckRecoverySecretKey(this.recoveryKey).then((req=>{
          if (req) {
            this.recoveryKeyErr=false;
            this.GoRestore();
          }
          else {
            this.recoveryKeyErr=true;
            this.StopRestore('app.string.restore_data','app.string.restore_master_key_recovery_key_err_msg');
          }
        }));
      }

    }
    else
    {
      this.GoRestore();
    }
  }
  GoRestore()
  {
    this.tkStore.RestoreByKVAsync().then((n)=>{
      //更新存档时间
      if (n>0) {
        AppPreference.setPreference('app_db_kv_archive_time', Date().toString());
      }
    }).catch((err:BusinessError)=>{
      hilog.error(err.code,"RestoreByKVAsync",`${err.message}`)
    }).finally(()=>{
      this.StopRestore('app.string.restore_data','app.string.restore_data_ok_msg',true);
    });
  }
  StopRestore(title:string,message:string,autoCloseApp:boolean=false)
  {
    this.progress=100;
    clearInterval(this.TimeInterval);
    setTimeout(() => {
      this.isBegin = false;
      this.progress = 0;
      this.isRestoreSuccess=false;
      //this.getUIContext().getPromptAction().showToast({ message: $r('app.string.restore_data_ok_msg'), bottom: this.TOAST_BOTTOM })
      this.getUIContext().showAlertDialog(
        {
          title: $r(title),
          message:$r(message),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          offset: { dx: 0, dy: -20 },
          gridCount: 3,
          buttons: [{
            value: 'cancel',
            action: () => {
            }
          },
            {
              enabled: true,
              defaultFocus: true,
              style: DialogButtonStyle.HIGHLIGHT,
              value: 'ok',
              action: () => {
                if (autoCloseApp) {
                  this.appCtx.terminateSelf();
                }
              }
            }],
        }
      );
    }, 200)
  }
  importRecoveryKey(){
    showSelectFilePicker(1, ['Text|.text']).then((uris) => {
      let backup_select_uri = uris[0];
      readFileContentAndCheckSize(backup_select_uri,1024).then((text)=>{
        this.recoveryKey=text;
        this.recoveryKeyShow=text;
        if (text=="") {
          this.getUIContext().getPromptAction().showToast({ message: "invalid Recovery Key file", bottom: this.TOAST_BOTTOM })
        }
      });
    });
  }

  build() {
    Column() {
      TopNavigationView({
        title: $r('app.string.restore_data'),
        onBackClick: () => {
          router.back();
        }
      })
      Column() {
        Column() {
          LoadingProgress()
            .width(100)
            .layoutWeight(1)
        }
        .height('40%')
        Column() {
          if (this.isEnabledKDF)
          {
            Stack({ })//有个强加进来的Input 为了屏蔽他（用户能点击正常触发输入法输入） 所以用一个遮罩层遮住
            {
              TextInput({ placeholder: 'UserName',text:"admin" })//要触发华为的密码保险箱 需要用户名密码同时存在 而且还不能隐藏 所以必须要这个input
                .type(InputType.USER_NAME)// 账号框使用USER_NAME属性
                .opacity(0)
                .visibility(Visibility.Visible)// 隐藏
                .onChange((value: string) => {
                })
              Column(){}.height(20).width('100%').backgroundColor('#00000000')
            }.height(20)

            Blank(10)
            TextInput({ placeholder: $r('app.string.restore_input_master_key') })
              .opacity(0.6)
              .type(InputType.NEW_PASSWORD)
              .placeholderColor(0x182431)
              .width('100%')
              .placeholderFont({ size: 16, weight: FontWeight.Regular })
              .margin({ top: 32, bottom: 8 })
              .showError(this.masterKeyErr ? $r('app.string.restore_master_key_err_msg'): undefined)
              .visibility(this.masterKeyInputEnable ? Visibility.Visible : Visibility.None)// 使用显隐控制，启动时即使组件处于隐藏状态，也会创建
              .onChange((value: string) => {
                this.masterKey = value.trim();
              })
            TextInput({ placeholder: $r('app.string.restore_input_recovery_key'),text:this.recoveryKeyShow})
              .opacity(0.6)
              .type(InputType.Normal)
              .placeholderColor(0x182431)
              .width('100%')
              .placeholderFont({ size: 16, weight: FontWeight.Regular })
              .margin({ top: 32, bottom: 8 })
              .showError(this.recoveryKeyErr ? $r('app.string.restore_master_key_recovery_key_err_msg'): undefined)
              .visibility(this.masterKeyInputEnable ? Visibility.None: Visibility.Visible)// 使用显隐控制，启动时即使组件处于隐藏状态，也会创建
              .onChange((value: string) => {
                this.recoveryKey = value.trim();
              })
            Blank(10)
            Button() {
              Text($r('app.string.restore_import_recovery_key'))
                .fontSize(16)
                .fontWeight(500)
                .fontColor($r('app.color.white'))
            }
            .id('publish')
            .width('100%')
            .height(40)
            .backgroundColor($r('app.color.button_blue'))
            .onClick(throttle((event) => {
              this.importRecoveryKey();
            }))
            .visibility(this.masterKeyInputEnable ? Visibility.None : Visibility.Visible)// 使用显隐控制，启动时即使组件处于隐藏状态，也会创建
            Blank(10)
            Row()
            {
              Text(this.masterKeyInputEnable?$r('app.string.restore_use_recovery_key'):$r('app.string.restore_use_master_key'))
                .fontColor($r('app.color.btn_text_blue'))
                .onClick(throttle((event)  => {
                  this.masterKeyInputEnable=!this.masterKeyInputEnable;
                }))
            }.align(Alignment.End)

            Blank(10)
            Text($r('app.string.restore_data_kdf_msg'))
              .fontSize(16)
              .fontWeight(500)
          }
          else
          {
            Text($r('app.string.restore_data_msg'))
              .fontSize(16)
              .fontWeight(500)
          }
          Blank(10)
          Button() {
            if (this.isBegin) {
              Row() {
                Progress({ value: this.progress, type: ProgressType.Ring })
                  .width(20)
                  .height(20)
                  .backgroundColor('#FFFFFF')
                  .color('#558DFF')
                  .style({ strokeWidth: 2, scaleCount: 100, scaleWidth: 2 })
                Text()
                {
                  Span($r('app.string.restore_data_restoring'))
                  Span(` ${this.progress}%`)
                }
                .fontSize(16)
                .fontColor('#FFFFFF')
                .fontWeight(500)
                .margin({ left: 12 })
              }.alignItems(VerticalAlign.Center)
            } else {
              Text($r('app.string.restore_data'))
                .fontSize(16)
                .fontWeight(500)
                .fontColor($r('app.color.white'))
            }
          }
          .id('publish')
          .width('100%')
          .height(40)
          .margin({ bottom: this.isBegin ? 16 : 24 })
          .enabled(!this.isRestoreSuccess)
          .backgroundColor($r('app.color.button_blue'))
          .onClick(throttle((event)  => {
            if (!this.isBegin) {
              this.restoreData();
            }
          }))

          if (this.isBegin) {
            Button() {
              Text($r('app.string.restore_data_cancel'))
                .fontSize(16)
                .fontWeight(500)
                .fontColor($r('app.color.btn_text_blue'))
            }
            .id('cancel')
            .width('100%')
            .height(40)
            .margin({ bottom: 24 })
            .backgroundColor($r('app.color.button_light_gray'))
            .enabled(true)
            .onClick(() => {
              // cancel task
              //this.progress = 0;
              //this.isBegin = false;
            })
          }
        }
        .padding({ left: 24, right: 24 })
        .align(Alignment.End)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
    .padding({ top: this.window.AvoidTopHeight, bottom: this.window.AvoidBottomHeight })
  }
}
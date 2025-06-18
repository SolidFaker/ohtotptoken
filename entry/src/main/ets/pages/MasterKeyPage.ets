import { AppStorageV2, router } from '@kit.ArkUI';
import { TopNavigationView } from '../components/TopNavigationView';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { AppPreference } from '../utils/AppPreference';
import { common } from '@kit.AbilityKit';
import { TokenStore } from '../utils/TokenStore';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { showSaveFilePicker, showSelectFilePicker, writeFileContent,
  writeFileContentCheckHashEqual } from '../utils/FileUtils';
import lottie, { AnimationItem } from '@ohos/lottie';
import { throttle } from '../utils/UiUtils';


@Entry
@ComponentV2
struct MasterKeyPage {
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local isBegin: boolean = false;//是否开始设置主密码
  @Local recoverySecretKey: string = "";//恢复密钥
  @Local recoverySecretKeyShow: string = "";//恢复密钥
  @Local masterKey: string = "";//用户设置的主密码
  @Local masterKeyErr: boolean= false;//用户设置的主密码错误
  @Local is_loaded: boolean = false;
  TOAST_BOTTOM: number = 135;
  tkStore = TokenStore.getInstance();

  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  // 构建上下文
  private renderingSettings: RenderingContextSettings = new RenderingContextSettings(true)
  private canvasRenderingContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderingSettings)
  private animateItem: AnimationItem | null = null;
  private animateName: string = "no-limit"; // 动画名称

  // 页面销毁时释放动画资源
  aboutToDisappear(): void {
    console.info('aboutToDisappear');
    lottie.destroy();
  }

  aboutToAppear(): void {
    this.isBegin = false;
  }
  setMasterKey() {
    if (this.masterKey!=null&&this.masterKey!="") {
      this.masterKey=this.masterKey.trim();
      if (this.masterKey.length>=8) {
        this.is_loaded=true;
        this.tkStore.SetMasterKeyAsync(this.masterKey.trim()).then((rk)=>{
          this.isBegin = true;
          this.recoverySecretKey=rk.replace(/=/g,"");
          this.recoverySecretKeyShow=this.formatBase32(this.recoverySecretKey);
          AppPreference.setPreference('app_use_master_key_set',true)
          this.is_loaded=false;
        })
      }
      else
      {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.restore_master_key_password_too_short_msg'), bottom: this.TOAST_BOTTOM })
      }
    }
  }
  confirmRecoveryKey(){
    //this.tkStore.CheckRecoverySecretKey(this.recoverySecretKey).then((b)=>{
    //  this.getUIContext().getPromptAction().showToast({ message: b?"恢复密钥OK":"恢复密钥Err", bottom: this.TOAST_BOTTOM })
    //})
    this.appCtx?.eventHub.emit('onMasterKeyPageBack');
    router.back();
  }
  exportRecoveryKey(){
    showSaveFilePicker([`totp_recovery_key.text`], ['Text|.text']).then((uris) => {
      if (uris[0] !== undefined && uris[0] !== '') {
        writeFileContentCheckHashEqual(uris[0], this.recoverySecretKey).then(()=>{
          this.getUIContext().getPromptAction().showToast({ message: "OK", bottom: this.TOAST_BOTTOM })
        });
      }
    });
  }
  formatBase32(base32Str:string) {
    // 1. 清理输入：转为大写，移除非Base32字符（A-Z2-7）和填充符
    const cleaned = base32Str
      .toUpperCase();
      //.replace(/[^A-Z2-7]/g, '');

    // 2. 按每4个字符分组
    const groups: string[] = [];
    for (let i = 0; i < cleaned.length; i += 4) {
      groups.push(cleaned.slice(i, i + 4));
    }

    // 3. 每3组一行进行格式化
    const lines: string[] = [];
    for (let i = 0; i < groups.length; i += 3) {
      const lineGroups = groups.slice(i, i + 3);
      lines.push(lineGroups.join('   ')); // 组间用空格分隔
    }

    // 4. 行间用换行符连接
    return lines.join('\n');
}

  build() {
    Scroll() {
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
      }
      else
      {
        Column() {
          TopNavigationView({
            title: $r('app.string.restore_master_key_set'),
            onBackClick: () => {
              router.back();
            }
          })
          Column() {
            Column() {
              // 关联画布
              Canvas(this.canvasRenderingContext)
                .width(200)
                .height(200)
                .backgroundColor(Color.Transparent)
                .onReady(() => {
                  // 加载动画
                  if (this.animateItem != null) {
                    // 可在此生命回调周期中加载动画，可以保证动画尺寸正确
                    this.animateItem?.resize();
                  } else {
                    // 抗锯齿的设置
                    this.canvasRenderingContext.imageSmoothingEnabled = true;
                    this.canvasRenderingContext.imageSmoothingQuality = 'medium'
                    this.loadAnimation();
                  }
                })
            }
            Blank(10)
            Column(){
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

              TextInput({ placeholder: $r('app.string.restore_input_master_key') })
                .opacity(0.6)
                .type(InputType.NEW_PASSWORD)
                .placeholderColor(0x182431)
                .width('100%')
                .placeholderFont({ size: 16, weight: FontWeight.Regular })
                .margin({ top: 32, bottom: 8 })
                .showError(this.masterKeyErr ? $r('app.string.restore_master_key_password_too_short_msg'): undefined)
                .onChange((value: string) => {
                  this.masterKey = value.trim();
                  if (this.masterKey.length<8) {
                    this.masterKeyErr=true;
                  }
                  else
                  {
                    this.masterKeyErr=false;
                  }
                })
                .visibility(this.isBegin ? Visibility.None : Visibility.Visible)// 使用显隐控制，启动时即使组件处于隐藏状态，也会创建
            }
            .padding({ left: 24, right: 24 })
            Blank(10)
            Column() {
              if (this.isBegin)
              {
                Text($r('app.string.restore_recovery_key'))
                  .fontSize(28)
                  .fontWeight(600)
                Text(this.recoverySecretKeyShow)
                  .fontSize(24)
                  .fontWeight(600)
                Blank(10)
                //Text(this.recoverySecretKey)
                //  .fontSize(20)
                //  .fontWeight(600)
                Blank(10)
                Text($r('app.string.restore_master_key_recovery_key_msg'))
                  .fontSize(16)
                  .fontWeight(600)
              }
              else
              {
                Text($r('app.string.restore_master_key_set_msg'))
                  .fontSize(16)
                  .fontWeight(600)
              }

              Blank(10)
              Button() {
                if (this.isBegin) {
                  Text($r('app.string.restore_recovery_key_confirm'))
                    .fontSize(16)
                    .fontWeight(500)
                    .fontColor($r('app.color.white'))
                } else {
                  Text($r('app.string.restore_master_key_set'))
                    .fontSize(16)
                    .fontWeight(500)
                    .fontColor($r('app.color.white'))
                }
              }
              .id('publish')
              .width('100%')
              .height(40)
              .margin({ bottom: this.isBegin ? 16 : 24 })
              .backgroundColor($r('app.color.button_blue'))
              .onClick(throttle((event) => {
                if (!this.isBegin) {
                  this.setMasterKey();
                }
                else
                {
                  this.confirmRecoveryKey();
                }
              }))

              Blank(10)
              Button() {
                Text($r('app.string.restore_recovery_key_export'))
                  .fontSize(16)
                  .fontWeight(500)
                  .fontColor($r('app.color.white'))
              }
              .id('publish')
              .width('100%')
              .height(40)
              .margin({ bottom: this.isBegin ? 16 : 24 })
              .backgroundColor($r('app.color.button_blue'))
              .onClick(throttle((event) => {
                this.exportRecoveryKey();
              }))
              .visibility(this.isBegin ? Visibility.Visible : Visibility.None)// 使用显隐控制，启动时即使组件处于隐藏状态，也会创建
            }
            .padding({ left: 24, right: 24 })
            .align(Alignment.End)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      }

    }
    .padding({ top: this.window.AvoidTopHeight, bottom: this.window.AvoidBottomHeight })
  }

  loadAnimation() {
    this.animateItem = lottie.loadAnimation({
      container: this.canvasRenderingContext,
      renderer: 'canvas', // canvas 渲染模式
      loop: false,
      autoplay: false,
      name: this.animateName,
      contentMode: 'Contain',
      path: "pages/common/no-limit.json",
    })
    // 因为动画是异步加载，所以对animateItem的操作需要放在动画加载完成回调里操作
    this.animateItem.addEventListener('DOMLoaded', (args: Object): void => {
      //this.animateItem?.changeColor([225, 25, 100, 1]);
      this.animateItem?.play()
    });
  }

  destroy() {
    this.animateItem?.removeEventListener("DOMLoaded");
    lottie.destroy(this.animateName);
    this.animateItem = null;
  }
}
import { otpType, TokenConfig } from '../utils/TokenConfig';
import { url } from '@kit.ArkTS';
import { HMACAlgorithm, ScanBarCode } from '../utils/TokenUtils';
import { TokenIcon } from '../components/TokenIcon';
import { SelectIconDialog } from './SelectIconDialog';

@Preview
@CustomDialog
export struct TOTPConfigDialog {
  controller?: CustomDialogController;
  @Prop conf_json?: string = '';
  @State conf: TokenConfig = new TokenConfig();
  @State btn_camera_clicked: number = 0;
  //弹窗扫码值 初始化 给首页快速扫码使用
  @State scan_code_original_Value:string = '';

  cancel?: () => void;
  confirm: (new_conf: string) => void = () => {};

  dialog_icon_config = new CustomDialogController({
    builder: SelectIconDialog({
      issuer: this.conf.TokenIssuer,
      confirm: (path) => {
        this.conf.TokenIconPath = path;
      }
    })
  });

  aboutToAppear(): void {
    if (this.conf_json != undefined && this.conf_json.length > 0) {
      this.conf = JSON.parse(this.conf_json!);
    }
    if (this.scan_code_original_Value!='') {
      this.addNewConfigOTP(this.scan_code_original_Value);
    }
  }

  addNewConfigOTP(uri: string): void {
    let otp_url: url.URL
    try {
      otp_url = url.URL.parseURL(uri)
    } catch (error) {
      console.error('Invalid OTPAuth URL:', error);
      return;
    }

    if (otp_url.protocol !== 'otpauth:') {
      console.error('Invalid protocol');
      return;
    }

    const type = otp_url.host.toLowerCase();

    if (type === 'totp') {
      this.conf.TokenType = otpType.TOTP;
    } else if (type == 'hotp') {
      this.conf.TokenType = otpType.HOTP;
    } else {
      console.error('Invalid type');
      return;
    }

    const pathParts = otp_url.pathname.slice(1).split('/');
    const labelParts = decodeURIComponent(pathParts[0]).split(':');

    if (labelParts.length > 1) {
      this.conf.TokenIssuer = labelParts[0];
      this.conf.TokenName = labelParts[1];
    }

    const parameters: Record<string, string> = {};
    const tail_part = otp_url.href.split('?');
    if (tail_part.length > 1) {
      const query = tail_part[1];
      if (query) {
        query.split('&').forEach(part => {
          const kv: string[] = part.split('=');
          //保留secret的大小写
          if(kv[0].toLowerCase()=='secret')parameters[kv[0].toLowerCase()] = kv[1];
          else parameters[kv[0].toLowerCase()] = kv[1].toLowerCase();
        });
      }
      this.conf.TokenSecret = parameters['secret'];
      this.conf.TokenPeriod = parseInt(parameters['period'] ?? '30');
      this.conf.TokenCounter = parseInt(parameters['counter'] ?? '0');
      this.conf.TokenDigits = parseInt(parameters['digits'] ?? '6');
    }
  }

  build() {
    Column({ space: 10 }) {
      Row() {

      }
      .height(10)
      Row() {
        TokenIcon({ issuer: this.conf.TokenIssuer, icon_path: this.conf.TokenIconPath })
          .onClick(() => {
            this.dialog_icon_config.open()
          })
        Text($r('app.string.tab_token_add_key'))
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
        SymbolGlyph($r('sys.symbol.camera'))
          .fontSize(30)
          .fontColor([$r('app.color.item_fg')])
          .fontWeight(FontWeight.Medium)
          .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
            this.btn_camera_clicked)
          .onClick(() => {
            this.btn_camera_clicked++
            ScanBarCode().then((code) => {
              this.addNewConfigOTP(code)
            });
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      Row(){

      }
      .width('100%')
      .borderRadius(1)
      .backgroundColor($r('app.color.item_fg'))
      .height(2)
      Column({ space: 10 }) {
        Row() {
          Text($r("app.string.dialog_cfg_tk_secret"))
            .width('30%')
          TextInput({ text: this.conf.TokenSecret, placeholder: $r("app.string.dialog_cfg_tk_secret")})
            .onChange((value) => {
              this.conf.TokenSecret = value
            })
            .type(InputType.Password)
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Text($r("app.string.dialog_cfg_tk_issuer"))
            .width('30%')
          TextInput({ text: this.conf.TokenIssuer, placeholder: $r("app.string.dialog_cfg_tk_issuer") })
            .onChange((value) => {
              this.conf.TokenIssuer=value;
            })
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Text($r("app.string.dialog_cfg_tk_name"))
            .width('30%')
          TextInput({ text: this.conf.TokenName, placeholder: $r("app.string.dialog_cfg_tk_name") })
            .onChange((value) => {
              this.conf.TokenName = value
            })
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Text($r('app.string.dialog_cfg_tk_alg'))
            .width('30%')
          Select([
            {value: 'SHA1'},
            {value: 'SHA224'},
            {value: 'SHA256'},
            {value: 'SHA384'},
            {value: 'SHA512'},
            {value: 'SM3'},
            {value: 'MD5'},
          ])
            .selected(0)
            .value(this.conf.TokenAlgorithm)
            .onSelect((_, value) => {
              this.conf.TokenAlgorithm = value as HMACAlgorithm
            })
            .width('70%')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        Row() {
          Text($r('app.string.dialog_cfg_tk_digits'))
            .width('30%')
          Row() {
            Text("4")
            Radio({ value: '4', group: 'rg_cfg_digits' }).checked(this.conf.TokenDigits === 4)
              .radioStyle({
                checkedBackgroundColor: Color.Blue
              })
              .onChange((isChecked: boolean) => {
                if (isChecked) {
                  this.conf.TokenDigits = 4
                }
              })
            Text("6")
            Radio({ value: '6', group: 'rg_cfg_digits' }).checked(this.conf.TokenDigits === 6)
              .radioStyle({
                checkedBackgroundColor: Color.Blue
              })
              .onChange((isChecked: boolean) => {
                if (isChecked) {
                  this.conf.TokenDigits = 6
                }
              })
            Text("8")
            Radio({ value: '8', group: 'rg_cfg_digits' }).checked(this.conf.TokenDigits === 8)
              .radioStyle({
                checkedBackgroundColor: Color.Blue
              })
              .onChange((isChecked: boolean) => {
                if (isChecked) {
                  this.conf.TokenDigits = 8
                }
              })
          }
          .width('70%')
          .justifyContent(FlexAlign.SpaceEvenly)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        if (this.conf.TokenType == otpType.TOTP) {
          Row() {
            Text($r('app.string.dialog_cfg_tk_timeout'))
              .width('30%')
            Row() {
              Slider({
                min: 1,
                max: 60,
                value: this.conf.TokenPeriod,
                step: 1,
                style: SliderStyle.InSet
              })
                .blockColor('#191970')
                .selectedColor('#4169E1')
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.conf.TokenPeriod = value
                })
              Text(this.conf.TokenPeriod.toFixed(0)).fontSize(12)
            }
            .width('70%')
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
        } else if (this.conf.TokenType == otpType.HOTP) {
          Row() {
            Text($r('app.string.dialog_cfg_tk_counter'))
              .width('30%')
            TextInput({ placeholder: this.conf.TokenCounter.toString() })
              .onChange((value) => {
                let counter = parseInt(value);
                if (!isNaN(counter)) {
                  this.conf.TokenCounter = counter;
                }
              })
              .width('70%')
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
        }
      }
      .padding({left: 10, right: 10})

      .width('100%')

      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        Button($r('app.string.dialog_btn_cancel'))
          .fontColor($r('app.color.item_fg'))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close()
            }
          })
          .width('100%')
        Button($r('app.string.dialog_btn_confirm'), { })
          .enabled(!!(this.conf.TokenSecret && this.conf.TokenIssuer && this.conf.TokenName))
          .fontColor(Color.Red)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.confirm(JSON.stringify(this.conf))
              this.controller.close()
            }
          })
          .width('100%')
      }
    }
    .padding(10)
    .width('100%')
  }
}

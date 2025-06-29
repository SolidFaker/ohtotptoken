import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { showSelectFilePicker } from '../utils/FileUtils';
import { AegisIconPack, TokenIconPacks } from '../utils/TokenUtils';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { AppStorageV2, promptAction } from '@kit.ArkUI';
import { SubItemDivider } from './SubItemDivider';
import { AppPreference } from '../utils/AppPreference';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { throttle,startBrowsableAbility } from '../utils/UiUtils';

@Preview
@ComponentV2
export struct SubItemIconManager {
  @Local collapsed: boolean = true;
  @Local installed_icon_pack: AegisIconPack[] = TokenIconPacks.aegis_icon_packs;
  @Local selected_icon_pack: number = TokenIconPacks.selected_icon_pack;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private icon_pack_dir = this.window.Context?.filesDir + "/icon_packs";

  build() {
    Column() {
      Row() {
        Column() {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.plus_square_on_square'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor([$r('app.color.str_main')])

            Text($r('app.string.setting_icon_pack'))
              .fontSize($r('sys.float.ohos_id_text_size_body1'))
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .fontWeight(FontWeight.Regular)
              .textAlign(TextAlign.Start)
          }

          Text($r('app.string.setting_icon_pack_desc'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontFamily('HarmonyHeiTi')
            .lineHeight(19)
        }
        .layoutWeight(2)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 10 }) {
          Blank()
          Text($r('app.string.setting_icon_pack_preview', this.installed_icon_pack.length))
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontColor([$r('sys.color.font_tertiary')])
            .fontSize(24)
            .height(48)
            .align(Alignment.Center)
            .rotate(this.collapsed ? { angle: 0 } : { angle: 90 })
            .translate(this.collapsed ? {} : { x: -3 })
        }
        .layoutWeight(1)
        .onClick(() => {
          this.window.uiContext?.animateTo({ duration: 200, curve: Curve.Sharp }, () => {
            this.collapsed = !this.collapsed;
          })
        })

      }
      .justifyContent(FlexAlign.SpaceBetween)
      .width('100%')

      if (!this.collapsed) {
        Column() {
          SubItemDivider()
            .margin({ bottom: 5 })
          if (this.installed_icon_pack.length === 0) {
            Row() {
              Text($r('app.string.setting_icon_pack_info'))
                .fontSize($r('sys.float.ohos_id_text_size_body1'))
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
                .fontWeight(FontWeight.Regular)
                .textAlign(TextAlign.Start)
              Column({ space: 10 }) {
                Button('aegis-icons', { buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.SMALL })
                  .borderRadius($r('sys.float.corner_radius_level4') )
                  .type(ButtonType.Capsule)
                  .margin({ left: $r('sys.float.padding_level8') })
                  .width(100)
                  .fontColor($r('sys.color.interactive_active'))
                  .onClick(throttle((event) => {
                    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                    startBrowsableAbility(context,'https://github.com/aegis-icons/aegis-icons/releases/latest/download/aegis-icons.zip');
                  }, 1000))
                Button('delta-icons', { buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.SMALL })
                  .borderRadius($r('sys.float.corner_radius_level4') )
                  .type(ButtonType.Capsule)
                  .margin({ left: $r('sys.float.padding_level8') })
                  .width(100)
                  .fontColor($r('sys.color.interactive_active'))
                  .onClick(throttle((event) => {
                    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                    startBrowsableAbility(context,'https://github.com/Delta-Icons/aegis/releases/latest/download/delta-aegis-icons.zip');
                  }, 1000))
                //Hyperlink('https://github.com/aegis-icons/aegis-icons/releases/latest/download/aegis-icons.zip', 'aegis-icons').color($r('sys.color.ohos_id_color_text_primary'))
                //Hyperlink('https://github.com/Delta-Icons/aegis/releases/latest/download/delta-aegis-icons.zip', 'delta-icons').color($r('sys.color.ohos_id_color_text_primary'))
              }
              .alignItems(HorizontalAlign.Center)
              .layoutWeight(1)
            }
            .margin({ bottom: 5 })
            .padding(10)
            .borderRadius(10)
            .backgroundColor($r('app.color.icon_pack_bg'))
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          List({ space: 5 }) {
            ListItem() {
              Row() {
                Radio({ value: '', group: 'icon_pack' })
                  .checked( this.selected_icon_pack === 0)
                  .onChange((checked) => {
                    if (checked) {
                      TokenIconPacks.selected_icon_pack = 0;
                      this.selected_icon_pack = TokenIconPacks.selected_icon_pack;
                      AppPreference.setPreference('app_appearance_icon_pack_selected', 0);
                      this.window.Context?.eventHub.emit('onIconPackChanged');
                    }
                  })
                Column() {
                  Text($r('app.string.setting_icon_pack_title', TokenIconPacks.default_icon_pack.name, "20250119"))
                    .fontSize($r('sys.float.ohos_id_text_size_body1'))
                    .fontColor($r('sys.color.ohos_id_color_text_primary'))
                    .fontWeight(FontWeight.Regular)
                    .textAlign(TextAlign.Start)
                  Text($r('app.string.setting_icon_pack_count', TokenIconPacks.default_icon_pack.issuers.length))
                    .fontSize($r('sys.float.ohos_id_text_size_body3'))
                    .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                    .fontWeight(FontWeight.Regular)
                    .textAlign(TextAlign.Start)
                }
                .alignItems(HorizontalAlign.Start)
              }
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('app.color.icon_pack_bg'))
              .width('100%')
            }
            ForEach(this.installed_icon_pack, (icon_pack: AegisIconPack, index: number) => {
              ListItem() {
                Row() {
                  Radio({ value: '', group: 'icon_pack' })
                    .checked(this.selected_icon_pack === index + 1)
                    .onChange((checked) => {
                      if (checked) {
                        TokenIconPacks.selected_icon_pack = index + 1;
                        this.selected_icon_pack = TokenIconPacks.selected_icon_pack;
                        AppPreference.setPreference('app_appearance_icon_pack_selected', index + 1);
                        this.window.Context?.eventHub.emit('onIconPackChanged');
                      }
                    })
                  Column() {
                    Text($r('app.string.setting_icon_pack_title', icon_pack.name, icon_pack.version.toString()))
                      .fontSize($r('sys.float.ohos_id_text_size_body1'))
                      .fontColor($r('sys.color.ohos_id_color_text_primary'))
                      .fontWeight(FontWeight.Regular)
                      .textAlign(TextAlign.Start)
                    Text($r('app.string.setting_icon_pack_count', icon_pack.icons.length))
                      .fontSize($r('sys.float.ohos_id_text_size_body3'))
                      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                      .fontWeight(FontWeight.Regular)
                      .textAlign(TextAlign.Start)
                  }
                  .alignItems(HorizontalAlign.Start)
                  Blank()
                  Row() {
                    SymbolGlyph($r('sys.symbol.trash'))
                      .fontSize(20)
                      .fontWeight(FontWeight.Medium)
                      .fontColor([$r('app.color.str_main')])
                  }
                  .width('10%')
                  .onClick(() => {
                    AlertDialog.show({
                      message: $r('app.string.alert_icon_pack_remove_confirm_msg', icon_pack.name),
                      autoCancel: true,
                      alignment: DialogAlignment.Center,
                      primaryButton: {
                        defaultFocus: false,
                        value: $r('app.string.dialog_btn_cancel'),
                        action: () => {
                          return
                        } },
                      secondaryButton: {
                        value: $r('app.string.dialog_btn_confirm'),
                        fontColor: Color.Red,
                        action: async () => {
                          TokenIconPacks.removeAegisIconPack(icon_pack).then(() => {
                            if (this.selected_icon_pack > index) {
                              TokenIconPacks.selected_icon_pack = this.selected_icon_pack - 1;
                              this.selected_icon_pack = TokenIconPacks.selected_icon_pack;
                              AppPreference.setPreference('app_appearance_icon_pack_selected', this.selected_icon_pack);
                            }
                            this.installed_icon_pack = TokenIconPacks.aegis_icon_packs;
                          });
                        }
                      }
                    })
                  })
                }
                .padding(10)
                .borderRadius(10)
                .backgroundColor($r('app.color.icon_pack_bg'))
                .width('100%')
              }
              .width('100%')
            }, (icon_pack: AegisIconPack) => {
              return icon_pack.name + icon_pack.on_device_path + icon_pack.version;
            })
          }
          .width('100%')

          Button($r('app.string.setting_add_icon_pack'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .width('60%')
            .margin({ top: 10 })
            .onClick(() => {
              showSelectFilePicker(5, ["ZIP File|.zip"]).then((paths) => {
                paths.forEach((path) => {
                  fs.open(path).then((fd) => {
                    const path_arr = fd.path.split('/');
                    const file_name = path_arr[path_arr.length-1];
                    const out_path = this.icon_pack_dir + "/" + file_name;
                    fs.mkdir(out_path).then(() => {
                      zlib.decompressFile(fd.path, out_path).then(() => {
                        TokenIconPacks.addAegisIconPack(out_path).then(() => {
                          this.installed_icon_pack = TokenIconPacks.aegis_icon_packs;
                          this.window.Context?.eventHub.emit('onIconPackChanged');
                          fs.close(fd.fd);
                        }).catch(() => {
                          fs.rmdir(out_path);
                        });
                      }).catch((reason: BusinessError) => {
                        promptAction.showToast(reason);
                        fs.close(fd.fd);
                      });
                    });
                  });
                });
              });
            })
        }
          .width('100%')
      }
    }
    .width('100%')
    .padding(10)
  }
}
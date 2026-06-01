import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { showSelectFilePicker } from '../utils/FileUtils';
import { AegisIconPack, TokenIconPacks } from '../utils/TokenUtils';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { SubItemDivider } from './SubItemDivider';
import { AppPreference, BUILTIN_DEFAULT_PACK_ID, PREF_KEYS } from '../utils/AppPreference';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { throttle, startBrowsableAbility } from '../utils/UiUtils';
import { showSnackBar, SnackBarNotifyType } from '../utils/HdsSnackBarUtils';
import { TokenStore } from '../utils/TokenStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

interface PackItem {
  id: string;
  name: string;
  count: number;
  invalid: boolean;
  version: string;
  aegisPack?: AegisIconPack;
}

@Preview
@ComponentV2
export struct SubItemIconManager {
  @Local collapsed: boolean = true;
  @Local isEditing: boolean = false;
  @Local rematchProgress: number = -1;
  @Local rematchTotal: number = 0;
  @Local rematchCurrent: number = 0;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local packItems: PackItem[] = [];
  @Local draftEnabledPacks: string[] = [];
  @Local editDisplayItems: PackItem[] = [];
  @Local dragFromIndex: number = -1;

  private icon_pack_dir = this.window.Context?.filesDir + "/icon_packs";

  private buildPackItems(): PackItem[] {
    const items: PackItem[] = [];
    items.push({
      id: BUILTIN_DEFAULT_PACK_ID,
      name: TokenIconPacks.default_icon_pack.name,
      count: TokenIconPacks.default_icon_pack.issuers.length,
      invalid: false,
      version: '20250923',
    });
    for (const pack of TokenIconPacks.aegis_icon_packs) {
      items.push({
        id: pack.uuid,
        name: pack.name,
        count: pack.icons.length,
        invalid: pack.invalid,
        version: pack.version.toString(),
        aegisPack: pack,
      });
    }
    return items;
  }

  private syncFromTokenIconPacks(): void {
    this.packItems = this.buildPackItems();
  }

  private buildEditDisplayItems(): PackItem[] {
    const items: PackItem[] = [];
    for (const packId of this.draftEnabledPacks) {
      const found = this.packItems.find(p => p.id === packId);
      if (found) items.push(found);
    }
    for (const item of this.packItems) {
      if (!this.draftEnabledPacks.includes(item.id)) items.push(item);
    }
    return items;
  }

  aboutToAppear(): void {
    this.syncFromTokenIconPacks();
  }

  private enterEditMode(): void {
    this.draftEnabledPacks = [...TokenIconPacks.enabled_packs];
    this.editDisplayItems = this.buildEditDisplayItems();
    this.isEditing = true;
  }

  private exitEditMode(): void {
    this.isEditing = false;
    this.draftEnabledPacks = [];
    this.editDisplayItems = [];
  }

  private isDraftEnabled(packId: string): boolean {
    return this.draftEnabledPacks.includes(packId);
  }

  private toggleDraftEnabled(packId: string): void {
    if (this.isDraftEnabled(packId)) {
      if (this.draftEnabledPacks.length <= 1) return;
      this.draftEnabledPacks = this.draftEnabledPacks.filter(id => id !== packId);
    } else {
      this.draftEnabledPacks = [...this.draftEnabledPacks, packId];
    }
    this.editDisplayItems = this.buildEditDisplayItems();
  }

  private async onSave(): Promise<void> {
    const oldPacks = [...TokenIconPacks.enabled_packs];
    const newPacks = [...this.draftEnabledPacks];
    if (newPacks.length === 0) return;

    TokenIconPacks.enabled_packs = newPacks;
    AppPreference.saveEnabledPacks(newPacks);

    const needsRematch = !this.arraysEqual(oldPacks, newPacks);
    this.exitEditMode();
    this.syncFromTokenIconPacks();

    if (needsRematch) {
      await this.rematchAndShowProgress();
    }
    TokenIconPacks.notifyChanged();
  }

  private arraysEqual(a: string[], b: string[]): boolean {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }

  private async rematchAndShowProgress(): Promise<void> {
    try {
      const tkStore = TokenStore.getInstance();
      const allTokens = await tkStore.getTokens();
      const changed = TokenIconPacks.rematchTokens(allTokens);
      if (changed.length === 0) return;

      this.rematchTotal = changed.length;
      this.rematchCurrent = 0;
      this.rematchProgress = 0;

      for (let i = 0; i < changed.length; i++) {
        try {
          await tkStore.updateToken(changed[i]);
        } catch (e) {
          hilog.error(0, 'SubItemIconManager', 'rematch token failed: ' + JSON.stringify(e));
        }
        this.rematchCurrent = i + 1;
        this.rematchProgress = Math.round((i + 1) / changed.length * 100);
      }
    } catch (err) {
      hilog.error(0, 'SubItemIconManager', 'rematchAndShowProgress failed: ' + JSON.stringify(err));
      showSnackBar('重新匹配图标失败', SnackBarNotifyType.ERROR);
    } finally {
      setTimeout(() => {
        this.rematchProgress = -1;
        this.rematchTotal = 0;
        this.rematchCurrent = 0;
      }, 500);
    }
  }

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
          Text($r('app.string.setting_icon_pack_preview', TokenIconPacks.aegis_icon_packs.length))
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

          if (TokenIconPacks.aegis_icon_packs.length === 0) {
            Row() {
              Text($r('app.string.setting_icon_pack_info'))
                .fontSize($r('sys.float.ohos_id_text_size_body1'))
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
                .fontWeight(FontWeight.Regular)
                .textAlign(TextAlign.Start)
              Column({ space: 10 }) {
                Button('aegis-icons', { buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.SMALL })
                  .borderRadius($r('sys.float.corner_radius_level4'))
                  .type(ButtonType.Capsule)
                  .margin({ left: $r('sys.float.padding_level8') })
                  .width(100)
                  .fontColor($r('sys.color.interactive_active'))
                  .onClick(throttle((event) => {
                    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
                    startBrowsableAbility(context, 'https://github.com/aegis-icons/aegis-icons/releases/latest/download/aegis-icons.zip');
                  }, 1000))
                Button('delta-icons', { buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.SMALL })
                  .borderRadius($r('sys.float.corner_radius_level4'))
                  .type(ButtonType.Capsule)
                  .margin({ left: $r('sys.float.padding_level8') })
                  .width(100)
                  .fontColor($r('sys.color.interactive_active'))
                  .onClick(throttle((event) => {
                    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
                    startBrowsableAbility(context, 'https://github.com/Delta-Icons/aegis/releases/latest/download/delta-aegis-icons.zip');
                  }, 1000))
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
            ForEach(this.isEditing ? this.editDisplayItems : this.packItems, (item: PackItem, index: number) => {
              ListItem() {
                Row() {
                  if (this.isEditing && this.isDraftEnabled(item.id)) {
                    SymbolGlyph($r('sys.symbol.line_3_horizontal'))
                      .fontSize(18)
                      .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
                      .margin({ right: 4 })
                  }

                  if (this.isEditing) {
                    Checkbox()
                      .select(this.isDraftEnabled(item.id))
                      .enabled(!item.invalid)
                      .onChange((checked) => {
                        this.toggleDraftEnabled(item.id);
                      })
                  } else {
                    Checkbox()
                      .select(TokenIconPacks.enabled_packs.includes(item.id))
                      .enabled(false)
                  }

                  Column() {
                    if (item.invalid) {
                      Text($r('app.string.setting_invalid_icon_pack_title'))
                        .fontSize($r('sys.float.ohos_id_text_size_body1'))
                        .fontColor($r('sys.color.ohos_id_color_warning'))
                        .fontWeight(FontWeight.Regular)
                        .textAlign(TextAlign.Start)
                    } else {
                      Text($r('app.string.setting_icon_pack_title', item.name, item.version))
                        .fontSize($r('sys.float.ohos_id_text_size_body1'))
                        .fontColor($r('sys.color.ohos_id_color_text_primary'))
                        .fontWeight(FontWeight.Regular)
                        .textAlign(TextAlign.Start)
                      Text($r('app.string.setting_icon_pack_count', item.count))
                        .fontSize($r('sys.float.ohos_id_text_size_body3'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .textAlign(TextAlign.Start)
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (!this.isEditing && item.aegisPack) {
                    Row() {
                      SymbolGlyph($r('sys.symbol.trash'))
                        .fontSize(20)
                        .fontWeight(FontWeight.Medium)
                        .fontColor([$r('app.color.str_main')])
                    }
                    .width('10%')
                    .onClick(() => {
                      this.getUIContext().showAlertDialog({
                        message: $r('app.string.alert_icon_pack_remove_confirm_msg', item.name),
                        autoCancel: true,
                        alignment: DialogAlignment.Center,
                        primaryButton: {
                          defaultFocus: false,
                          value: $r('app.string.dialog_btn_cancel'),
                          action: () => {
                            return;
                          }
                        },
                        secondaryButton: {
                          value: $r('app.string.dialog_btn_confirm'),
                          fontColor: Color.Red,
                          action: async () => {
                            TokenIconPacks.removeAegisIconPack(item.aegisPack!).then(async () => {
                              this.syncFromTokenIconPacks();
                              await this.rematchAndShowProgress();
                              TokenIconPacks.notifyChanged();
                            });
                          }
                        }
                      })
                    })
                  }
                }
                .padding(10)
                .borderRadius(10)
                .backgroundColor($r('app.color.icon_pack_bg'))
                .width('100%')
              }
              .width('100%')
              .draggable(this.isEditing && this.isDraftEnabled(item.id))
              .onDragStart(() => {
                this.dragFromIndex = index;
              })
              .onDrop((_event: DragEvent, _extraParams: string) => {
                const fromIdx = this.dragFromIndex;
                const toIdx = index;
                this.dragFromIndex = -1;
                if (fromIdx < 0 || fromIdx === toIdx) return;
                const enabledCount = this.draftEnabledPacks.length;
                if (fromIdx >= enabledCount || toIdx >= enabledCount) return;
                const arr = [...this.editDisplayItems];
                const moved = arr.splice(fromIdx, 1)[0];
                const insertIdx = toIdx > fromIdx ? toIdx - 1 : toIdx;
                arr.splice(insertIdx, 0, moved);
                this.editDisplayItems = arr;
                this.draftEnabledPacks = arr.slice(0, enabledCount).map(p => p.id);
              })
              .onDragEnd(() => {
                this.dragFromIndex = -1;
              })
            }, (item: PackItem) => item.id + item.name)
          }
          .width('100%')

          if (this.rematchProgress >= 0) {
            Column() {
              Row() {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color($r('sys.color.font_primary'))
                Text(`正在重新匹配图标... ${this.rematchCurrent}/${this.rematchTotal}`)
                  .fontSize($r('sys.float.ohos_id_text_size_body2'))
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  .margin({ left: 8 })
              }
              Progress({ value: this.rematchProgress, total: 100, type: ProgressType.Linear })
                .width('100%')
                .margin({ top: 4 })
            }
            .padding(10)
            .borderRadius(10)
            .backgroundColor($r('app.color.icon_pack_bg'))
            .width('100%')
          }

          Row() {
            Button($r('app.string.setting_add_icon_pack'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .onClick(() => {
                showSelectFilePicker(5, ["ZIP File|.zip"]).then((paths) => {
                  paths.forEach((path) => {
                    fs.open(path).then((fd) => {
                      const path_arr = fd.path.split('/');
                      const file_name = path_arr[path_arr.length - 1];
                      const out_path = this.icon_pack_dir + "/" + file_name;
                      fs.mkdir(out_path).then(() => {
                        zlib.decompressFile(fd.path, out_path).then(() => {
                          return TokenIconPacks.addAegisIconPack(out_path);
                        }).then(() => {
                          this.syncFromTokenIconPacks();
                          TokenIconPacks.notifyChanged();
                        }).catch((err: BusinessError) => {
                          hilog.error(0, 'SubItemIconManager', 'Failed to add icon pack: ' + JSON.stringify(err));
                          showSnackBar(err.message ?? `${err}`, SnackBarNotifyType.ERROR);
                          fs.rmdir(out_path).catch(() => {});
                        }).finally(() => {
                          fs.close(fd.fd).catch(() => {});
                        });
                      }).catch((err: BusinessError) => {
                        showSnackBar(err.message ?? `${err}`, SnackBarNotifyType.ERROR);
                        fs.close(fd.fd).catch(() => {});
                      });
                    }).catch((err: BusinessError) => {
                      showSnackBar(err.message ?? `${err}`, SnackBarNotifyType.ERROR);
                    });
                  });
                });
              })

            Blank()

            if (this.isEditing) {
              Button($r('app.string.dialog_btn_cancel'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ right: 10 })
                .onClick(() => {
                  this.exitEditMode();
                })
              Button($r('app.string.dialog_btn_confirm'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick(() => {
                  this.onSave();
                })
            } else {
              Button($r('app.string.setting_icon_pack_edit'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick(() => {
                  this.enterEditMode();
                })
            }
          }
          .width('100%')
          .margin({ top: 10 })

          if (AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean) {
            Row() {
              SymbolGlyph($r('sys.symbol.info_circle'))
                .fontSize(16)
                .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
                .margin({ right: 6 })
              Text($r('app.string.icon_pack_cloud_backup_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption'))
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .fontWeight(FontWeight.Regular)
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 8 })
            .padding({ left: 4, right: 4 })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(10)
  }
}

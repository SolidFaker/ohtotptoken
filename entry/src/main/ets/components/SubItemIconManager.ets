import { dialogSystemMaterial } from 'common';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { showSelectFilePicker } from 'common';
import { AegisIconPack, TokenIconPacks } from 'common';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { SubItemDivider } from './SubItemDivider';
import { AppPreference, BUILTIN_DEFAULT_PACK_ID, PREF_KEYS } from 'common';
import {
  IconPackGateRejectError, IconPackImportMutex, IconPackZipGateLimits, IconPackZipGateReject,
  InstalledPackInfo, IconPackZipEntryInfo, ZipRawEntryInfo, gateZipTotalSize, gateZipRawEntries,
  gateZipCentralIndex, gateExtractedPackEntries, collectIconPackDirEntries, removeIconPackDirBestEffort,
  mapGetOriginalSizeError, iconPackGateRejectText
} from 'common';
import { IconPackImportDiag } from '../utils/IconPackImportDiag';
import type { ZipIndex } from './IconPackZipReader';
import { AppWindowInfo } from 'common';
import { throttle, startBrowsableAbility } from 'common';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { TokenStore } from 'common';
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING, SETTING_ROW_ICON_OFFSET } from './SettingStyle';

/** lazy import 的 reader 模块形状（显式接口，避免动态 import 落入 any/unknown）。 */
interface ZipReaderModule {
  readZipIndex(bytes: ArrayBuffer): Promise<ZipIndex>;
}

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

  private installedPackInfos(): InstalledPackInfo[] {
    const infos: InstalledPackInfo[] = [];
    for (const pack of TokenIconPacks.aegis_icon_packs) {
      if (!pack.invalid) {
        const info: InstalledPackInfo = { name: pack.name, version: String(pack.version ?? 0) };
        infos.push(info);
      }
    }
    return infos;
  }

  /** lazy import 的 reader 模块形状（显式类型，避免动态 import 落入 any）。 */
  private async loadZipReader(): Promise<ZipReaderModule> {
    return await import('./IconPackZipReader');
  }

  /**
   * 导入选中的图标包 zip：进程内互斥（多点击/多面板共享一把锁，忙碌即拒）→ 解压前四段门控
   * （getOriginalSize 拦格式/总体积 → 原始中央目录拦原始路径逃逸（目录条目也在内）→ jszip 归一化
   * 中央目录拦 pack.json/限额/同名同版本重复 → 均零写入；解压后落盘复扫作纵深防御），任何拒绝都
   * 整目录回收——不产生 invalid 条目或解压残留。jszip 读取经 lazy import（冷启动不加载重依赖）。
   * 日志只经 IconPackImportDiag 白名单枚举/数字；未知错误 UI 用固定 IO_ERROR 文案，不透传异常文本。
   */
  private async importIconPackFile(fd: fs.File): Promise<void> {
    if (!IconPackImportMutex.tryAcquire()) {
      showSnackBar($r('app.string.cloud_backup_operation_busy'), SnackBarNotifyType.ERROR);
      try {
        fs.closeSync(fd.fd);
      } catch (_) {
        // 描述符关闭失败不影响结果；忙碌路径未做任何文件修改。
      }
      return;
    }
    const segments = fd.path.split('/');
    const outPath = this.icon_pack_dir + '/' + segments[segments.length - 1];
    // 只有本操作成功建出的目录才由本操作回收：mkdir 失败说明目录已存在（并发同名导入的
    // 胜者或遗留目录），绝不能代删——否则会破坏他人正在进行的解压。
    let createdDir = false;
    const diag = IconPackImportDiag.begin();
    try {
      // 压缩体积上限：JSZip 门控需整文件读入内存，先按 stat 拦截保护。
      const compressed = await fs.stat(fd.path);
      if (compressed.size > IconPackZipGateLimits.MAX_COMPRESSED_BYTES) {
        throw new IconPackGateRejectError(IconPackZipGateReject.TOO_LARGE_TOTAL);
      }
      // 解压前·格式与未压缩总体积（损坏/非 ZIP 时 getOriginalSize 抛 900003）。
      let totalBytes = -1;
      try {
        totalBytes = await zlib.getOriginalSize(fd.path);
      } catch (error) {
        throw new IconPackGateRejectError(mapGetOriginalSizeError(error as BusinessError));
      }
      const sizeVerdict = gateZipTotalSize(totalBytes);
      if (!sizeVerdict.ok) {
        throw new IconPackGateRejectError(sizeVerdict.reject);
      }
      // 整文件读入内存（JSZip 需要完整字节；短读如实失败）。
      const bytes = new ArrayBuffer(compressed.size);
      let readTotal = 0;
      const chunk = new ArrayBuffer(256 * 1024);
      while (readTotal < compressed.size) {
        const want = Math.min(256 * 1024, compressed.size - readTotal);
        const read = fs.readSync(fd.fd, chunk, { offset: readTotal, length: want });
        if (read <= 0) {
          break;
        }
        new Uint8Array(bytes, readTotal, read).set(new Uint8Array(chunk, 0, read));
        readTotal += read;
      }
      if (readTotal < compressed.size) {
        throw new IconPackGateRejectError(IconPackZipGateReject.IO_ERROR);
      }
      // 解压前·原始中央目录 + 归一化中央目录门（零写入）：原始路径逃逸（文件与目录条目都在内）、
      // pack.json 存在并可解析、文件数/单文件/总体积限额、同名同版本重复导入拒绝。
      // pack.json 内容为流式真实字节硬限读取（谎报声明在展开途中截停，不全量展开后拒）。
      // lazy import：jszip 与解析器只在首次导入时加载，不进冷启动路径。
      const reader = await this.loadZipReader();
      let index: ZipIndex;
      try {
        index = await reader.readZipIndex(bytes);
      } catch (error) {
        // 只读固定 error.name（reader 以固定 token 命名错误），不读异常文本。
        throw new IconPackGateRejectError((error as Error).name === 'ICON_PACK_META_TOO_LARGE'
          ? IconPackZipGateReject.FILE_TOO_LARGE : IconPackZipGateReject.NOT_ZIP_OR_DAMAGED);
      }
      const rawEntries: ZipRawEntryInfo[] = [];
      for (const raw of index.rawEntries) {
        const mappedRaw: ZipRawEntryInfo = {
          rawName: raw.rawName, sizeBytes: raw.sizeBytes, isDirectory: raw.isDirectory
        };
        rawEntries.push(mappedRaw);
      }
      const rawVerdict = gateZipRawEntries(rawEntries);
      if (!rawVerdict.ok) {
        throw new IconPackGateRejectError(rawVerdict.reject);
      }
      const centralEntries: IconPackZipEntryInfo[] = [];
      for (const item of index.entries) {
        const mapped: IconPackZipEntryInfo = {
          relativePath: item.relativePath, sizeBytes: item.sizeBytes, isDirectory: item.isDirectory
        };
        centralEntries.push(mapped);
      }
      const centralVerdict = gateZipCentralIndex(centralEntries, index.packJsonContent, this.installedPackInfos());
      if (!centralVerdict.ok) {
        throw new IconPackGateRejectError(centralVerdict.reject);
      }
      await fs.mkdir(outPath);
      createdDir = true;
      await zlib.decompressFile(fd.path, outPath);
      const entries = await collectIconPackDirEntries(outPath);
      const verdict = gateExtractedPackEntries(entries);
      if (!verdict.ok) {
        throw new IconPackGateRejectError(verdict.reject);
      }
      await TokenIconPacks.addAegisIconPack(outPath);
      diag.succeeded();
      this.syncFromTokenIconPacks();
      TokenIconPacks.notifyChanged();
    } catch (err) {
      if (err instanceof IconPackGateRejectError) {
        diag.gateRejected(err.reason);
        showSnackBar(iconPackGateRejectText(err.reason), SnackBarNotifyType.ERROR);
      } else {
        diag.failed(err);
        showSnackBar(iconPackGateRejectText(IconPackZipGateReject.IO_ERROR), SnackBarNotifyType.ERROR);
      }
      if (createdDir) {
        try {
          await removeIconPackDirBestEffort(outPath);
        } catch (cleanupError) {
          // 清理失败准确可见：白名单数字码 + 固定 PARTIAL_FAILURE，不输出路径或异常文本。
          diag.cleanupFailed(cleanupError);
        }
      }
    } finally {
      IconPackImportMutex.release();
      diag.end();
      try {
        fs.closeSync(fd.fd);
      } catch (_) {
        // 描述符关闭失败不影响导入结果；原 fd 语义与既有实现一致。
      }
    }
  }

  private async rematchAndShowProgress(): Promise<void> {
    const diag = IconPackImportDiag.begin();
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
          diag.rematchFailed(e);
        }
        this.rematchCurrent = i + 1;
        this.rematchProgress = Math.round((i + 1) / changed.length * 100);
      }
    } catch (err) {
      diag.rematchFailed(err);
      showSnackBar($r('app.string.icon_pack_rematch_failed'), SnackBarNotifyType.ERROR);
    } finally {
      diag.end();
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
            .width('100%')
            .padding({ left: SETTING_ROW_ICON_OFFSET })
            .textAlign(TextAlign.Start)
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

      }
      .justifyContent(FlexAlign.SpaceBetween)
      .width('100%')
      .onClick(() => {
        this.window.uiContext?.animateTo({ duration: 200, curve: Curve.Sharp }, () => {
          this.collapsed = !this.collapsed;
        })
      })

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
            .borderRadius($r('sys.float.corner_radius_level5'))
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
                        systemMaterial: dialogSystemMaterial(),
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
                .borderRadius($r('sys.float.corner_radius_level5'))
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
            .borderRadius($r('sys.float.corner_radius_level5'))
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
                      return this.importIconPackFile(fd);
                    }).catch(() => {
                      // 打开失败不透传异常文本；固定 IO_ERROR 文案。
                      showSnackBar(iconPackGateRejectText(IconPackZipGateReject.IO_ERROR), SnackBarNotifyType.ERROR);
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
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .justifyContent(FlexAlign.Center)
  }
}

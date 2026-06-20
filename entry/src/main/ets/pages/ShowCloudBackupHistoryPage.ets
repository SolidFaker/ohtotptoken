import { AppStorageV2, LengthMetrics } from '@kit.ArkUI';
import { CloudBackupManager } from '../utils/CloudBackupManager';
import { CloudBackupRecord } from '../utils/CloudBackupCrypto';
import { AppPreference, PREF_KEYS } from '../utils/AppPreference';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { showSnackBar, SnackBarNotifyType } from '../utils/HdsSnackBarUtils';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { CommonConstants } from '../utils/CommonConstants';
import { DeviceInfoHelper } from '../utils/DeviceInfoHelper';
import { SyncTimeHelper } from '../utils/SyncTimeHelper';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { loadBackupHistoryRecords } from '../utils/CloudSyncTask';

const TAG = 'ShowCloudBackupHistoryPage';
const DOMAIN = 0xFF00;

@Entry
@Preview
@ComponentV2
export struct ShowCloudBackupHistoryPage {
  pageInfos: NavPathStack | null = null;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local backupRecords: CloudBackupRecord[] = [];
  @Local isLoading: boolean = true;
  @Local currentDeviceId: string = '';
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private backupManager: CloudBackupManager = CloudBackupManager.getInstance();
  private scroller: Scroller = new Scroller();

  /** 页面生命周期：获取本设备 ID，加载备份历史列表 */
  aboutToAppear(): void {
    this.currentDeviceId = DeviceInfoHelper.getInstance().getDeviceId();
    this.loadBackupHistory();
  }

  /**
   * 通过 TaskPool 后台线程加载备份历史记录，避免逐文件 I/O 阻塞主线程。
   * 后台线程执行目录遍历 + 文件读取 + header 解析，完成后回主线程更新 UI。
   */
  private loadBackupHistory(): void {
    this.isLoading = true;
    const cloudDir: string = this.appCtx.cloudFileDir;
    taskpool.execute(loadBackupHistoryRecords, cloudDir).then((result: Object) => {
      this.backupRecords = result as CloudBackupRecord[];
      this.isLoading = false;
    }).catch((err: BusinessError) => {
      this.isLoading = false;
      hilog.error(DOMAIN, TAG, `loadBackupHistory: taskpool failed: ${err.code} ${err.message}`);
    });
  }

  /** 筛选当前设备的备份记录 */
  private getDeviceRecords(): CloudBackupRecord[] {
    return this.backupRecords.filter(r => r.deviceId === this.currentDeviceId);
  }

  /** 筛选其他设备的备份记录 */
  private getOtherDeviceRecords(): CloudBackupRecord[] {
    return this.backupRecords.filter(r => r.deviceId !== this.currentDeviceId);
  }

  build() {
    HdsNavDestination() {
      Column() {
        RelativeContainer() {
          Stack() {
            if (this.isLoading) {
              Column() {
                LoadingProgress()
                  .color($r('sys.color.font_primary'))
                  .width(LengthMetrics.vp(80).value).height(LengthMetrics.vp(80).value)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
            }
            else
            {
              Column() {
                if (this.backupRecords.length === 0 && !this.isLoading) {
                  Column() {
                    SymbolGlyph($r('sys.symbol.rectangle_split_3x1'))
                      .fontSize(LengthMetrics.vp(48).value)
                      .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
                    Text($r('app.string.cloud_backup_history_empty'))
                      .fontSize($r('sys.float.ohos_id_text_size_body1'))
                      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                      .margin({ top: $r('sys.float.padding_level2') })
                  }
                  .width('100%')
                  .layoutWeight(1)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                } else {
                  List({ space: LengthMetrics.vp(10).value, scroller: this.scroller }) {
                    ListItem()
                      .height(CommonConstants.AVOID_TOP_BASE_HEIGHT)

                    if (this.getDeviceRecords().length > 0) {
                      ListItem() {
                        Row() {
                          Text($r('app.string.cloud_backup_this_device'))
                            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
                            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                            .fontWeight(FontWeight.Medium)
                        }
                        .width('100%')
                        .padding({ left: $r('sys.float.padding_level8'), top: LengthMetrics.vp(4).value, bottom: LengthMetrics.vp(2).value })
                      }

                      ForEach(this.getDeviceRecords(), (record: CloudBackupRecord) => {
                        ListItem() {
                          this.BackupRecordItem(record, true)
                        }
                      }, (record: CloudBackupRecord) => record.id)
                    }

                    if (this.getOtherDeviceRecords().length > 0) {
                      ListItem() {
                        Row() {
                          Text($r('app.string.cloud_backup_other_devices'))
                            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
                            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                            .fontWeight(FontWeight.Medium)
                        }
                        .width('100%')
                        .padding({ left: $r('sys.float.padding_level8'), top: $r('sys.float.padding_level2'), bottom: LengthMetrics.vp(2).value })
                      }

                      ForEach(this.getOtherDeviceRecords(), (record: CloudBackupRecord) => {
                        ListItem() {
                          this.BackupRecordItem(record, false)
                        }
                      }, (record: CloudBackupRecord) => record.id)
                    }
                  }
                  .chainAnimation(AppPreference.getPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE) as boolean)
                  .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
                  .scrollBar(BarState.Off)
                  .backgroundColor($r('app.color.window_background'))
                  .width('100%')
                  .layoutWeight(1)
                  .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8'), bottom: $r('sys.float.padding_level8') })
                }

                Row() {
                  Text($r('app.string.cloud_backup_history_max_hint'))
                    .fontSize($r('sys.float.ohos_id_text_size_caption'))
                    .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ bottom: $r('sys.float.padding_level2') })

                Row() {
                  Text($r('app.string.cloud_sync_device_id_hint'))
                    .fontSize($r('sys.float.ohos_id_text_size_caption'))
                    .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                }
                .width('100%')
                .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8'), bottom: $r('sys.float.padding_level8') })
              }
              .width('100%')
              .height('100%')
            }

          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.window_background'))
    }
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary')
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.cloud_backup_history_title'),
        },
      }
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }

  /** 备份记录卡片：左侧图标+元数据（日期/令牌数/大小/加密标识），右侧操作按钮（恢复/删除） */
  @Builder
  BackupRecordItem(record: CloudBackupRecord, isCurrentDevice: boolean) {
    Column() {
      Row({ space: LengthMetrics.vp(12).value }) {
        Column() {
          SymbolGlyph($r('sys.symbol.doc_text'))
            .fontSize(LengthMetrics.vp(24).value)
            .fontColor([$r('app.color.str_main')])
        }
        .width(LengthMetrics.vp(44).value)
        .height(LengthMetrics.vp(44).value)
        .borderRadius($r('sys.float.corner_radius_level4'))
        .backgroundColor($r('app.color.item_bg'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        Column({ space: LengthMetrics.vp(4).value }) {
          Text(record.date)
            .fontSize($r('sys.float.ohos_id_text_size_body1'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row({ space: LengthMetrics.vp(8).value }) {
            Text($r('app.string.cloud_backup_record_tokens', record.tokenCount))
              .fontSize($r('sys.float.ohos_id_text_size_caption'))
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))

            Text(this.formatSize(record.size))
              .fontSize($r('sys.float.ohos_id_text_size_caption'))
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))

            if (record.encrypted) {
              Row({ space: LengthMetrics.vp(2).value }) {
                SymbolGlyph($r('sys.symbol.lock'))
                  .fontSize(LengthMetrics.vp(10).value)
                  .fontColor([$r('app.color.str_main')])
              }
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: LengthMetrics.vp(6).value }) {
          SymbolGlyph($r('sys.symbol.arrowshape_down_to_line_fill'))
            .fontSize(LengthMetrics.vp(20).value)
            .fontColor([$r('app.color.str_main')])
            .onClick(() => {
              this.showRestoreConfirmDialog(record);
            })

          if (isCurrentDevice) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(LengthMetrics.vp(20).value)
              .fontColor([$r('sys.color.ohos_id_color_warning')])
              .onClick(() => {
                this.showDeleteConfirmDialog(record);
              })
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding($r('sys.float.padding_level8'))
      .alignItems(VerticalAlign.Center)

      Row() {
        SymbolGlyph($r('sys.symbol.icloud'))
          .fontSize(LengthMetrics.vp(12).value)
          .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
        Text(record.deviceName)
          .fontSize($r('sys.float.ohos_id_text_size_caption'))
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ left: LengthMetrics.vp(4).value })

          Text('·')
          .fontSize($r('sys.float.ohos_id_text_size_caption'))
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ left: LengthMetrics.vp(4).value, right: LengthMetrics.vp(4).value })

        if (record.location === 2) {
          SymbolGlyph($r('sys.symbol.arrow_down_circle'))
            .fontSize(LengthMetrics.vp(12).value)
            .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
          Text($r('app.string.cloud_sync_status_cloud_only'))
            .fontSize($r('sys.float.ohos_id_text_size_caption'))
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .margin({ left: LengthMetrics.vp(2).value })
        } else {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(LengthMetrics.vp(12).value)
            .fontColor([$r('app.color.str_main')])
          Text($r('app.string.cloud_sync_status_synced'))
            .fontSize($r('sys.float.ohos_id_text_size_caption'))
            .fontColor($r('app.color.str_main'))
            .margin({ left: LengthMetrics.vp(2).value })
        }
      }
      .padding({ left: LengthMetrics.vp(68).value, bottom: LengthMetrics.vp(10).value })
      .width('100%')
    }
    .width('100%')
    .backgroundColor($r('app.color.item_bg'))
    .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
    .shadow({ radius: 10, color: $r('app.color.shadow'), offsetX: 10, offsetY: 10 })
  }

  /** 文件大小格式化：<1KB 显示字节，否则显示 KB */
  private formatSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    return `${(bytes / 1024).toFixed(1)} KB`;
  }

  /** 恢复确认弹窗：底部 AlertDialog，确认后调用 triggerRestore 解密并写入令牌 */
  private showRestoreConfirmDialog(record: CloudBackupRecord): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.cloud_backup_restore_confirm_title'),
      message: $r('app.string.cloud_backup_restore_confirm_msg', record.date),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      gridCount: 4,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            this.triggerRestore(record.id);
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

  /** 删除确认弹窗：仅当前设备的备份可删除，底部 AlertDialog 二次确认 */
  private showDeleteConfirmDialog(record: CloudBackupRecord): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.cloud_backup_delete_confirm_title'),
      message: $r('app.string.cloud_backup_delete_confirm_msg', record.date),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      gridCount: 4,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            this.triggerDelete(record.id);
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

  /** 触发恢复：调用 CloudBackupManager 解密备份文件并逐条 upsert 令牌到本地存储 */
  private triggerRestore(recordId: string): void {
    this.isLoading = true;
    this.backupManager.restoreFromBackupRecord(recordId).then((success: boolean) => {
      this.isLoading = false;
      if (success) {
        showSnackBar($r('app.string.cloud_backup_restore_success'), SnackBarNotifyType.SUCCESS);
      } else {
        showSnackBar($r('app.string.cloud_backup_restore_failed'), SnackBarNotifyType.WARNING);
      }
    });
  }

  /** 触发删除：调用 CloudBackupManager 删除云端文件 + 同步，成功后更新 lastSyncTime 并刷新列表 */
  private triggerDelete(recordId: string): void {
    this.isLoading = true;
    this.backupManager.deleteBackupRecord(recordId).then((success: boolean) => {
      this.isLoading = false;
      if (success) {
        this.updateLastSyncTimeAfterDelete(recordId);
        showSnackBar($r('app.string.cloud_backup_delete_success'), SnackBarNotifyType.SUCCESS);
        this.loadBackupHistory();
      } else {
        showSnackBar($r('app.string.cloud_backup_delete_failed'), SnackBarNotifyType.WARNING);
      }
    });
  }

  /**
   * 删除备份记录后更新 lastSyncTime：
   * 如果删除的是今天的备份，尝试用剩余今天记录的最新时间戳替换；
   * 若今天无剩余记录，则设为昨天末尾时间戳。
   */
  private updateLastSyncTimeAfterDelete(deletedRecordId: string): void {
    const rawTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
    const lastTs = SyncTimeHelper.parseStoredTimestamp(rawTime);
    if (lastTs <= 0 || !SyncTimeHelper.isToday(lastTs)) {
      return;
    }
    let deletedIsToday = false;
    for (const record of this.backupRecords) {
      if (record.id === deletedRecordId) {
        if (SyncTimeHelper.isToday(record.timestamp)) {
          deletedIsToday = true;
        }
        break;
      }
    }
    if (!deletedIsToday) {
      return;
    }
    let latestRemainingTs: number = 0;
    for (const record of this.backupRecords) {
      if (record.id === deletedRecordId) {
        continue;
      }
      if (SyncTimeHelper.isToday(record.timestamp) && record.timestamp > latestRemainingTs) {
        latestRemainingTs = record.timestamp;
      }
    }
    if (latestRemainingTs > 0) {
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${latestRemainingTs}`);
    } else {
      AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${SyncTimeHelper.getYesterdayEndTs()}`);
    }
  }
}

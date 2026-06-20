/*
 * Copyright (c) 2023-2024 ohtotptoken Project Contributors
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { common, Want } from '@kit.AbilityKit';
import { AppStorageV2, promptAction, LengthMetrics } from '@kit.ArkUI';
import { SettingItem } from '../components/SettingItem';
import { AppPreference, SettingValue, PREF_KEYS, ROUTE_NAMES } from '../utils/AppPreference';
import { SubItemButton } from '../components/SubItemButton';
import { SubItemDivider } from '../components/SubItemDivider';
import { AppWindowInfo } from '../entryability/EntryAbility';
import { showSnackBar, SnackBarNotifyType } from '../utils/HdsSnackBarUtils';
import { CloudBackupManager } from '../utils/CloudBackupManager';
import { HuaweiAccountManager } from '../utils/HuaweiAccountManager';
import { hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { CommonConstants } from '../utils/CommonConstants';
import { cloudSync } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { checkCloudBackupRecords } from '../utils/CloudSyncTask';
import { SyncTimeHelper } from '../utils/SyncTimeHelper';
import { IconPackCloudBackup, IconPackSyncState } from '../utils/IconPackCloudBackup';

const TAG = 'ShowCloudSyncDetailsPage';
const DOMAIN = 0xFF00;

enum ClearCloudType {
  DEVICE,
  DEVICE_NAME,
  ALL,
}

@Entry
@Preview
@ComponentV2
export struct ShowCloudSyncDetailsPage {
  pageInfos: NavPathStack | null = null;
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Local cloudSyncEnabled: SettingValue = false;
  @Local lastSyncTime: string = '';
  @Local Is_loaded: boolean = true;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local syncState: number = -1;
  @Local syncError: number = 0;
  @Local loadingText: ResourceStr = '';
  @Local iconPackBackupExists: boolean = false;
  @Local iconPackBackupCount: number = 0;
  @Local iconPackBackupSize: number = 0;
  @Local iconPackBackupTime: string = '';
  @Local iconPackSyncState: number = IconPackSyncState.IDLE;
  @Local iconPackSourceDevice: string = '';
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private scroller: Scroller = new Scroller();
  private fileSync: cloudSync.FileSync = new cloudSync.FileSync();
  private lastSyncTriggerTime: number = 0;
  private isInitialSyncRunning: boolean = false;
  private lastInitialSyncTime: number = 0;
  private readonly SYNC_COOLDOWN_MS: number = 60000;
  private readonly INITIAL_SYNC_COOLDOWN_MS: number = 600000;
  private iconPackStatePollTimer: number = -1;
  private syncProgressCallback = (pg: cloudSync.SyncProgress) => {
    this.syncState = pg.state as number;
    this.syncError = pg.error as number;
  }

  /** 页面生命周期：加载偏好设置、注册 FileSync 进度回调、按需触发初始同步 */
  aboutToAppear(): void {
    try {
      this.cloudSyncEnabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE);
      const rawTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string ?? '';
      this.lastSyncTime = SyncTimeHelper.formatTimestamp(SyncTimeHelper.parseStoredTimestamp(rawTime));
      this.syncHuaweiAccountState();
      if (!this.isHuaweiLoggedIn) {
        return;
      }
      try {
        this.fileSync.on('progress', this.syncProgressCallback);
      } catch (err) {
        let e = err as BusinessError;
        hilog.error(DOMAIN, TAG, `FileSync on progress failed: ${e.code} ${e.message}`);
      }
      if (this.cloudSyncEnabled) {
        this.triggerInitialSyncAsync();
      }
      this.loadIconPackBackupStatus();
    }
    finally {
      this.Is_loaded=false;
    }

  }

  /** 页面生命周期：注销 FileSync 进度回调 */
  aboutToDisappear(): void {
    try {
      this.fileSync.off('progress', this.syncProgressCallback);
    } catch (err) {
      let e = err as BusinessError;
      hilog.error(DOMAIN, TAG, `FileSync off progress failed: ${e.code} ${e.message}`);
    }
    if (this.iconPackStatePollTimer >= 0) {
      clearInterval(this.iconPackStatePollTimer);
      this.iconPackStatePollTimer = -1;
    }
  }
  /** 同步华为账号管理器的登录态到组件 @Local 变量，用于 UI 条件渲染 */
  private syncHuaweiAccountState(): void {
    const accountMgr = HuaweiAccountManager.getInstance();
    this.isHuaweiLoggedIn = accountMgr.userLogin;
  }

  private async loadIconPackBackupStatus(): Promise<void> {
    const status = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
    this.iconPackBackupExists = status.exists;
    this.iconPackBackupCount = status.packCount;
    this.iconPackBackupSize = status.size;
    this.iconPackBackupTime = status.lastTime;
    this.iconPackSourceDevice = status.sourceDeviceName;
    this.iconPackSyncState = IconPackCloudBackup.getInstance().getState();

    // 启动轮询：每 2 秒检查状态机，非 IDLE 时刷新 UI
    if (this.iconPackStatePollTimer < 0) {
      this.iconPackStatePollTimer = setInterval(() => {
        const newState = IconPackCloudBackup.getInstance().getState();
        if (newState !== this.iconPackSyncState) {
          this.iconPackSyncState = newState;
          // 状态回到 IDLE 时刷新备份信息（操作完成）
          if (newState === IconPackSyncState.IDLE) {
            this.loadIconPackBackupStatus();
          }
        }
      }, 2000) as number;
    }
  }

  /** 将状态机枚举值映射为可读文本 */
  private getIconPackSyncStateText(): ResourceStr {
    switch (this.iconPackSyncState) {
      case IconPackSyncState.BACKING_UP:
        return $r('app.string.cloud_sync_icon_pack_state_backing_up');
      case IconPackSyncState.RESTORING:
        return $r('app.string.cloud_sync_icon_pack_state_restoring');
      case IconPackSyncState.CLEARING:
        return $r('app.string.cloud_sync_icon_pack_state_clearing');
      case IconPackSyncState.CHECKING:
        return $r('app.string.cloud_sync_icon_pack_state_checking');
      default:
        return '';
    }
  }

  private isIconPackBusy(): boolean {
    return this.iconPackSyncState !== IconPackSyncState.IDLE;
  }

  private formatFileSize(bytes: number): string {
    if (bytes <= 0) return '0B';
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
  }

  build() {
    HdsNavDestination() {
      Column() {
        RelativeContainer() {
          Stack() {
            if (this.Is_loaded) {
              Column() {
                LoadingProgress()
                  .color($r('sys.color.font_primary'))
                  .width(LengthMetrics.vp(80).value).height(LengthMetrics.vp(80).value)
                Text(this.loadingText)
                  .fontSize($r('sys.float.ohos_id_text_size_body1'))
                  .fontColor($r('sys.color.font_primary'))
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
            } else {
              List({ space: LengthMetrics.vp(10).value, scroller: this.scroller }) {
                ListItem()
                  .height(CommonConstants.AVOID_TOP_BASE_HEIGHT)

                ListItem() {
                  SettingItem({ title: $r('app.string.cloud_sync_sync_state') }) {
                    Row() {
                      Text($r('app.string.cloud_sync_status'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Text(this.cloudSyncEnabled ?
                        $r('app.string.cloud_sync_enabled') : $r('app.string.cloud_sync_disabled'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor(this.cloudSyncEnabled ?
                          $r('sys.color.ohos_id_color_text_primary') :
                          $r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')
                    .padding({ top: $r('sys.float.padding_level8'), right:$r('sys.float.padding_level8'), bottom: 0, left: $r('sys.float.padding_level8') })

                    ListItem() {
                      Text($r('app.string.cloud_sync_status_hint'))
                        .fontSize($r('sys.float.ohos_id_text_size_caption'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .width('100%')
                    }
                    .padding($r('sys.float.padding_level8'))
                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_last_time'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Text((this.lastSyncTime != null && this.lastSyncTime != "") ? this.lastSyncTime : $r('app.string.cloud_sync_never'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor((this.lastSyncTime != null && this.lastSyncTime != "") ?
                          $r('sys.color.ohos_id_color_text_primary') :
                          $r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_encryption'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Text(this.isHuaweiLoggedIn ?
                        $r('app.string.cloud_sync_encryption_huawei_account') :
                        $r('app.string.cloud_sync_encryption_none'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor(this.isHuaweiLoggedIn ?
                          $r('sys.color.ohos_id_color_text_primary') :
                          $r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_network'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Text($r('app.string.cloud_sync_wifi_only'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_primary'))
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_sync_state'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Row({ space: LengthMetrics.vp(6).value }) {
                        if (this.syncState === 0 || this.syncState === 2) {
                          LoadingProgress()
                            .width(LengthMetrics.vp(16).value)
                            .height(LengthMetrics.vp(16).value)
                            .color($r('app.color.str_main'))
                        }
                        Text(this.getSyncStateText())
                          .fontSize($r('sys.float.ohos_id_text_size_body2'))
                          .fontColor(this.getSyncStateColor())
                          .fontWeight(FontWeight.Medium)
                      }
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    if (this.syncError !== 0) {
                      SubItemDivider()

                      Row() {
                        Text($r('app.string.cloud_sync_sync_error'))
                          .fontSize($r('sys.float.ohos_id_text_size_body2'))
                          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                          .fontWeight(FontWeight.Regular)
                          .layoutWeight(1)
                        Text(this.getSyncErrorText())
                          .fontSize($r('sys.float.ohos_id_text_size_body2'))
                          .fontColor($r('sys.color.ohos_id_color_warning'))
                          .fontWeight(FontWeight.Medium)
                      }
                      .width('100%')
                      .padding($r('sys.float.padding_level8'))
                    }
                  }
                }
                .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })

                ListItem() {
                  SettingItem({ title: $r('app.string.cloud_sync_icon_pack_title') }) {
                    Row() {
                      Text($r('app.string.cloud_sync_icon_pack_status'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      if (this.isIconPackBusy()) {
                        LoadingProgress()
                          .width(16)
                          .height(16)
                          .margin({ right: 6 })
                        Text(this.getIconPackSyncStateText())
                          .fontSize($r('sys.float.ohos_id_text_size_body2'))
                          .fontColor($r('sys.color.ohos_id_color_emphasize'))
                          .fontWeight(FontWeight.Medium)
                      } else {
                        Text(this.getIconPackBackupStatusText())
                          .fontSize($r('sys.float.ohos_id_text_size_body2'))
                          .fontColor(this.iconPackBackupExists ?
                            $r('sys.color.ohos_id_color_text_primary') :
                            $r('sys.color.ohos_id_color_text_secondary'))
                          .fontWeight(FontWeight.Medium)
                      }
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_icon_pack_last_time'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Text((this.iconPackBackupTime != null && this.iconPackBackupTime !== '') ?
                        this.iconPackBackupTime : $r('app.string.cloud_sync_never'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor((this.iconPackBackupTime != null && this.iconPackBackupTime !== '') ?
                          $r('sys.color.ohos_id_color_text_primary') :
                          $r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_icon_pack_source_device'))
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Regular)
                        .layoutWeight(1)
                      Text((this.iconPackSourceDevice !== null && this.iconPackSourceDevice !== '') ?
                        this.iconPackSourceDevice : '-')
                        .fontSize($r('sys.float.ohos_id_text_size_body2'))
                        .fontColor((this.iconPackSourceDevice !== null && this.iconPackSourceDevice !== '') ?
                          $r('sys.color.ohos_id_color_text_primary') :
                          $r('sys.color.ohos_id_color_text_secondary'))
                        .fontWeight(FontWeight.Medium)
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))

                    SubItemDivider()

                    Row() {
                      Text($r('app.string.cloud_sync_icon_pack_hint'))
                        .fontSize($r('sys.float.ohos_id_text_size_caption'))
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .padding($r('sys.float.padding_level8'))
                  }
                }
                .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })



                ListItem() {
                  SettingItem({ title: $r('app.string.cloud_sync_operations') }) {
                    if (this.cloudSyncEnabled) {
                      SubItemButton({
                        symbol: $r('sys.symbol.mobiledata'),
                        text: $r('app.string.cloud_sync_trigger_sync'),
                        description: $r('app.string.cloud_sync_trigger_sync_des')
                      })
                        .onClick(() => {
                          this.triggerFileSync();
                        })

                      SubItemDivider()

                      SubItemButton({
                        symbol: $r('sys.symbol.arrow_clockwise'),
                        text: $r('app.string.cloud_backup_manual'),
                        description: $r('app.string.cloud_backup_manual_des')
                      })
                        .onClick(() => {
                          if (!this.cloudSyncEnabled) {
                            return;
                          }
                          this.loadingText = $r('app.string.cloud_sync_backing_up');
                          this.Is_loaded = true;
                          this.triggerCloudSync();
                        })

                      SubItemDivider()
                    }

                    SubItemButton({
                      symbol: $r('sys.symbol.arrow_counterclockwise_clock'),
                      text: $r('app.string.cloud_backup_history_title'),
                      description: $r('app.string.cloud_backup_history_subtitle')
                    })
                      .onClick(() => {
                        this.pageInfos?.pushPathByName(ROUTE_NAMES.ShowCloudBackupHistoryPage, null);
                      })

                    SubItemDivider()

                    SubItemButton({
                      symbol: $r('sys.symbol.gearshape'),
                      text: $r('app.string.cloud_sync_open_cloud_space')
                    })
                      .onClick(() => {
                        this.startCloudSpaceSettings();
                      })

                    SubItemDivider()

                    SubItemButton({
                      symbol: $r('sys.symbol.trash'),
                      text: $r('app.string.cloud_sync_clear_storage')
                    })
                      .onClick(() => {
                        this.showClearCloudStorageDialog();
                      })
                  }
                }
                .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })

                ListItem()
                  .height(CommonConstants.AVOID_TOP_BASE_HEIGHT)
              }
              .chainAnimation(AppPreference.getPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE) as boolean)
              .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
              .scrollBar(BarState.Off)
              .backgroundColor($r('app.color.window_background'))
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
          mainTitle: $r('app.string.data_huawei_cloud_sync_details'),
        },
      }
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }

  /** 图标包备份状态文本 */
  private getIconPackBackupStatusText(): ResourceStr {
    if (this.iconPackBackupCount === 0) {
      return $r('app.string.cloud_sync_icon_pack_status_empty');
    }
    if (!this.iconPackBackupExists) {
      return $r('app.string.cloud_sync_icon_pack_status_none');
    }
    const suffix = this.appCtx.resourceManager.getStringSync($r('app.string.cloud_sync_icon_pack_status_done_suffix').id);
    const sizeStr = this.formatFileSize(this.iconPackBackupSize);
    return `${this.iconPackBackupCount} ${suffix} ${sizeStr}`;
  }

  /** FileSync 状态码 → i18n 文本映射（0=上传中, 1=上传失败, 2=下载中, 3=下载失败, 4=完成, 5=已停止） */
  private getSyncStateText(): ResourceStr {
    if (this.syncState === 0) {
      return $r('app.string.cloud_sync_state_uploading');
    }
    if (this.syncState === 1) {
      return $r('app.string.cloud_sync_state_upload_failed');
    }
    if (this.syncState === 2) {
      return $r('app.string.cloud_sync_state_downloading');
    }
    if (this.syncState === 3) {
      return $r('app.string.cloud_sync_state_download_failed');
    }
    if (this.syncState === 4) {
      return $r('app.string.cloud_sync_state_completed');
    }
    if (this.syncState === 5) {
      return $r('app.string.cloud_sync_state_stopped');
    }
    return $r('app.string.cloud_sync_state_idle');
  }

  /** FileSync 状态码 → 颜色映射（失败=警告色, 完成=主色, 进行中=主题色, 其他=次级色） */
  private getSyncStateColor(): ResourceColor {
    if (this.syncState === 1 || this.syncState === 3) {
      return $r('sys.color.ohos_id_color_warning');
    }
    if (this.syncState === 4) {
      return $r('sys.color.ohos_id_color_text_primary');
    }
    if (this.syncState === 0 || this.syncState === 2) {
      return $r('app.color.str_main');
    }
    return $r('sys.color.ohos_id_color_text_secondary');
  }

  /** FileSync 错误码 → i18n 文本映射（网络/WiFi/电量/存储/温度/服务器异常） */
  private getSyncErrorText(): ResourceStr {
    if (this.syncError === 1) {
      return $r('app.string.cloud_sync_error_network_unavailable');
    }
    if (this.syncError === 2) {
      return $r('app.string.cloud_sync_error_wifi_unavailable');
    }
    if (this.syncError === 3) {
      return $r('app.string.cloud_sync_error_battery_low');
    }
    if (this.syncError === 4) {
      return $r('app.string.cloud_sync_error_battery_warning');
    }
    if (this.syncError === 5) {
      return $r('app.string.cloud_sync_error_cloud_full');
    }
    if (this.syncError === 6) {
      return $r('app.string.cloud_sync_error_local_full');
    }
    if (this.syncError === 7) {
      return $r('app.string.cloud_sync_error_temperature_high');
    }
    if (this.syncError === 8) {
      return $r('app.string.cloud_sync_error_server_error');
    }
    return $r('app.string.cloud_sync_error_no_error');
  }

  /** 手动触发从云端恢复：启动 FileSync，含60秒冷却防抖 */
  private triggerFileSync(): void {
    if (!this.isHuaweiLoggedIn || !this.cloudSyncEnabled) {
      return;
    }
    const now = Date.now();
    if (now - this.lastSyncTriggerTime < this.SYNC_COOLDOWN_MS) {
      showSnackBar($r('app.string.cloud_sync_cooldown'), SnackBarNotifyType.WARNING);
      return;
    }
    this.lastSyncTriggerTime = now;
    this.loadingText = $r('app.string.cloud_sync_syncing');
    this.Is_loaded = true;
    try {
      this.fileSync.start().then(() => {
        this.Is_loaded = false;
        showSnackBar($r('app.string.cloud_sync_started'), SnackBarNotifyType.SUCCESS);
      }).catch((err: BusinessError) => {
        this.Is_loaded = false;
        hilog.error(DOMAIN, TAG, `FileSync start failed: ${err.code} ${err.message}`);
        showSnackBar($r('app.string.cloud_sync_start_failed'), SnackBarNotifyType.WARNING);
      });
    } catch (err) {
      this.Is_loaded = false;
      let e = err as BusinessError;
      hilog.error(DOMAIN, TAG,`FileSync start exception: ${e.code} ${e.message}`);
      showSnackBar($r('app.string.cloud_sync_start_failed'), SnackBarNotifyType.WARNING);
    }
  }

  /** 清空云端存储操作菜单：选择"仅清空本设备"/"清空同名设备旧备份"/"清空所有设备"，二次确认后执行 */
  private showClearCloudStorageDialog(): void {
    if (!this.isHuaweiLoggedIn) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: $r('app.string.cloud_sync_clear_storage_confirm'),
        buttons: [
          {
            text: $r('app.string.cloud_sync_clear_device'),
            color: $r('sys.color.ohos_id_color_warning'),
          },
          {
            text: $r('app.string.cloud_sync_clear_device_name'),
            color: $r('sys.color.ohos_id_color_warning'),
          },
          {
            text: $r('app.string.cloud_sync_clear_all'),
            color: $r('sys.color.ohos_id_color_warning'),
          },
        ],
      }, (err: BusinessError, data: promptAction.ActionMenuSuccessResponse) => {
        if (err) {
          return;
        }
        if (data.index === 0) {
          this.showClearConfirmDialog(ClearCloudType.DEVICE);
        } else if (data.index === 1) {
          this.showClearConfirmDialog(ClearCloudType.DEVICE_NAME);
        } else if (data.index === 2) {
          this.showClearConfirmDialog(ClearCloudType.ALL);
        }
      });
    } catch (error) {
      let e = error as BusinessError;
      hilog.error(DOMAIN, TAG, `showActionMenu error: ${e.code} ${e.message}`);
    }
  }

  /** 清空确认弹窗：底部弹出 AlertDialog，确认后调用 triggerClearCloudStorage */
  private showClearConfirmDialog(clearType: ClearCloudType): void {
    const msg = clearType === ClearCloudType.ALL
      ? $r('app.string.cloud_sync_clear_all_confirm_msg')
      : clearType === ClearCloudType.DEVICE_NAME
        ? $r('app.string.cloud_sync_clear_device_name_confirm_msg')
        : $r('app.string.cloud_sync_clear_device_confirm_msg');
    this.getUIContext().showAlertDialog({
      title: $r('app.string.cloud_sync_clear_storage_confirm'),
      message: msg,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      gridCount: 4,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            this.triggerClearCloudStorage(clearType);
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

  /** 手动触发立即备份：调用 CloudBackupManager.backupToCloud 上传令牌到云端 */
  private triggerCloudSync(): void {
    if (!this.isHuaweiLoggedIn || !this.cloudSyncEnabled) {
      this.Is_loaded = false;
      return;
    }
    CloudBackupManager.getInstance().backupToCloud().then(success => {
      this.Is_loaded = false;
      if (success) {
        const rawTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
        this.lastSyncTime = SyncTimeHelper.formatTimestamp(SyncTimeHelper.parseStoredTimestamp(rawTime));
      }
    });
  }

  /** 执行清空云端备份操作，根据类型选择对应的清理方法 */
  private triggerClearCloudStorage(clearType: ClearCloudType): void {
    this.loadingText = $r('app.string.cloud_sync_clearing');
    this.Is_loaded = true;
    const mgr = CloudBackupManager.getInstance();
    const clearPromise = clearType === ClearCloudType.ALL
      ? mgr.clearCloudStorage()
      : clearType === ClearCloudType.DEVICE_NAME
        ? mgr.clearDeviceNameCloudStorage()
        : mgr.clearDeviceCloudStorage();
    clearPromise.then(() => {
      this.Is_loaded = false;
      if (clearType !== ClearCloudType.DEVICE_NAME) {
        const yesterdayTs = SyncTimeHelper.getYesterdayEndTs();
        AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, `${yesterdayTs}`);
        this.lastSyncTime = SyncTimeHelper.formatTimestamp(yesterdayTs);
      }
      showSnackBar($r('app.string.cloud_sync_clear_storage_success'), SnackBarNotifyType.SUCCESS);
    });
  }

  /** 跳转华为云空间系统设置页面（com.huawei.hmos.settings） */
  private startCloudSpaceSettings(): void {
    let want: Want = {
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
      uri: 'cloud_space'
    };

    this.appCtx.startAbility(want).then(() => {
      hilog.info(DOMAIN, TAG, 'Start cloud space settings ability successfully.');
  }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, `Failed to startAbility. Code: ${err.code}, message: ${err.message}`);
  });
}

  /**
   * 初始同步：页面打开时在 TaskPool 后台线程检查云端备份记录数，
   * 仅当本地无备份记录时触发 FileSync 从云端拉取。
   * 三重防护：isInitialSyncRunning 防并发，lastInitialSyncTime 防短时间内重复，
   * CLOUD_SYNC_LAST_TIME 时间戳判断距上次同步是否超过10分钟。
   */
  private triggerInitialSyncAsync(): void {
    if (this.isInitialSyncRunning) {
      hilog.info(DOMAIN, TAG, 'triggerInitialSyncAsync: already running, skip');
      return;
    }
    const now = Date.now();
    if (this.lastInitialSyncTime > 0 && (now - this.lastInitialSyncTime) < this.INITIAL_SYNC_COOLDOWN_MS) {
      hilog.info(DOMAIN, TAG, `triggerInitialSyncAsync: cooldown, last run ${now - this.lastInitialSyncTime}ms ago, skip`);
      return;
    }
    const rawTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
    const lastTs = SyncTimeHelper.parseStoredTimestamp(rawTime);
    if (lastTs > 0 && SyncTimeHelper.isWithinMinutes(lastTs, this.INITIAL_SYNC_COOLDOWN_MS / 60000)) {
      hilog.info(DOMAIN, TAG, `triggerInitialSyncAsync: last sync ts=${lastTs}, within ${this.INITIAL_SYNC_COOLDOWN_MS / 60000}min, skip`);
      return;
    }
    this.isInitialSyncRunning = true;
    this.lastInitialSyncTime = now;
    const cloudDir = this.appCtx.cloudFileDir;
    hilog.info(DOMAIN, TAG, 'triggerInitialSyncAsync: dispatching to taskpool');
    taskpool.execute(checkCloudBackupRecords, cloudDir).then((result: Object) => {
      const recordCount = result as number;
      hilog.info(DOMAIN, TAG, `triggerInitialSyncAsync: taskpool returned recordCount=${recordCount}`);
      if (recordCount === 0) {
        this.loadingText = $r('app.string.cloud_sync_loading_history');
        this.Is_loaded = true;
        try {
          this.fileSync.start().then(() => {
            this.Is_loaded = false;
            this.isInitialSyncRunning = false;
            hilog.info(DOMAIN, TAG, 'triggerInitialSyncAsync: FileSync completed');
          }).catch((err: BusinessError) => {
            this.Is_loaded = false;
            this.isInitialSyncRunning = false;
            hilog.error(DOMAIN, TAG, `triggerInitialSyncAsync: FileSync failed: ${err.code} ${err.message}`);
          });
        } catch (err) {
          this.Is_loaded = false;
          this.isInitialSyncRunning = false;
          let e = err as BusinessError;
          hilog.error(DOMAIN, TAG, `triggerInitialSyncAsync: FileSync exception: ${e.code} ${e.message}`);
        }
      } else {
        this.isInitialSyncRunning = false;
      }
    }).catch((err: BusinessError) => {
      this.isInitialSyncRunning = false;
      hilog.error(DOMAIN, TAG, `triggerInitialSyncAsync: taskpool failed: ${err.code} ${err.message}`);
    });
  }
}

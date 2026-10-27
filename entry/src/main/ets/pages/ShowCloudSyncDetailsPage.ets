import { common, Want } from '@kit.AbilityKit';
import { AppStorageV2, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import {
  AppPreference, AppWindowInfo, CloudBackupActionResult, CloudBackupDiagnostics, CloudBackupFailureReason, CloudBackupManager,
  CloudBackupSyncError, CloudBackupSyncService, CloudBackupSyncSnapshot, CloudBackupSyncState,
  CloudSyncFailureStage, CloudSyncFailureState, CloudSyncFailureView, cloudSyncFailureView,
  CommonConstants, DiagnosticKind, DiagnosticReason, DiagnosticResult, DiagnosticStage, DiagnosticUiAction,
  dialogSystemMaterial, HuaweiAccountManager, IconPackCloudBackup, IconPackSyncState,
  PREF_KEYS, showSnackBar, SnackBarNotifyType, SyncTimeHelper
} from 'common';
import { MaterialTheme } from '../components/MaterialTheme';
import { MaterialSheetStyle } from '../components/MaterialSheetStyle';
import { PageScaffold } from '../components/PageScaffold';
import { SettingItem } from '../components/SettingItem';
import { SubItemButton } from '../components/SubItemButton';
import { SubItemDivider } from '../components/SubItemDivider';
// [冷启动优化] 历史面板与反馈内容仅在首次打开对应面板时加载
import lazy { CloudBackupHistorySheet, cloudBackupHistorySheetOptions } from './setting/CloudBackupHistorySheet';
import lazy { FeedbackSheet } from './setting/FeedbackSheet';

enum ClearCloudType {
  DEVICE,
  DEVICE_NAME,
  ALL
}

@Entry
@Preview
@ComponentV2
export struct ShowCloudSyncDetailsPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param inMaterialSheet: boolean = false;
  @Param sheetRoot: boolean = false;
  @Event onCloseSheet: () => void = () => {};
  @Local cloudSyncEnabled: boolean = false;
  @Local lastSyncTime: string = '';
  @Local lastFailure: CloudSyncFailureView | null = null;
  @Local isLoading: boolean = false;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local syncState: CloudBackupSyncState = CloudBackupSyncState.UNKNOWN;
  @Local syncError: CloudBackupSyncError = CloudBackupSyncError.NO_ERROR;
  @Local loadingText: ResourceStr = '';
  @Local actionMessage: ResourceStr = '';
  @Local skippedMessage: ResourceStr = '';
  @Local serviceBusy: boolean = false;
  @Local cleanupPending: boolean = false;
  @Local isRetryingCleanup: boolean = false;
  @Local needsSyncRetry: boolean = false;
  @Local confirmationOpen: boolean = false;
  @Local isHistorySheetVisible: boolean = false;
  @Local isFeedbackSheetVisible: boolean = false;
  @Local iconPackStatusKnown: boolean = false;
  @Local iconPackMetaAbsent: boolean = false;
  @Local iconPackPublicationUnresolved: boolean = false;
  @Local iconPackBackupExists: boolean = false;
  @Local iconPackBackupCount: number = 0;
  @Local iconPackBackupSize: number = 0;
  @Local iconPackBackupTime: string = '';
  @Local iconPackSyncState: number = IconPackSyncState.IDLE;
  @Local iconPackSourceDevice: string = '';
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private backupManager: CloudBackupManager = CloudBackupManager.getInstance();
  private syncService: CloudBackupSyncService = CloudBackupSyncService.getInstance();
  private scroller: Scroller = new Scroller();
  private unsubscribeSync: (() => void) | null = null;
  private statePollTimer: number = -1;
  private isMounted: boolean = false;
  private iconStatusLoading: boolean = false;
  private iconStatusAttempts: number = 0;
  private lastSyncTriggerTime: number = 0;
  private lastInitialSyncTime: number = 0;
  private readonly SYNC_COOLDOWN_MS: number = 60000;
  private readonly INITIAL_SYNC_COOLDOWN_MS: number = 600000;

  aboutToAppear(): void {
    this.isMounted = true;
    this.cloudSyncEnabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
    this.refreshLastBackupTime();
    this.refreshLastBackupFailure();
    this.refreshOperationState();
    this.applySyncSnapshot(this.syncService.getSnapshot());
    // 与管理器提交同步使用同一实例；初始 COMPLETED 只表示全局状态，不证明本次上传完成。
    this.unsubscribeSync = this.syncService.subscribe((snapshot: CloudBackupSyncSnapshot) => {
      if (this.isMounted) { this.applySyncSnapshot(snapshot); }
    });
    this.statePollTimer = setInterval(() => {
      const wasBusy = this.serviceBusy;
      const oldIconState = this.iconPackSyncState;
      this.refreshOperationState();
      this.iconPackSyncState = IconPackCloudBackup.getInstance().getState();
      // 状态未定（未读到、也未确认缺失）时补拉有限次数：打开瞬间的守卫拦截不致永久停留未知。
      const iconUnresolved = !this.iconPackStatusKnown && !this.iconPackMetaAbsent &&
        this.iconStatusAttempts < 5;
      if (!this.serviceBusy && !this.cleanupPending && !this.isLoading &&
        (wasBusy || oldIconState !== this.iconPackSyncState || iconUnresolved)) {
        this.refreshLastBackupTime();
        this.refreshLastBackupFailure();
        this.loadIconPackBackupStatus();
      }
    }, 2000) as number;
    this.initializeStatus();
  }

  aboutToDisappear(): void {
    this.isMounted = false;
    this.confirmationOpen = false;
    if (this.unsubscribeSync !== null) {
      this.unsubscribeSync();
      this.unsubscribeSync = null;
    }
    if (this.statePollTimer >= 0) {
      clearInterval(this.statePollTimer);
      this.statePollTimer = -1;
    }
  }

  private applySyncSnapshot(snapshot: CloudBackupSyncSnapshot): void {
    this.syncState = snapshot.state;
    this.syncError = snapshot.error;
  }

  private refreshLastBackupTime(): void {
    const rawTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string ?? '';
    this.lastSyncTime = SyncTimeHelper.formatTimestamp(SyncTimeHelper.parseStoredTimestamp(rawTime));
  }

  /** 失败状态键 → 视图模型；成功清除后为 null，重启后仍可读回（AppPreference 持久化）。 */
  private refreshLastBackupFailure(): void {
    this.lastFailure = cloudSyncFailureView(CloudSyncFailureState.read());
  }

  /** 失败阶段文案；未知枚举（跨版本脏数据）落通用"未知阶段"。 */
  private lastFailureStageText(view: CloudSyncFailureView): ResourceStr {
    if (!view.knownStage) { return $r('app.string.cloud_backup_failure_stage_unknown'); }
    switch (view.stage) {
      case CloudSyncFailureStage.DEVICE_INFO: return $r('app.string.cloud_backup_failure_stage_device_info');
      case CloudSyncFailureStage.SNAPSHOT: return $r('app.string.cloud_backup_failure_stage_snapshot');
      case CloudSyncFailureStage.ENCRYPT: return $r('app.string.cloud_backup_failure_stage_encrypt');
      case CloudSyncFailureStage.WRITE: return $r('app.string.cloud_backup_failure_stage_write');
      case CloudSyncFailureStage.STAGED_VERIFY: return $r('app.string.cloud_backup_failure_stage_staged_verify');
      case CloudSyncFailureStage.PUBLISH: return $r('app.string.cloud_backup_failure_stage_publish');
      case CloudSyncFailureStage.POST_PUBLISH_VERIFY: return $r('app.string.cloud_backup_failure_stage_post_verify');
      case CloudSyncFailureStage.ROTATE: return $r('app.string.cloud_backup_failure_stage_rotate');
      case CloudSyncFailureStage.ICON: return $r('app.string.cloud_backup_failure_stage_icon');
      case CloudSyncFailureStage.SYNC: return $r('app.string.cloud_backup_failure_stage_sync');
      default: return $r('app.string.cloud_backup_failure_stage_unknown');
    }
  }

  /** 失败原因文案：复用既有 reason 映射，POST_VERIFY_FAILED/UNKNOWN 落专用兜底。 */
  private lastFailureReasonText(view: CloudSyncFailureView): ResourceStr {
    if (!view.knownReason) { return $r('app.string.cloud_backup_unknown_error'); }
    return this.failureText(view.reason, $r('app.string.cloud_backup_unknown_error'));
  }

  private refreshOperationState(): void {
    this.isHuaweiLoggedIn = HuaweiAccountManager.getInstance().userLogin;
    this.serviceBusy = this.backupManager.isBusy();
    this.cleanupPending = this.backupManager.isCleanupPending();
  }

  private interactionBlocked(): boolean {
    return this.isLoading || this.isRetryingCleanup || this.confirmationOpen || this.serviceBusy || this.cleanupPending;
  }

  private canStartAction(): boolean {
    this.refreshOperationState();
    return this.isMounted && this.isHuaweiLoggedIn && !this.interactionBlocked();
  }

  private async initializeStatus(): Promise<void> {
    await this.triggerInitialSyncAsync();
    if (this.isMounted && this.isHuaweiLoggedIn) { await this.loadIconPackBackupStatus(); }
  }

  private async loadIconPackBackupStatus(): Promise<void> {
    if (!this.isMounted || !this.isHuaweiLoggedIn || this.iconStatusLoading ||
      this.backupManager.isBusy() || this.backupManager.isCleanupPending()) {
      return;
    }
    this.iconStatusLoading = true;
    this.iconStatusAttempts++;
    try {
      const status = await IconPackCloudBackup.getInstance().getCloudBackupStatus();
      if (!this.isMounted) { return; }
      this.iconPackBackupExists = status.exists;
      this.iconPackBackupCount = status.packCount;
      this.iconPackBackupSize = status.size;
      this.iconPackBackupTime = status.lastTime;
      this.iconPackSourceDevice = status.sourceDeviceName;
      this.iconPackStatusKnown = status.metadataKnown === true;
      this.iconPackMetaAbsent = status.metadataAbsent === true;
      this.iconPackPublicationUnresolved = status.publicationUnresolved === true;
    } catch (_) {
      this.iconPackStatusKnown = false;
      this.iconPackMetaAbsent = false;
    } finally {
      this.iconStatusLoading = false;
      this.iconPackSyncState = IconPackCloudBackup.getInstance().getState();
      this.refreshOperationState();
    }
  }

  private pageBackground(): ResourceColor {
    return this.inMaterialSheet ? MaterialTheme.surfaceBackground($r('app.color.window_background')) :
      $r('app.color.window_background');
  }

  private historySheetOptions(): SheetOptions {
    return cloudBackupHistorySheetOptions();
  }

  private feedbackSheetOptions(): SheetOptions {
    return MaterialSheetStyle.options();
  }

  @Builder
  HistorySheetContent() {
    CloudBackupHistorySheet({
      scrollEffectType: this.scrollEffectType,
      onClose: () => { this.isHistorySheetVisible = false; }
    })
  }

  @Builder
  FeedbackSheetContent() {
    // embedded:false 与设置页反馈 sheet（SheetCoordinator）同一呈现配置。
    FeedbackSheet({ scrollEffectType: this.scrollEffectType, embedded: false })
      .height('100%')
  }

  build() {
    HdsNavDestination() {
      PageScaffold({ bgColor: this.pageBackground() }) {
        List({ space: 12, scroller: this.scroller }) {
          ListItem().height(CommonConstants.AVOID_TOP_BASE_HEIGHT)
          if (this.isLoading || this.isRetryingCleanup || this.serviceBusy || this.cleanupPending || this.actionMessage !== '') {
            ListItem() {
              Column({ space: 12 }) {
                if (this.isLoading || this.isRetryingCleanup) {
                  LoadingProgress().width(36).height(36).color($r('app.color.str_main'))
                  Text(this.loadingText).fontSize($r('sys.float.ohos_id_text_size_body2'))
                    .fontColor($r('sys.color.font_secondary'))
                }
                if (this.cleanupPending) {
                  Text($r('app.string.cloud_backup_cleanup_pending'))
                    .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.ohos_id_color_warning'))
                  Button($r('app.string.cloud_backup_retry_cleanup'))
                    .width('100%').labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 })
                    .enabled(!this.isLoading && !this.isRetryingCleanup && !this.confirmationOpen)
                    .onClick(() => this.retryCleanup())
                } else if (this.serviceBusy && !this.isLoading) {
                  Text($r('app.string.cloud_backup_operation_busy'))
                    .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
                }
                if (this.actionMessage !== '') {
                  Text(this.actionMessage).fontSize($r('sys.float.ohos_id_text_size_body2'))
                    .fontColor($r('sys.color.font_secondary')).width('100%')
                }
                if (this.skippedMessage !== '') {
                  Text(this.skippedMessage).fontSize($r('sys.float.ohos_id_text_size_body2'))
                    .fontColor($r('sys.color.ohos_id_color_warning')).width('100%')
                }
                if (this.needsSyncRetry && !this.cleanupPending) {
                  Button($r('app.string.cloud_backup_retry_sync'))
                    .width('100%').labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).enabled(!this.interactionBlocked())
                    .onClick(() => this.retrySync())
                }
              }
              .width('100%').padding(16)
            }
          }
          ListItem() {
            SettingItem({ title: $r('app.string.cloud_sync_status') }) {
              this.StatusValue($r('app.string.cloud_sync_status'), this.cloudSyncEnabled ?
                $r('app.string.cloud_sync_enabled') : $r('app.string.cloud_sync_disabled'))
              Text($r('app.string.cloud_sync_status_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
                .width('100%').padding(16)
              SubItemDivider()
              this.StatusValue($r('app.string.cloud_sync_last_time'), this.lastSyncTime !== '' ?
                this.lastSyncTime : $r('app.string.cloud_sync_never'))
              Text($r('app.string.cloud_backup_last_time_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
                .width('100%').padding({ left: 16, right: 16, bottom: 16 })
              SubItemDivider()
              this.StatusValue($r('app.string.cloud_sync_encryption'), this.isHuaweiLoggedIn ?
                $r('app.string.cloud_sync_encryption_huawei_account') : $r('app.string.cloud_sync_encryption_none'))
              SubItemDivider()
              this.StatusValue($r('app.string.cloud_sync_network'), $r('app.string.cloud_sync_wifi_only'))
              SubItemDivider()
              this.StatusValue($r('app.string.cloud_backup_global_sync_state'), this.getSyncStateText())
              Text($r('app.string.cloud_backup_global_sync_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
                .width('100%').padding({ left: 16, right: 16, bottom: 16 })
              if (this.syncError !== CloudBackupSyncError.NO_ERROR) {
                SubItemDivider()
                this.StatusValue($r('app.string.cloud_sync_sync_error'), this.getSyncErrorText(), true)
              }
              if (this.lastFailure !== null) {
                SubItemDivider()
                // 最近一次备份失败行：内联响应式绑定（@Builder 按值传参不随状态刷新，规避 §15 教训）。
                Column({ space: 6 }) {
                  Text($r('app.string.cloud_backup_last_failure_title'))
                    .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
                  Text(this.lastFailureStageText(this.lastFailure))
                    .fontSize($r('sys.float.ohos_id_text_size_body1')).fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.ohos_id_color_warning'))
                  Text(this.lastFailureReasonText(this.lastFailure))
                    .fontSize($r('sys.float.ohos_id_text_size_body2'))
                    .fontColor($r('sys.color.ohos_id_color_warning'))
                  Text($r('app.string.cloud_backup_last_failure_feedback'))
                    .fontSize($r('sys.float.ohos_id_text_size_caption'))
                    .fontColor($r('sys.color.ohos_id_color_warning'))
                  SubItemButton({
                    symbol: $r('sys.symbol.envelope'), text: $r('app.string.app_issue_feedback'),
                    description: $r('app.string.cloud_backup_last_failure_feedback_entry'), descriptionMaxLines: 0
                  })
                    .enabled(!this.interactionBlocked())
                    .onClick(() => this.openFeedback())
                }
                .alignItems(HorizontalAlign.Start).width('100%').padding(16)
              }
            }
          }
          ListItem() {
            SettingItem({ title: $r('app.string.cloud_sync_icon_pack_title') }) {
              // 图标包状态在首次构建后才确定：@Builder 按值传参不随状态刷新，须直接绑定。
              Column({ space: 6 }) {
                Text($r('app.string.cloud_sync_icon_pack_status'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
                Text(this.getIconPackStatusText())
                  .fontSize($r('sys.float.ohos_id_text_size_body1')).fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
              }
              .alignItems(HorizontalAlign.Start).width('100%').padding(16)
              SubItemDivider()
              Column({ space: 6 }) {
                Text($r('app.string.cloud_sync_icon_pack_last_time'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
                Text(this.iconPackStatusKnown && this.iconPackBackupTime !== '' ?
                  this.iconPackBackupTime : this.iconPackMetaAbsent && !this.iconPackBackupExists ?
                    $r('app.string.cloud_sync_never') : $r('app.string.cloud_backup_value_unknown'))
                  .fontSize($r('sys.float.ohos_id_text_size_body1')).fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
              }
              .alignItems(HorizontalAlign.Start).width('100%').padding(16)
              SubItemDivider()
              Column({ space: 6 }) {
                Text($r('app.string.cloud_sync_icon_pack_source_device'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
                Text(this.iconPackStatusKnown && this.iconPackSourceDevice.trim() !== '' ?
                  this.iconPackSourceDevice : $r('app.string.cloud_backup_unknown_device'))
                  .fontSize($r('sys.float.ohos_id_text_size_body1')).fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
              }
              .alignItems(HorizontalAlign.Start).width('100%').padding(16)
              Text($r('app.string.cloud_sync_icon_pack_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
                .width('100%').padding(16)
            }
          }
          ListItem() {
            SettingItem({ title: $r('app.string.cloud_sync_operations') }) {
              if (this.cloudSyncEnabled) {
                SubItemButton({
                  symbol: $r('sys.symbol.mobiledata'), text: $r('app.string.cloud_sync_trigger_sync'),
                  description: $r('app.string.cloud_sync_trigger_sync_des'), descriptionMaxLines: 0
                })
                  .enabled(!this.interactionBlocked() && this.isHuaweiLoggedIn)
                  .onClick(() => this.triggerFileSync())
                SubItemDivider()
                SubItemButton({
                  symbol: $r('sys.symbol.arrow_clockwise'), text: $r('app.string.cloud_backup_manual'),
                  description: $r('app.string.cloud_backup_manual_des'), descriptionMaxLines: 0
                })
                  .enabled(!this.interactionBlocked() && this.isHuaweiLoggedIn)
                  .onClick(() => this.triggerCloudSync())
                SubItemDivider()
              }
              SubItemButton({
                symbol: $r('sys.symbol.arrow_counterclockwise_clock'), text: $r('app.string.cloud_backup_history_title'),
                description: $r('app.string.cloud_backup_history_subtitle'), descriptionMaxLines: 0
              })
                .id('cloud-backup-history-open')
                .enabled(!this.interactionBlocked() && this.isHuaweiLoggedIn)
                .onClick(() => {
                  if (this.canStartAction()) { this.isHistorySheetVisible = true; }
                })
              SubItemDivider()
              SubItemButton({ symbol: $r('sys.symbol.gearshape'), text: $r('app.string.cloud_sync_open_cloud_space') })
                .onClick(() => this.startCloudSpaceSettings())
            }
          }
          ListItem() {
            SettingItem({ title: $r('app.string.cloud_backup_danger_zone') }) {
              Column({ space: 12 }) {
                Text($r('app.string.cloud_backup_delete_local_unaffected'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary')).width('100%')
                Button($r('app.string.cloud_sync_clear_storage'))
                  .fontColor($r('sys.color.ohos_id_color_warning')).backgroundColor($r('sys.color.comp_background_gray'))
                  .width('100%').labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 })
                  .enabled(!this.interactionBlocked() && this.isHuaweiLoggedIn)
                  .onClick(() => this.showClearCloudStorageDialog())
              }
              .padding(16).width('100%')
            }
          }
        }
        .chainAnimation(AppPreference.getPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE) as boolean)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).scrollBar(BarState.Off)
        .backgroundColor(this.pageBackground()).width('100%').height('100%')
        .padding({ left: 16, right: 16 }).contentEndOffset(this.window.AvoidBottomHeight + 24)
        .bindSheet($$this.isFeedbackSheetVisible, this.FeedbackSheetContent(), this.feedbackSheetOptions())
      }
    }
    .backgroundColor(this.pageBackground())
    .bindToScrollable([this.scroller])
    .hideBackButton(this.sheetRoot)
    .onBackPressed(() => {
      if (!this.sheetRoot) { return false; }
      this.onCloseSheet();
      return true;
    })
    .bindSheet($$this.isHistorySheetVisible, this.HistorySheetContent(), this.historySheetOptions())
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            backIconStyle: MaterialTheme.navigationIconStyle(), menuStyle: MaterialTheme.navigationIconStyle()
          }
        },
        scrollEffectStyle: MaterialTheme.navigationScrollStyle(),
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectType },
        systemMaterialEffect: { materialType: MaterialTheme.hdsMaterialType(), materialLevel: MaterialTheme.hdsMaterialLevel() }
      },
      content: { title: { mainTitle: $r('app.string.data_huawei_cloud_sync_details') } }
    })
  }

  @Builder
  StatusValue(label: ResourceStr, value: ResourceStr, warning: boolean = false) {
    Column({ space: 6 }) {
      Text(label).fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
      Text(value).fontSize($r('sys.float.ohos_id_text_size_body1')).fontWeight(FontWeight.Medium)
        .fontColor(warning ? $r('sys.color.ohos_id_color_warning') : $r('sys.color.font_primary'))
    }
    .alignItems(HorizontalAlign.Start).width('100%').padding(16)
  }

  private getIconPackStatusText(): ResourceStr {
    switch (this.iconPackSyncState) {
      case IconPackSyncState.BACKING_UP: return $r('app.string.cloud_sync_icon_pack_state_backing_up');
      case IconPackSyncState.RESTORING: return $r('app.string.cloud_sync_icon_pack_state_restoring');
      case IconPackSyncState.CLEARING: return $r('app.string.cloud_sync_icon_pack_state_clearing');
      case IconPackSyncState.CHECKING: return $r('app.string.cloud_sync_icon_pack_state_checking');
    }
    if (this.iconPackPublicationUnresolved) {
      return $r('app.string.cloud_sync_icon_pack_publication_unresolved');
    }
    if (!this.iconPackStatusKnown) {
      // 元数据与压缩包都确定不在云端 = 从未备份过图标包（无内容跳过从不写出文件）；
      // 只有“文件在但读不了/校验不过”或“有 zip 无元数据”才如实显示无法确认。
      if (this.iconPackMetaAbsent && !this.iconPackBackupExists) {
        return $r('app.string.cloud_sync_icon_pack_status_none');
      }
      return $r('app.string.cloud_backup_metadata_unknown');
    }
    if (!this.iconPackBackupExists) { return $r('app.string.cloud_sync_icon_pack_status_none'); }
    if (this.iconPackBackupCount === 0) { return $r('app.string.cloud_sync_icon_pack_status_empty'); }
    const size = this.iconPackBackupSize < 1024 ? `${this.iconPackBackupSize} B` : `${(this.iconPackBackupSize / 1024).toFixed(1)} KB`;
    return $r('app.string.cloud_backup_icon_summary', this.iconPackBackupCount, size);
  }

  private getSyncStateText(): ResourceStr {
    switch (this.syncState) {
      case CloudBackupSyncState.UPLOADING: return $r('app.string.cloud_sync_state_uploading');
      case CloudBackupSyncState.UPLOAD_FAILED: return $r('app.string.cloud_sync_state_upload_failed');
      case CloudBackupSyncState.DOWNLOADING: return $r('app.string.cloud_sync_state_downloading');
      case CloudBackupSyncState.DOWNLOAD_FAILED: return $r('app.string.cloud_sync_state_download_failed');
      case CloudBackupSyncState.COMPLETED: return $r('app.string.cloud_backup_global_sync_idle');
      case CloudBackupSyncState.STOPPED: return $r('app.string.cloud_sync_state_stopped');
      default: return $r('app.string.cloud_backup_value_unknown');
    }
  }

  private getSyncErrorText(): ResourceStr {
    switch (this.syncError) {
      case CloudBackupSyncError.NETWORK_UNAVAILABLE: return $r('app.string.cloud_sync_error_network_unavailable');
      case CloudBackupSyncError.WIFI_UNAVAILABLE: return $r('app.string.cloud_sync_error_wifi_unavailable');
      case CloudBackupSyncError.BATTERY_LEVEL_LOW: return $r('app.string.cloud_sync_error_battery_low');
      case CloudBackupSyncError.BATTERY_LEVEL_WARNING: return $r('app.string.cloud_sync_error_battery_warning');
      case CloudBackupSyncError.CLOUD_STORAGE_FULL: return $r('app.string.cloud_sync_error_cloud_full');
      case CloudBackupSyncError.LOCAL_STORAGE_FULL: return $r('app.string.cloud_sync_error_local_full');
      case CloudBackupSyncError.DEVICE_TEMPERATURE_TOO_HIGH: return $r('app.string.cloud_sync_error_temperature_high');
      case CloudBackupSyncError.REMOTE_SERVER_ABNORMAL: return $r('app.string.cloud_sync_error_server_error');
      case CloudBackupSyncError.NO_ERROR: return $r('app.string.cloud_sync_error_no_error');
      default: return $r('app.string.cloud_backup_unknown_error');
    }
  }

  private openFeedback(): void {
    const context = CloudBackupDiagnostics.begin(DiagnosticKind.UI);
    CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_ACTION, DiagnosticResult.BEGIN,
      { uiAction: DiagnosticUiAction.FEEDBACK });
    try {
      if (!this.isMounted || this.interactionBlocked() || this.lastFailure === null) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_RESULT, DiagnosticResult.BLOCKED,
          { uiAction: DiagnosticUiAction.FEEDBACK, reason: DiagnosticReason.UNAVAILABLE });
        return;
      }
      this.isFeedbackSheetVisible = true;
      CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_RESULT, DiagnosticResult.OK,
        { uiAction: DiagnosticUiAction.FEEDBACK, reason: DiagnosticReason.NONE });
    } catch (_) {
      CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_RESULT, DiagnosticResult.FAIL,
        { uiAction: DiagnosticUiAction.FEEDBACK, reason: DiagnosticReason.UNAVAILABLE });
    } finally {
      CloudBackupDiagnostics.end(context);
    }
  }

  private async triggerFileSync(): Promise<void> {
    if (!this.canStartAction() || !this.cloudSyncEnabled) { return; }
    this.skippedMessage = '';
    const now = Date.now();
    if (this.lastSyncTriggerTime > 0 && now - this.lastSyncTriggerTime < this.SYNC_COOLDOWN_MS) {
      showSnackBar($r('app.string.cloud_sync_cooldown'), SnackBarNotifyType.WARNING);
      return;
    }
    this.isLoading = true;
    this.loadingText = $r('app.string.cloud_sync_syncing');
    try {
      const accepted = await this.backupManager.retrySync();
      if (!this.isMounted) { return; }
      if (accepted) { this.lastSyncTriggerTime = now; }
      this.actionMessage = accepted ? $r('app.string.cloud_backup_sync_pending') : $r('app.string.cloud_backup_sync_submit_failed');
      showSnackBar(this.actionMessage, accepted ? SnackBarNotifyType.SUCCESS : SnackBarNotifyType.WARNING);
    } catch (_) {
      this.actionMessage = $r('app.string.cloud_backup_sync_submit_failed');
    } finally {
      this.isLoading = false;
      this.refreshOperationState();
    }
  }

  private showClearCloudStorageDialog(): void {
    if (!this.canStartAction()) { return; }
    this.confirmationOpen = true;
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        systemMaterial: dialogSystemMaterial(), title: $r('app.string.cloud_sync_clear_storage_confirm'),
        buttons: [
          { text: $r('app.string.cloud_sync_clear_device'), color: $r('sys.color.ohos_id_color_warning') },
          { text: $r('app.string.cloud_sync_clear_device_name'), color: $r('sys.color.ohos_id_color_warning') },
          { text: $r('app.string.cloud_sync_clear_all'), color: $r('sys.color.ohos_id_color_warning') }
        ]
      }, (err: BusinessError, data: promptAction.ActionMenuSuccessResponse) => {
        this.confirmationOpen = false;
        if (err || !this.isMounted) { return; }
        if (data.index === 0) { this.showClearConfirmDialog(ClearCloudType.DEVICE); }
        else if (data.index === 1) { this.showClearConfirmDialog(ClearCloudType.DEVICE_NAME); }
        else if (data.index === 2) { this.showClearConfirmDialog(ClearCloudType.ALL); }
      });
    } catch (_) {
      this.confirmationOpen = false;
      showSnackBar($r('app.string.cloud_sync_clear_storage_failed'), SnackBarNotifyType.WARNING);
    }
  }

  private showClearConfirmDialog(clearType: ClearCloudType): void {
    if (!this.canStartAction()) { return; }
    const message = clearType === ClearCloudType.ALL ? $r('app.string.cloud_sync_clear_all_confirm_msg') :
      clearType === ClearCloudType.DEVICE_NAME ? $r('app.string.cloud_sync_clear_device_name_confirm_msg') :
        $r('app.string.cloud_sync_clear_device_confirm_msg');
    this.confirmationOpen = true;
    try {
      this.getUIContext().showAlertDialog({
        systemMaterial: dialogSystemMaterial(), title: $r('app.string.cloud_sync_clear_storage_confirm'), message: message,
        autoCancel: true, alignment: DialogAlignment.Bottom, gridCount: 4, offset: { dx: 0, dy: -20 },
        buttonDirection: DialogButtonDirection.VERTICAL,
        buttons: [
          { value: $r('app.string.cloud_sync_clear_storage'), fontColor: $r('sys.color.ohos_id_color_warning'), action: () => {
            this.confirmationOpen = false;
            this.triggerClearCloudStorage(clearType);
          } },
          { value: $r('app.string.dialog_btn_cancel'), action: () => { this.confirmationOpen = false; } }
        ],
        cancel: () => { this.confirmationOpen = false; }
      });
    } catch (_) {
      this.confirmationOpen = false;
      showSnackBar($r('app.string.cloud_sync_clear_storage_failed'), SnackBarNotifyType.WARNING);
    }
  }

  /** false、拒绝及同步提交失败分别消费，任何出口均恢复 loading。 */
  private async triggerCloudSync(): Promise<void> {
    if (!this.canStartAction() || !this.cloudSyncEnabled) { return; }
    this.skippedMessage = '';
    this.loadingText = $r('app.string.cloud_sync_backing_up');
    this.isLoading = true;
    try {
      const result = await this.backupManager.backupToCloudResult();
      if (!this.isMounted) { return; }
      this.updateSyncRetryState(result);
      this.actionMessage = result.success ? $r('app.string.cloud_backup_created_locally') :
        this.actionFailureText(result, $r('app.string.cloud_backup_create_failed'));
      showSnackBar(this.actionMessage, result.success ? SnackBarNotifyType.SUCCESS : SnackBarNotifyType.WARNING);
      this.refreshLastBackupTime();
      this.refreshLastBackupFailure();
    } catch (_) {
      if (this.isMounted) {
        this.actionMessage = $r('app.string.cloud_backup_create_failed');
        showSnackBar(this.actionMessage, SnackBarNotifyType.WARNING);
      }
    } finally {
      this.isLoading = false;
      this.refreshOperationState();
    }
    if (this.isMounted) { await this.loadIconPackBackupStatus(); }
  }

  private async triggerClearCloudStorage(clearType: ClearCloudType): Promise<void> {
    if (!this.canStartAction()) { return; }
    this.loadingText = $r('app.string.cloud_sync_clearing');
    this.isLoading = true;
    this.skippedMessage = '';
    try {
      const result = clearType === ClearCloudType.ALL ? await this.backupManager.clearCloudStorageResult() :
        clearType === ClearCloudType.DEVICE_NAME ? await this.backupManager.clearDeviceNameCloudStorageResult() :
          await this.backupManager.clearDeviceCloudStorageResult();
      if (!this.isMounted) { return; }
      this.updateSyncRetryState(result);
      this.actionMessage = result.success ? $r('app.string.cloud_sync_clear_storage_success') :
        this.actionFailureText(result, $r('app.string.cloud_sync_clear_storage_failed'));
      // 无归属记录跳过数如实上报：既不冒充已删除，也不当作失败。
      this.skippedMessage = result.skippedUnowned > 0 ?
        $r('app.string.cloud_backup_clear_result_skipped', result.skippedUnowned) : '';
      if (result.success && result.deletedCount > 0) {
        this.actionMessage = $r('app.string.cloud_backup_clear_result_deleted', result.deletedCount);
      }
      showSnackBar(this.actionMessage, result.success ? SnackBarNotifyType.SUCCESS : SnackBarNotifyType.WARNING);
      this.refreshLastBackupTime();
      this.refreshLastBackupFailure();
    } catch (_) {
      if (this.isMounted) {
        this.actionMessage = $r('app.string.cloud_sync_clear_storage_failed');
        showSnackBar(this.actionMessage, SnackBarNotifyType.WARNING);
      }
    } finally {
      this.isLoading = false;
      this.refreshOperationState();
    }
    if (this.isMounted) { await this.loadIconPackBackupStatus(); }
  }

  private async retryCleanup(): Promise<void> {
    if (!this.isMounted || this.isLoading || this.isRetryingCleanup || this.confirmationOpen) { return; }
    this.isRetryingCleanup = true;
    this.loadingText = $r('app.string.cloud_backup_operation_running');
    try {
      const drained = await this.backupManager.retryPendingCleanup();
      this.actionMessage = drained ? $r('app.string.cloud_backup_cleanup_ready') : $r('app.string.cloud_backup_cleanup_pending');
    } catch (_) {
      this.actionMessage = $r('app.string.cloud_backup_cleanup_pending');
    } finally {
      this.isRetryingCleanup = false;
      this.refreshOperationState();
    }
  }

  private async retrySync(): Promise<void> {
    if (!this.canStartAction() || !this.needsSyncRetry) { return; }
    this.isLoading = true;
    this.loadingText = $r('app.string.cloud_sync_syncing');
    try {
      const accepted = await this.backupManager.retrySync();
      this.needsSyncRetry = !accepted;
      this.actionMessage = accepted ? $r('app.string.cloud_backup_sync_pending') : $r('app.string.cloud_backup_sync_submit_failed');
    } catch (_) {
      this.actionMessage = $r('app.string.cloud_backup_sync_submit_failed');
    } finally {
      this.isLoading = false;
      this.refreshOperationState();
    }
  }

  private async startCloudSpaceSettings(): Promise<void> {
    const want: Want = {
      bundleName: 'com.huawei.hmos.settings', abilityName: 'com.huawei.hmos.settings.MainAbility', uri: 'cloud_space'
    };
    try {
      await this.appCtx.startAbility(want);
    } catch (_) {
      if (this.isMounted) {
        showSnackBar($r('app.string.cloud_backup_settings_failed'), SnackBarNotifyType.WARNING);
      }
    }
  }

  /** 初始检查也走管理器许可；绝不在页面直接创建第三个 FileSync 或无锁 TaskPool 读取。 */
  private async triggerInitialSyncAsync(): Promise<void> {
    if (!this.canStartAction() || !this.cloudSyncEnabled) { return; }
    const now = Date.now();
    if (this.lastInitialSyncTime > 0 && now - this.lastInitialSyncTime < this.INITIAL_SYNC_COOLDOWN_MS) { return; }
    const rawTime = AppPreference.getPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME) as string;
    const lastTimestamp = SyncTimeHelper.parseStoredTimestamp(rawTime);
    if (lastTimestamp > 0 && SyncTimeHelper.isWithinMinutes(lastTimestamp, 10)) { return; }
    this.isLoading = true;
    this.loadingText = $r('app.string.cloud_sync_loading_history');
    this.lastInitialSyncTime = now;
    try {
      const hasRecords = await this.backupManager.hasBackupRecords();
      if (!this.isMounted) { return; }
      if (hasRecords === undefined) {
        this.refreshOperationState();
        this.actionMessage = this.cleanupPending ? $r('app.string.cloud_backup_cleanup_pending') :
          this.serviceBusy ? $r('app.string.cloud_backup_operation_busy') : $r('app.string.cloud_backup_history_load_failed');
      } else if (hasRecords === false) {
        const accepted = await this.backupManager.retrySync();
        if (this.isMounted) {
          this.actionMessage = accepted ? $r('app.string.cloud_backup_sync_pending') : $r('app.string.cloud_backup_sync_submit_failed');
        }
      }
    } catch (_) {
      if (this.isMounted) { this.actionMessage = $r('app.string.cloud_backup_history_load_failed'); }
    } finally {
      this.isLoading = false;
      this.refreshOperationState();
    }
  }

  private updateSyncRetryState(result: CloudBackupActionResult): void {
    if (result.syncStartAccepted) {
      this.needsSyncRetry = false;
    } else if (result.localComplete || result.partialFailure) {
      this.needsSyncRetry = true;
    }
  }

  private actionFailureText(result: CloudBackupActionResult, fallback: ResourceStr): ResourceStr {
    if (result.reason === CloudBackupFailureReason.CLEANUP_PENDING || result.reason === CloudBackupFailureReason.BUSY) {
      return this.failureText(result.reason, fallback);
    }
    if (result.partialFailure) {
      return result.syncStartAccepted ? $r('app.string.cloud_backup_partial_failure') :
        $r('app.string.cloud_backup_partial_sync_failed');
    }
    if (result.localComplete && !result.syncStartAccepted && result.reason === CloudBackupFailureReason.SYNC_FAILED) {
      return $r('app.string.cloud_backup_local_done_sync_failed');
    }
    return this.failureText(result.reason, fallback);
  }

  private failureText(reason: CloudBackupFailureReason, fallback: ResourceStr): ResourceStr {
    switch (reason) {
      case CloudBackupFailureReason.NOT_READY: return $r('app.string.cloud_backup_not_ready');
      case CloudBackupFailureReason.NOT_SIGNED_IN: return $r('app.string.cloud_backup_login_required');
      case CloudBackupFailureReason.IDENTITY_UNAVAILABLE: return $r('app.string.cloud_backup_identity_unavailable');
      case CloudBackupFailureReason.BUSY: return $r('app.string.cloud_backup_operation_busy');
      case CloudBackupFailureReason.CLEANUP_PENDING: return $r('app.string.cloud_backup_cleanup_pending');
      case CloudBackupFailureReason.INVALID_TARGET: return $r('app.string.cloud_backup_invalid_target');
      case CloudBackupFailureReason.READ_FAILED: return $r('app.string.cloud_backup_read_failed');
      case CloudBackupFailureReason.WRITE_FAILED: return $r('app.string.cloud_backup_write_failed');
      case CloudBackupFailureReason.FORMAT_INVALID: return $r('app.string.cloud_backup_metadata_invalid');
      case CloudBackupFailureReason.DECRYPT_FAILED: return $r('app.string.cloud_backup_decrypt_failed');
      case CloudBackupFailureReason.DELETE_FAILED: return $r('app.string.cloud_backup_delete_failed');
      case CloudBackupFailureReason.ICON_FAILED: return $r('app.string.cloud_backup_icon_failed');
      case CloudBackupFailureReason.SYNC_FAILED: return $r('app.string.cloud_backup_sync_submit_failed');
      case CloudBackupFailureReason.POST_VERIFY_FAILED: return $r('app.string.cloud_backup_failure_reason_post_verify');
      default: return fallback;
    }
  }
}

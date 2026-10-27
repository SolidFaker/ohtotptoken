import { AppStorageV2 } from '@kit.ArkUI';
import { HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import {
  AppPreference, AppWindowInfo, CloudBackupActionResult, CloudBackupDiagnostics, CloudBackupFailureReason,
  CloudBackupIdentityStatus, CloudBackupManager, CloudBackupMetadataStatus, CloudBackupRecord,
  CommonConstants, DeviceInfoHelper, DiagnosticKind, DiagnosticReason, DiagnosticResult, DiagnosticStage,
  DiagnosticUiAction, dialogSystemMaterial, PREF_KEYS, showSnackBar, SnackBarNotifyType
} from 'common';
import { MaterialSheetStyle } from '../components/MaterialSheetStyle';
import { MaterialTheme } from '../components/MaterialTheme';
import { PageScaffold } from '../components/PageScaffold';
import { SettingItem } from '../components/SettingItem';

@Entry
@Preview
@ComponentV2
export struct ShowCloudBackupHistoryPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param inMaterialSheet: boolean = false;
  /** 作为历史面板栈根时隐藏返回箭头，系统返回改为关闭面板而非弹出空栈。 */
  @Param sheetRoot: boolean = false;
  @Event onCloseSheet: () => void = () => {};
  @Local backupRecords: CloudBackupRecord[] = [];
  @Local isLoading: boolean = false;
  @Local isActionRunning: boolean = false;
  @Local serviceBusy: boolean = false;
  @Local cleanupPending: boolean = false;
  @Local isRetryingCleanup: boolean = false;
  @Local needsSyncRetry: boolean = false;
  @Local confirmationOpen: boolean = false;
  @Local isDetailVisible: boolean = false;
  @Local selectedRecord: CloudBackupRecord | null = null;
  @Local historyLoaded: boolean = false;
  @Local historyError: ResourceStr = '';
  @Local actionMessage: ResourceStr = '';
  @Local currentDeviceId: string = '';
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private backupManager: CloudBackupManager = CloudBackupManager.getInstance();
  private scroller: Scroller = new Scroller();
  private statePollTimer: number = -1;
  private isMounted: boolean = false;

  aboutToAppear(): void {
    this.isMounted = true;
    this.currentDeviceId = DeviceInfoHelper.getInstance().getDeviceId().trim();
    this.refreshOperationState();
    this.statePollTimer = setInterval(() => this.refreshOperationState(), 1000) as number;
    this.loadBackupHistory();
  }

  aboutToDisappear(): void {
    this.isMounted = false;
    this.confirmationOpen = false;
    if (this.statePollTimer >= 0) {
      clearInterval(this.statePollTimer);
      this.statePollTimer = -1;
    }
  }

  private refreshOperationState(): void {
    this.serviceBusy = this.backupManager.isBusy();
    this.cleanupPending = this.backupManager.isCleanupPending();
  }

  private interactionBlocked(): boolean {
    return this.isLoading || this.isActionRunning || this.isRetryingCleanup || this.confirmationOpen ||
      this.serviceBusy || this.cleanupPending;
  }

  private canStartAction(): boolean {
    this.refreshOperationState();
    if (!this.isMounted || this.interactionBlocked()) {
      return false;
    }
    return true;
  }

  /** 管理器持有缓存和 TaskPool 的同一许可，并在主线程消费有界诊断摘要。 */
  private async loadBackupHistory(): Promise<void> {
    if (!this.canStartAction()) {
      return;
    }
    this.isLoading = true;
    this.historyError = '';
    try {
      const result = await this.backupManager.listBackupHistoryResult();
      if (!this.isMounted) {
        return;
      }
      if (result.success) {
        this.currentDeviceId = DeviceInfoHelper.getInstance().getDeviceId().trim();
        this.historyLoaded = true;
        this.backupRecords = result.records;
        if (this.selectedRecord !== null) {
          const selectedId = this.selectedRecord.id;
          this.selectedRecord = this.backupRecords.find((record: CloudBackupRecord) => record.id === selectedId) ?? null;
          if (this.selectedRecord === null) {
            this.isDetailVisible = false;
          }
        }
      } else {
        // 读取失败保留上一次列表，不能用空列表冒充“没有备份”。
        this.historyError = this.failureText(result.reason, $r('app.string.cloud_backup_history_load_failed'));
      }
    } catch (_) {
      if (this.isMounted) {
        this.historyError = $r('app.string.cloud_backup_history_load_failed');
      }
    } finally {
      this.isLoading = false;
      this.refreshOperationState();
    }
  }

  private hasKnownSource(record: CloudBackupRecord): boolean {
    return record.metadataStatus === CloudBackupMetadataStatus.VALID &&
      record.identityStatus !== CloudBackupIdentityStatus.ID_MISSING &&
      record.deviceId.trim() !== '' && record.deviceId.trim() !== 'unknown_odid';
  }

  private isCurrentDevice(record: CloudBackupRecord): boolean {
    return this.currentDeviceId !== '' && this.currentDeviceId !== 'unknown_odid' &&
      this.hasKnownSource(record) && record.deviceId === this.currentDeviceId;
  }

  private getDeviceRecords(): CloudBackupRecord[] {
    return this.backupRecords.filter((record: CloudBackupRecord) => this.isCurrentDevice(record));
  }

  private getOtherDeviceRecords(): CloudBackupRecord[] {
    return this.backupRecords.filter((record: CloudBackupRecord) => !this.isCurrentDevice(record) && this.hasKnownSource(record));
  }

  private getUnknownSourceRecords(): CloudBackupRecord[] {
    return this.backupRecords.filter((record: CloudBackupRecord) => !this.hasKnownSource(record));
  }

  private sourceText(record: CloudBackupRecord): ResourceStr {
    if (!this.hasKnownSource(record)) {
      return $r('app.string.cloud_backup_source_unknown');
    }
    return this.isCurrentDevice(record) ? $r('app.string.cloud_backup_this_device') :
      $r('app.string.cloud_backup_source_other');
  }

  private deviceNameText(record: CloudBackupRecord): ResourceStr {
    if (record.metadataStatus !== CloudBackupMetadataStatus.VALID) {
      return $r('app.string.cloud_backup_unknown_device');
    }
    return record.deviceName.trim() !== '' ? record.deviceName : $r('app.string.cloud_backup_name_missing');
  }

  private metadataText(record: CloudBackupRecord): ResourceStr {
    switch (record.metadataStatus) {
      case CloudBackupMetadataStatus.VALID:
        return $r('app.string.cloud_backup_metadata_valid');
      case CloudBackupMetadataStatus.PENDING:
        return $r('app.string.cloud_backup_metadata_pending');
      case CloudBackupMetadataStatus.READ_FAILED:
        return $r('app.string.cloud_backup_metadata_read_failed');
      case CloudBackupMetadataStatus.INVALID:
        return $r('app.string.cloud_backup_metadata_invalid');
      default:
        return $r('app.string.cloud_backup_metadata_unknown');
    }
  }

  private locationText(record: CloudBackupRecord): ResourceStr {
    switch (record.location) {
      case 1:
        return $r('app.string.cloud_backup_location_local');
      case 2:
        return $r('app.string.cloud_sync_status_cloud_only');
      case 3:
        return $r('app.string.cloud_backup_location_both');
      default:
        return $r('app.string.cloud_backup_location_unknown');
    }
  }

  private tokenCountText(record: CloudBackupRecord): ResourceStr {
    return record.metadataStatus === CloudBackupMetadataStatus.VALID && record.tokenCountKnown === true &&
      Number.isInteger(record.tokenCount) && record.tokenCount >= 0 ?
      $r('app.string.cloud_backup_record_tokens', record.tokenCount) : $r('app.string.cloud_backup_count_unknown');
  }

  private sizeText(record: CloudBackupRecord): ResourceStr {
    if (!Number.isFinite(record.size) || record.size < 0) {
      return $r('app.string.cloud_backup_value_unknown');
    }
    return record.size < 1024 ? `${record.size} B` : `${(record.size / 1024).toFixed(1)} KB`;
  }

  private recordDateText(record: CloudBackupRecord): ResourceStr {
    return record.date.trim() !== '' ? record.date : $r('app.string.cloud_backup_value_unknown');
  }

  private isEnumerated(record: CloudBackupRecord): boolean {
    return this.backupRecords.some((item: CloudBackupRecord) => item.id === record.id);
  }

  private canRestore(record: CloudBackupRecord): boolean {
    return this.isEnumerated(record) && record.metadataStatus === CloudBackupMetadataStatus.VALID;
  }

  private openDetail(record: CloudBackupRecord): void {
    if (!this.canStartAction() || !this.isEnumerated(record)) {
      return;
    }
    this.selectedRecord = record;
    this.actionMessage = '';
    this.isDetailVisible = true;
  }

  private detailSheetOptions(): SheetOptions {
    const options = MaterialSheetStyle.options(SheetSize.MEDIUM);
    options.backgroundColor = $r('app.color.window_background');
    options.detents = [SheetSize.MEDIUM, SheetSize.LARGE];
    return options;
  }

  private pageBackground(): ResourceColor {
    return this.inMaterialSheet ? MaterialTheme.surfaceBackground($r('app.color.window_background')) :
      $r('app.color.window_background');
  }

  build() {
    HdsNavDestination() {
      PageScaffold({ bgColor: this.pageBackground() }) {
        List({ space: 12, scroller: this.scroller }) {
          ListItem().height(CommonConstants.AVOID_TOP_BASE_HEIGHT)
          ListItem() {
            Column({ space: 12 }) {
              if (this.isLoading || this.isActionRunning || this.isRetryingCleanup) {
                LoadingProgress().width(36).height(36).color($r('app.color.str_main'))
                Text($r('app.string.cloud_backup_operation_running'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2'))
                  .fontColor($r('sys.color.font_secondary'))
              }
              if (this.cleanupPending) {
                this.CleanupPendingContent()
              } else if (this.serviceBusy && !this.isLoading && !this.isActionRunning) {
                Text($r('app.string.cloud_backup_operation_busy'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2'))
                  .fontColor($r('sys.color.font_secondary'))
              }
              if (this.historyError !== '') {
                Text(this.historyError)
                  .fontSize($r('sys.float.ohos_id_text_size_body2'))
                  .fontColor($r('sys.color.ohos_id_color_warning'))
              }
              if (!this.isDetailVisible && this.actionMessage !== '') {
                Text(this.actionMessage)
                  .fontSize($r('sys.float.ohos_id_text_size_body2'))
                  .fontColor($r('sys.color.font_secondary'))
              }
              if (this.needsSyncRetry && !this.cleanupPending) {
                Button($r('app.string.cloud_backup_retry_sync'))
                  .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%')
                  .enabled(!this.interactionBlocked())
                  .onClick(() => this.retrySync())
              }
              Button($r('app.string.cloud_backup_refresh'))
                .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%')
                .enabled(!this.interactionBlocked())
                .onClick(() => this.loadBackupHistory())
            }
            .width('100%')
          }
          if (this.historyLoaded && this.backupRecords.length === 0 && !this.isLoading && this.historyError === '') {
            ListItem() {
              Text($r('app.string.cloud_backup_history_empty'))
                .fontSize($r('sys.float.ohos_id_text_size_body1'))
                .fontColor($r('sys.color.font_secondary'))
                .width('100%').textAlign(TextAlign.Center).padding(24)
            }
          }
          if (this.getDeviceRecords().length > 0) {
            ListItem() { this.GroupTitle($r('app.string.cloud_backup_this_device')) }
            ForEach(this.getDeviceRecords(), (record: CloudBackupRecord) => {
              ListItem() { this.BackupRecordItem(record) }
            }, (record: CloudBackupRecord) => record.id)
          }
          if (this.getOtherDeviceRecords().length > 0) {
            ListItem() { this.GroupTitle($r('app.string.cloud_backup_other_devices')) }
            ForEach(this.getOtherDeviceRecords(), (record: CloudBackupRecord) => {
              ListItem() { this.BackupRecordItem(record) }
            }, (record: CloudBackupRecord) => record.id)
          }
          if (this.getUnknownSourceRecords().length > 0) {
            ListItem() { this.GroupTitle($r('app.string.cloud_backup_source_unknown')) }
            ForEach(this.getUnknownSourceRecords(), (record: CloudBackupRecord) => {
              ListItem() { this.BackupRecordItem(record) }
            }, (record: CloudBackupRecord) => record.id)
            ListItem() {
              Column({ space: 8 }) {
                Text($r('app.string.cloud_backup_unknown_cleanup_hint'))
                  .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary')).width('100%')
                Button($r('app.string.cloud_backup_unknown_cleanup_entry'))
                  .fontColor($r('sys.color.ohos_id_color_warning')).backgroundColor($r('sys.color.comp_background_gray'))
                  .width('100%').labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 })
                  .enabled(!this.interactionBlocked())
                  .onClick(() => this.showUnknownCleanupConfirmDialog())
              }
              .width('100%')
            }
          }
          ListItem() {
            Column({ space: 8 }) {
              Text($r('app.string.cloud_backup_history_max_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
              Text($r('app.string.cloud_sync_device_id_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
              Text($r('app.string.cloud_backup_location_hint'))
                .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
            }
            .alignItems(HorizontalAlign.Start).width('100%').padding({ top: 12, bottom: 16 })
          }
        }
        .chainAnimation(AppPreference.getPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE) as boolean)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .scrollBar(BarState.Off)
        .backgroundColor(this.pageBackground())
        .width('100%').height('100%')
        .padding({ left: 16, right: 16 })
        .contentEndOffset(this.window.AvoidBottomHeight + 16)
      }
    }
    .backgroundColor(this.pageBackground())
    .bindSheet($$this.isDetailVisible, this.BackupDetailSheet(), this.detailSheetOptions())
    .bindToScrollable([this.scroller])
    .hideBackButton(this.sheetRoot)
    .onBackPressed(() => {
      if (!this.sheetRoot) { return false; }
      this.onCloseSheet();
      return true;
    })
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    .titleBar({
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            backIconStyle: MaterialTheme.navigationIconStyle(),
            menuStyle: MaterialTheme.navigationIconStyle()
          }
        },
        scrollEffectStyle: MaterialTheme.navigationScrollStyle(),
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectType },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: MaterialTheme.hdsMaterialLevel()
        }
      },
      content: { title: { mainTitle: $r('app.string.cloud_backup_history_title') } }
    })
  }

  @Builder
  GroupTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
      .fontColor($r('sys.color.font_secondary')).fontWeight(FontWeight.Medium)
      .width('100%').padding({ left: 8, top: 8, bottom: 2 })
  }

  /** 整张卡片打开详情，不用小图标承担恢复或危险操作。 */
  @Builder
  BackupRecordItem(record: CloudBackupRecord) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 8 }) {
        Text(this.recordDateText(record))
          .fontSize($r('sys.float.ohos_id_text_size_body1')).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(this.deviceNameText(record))
          .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
        Text(this.metadataText(record))
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor(record.metadataStatus === CloudBackupMetadataStatus.INVALID ?
            $r('sys.color.ohos_id_color_warning') : $r('sys.color.font_secondary'))
        Text(this.tokenCountText(record))
          .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
        Text(this.locationText(record))
          .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
        Text($r('app.string.cloud_backup_view_details'))
          .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('app.color.str_main'))
      }
      .width('100%').alignItems(HorizontalAlign.Start).padding(16)
    }
    .width('100%').backgroundColor($r('app.color.item_bg'))
    .borderRadius($r('sys.float.ohos_id_menu_outer_border_radius'))
    .shadow({ radius: 6, color: $r('app.color.shadow'), offsetX: 0, offsetY: 2 })
    .enabled(!this.interactionBlocked())
    .onClick(() => this.openDetail(record))
  }

  @Builder
  DetailValue(label: ResourceStr, value: ResourceStr) {
    Column({ space: 4 }) {
      Text(label).fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
      Text(value).fontSize($r('sys.float.ohos_id_text_size_body1')).fontColor($r('sys.color.font_primary'))
    }
    .alignItems(HorizontalAlign.Start).width('100%').padding(12)
  }

  @Builder
  CleanupPendingContent() {
    Column({ space: 12 }) {
      Text($r('app.string.cloud_backup_cleanup_pending'))
        .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.ohos_id_color_warning'))
      Button($r('app.string.cloud_backup_retry_cleanup'))
        .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%')
        .enabled(!this.isLoading && !this.isActionRunning && !this.isRetryingCleanup && !this.confirmationOpen)
        .onClick(() => this.retryCleanup())
    }
    .width('100%')
  }

  @Builder
  BackupDetailSheet() {
    Scroll() {
      Column({ space: 16 }) {
        Text($r('app.string.cloud_backup_detail_title'))
          .fontSize($r('sys.float.Subtitle_M')).fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary')).width('100%')
        if (this.selectedRecord !== null) {
          SettingItem({ title: $r('app.string.cloud_backup_detail_metadata') }) {
            this.DetailValue($r('app.string.cloud_backup_detail_date'), this.recordDateText(this.selectedRecord))
            this.DetailValue($r('app.string.cloud_backup_detail_source'), this.sourceText(this.selectedRecord))
            this.DetailValue($r('app.string.cloud_backup_detail_device'), this.deviceNameText(this.selectedRecord))
            this.DetailValue($r('app.string.cloud_backup_detail_content'), this.metadataText(this.selectedRecord))
            this.DetailValue($r('app.string.cloud_backup_detail_location'), this.locationText(this.selectedRecord))
            this.DetailValue($r('app.string.cloud_backup_detail_size'), this.sizeText(this.selectedRecord))
            this.DetailValue($r('app.string.cloud_sync_token_count'), this.tokenCountText(this.selectedRecord))
          }
          Text($r('app.string.cloud_backup_detail_privacy_hint'))
            .fontSize($r('sys.float.ohos_id_text_size_caption')).fontColor($r('sys.color.font_secondary'))
            .width('100%')
          if (this.actionMessage !== '') {
            Text(this.actionMessage)
              .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary')).width('100%')
          }
          if (this.isActionRunning || this.isLoading || this.isRetryingCleanup) {
            LoadingProgress().width(36).height(36)
            Text($r('app.string.cloud_backup_operation_running'))
              .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary'))
          }
          if (this.cleanupPending) {
            this.CleanupPendingContent()
          }
          Button($r('app.string.cloud_backup_restore_confirm_title'))
            .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%')
            .enabled(!this.interactionBlocked() && this.canRestore(this.selectedRecord))
            .onClick(() => {
              if (this.selectedRecord !== null) { this.showRestoreConfirmDialog(this.selectedRecord); }
            })
          if (this.selectedRecord.metadataStatus !== CloudBackupMetadataStatus.VALID) {
            Text($r('app.string.cloud_backup_restore_requires_metadata'))
              .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary')).width('100%')
            Button($r('app.string.cloud_backup_refresh'))
              .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%').enabled(!this.interactionBlocked())
              .onClick(() => this.loadBackupHistory())
          }
          SettingItem({ title: $r('app.string.cloud_backup_danger_zone') }) {
            Column({ space: 12 }) {
              Text($r('app.string.cloud_backup_delete_local_unaffected'))
                .fontSize($r('sys.float.ohos_id_text_size_body2')).fontColor($r('sys.color.font_secondary')).width('100%')
              Button($r('app.string.cloud_backup_delete_confirm_title'))
                .fontColor($r('sys.color.ohos_id_color_warning')).backgroundColor($r('sys.color.comp_background_gray'))
                .labelStyle({ maxLines: 4 }).constraintSize({ minHeight: 48 }).width('100%')
                .enabled(!this.interactionBlocked())
                .onClick(() => {
                  if (this.selectedRecord !== null) { this.showDeleteConfirmDialog(this.selectedRecord); }
                })
            }
            .padding(16).width('100%')
          }
        }
      }
      .padding({ left: 20, right: 20, top: 20, bottom: this.window.AvoidBottomHeight + 24 })
      .width('100%').alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%').scrollBar(BarState.Off)
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }

  private selectionStillValid(record: CloudBackupRecord): boolean {
    return this.isMounted && this.isDetailVisible && this.selectedRecord?.id === record.id && this.isEnumerated(record);
  }

  private showRestoreConfirmDialog(record: CloudBackupRecord): void {
    if (!this.canStartAction() || !this.selectionStillValid(record) || !this.canRestore(record)) {
      return;
    }
    // 空备份（0 令牌）恢复是合法操作但不产生任何令牌，确认框改用警示文案与警示色。
    const emptyBackup = record.tokenCountKnown === true && record.tokenCount === 0;
    this.confirmationOpen = true;
    try {
      this.getUIContext().showAlertDialog({
        systemMaterial: dialogSystemMaterial(),
        title: $r('app.string.cloud_backup_restore_confirm_title'),
        message: emptyBackup ? $r('app.string.cloud_backup_restore_empty_msg') :
          $r('app.string.cloud_backup_restore_confirm_msg', record.date),
        autoCancel: true, alignment: DialogAlignment.Bottom, gridCount: 4,
        offset: { dx: 0, dy: -20 }, buttonDirection: DialogButtonDirection.VERTICAL,
        buttons: [
          { value: $r('app.string.cloud_backup_restore_confirm_title'),
            fontColor: emptyBackup ? $r('sys.color.ohos_id_color_warning') : $r('sys.color.font_emphasize'),
            action: () => {
              this.confirmationOpen = false;
              if (this.selectionStillValid(record) && this.canRestore(record)) { this.triggerRestore(record); }
            } },
          { value: $r('app.string.dialog_btn_cancel'), action: () => { this.confirmationOpen = false; } }
        ],
        cancel: () => { this.confirmationOpen = false; }
      });
    } catch (_) {
      this.confirmationOpen = false;
      showSnackBar($r('app.string.cloud_backup_restore_failed'), SnackBarNotifyType.WARNING);
    }
  }

  private showDeleteConfirmDialog(record: CloudBackupRecord): void {
    if (!this.canStartAction() || !this.selectionStillValid(record)) {
      return;
    }
    const message = !this.hasKnownSource(record) ? $r('app.string.cloud_backup_delete_unknown_confirm', record.date) :
      this.isCurrentDevice(record) ? $r('app.string.cloud_backup_delete_confirm_msg', record.date) :
        $r('app.string.cloud_backup_delete_other_confirm', record.date);
    this.confirmationOpen = true;
    try {
      this.getUIContext().showAlertDialog({
        systemMaterial: dialogSystemMaterial(),
        title: $r('app.string.cloud_backup_delete_confirm_title'), message: message,
        autoCancel: true, alignment: DialogAlignment.Bottom, gridCount: 4,
        offset: { dx: 0, dy: -20 }, buttonDirection: DialogButtonDirection.VERTICAL,
        buttons: [
          { value: $r('app.string.cloud_backup_delete_confirm_title'), fontColor: $r('sys.color.ohos_id_color_warning'),
            action: () => {
              this.confirmationOpen = false;
              if (this.selectionStillValid(record)) { this.triggerDelete(record); }
            } },
          { value: $r('app.string.dialog_btn_cancel'), action: () => { this.confirmationOpen = false; } }
        ],
        cancel: () => { this.confirmationOpen = false; }
      });
    } catch (_) {
      this.confirmationOpen = false;
      showSnackBar($r('app.string.cloud_backup_delete_failed'), SnackBarNotifyType.WARNING);
    }
  }

  /** 聚合清理入口的二次确认：明确范围为"来源未确认"记录，本地令牌不受影响。 */
  private showUnknownCleanupConfirmDialog(): void {
    if (!this.canStartAction()) {
      return;
    }
    const targets = this.getUnknownSourceRecords();
    if (targets.length === 0) {
      return;
    }
    this.confirmationOpen = true;
    try {
      this.getUIContext().showAlertDialog({
        systemMaterial: dialogSystemMaterial(),
        title: $r('app.string.cloud_backup_unknown_cleanup_entry'),
        message: $r('app.string.cloud_backup_unknown_cleanup_confirm', targets.length),
        autoCancel: true, alignment: DialogAlignment.Bottom, gridCount: 4,
        offset: { dx: 0, dy: -20 }, buttonDirection: DialogButtonDirection.VERTICAL,
        buttons: [
          { value: $r('app.string.cloud_backup_unknown_cleanup_entry'), fontColor: $r('sys.color.ohos_id_color_warning'),
            action: () => {
              this.confirmationOpen = false;
              this.triggerUnknownSourceCleanup(targets);
            } },
          { value: $r('app.string.dialog_btn_cancel'), action: () => { this.confirmationOpen = false; } }
        ],
        cancel: () => { this.confirmationOpen = false; }
      });
    } catch (_) {
      this.confirmationOpen = false;
      showSnackBar($r('app.string.cloud_backup_delete_failed'), SnackBarNotifyType.WARNING);
    }
  }

  /** 本地删除与同步提交分别汇总；已删除项立即移除，失败项保留，同步重试不重删。 */
  private async triggerUnknownSourceCleanup(targets: CloudBackupRecord[]): Promise<void> {
    const context = CloudBackupDiagnostics.begin(DiagnosticKind.UI);
    CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_ACTION, DiagnosticResult.BEGIN,
      { uiAction: DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP });
    let deleted = 0;
    let failed = 0;
    let syncRejected = false;
    let syncSubmitted = false;
    try {
      if (!this.canStartAction() || targets.length === 0) {
        CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_RESULT, DiagnosticResult.BLOCKED,
          { uiAction: DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP, reason: DiagnosticReason.UNAVAILABLE });
        return;
      }
      this.isActionRunning = true;
      try {
        for (const record of targets) {
          const result = await this.backupManager.deleteBackupRecordResult(record.id);
          if (!this.isMounted) {
            CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_RESULT, DiagnosticResult.CANCELLED,
              { uiAction: DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP, reason: DiagnosticReason.CANCELLED });
            return;
          }
          if (result.syncStartAccepted) {
            syncSubmitted = true;
            if (!syncRejected) { this.needsSyncRetry = false; }
          } else if (result.localComplete || result.partialFailure || result.reason === CloudBackupFailureReason.SYNC_FAILED) {
            syncRejected = true;
            this.needsSyncRetry = true;
          }
          if (result.localComplete || result.success) {
            deleted++;
            // 后续删除或历史刷新失败不能让已删除记录继续可恢复。
            this.backupRecords = this.backupRecords.filter((item: CloudBackupRecord) => item.id !== record.id);
            if (this.selectedRecord?.id === record.id) {
              this.selectedRecord = null;
              this.isDetailVisible = false;
            }
          } else {
            failed++;
          }
        }
      } catch (_) {
        // 未完成及尚未尝试的项目仍在列表中，不伪称已经删除。
        failed = targets.length - deleted;
      } finally {
        this.isActionRunning = false;
        this.refreshOperationState();
      }
      if (!this.isMounted) { return; }
      this.actionMessage = syncRejected ?
        $r('app.string.cloud_backup_unknown_cleanup_sync_failed', deleted, failed) : syncSubmitted ?
          $r('app.string.cloud_backup_unknown_cleanup_sync_pending', deleted, failed) :
          $r('app.string.cloud_backup_unknown_cleanup_done', deleted, failed);
      showSnackBar(this.actionMessage, failed > 0 || syncRejected || syncSubmitted ?
        SnackBarNotifyType.WARNING : SnackBarNotifyType.SUCCESS);
      CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_RESULT, failed > 0 || syncRejected ?
        DiagnosticResult.FAIL : syncSubmitted ? DiagnosticResult.PENDING : DiagnosticResult.OK,
        { uiAction: DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP,
          reason: syncRejected ? DiagnosticReason.SYNC_REJECTED : failed > 0 ? DiagnosticReason.PARTIAL_FAILURE : DiagnosticReason.NONE,
          partialFailure: failed > 0, syncStartAccepted: syncSubmitted && !syncRejected });
      if (deleted > 0) {
        await this.loadBackupHistory();
        if (this.isMounted) {
          CloudBackupDiagnostics.mark(context, DiagnosticStage.UI_REFRESH, this.historyError !== '' ?
            DiagnosticResult.FAIL : this.serviceBusy || this.cleanupPending ? DiagnosticResult.PENDING : DiagnosticResult.OK,
            { uiAction: DiagnosticUiAction.UNKNOWN_SOURCE_CLEANUP,
              reason: this.historyError !== '' ? DiagnosticReason.UNAVAILABLE : DiagnosticReason.NONE });
        }
      }
    } finally {
      CloudBackupDiagnostics.end(context);
    }
  }

  private async triggerRestore(record: CloudBackupRecord): Promise<void> {
    if (!this.canStartAction() || !this.selectionStillValid(record) || !this.canRestore(record)) {
      return;
    }
    this.isActionRunning = true;
    try {
      const result = await this.backupManager.restoreFromBackupRecordResult(record.id);
      if (!this.isMounted) { return; }
      this.actionMessage = result.success ?
        $r('app.string.cloud_backup_restore_success_count', result.restoredCount) :
        this.actionFailureText(result, $r('app.string.cloud_backup_restore_failed'));
      showSnackBar(this.actionMessage, result.success ? SnackBarNotifyType.SUCCESS : SnackBarNotifyType.WARNING);
      if (result.success) {
        this.isDetailVisible = false;
      } else if (result.reason === CloudBackupFailureReason.FORMAT_INVALID) {
        // 仅确定的格式/完整性失败禁用恢复；DECRYPT_FAILED 保留有效元数据及重试入口。
        const invalidRecord: CloudBackupRecord = {
          id: record.id, date: record.date, timestamp: record.timestamp, tokenCount: record.tokenCount,
          size: record.size, encrypted: record.encrypted, deviceId: record.deviceId, deviceName: record.deviceName,
          location: record.location, metadataStatus: CloudBackupMetadataStatus.INVALID,
          identityStatus: record.identityStatus, tokenCountKnown: false
        };
        this.backupRecords = this.backupRecords.map((item: CloudBackupRecord) => item.id === record.id ? invalidRecord : item);
        if (this.selectedRecord?.id === record.id) { this.selectedRecord = invalidRecord; }
      }
    } catch (_) {
      if (this.isMounted) {
        this.actionMessage = $r('app.string.cloud_backup_restore_failed');
        showSnackBar(this.actionMessage, SnackBarNotifyType.WARNING);
      }
    } finally {
      this.isActionRunning = false;
      this.refreshOperationState();
    }
  }

  private async triggerDelete(record: CloudBackupRecord): Promise<void> {
    if (!this.canStartAction() || !this.selectionStillValid(record)) {
      return;
    }
    this.isActionRunning = true;
    let shouldRefresh = false;
    try {
      const result = await this.backupManager.deleteBackupRecordResult(record.id);
      if (!this.isMounted) { return; }
      if (result.syncStartAccepted) {
        this.needsSyncRetry = false;
      } else if (result.localComplete || result.partialFailure) {
        this.needsSyncRetry = true;
      }
      this.actionMessage = result.success ? $r('app.string.cloud_backup_delete_success') :
        this.actionFailureText(result, $r('app.string.cloud_backup_delete_failed'));
      showSnackBar(this.actionMessage, result.success ? SnackBarNotifyType.SUCCESS : SnackBarNotifyType.WARNING);
      if (result.localComplete || result.success) {
        // 本地删除完成后不保留可恢复的过期记录；同步重试只提交同步，不重新执行删除。
        this.backupRecords = this.backupRecords.filter((item: CloudBackupRecord) => item.id !== record.id);
        this.selectedRecord = null;
        this.isDetailVisible = false;
        shouldRefresh = true;
      }
    } catch (_) {
      if (this.isMounted) {
        this.actionMessage = $r('app.string.cloud_backup_delete_failed');
        showSnackBar(this.actionMessage, SnackBarNotifyType.WARNING);
      }
    } finally {
      this.isActionRunning = false;
      this.refreshOperationState();
    }
    if (shouldRefresh && this.isMounted) { await this.loadBackupHistory(); }
  }

  private async retryCleanup(): Promise<void> {
    if (!this.isMounted || this.isLoading || this.isActionRunning || this.isRetryingCleanup || this.confirmationOpen) {
      return;
    }
    this.isRetryingCleanup = true;
    try {
      const drained = await this.backupManager.retryPendingCleanup();
      this.actionMessage = drained ? $r('app.string.cloud_backup_cleanup_ready') : $r('app.string.cloud_backup_cleanup_pending');
    } catch (_) {
      this.actionMessage = $r('app.string.cloud_backup_cleanup_pending');
    } finally {
      this.isRetryingCleanup = false;
      this.refreshOperationState();
    }
    // 不自动重放原备份/恢复/删除；用户在确认安全结束后显式选择下一步。
  }

  private async retrySync(): Promise<void> {
    if (!this.canStartAction() || !this.needsSyncRetry) { return; }
    this.isActionRunning = true;
    try {
      const accepted = await this.backupManager.retrySync();
      this.needsSyncRetry = !accepted;
      this.actionMessage = accepted ? $r('app.string.cloud_backup_sync_pending') : $r('app.string.cloud_backup_sync_submit_failed');
    } catch (_) {
      this.actionMessage = $r('app.string.cloud_backup_sync_submit_failed');
    } finally {
      this.isActionRunning = false;
      this.refreshOperationState();
    }
  }

  private actionFailureText(result: CloudBackupActionResult, fallback: ResourceStr): ResourceStr {
    if (result.reason === CloudBackupFailureReason.CLEANUP_PENDING || result.reason === CloudBackupFailureReason.BUSY) {
      return this.failureText(result.reason, fallback);
    }
    if (result.partialFailure) { return $r('app.string.cloud_backup_partial_failure'); }
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
      default: return fallback;
    }
  }
}

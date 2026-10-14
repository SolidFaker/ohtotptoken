import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageV2, LengthMetrics, promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import {
  AppPreference, AppWindowInfo, convertToken2URI, dialogSystemMaterial, encodeLocalBackup, generateFileNameWithDate,
  HuaweiAccountManager, LocalBackupError, LocalBackupFailure, LocalBackupFileIo, LocalBackupKind, LocalBackupSource,
  otpType, PREF_KEYS, readLocalBackupSource, ROUTE_NAMES, showSaveFilePicker, showSelectFilePicker, showSnackBar,
  SnackBarNotifyType, TokenBackup, TokenConfig, TokenImporter, TokenImporterRegistry
} from 'common';
import { SubItemButton } from '../../components/SubItemButton';
import { SubItemToggle } from '../../components/SubItemToggle';
import { SettingItem } from '../../components/SettingItem';
import { SubItemDivider } from '../../components/SubItemDivider';
import { EncryptionPassWordDialog } from '../../dialogs/EncryptionPassWordDialog';
import { commitPreparedBackup, TokenImportHandler } from '../../utils/BackupImportOperation';
import { TokenBatchOperation } from '../../utils/TokenBatchOperation';
import { isLocalBackupMenuCancellation, LocalBackupFlow, LocalBackupStage } from '../../utils/LocalBackupFlow';
import { TokenProgressDialog, TokenProgressDialogParams } from '../../dialogs/TokenProgressDialog';
// [冷启动优化] 云面板及配置延迟到备份页面首次构建，避免冷启动加载。
import lazy { CloudBackupDetailsSheet, cloudBackupDetailsSheetOptions } from './CloudBackupDetailsSheet';
import { UriImportSheet } from './UriImportSheet';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';
import { MaterialTheme } from '../../components/MaterialTheme';

@Preview
@ComponentV2
export struct BackupAndMigrationSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param Tokens: Array<TokenConfig> = [];
  @Require @Param scrollEffectStyle: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Param hostActive: boolean = true;
  @Event backupReload: TokenImportHandler = async () => {};
  @Event onUriImportVisibilityChange: (visible: boolean) => void = () => {};
  @Event onLocalExecutionChange: (executing: boolean) => void = () => {};

  @Local versionCode?: number;
  @Local cloudBackupEnabled: boolean = false;
  @Local cloudDetailsVisible: boolean = false;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local importers: TokenImporter[] = [];
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local flow: LocalBackupFlow = new LocalBackupFlow((executing: boolean) => {
    this.onLocalExecutionChange(executing);
    if (this.flow.stage === LocalBackupStage.IDLE) { this.clearSensitiveReferences(); }
  });
  private sheetScroller: Scroller = new Scroller();
  private exportSnapshot: TokenBackup | undefined;
  private source: LocalBackupSource | undefined;
  private encodedExport: string = '';
  private passwordDialogId: number | undefined;
  private afterPasswordClosed: (() => void) | undefined;

  aboutToAppear(): void {
    this.flow.activate();
    this.versionCode = AppStorage.get<bundleManager.BundleInfo>('BundleInfo')?.versionCode;
    this.cloudBackupEnabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
    this.isHuaweiLoggedIn = HuaweiAccountManager.getInstance().userLogin;
    const registry = TokenImporterRegistry.getInstance();
    registry.init();
    this.importers = registry.getAll();
  }

  @Monitor('hostActive')
  onHostActiveChanged(): void {
    if (this.hostActive) { this.flow.activate(); }
    else {
      this.flow.invalidate();
      this.clearSensitiveReferences();
      this.closePasswordDialog();
    }
  }

  aboutToDisappear(): void {
    this.flow.invalidate();
    this.clearSensitiveReferences();
    this.closePasswordDialog();
  }

  private clearSensitiveReferences(): void {
    this.afterPasswordClosed = undefined;
    this.exportSnapshot = undefined;
    this.source?.dispose();
    this.source = undefined;
    this.encodedExport = '';
  }

  private closePasswordDialog(): void {
    const id = this.passwordDialogId;
    this.passwordDialogId = undefined;
    if (id !== undefined) {
      try { this.getUIContext().getPromptAction().closeCustomDialog(id); } catch (_) {}
    }
  }

  private finish(generation: number): void {
    if (!this.flow.isCurrent(generation)) { return; }
    this.clearSensitiveReferences();
    this.flow.finish(generation);
  }

  private cancel(generation: number): void {
    if (!this.flow.isCurrent(generation) || !this.flow.cancel()) { return; }
    this.clearSensitiveReferences();
  }

  private fail(generation: number, message: ResourceStr): void {
    if (!this.flow.isCurrent(generation)) { return; }
    showSnackBar(message, SnackBarNotifyType.ERROR);
    this.finish(generation);
  }

  private blocked(): boolean {
    return this.cloudDetailsVisible || this.flow.stage !== LocalBackupStage.IDLE || TokenBatchOperation.isBusy();
  }

  private pageBackground(): ResourceColor {
    return this.embedded ? $r('app.color.window_background') :
      MaterialTheme.surfaceBackground($r('app.color.window_background'));
  }

  private beginExport(): number | undefined {
    const generation = this.flow.begin();
    if (generation === undefined) { return undefined; }
    const exportable = this.Tokens.filter((token: TokenConfig): boolean => token.TokenType !== otpType.NFC_external);
    if (exportable.length === 0) {
      showSnackBar($r('app.string.toast_no_exportable_tokens'), SnackBarNotifyType.WARNING);
      this.finish(generation);
      return undefined;
    }
    try { this.exportSnapshot = new TokenBackup(this.versionCode ?? 0, exportable); } catch (_) {
      this.fail(generation, $r('app.string.local_backup_prepare_failed'));
      return undefined;
    }
    return generation;
  }

  private confirmStep(generation: number, title: ResourceStr, message: ResourceStr, action: ResourceStr,
    warning: boolean, confirmed: () => void): void {
    if (!this.flow.transition(generation, LocalBackupStage.CONFIRMING)) { return; }
    try {
      this.getUIContext().showAlertDialog({
        systemMaterial: dialogSystemMaterial(), title: title, message: message,
        autoCancel: true, alignment: DialogAlignment.Bottom, gridCount: 4,
        offset: { dx: 0, dy: -Math.max(20, this.window.AvoidBottomHeight) },
        buttonDirection: DialogButtonDirection.VERTICAL,
        buttons: [
          { value: action, fontColor: warning ? $r('sys.color.ohos_id_color_warning') : $r('sys.color.font_emphasize'),
            action: () => {
              if (this.flow.isCurrent(generation) && this.flow.stage === LocalBackupStage.CONFIRMING) { confirmed(); }
            } },
          { value: $r('app.string.dialog_btn_cancel'), action: () => this.cancel(generation) }
        ],
        cancel: () => this.cancel(generation)
      });
    } catch (_) { this.fail(generation, $r('app.string.local_backup_prepare_failed')); }
  }

  async callFilePickerSaveFile(): Promise<void> {
    const generation = this.beginExport();
    if (generation === undefined) { return; }
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        systemMaterial: dialogSystemMaterial(), title: $r('app.string.setting_backup_output'),
        buttons: [
          { text: $r('app.string.setting_backup_type_enc'), color: $r('sys.color.font_primary') },
          { text: $r('app.string.setting_backup_type_default'), color: $r('sys.color.font_primary') }
        ]
      }, (error: BusinessError, result: promptAction.ActionMenuSuccessResponse) => {
        if (!this.flow.isCurrent(generation) || this.flow.stage !== LocalBackupStage.CHOOSING) { return; }
        if (error) {
          if (isLocalBackupMenuCancellation(error)) { this.cancel(generation); }
          else { this.fail(generation, $r('app.string.local_backup_prepare_failed')); }
          return;
        }
        if (result.index < 0) { this.cancel(generation); return; }
        if (result.index === 0) { this.openPassword(generation, true); }
        else if (result.index === 1) {
          this.confirmStep(generation, $r('app.string.setting_backup_type_default'),
            $r('app.string.local_backup_plain_warning'), $r('app.string.local_backup_export_anyway'), true,
            () => { this.prepareExport(generation, false); });
        } else { this.cancel(generation); }
      });
    } catch (_) { this.fail(generation, $r('app.string.local_backup_prepare_failed')); }
  }

  async callFilePickerSaveMigrationFile(): Promise<void> {
    const generation = this.beginExport();
    if (generation === undefined) { return; }
    this.confirmStep(generation, $r('app.string.setting_migration_output'),
      $r('app.string.local_backup_migration_warning'), $r('app.string.local_backup_export_anyway'), true,
      () => { this.prepareExport(generation, true); });
  }

  private async prepareExport(generation: number, migration: boolean): Promise<void> {
    const backup = this.exportSnapshot;
    if (!this.flow.isCurrent(generation) || backup === undefined) { return; }
    try {
      await this.flow.progress(this, $r('app.string.local_backup_processing'), generation, false, async () => {
        const encoded = migration ? backup.configs.map((token: TokenConfig): string => convertToken2URI(token) + '\n').join('') :
          await encodeLocalBackup(backup);
        if (this.flow.isCurrent(generation)) { this.encodedExport = encoded; }
      });
      if (this.flow.isCurrent(generation)) {
        this.exportSnapshot = undefined;
        await this.savePreparedExport(generation, migration ? 'txt' : 'json');
      }
    } catch (_) { this.fail(generation, $r('app.string.local_backup_prepare_failed')); }
  }

  private async savePreparedExport(generation: number, extension: string): Promise<void> {
    if (!this.flow.transition(generation, LocalBackupStage.PICKING)) { return; }
    let uris: string[];
    try {
      const name = extension === 'txt' ? 'totp_migration_' : 'totp_backup_';
      uris = await showSaveFilePicker([`${name}${generateFileNameWithDate()}.${extension}`], [`${extension.toUpperCase()}|.${extension}`]);
    } catch (_) { this.fail(generation, $r('app.string.local_backup_picker_failed')); return; }
    if (!this.flow.isCurrent(generation)) { return; }
    if (uris.length === 0 || !uris[0]) { this.cancel(generation); return; }
    const content = this.encodedExport;
    this.encodedExport = '';
    try {
      await this.flow.progress(this, $r('app.string.local_backup_saving'), generation, true, async () => {
        await new LocalBackupFileIo().writeText(uris[0], content);
      });
      if (this.flow.isCurrent(generation)) {
        showSnackBar($r('app.string.local_backup_saved'), SnackBarNotifyType.SUCCESS);
      }
    } catch (_) {
      if (this.flow.isCurrent(generation)) { showSnackBar($r('app.string.local_backup_save_incomplete'), SnackBarNotifyType.ERROR); }
    } finally { this.finish(generation); }
  }

  @Builder
  PasswordBuilder(generation: number, exporting: boolean) {
    EncryptionPassWordDialog({
      title: exporting ? $r('app.string.dialog_backup_password_set') : $r('app.string.dialog_backup_password'),
      description: exporting ? $r('app.string.local_backup_password_notice') : $r('app.string.local_backup_password_original'),
      showConfirmPassword: exporting,
      isActive: () => this.flow.isCurrent(generation),
      submitError: exporting ? $r('app.string.local_backup_prepare_failed') : $r('app.string.local_backup_password_failed'),
      submit: async (password: string): Promise<boolean> => {
        if (!this.flow.isCurrent(generation) || this.flow.stage !== LocalBackupStage.PASSWORD) { return false; }
        const backup = this.exportSnapshot;
        const source = this.source;
        try {
          await this.flow.work(generation, false, async () => {
            if (exporting && backup !== undefined) {
              const content = await encodeLocalBackup(backup, true, password);
              if (this.flow.isCurrent(generation)) { this.encodedExport = content; }
            } else if (!exporting && source !== undefined) {
              const prepared = await source.prepare(password);
              this.flow.remember(generation, prepared);
            } else { throw new Error('Local backup source unavailable'); }
          });
          if (!this.flow.isCurrent(generation)) { return false; }
          this.exportSnapshot = undefined;
          this.source?.dispose();
          this.source = undefined;
          this.flow.transition(generation, exporting ? LocalBackupStage.PICKING : LocalBackupStage.CONFIRMING);
          return true;
        } catch (_) {
          this.flow.transition(generation, LocalBackupStage.PASSWORD);
          return false;
        }
      },
      accepted: () => {
        this.afterPasswordClosed = () => {
          if (!this.flow.isCurrent(generation)) { return; }
          if (exporting) { this.savePreparedExport(generation, 'bak'); }
          else { this.showImportSummary(generation); }
        };
        this.closePasswordDialog();
      },
      cancel: () => {
        this.cancel(generation);
        this.closePasswordDialog();
      }
    })
  }

  private async openPassword(generation: number, exporting: boolean): Promise<void> {
    if (!this.flow.transition(generation, LocalBackupStage.PASSWORD)) { return; }
    try {
      const id = await this.getUIContext().getPromptAction().openCustomDialog({
        systemMaterial: dialogSystemMaterial(), builder: () => { this.PasswordBuilder(generation, exporting); },
        autoCancel: true, alignment: DialogAlignment.Top, offset: { dx: 0, dy: 16 },
        keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
        onDidDisappear: () => {
          const next = this.afterPasswordClosed;
          this.afterPasswordClosed = undefined;
          next?.();
        },
        onWillDismiss: (action: DismissDialogAction) => {
          if (this.flow.stage === LocalBackupStage.PASSWORD || this.flow.stage === LocalBackupStage.PREPARING) {
            this.cancel(generation);
          }
          action.dismiss();
        }
      });
      if (!this.flow.isCurrent(generation)) {
        this.getUIContext().getPromptAction().closeCustomDialog(id);
      } else { this.passwordDialogId = id; }
    } catch (_) { this.fail(generation, $r('app.string.local_backup_prepare_failed')); }
  }

  async callFilePickerSelectFile(): Promise<void> {
    const generation = this.flow.begin(LocalBackupStage.PICKING);
    if (generation === undefined) { return; }
    let uris: string[];
    try { uris = await showSelectFilePicker(1, ['JSON|.json', 'BAK|.bak', 'TEXT|.txt']); } catch (_) {
      this.fail(generation, $r('app.string.local_backup_picker_failed')); return;
    }
    if (!this.flow.isCurrent(generation)) { return; }
    if (uris.length === 0 || !uris[0]) { this.cancel(generation); return; }
    try {
      await this.flow.progress(this, $r('app.string.local_backup_processing'), generation, false, async (report) => {
        const source = await readLocalBackupSource(uris[0], new LocalBackupFileIo(undefined,
          () => !this.flow.isCurrent(generation)), report);
        if (!this.flow.isCurrent(generation)) { source.dispose(); return; }
        this.source = source;
        if (source.kind === LocalBackupKind.PLAIN) {
          this.flow.remember(generation, await source.prepare('', report));
        }
      });
      if (!this.flow.isCurrent(generation) || this.source === undefined) { return; }
      const kind = this.source.kind;
      if (kind === LocalBackupKind.PASSWORD_V2 || kind === LocalBackupKind.LEGACY_CANDIDATE) {
        await this.openPassword(generation, false);
      } else {
        this.source.dispose();
        this.source = undefined;
        if (kind === LocalBackupKind.PLAIN) { this.showImportSummary(generation); }
        else if (kind === LocalBackupKind.MIGRATION) {
          this.confirmStep(generation, $r('app.string.local_backup_migration_title'), $r('app.string.local_backup_migration_redirect'),
            $r('app.string.local_backup_open_uri'), false, () => {
              this.finish(generation);
              this.pageInfos.pushPathByName(ROUTE_NAMES.UriImportSheet, null);
            });
        } else { this.fail(generation, $r('app.string.local_backup_unsupported')); }
      }
    } catch (error) {
      const reason = error instanceof LocalBackupError ? error.reason : LocalBackupFailure.FORMAT;
      this.fail(generation, reason === LocalBackupFailure.READ ? $r('app.string.local_backup_read_failed') :
        $r('app.string.local_backup_unsupported'));
    }
  }

  private showImportSummary(generation: number): void {
    const prepared = this.flow.snapshot(generation);
    if (prepared === undefined) { return; }
    this.confirmStep(generation, $r('app.string.local_backup_summary_title'),
      prepared.encrypted ? $r('app.string.local_backup_summary_encrypted', prepared.tokenCount, prepared.groupCount) :
        $r('app.string.local_backup_summary_plain', prepared.tokenCount, prepared.groupCount),
      $r('app.string.local_backup_import_confirm'), false, () => { this.commitImport(generation); });
  }

  private async commitImport(generation: number): Promise<void> {
    const prepared = this.flow.snapshot(generation);
    if (prepared === undefined || this.flow.stage !== LocalBackupStage.CONFIRMING) { return; }
    try {
      await this.flow.progress(this, $r('app.string.token_batch_import_title'), generation, true, async (report) => {
        await commitPreparedBackup(prepared, this.backupReload, report);
      });
      if (this.flow.isCurrent(generation)) {
        showSnackBar($r('app.string.toast_multi_token_update', prepared.tokenCount), SnackBarNotifyType.SUCCESS);
      }
    } catch (_) {
      if (this.flow.isCurrent(generation)) {
        showSnackBar($r('app.string.local_backup_import_incomplete'), SnackBarNotifyType.ERROR);
      }
    } finally { this.finish(generation); }
  }

  @Builder
  navDestinationBuilder(name: string, _param: Object) {
    if (name === ROUTE_NAMES.UriImportSheet) {
      UriImportSheet({ scrollEffectStyle: this.scrollEffectStyle, backupReload: this.backupReload,
        onVisibilityChange: this.onUriImportVisibilityChange })
    }
  }

  @Builder
  CloudDetailsContent() {
    CloudBackupDetailsSheet({
      scrollEffectType: this.scrollEffectStyle,
      onClose: () => { this.cloudDetailsVisible = false; }
    })
  }

  @Builder
  buildTokenProgressDialog(params: TokenProgressDialogParams) { TokenProgressDialog({ params: params }) }

  build() {
    Column() {
      HdsNavigation(this.pageInfos) {
        Column({ space: LengthMetrics.vp(12).value }) {
          List({ scroller: this.sheetScroller, space: 10 }) {
            ListItem() {
              SettingItem({ title: $r('app.string.setting_backup') }) {
                SubItemButton({ symbol: $r('sys.symbol.save'), text: $r('app.string.setting_backup_export'),
                  description: $r('app.string.local_backup_export_description'), descriptionMaxLines: 0 })
                  .id('local-backup-export').constraintSize({ minHeight: 48 }).enabled(!this.blocked())
                  .accessibilityText($r('app.string.setting_backup_export')).onClick(() => { this.callFilePickerSaveFile(); })
                SubItemDivider({ insetLeft: 46 })
                SubItemButton({ symbol: $r('sys.symbol.folder'), text: $r('app.string.setting_backup_import'),
                  description: $r('app.string.local_backup_import_description'), descriptionMaxLines: 0 })
                  .id('local-backup-import').constraintSize({ minHeight: 48 }).enabled(!this.blocked())
                  .accessibilityText($r('app.string.setting_backup_import')).onClick(() => { this.callFilePickerSelectFile(); })
                SubItemDivider({ insetLeft: 46 })
                SubItemButton({ symbol: $r('sys.symbol.briefcase'), text: $r('app.string.setting_migration'),
                  description: $r('app.string.local_backup_migration_description'), descriptionMaxLines: 0 })
                  .id('local-backup-migration').constraintSize({ minHeight: 48 }).enabled(!this.blocked())
                  .accessibilityText($r('app.string.setting_migration')).onClick(() => { this.callFilePickerSaveMigrationFile(); })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
            if (this.importers.length > 0) {
              ListItem() {
                SettingItem({ title: $r('app.string.setting_import_from_other_apps') }) {
                  ForEach(this.importers, (importer: TokenImporter, index: number) => {
                    if (index > 0) { SubItemDivider({ insetLeft: 46 }) }
                    SubItemButton({ symbol: importer.icon, text: importer.name, description: importer.description })
                      .enabled(!this.blocked())
                      .onClick(() => {
                        if (this.blocked()) { return; }
                        if (importer.id === 'uri') { this.pageInfos.pushPathByName(ROUTE_NAMES.UriImportSheet, null); }
                        else {
                          importer.import(this.getUIContext(), (tokens: Array<TokenConfig>) => {
                            if (!this.blocked()) { this.backupReload(tokens); }
                          });
                        }
                      })
                  }, (importer: TokenImporter) => importer.id)
                }
              }
              .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
            }
            ListItem() {
              SettingItem({ title: $r('app.string.data_rdb_cloud_sync') }) {
                SubItemToggle({ icon: $r('sys.symbol.icloud'), title: $r('app.string.data_rdb_cloud_sync'),
                  isOn: this.cloudBackupEnabled, disable: !this.isHuaweiLoggedIn || this.blocked(),
                  description: this.isHuaweiLoggedIn ? $r('app.string.data_rdb_cloud_sync_des') : $r('app.string.cloud_backup_login_required'),
                  onChange: (isOn: boolean) => {
                    if (this.blocked()) { return; }
                    if (isOn && !HuaweiAccountManager.getInstance().userLogin) {
                      this.cloudBackupEnabled = false;
                      AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
                      this.showHuaweiAccountRequiredDialog(); return;
                    }
                    this.cloudBackupEnabled = isOn;
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, isOn);
                  }
                })
                SubItemDivider({ insetLeft: 46 })
                SubItemButton({ symbol: $r('sys.symbol.info_circle'), text: $r('app.string.data_huawei_cloud_sync_details'),
                  description: this.isHuaweiLoggedIn ? '' : $r('app.string.cloud_backup_login_required'),
                  descriptionColor: $r('sys.color.ohos_id_color_warning') })
                  .id('cloud-backup-details-open')
                  .enabled(!this.blocked())
                  .onClick(() => {
                    if (this.blocked()) { return; }
                    if (!this.isHuaweiLoggedIn) { this.showHuaweiAccountRequiredDialog(); return; }
                    this.cloudDetailsVisible = true;
                  })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
          }
          .clip(false).width('100%').height('100%').layoutWeight(1).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).contentEndOffset(this.window.AvoidBottomHeight)
          .backgroundColor(this.pageBackground())
        }
        .width('100%').height('100%').backgroundColor(this.pageBackground())
      }
      .width('100%').height('100%').clip(false).backgroundColor(this.pageBackground())
      .mode(NavigationMode.Stack).navDestination(this.navDestinationBuilder).bindToScrollable([this.sheetScroller])
      .hideBackButton(this.embedded)
      .titleMode(this.embedded ? HdsNavigationTitleMode.MINI : HdsNavigationTitleMode.MODAL)
      .titleBar({
        avoidLayoutSafeArea: this.embedded, enableComponentSafeArea: true,
        style: {
          originalStyle: { contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            backIconStyle: MaterialTheme.navigationIconStyle(), menuStyle: MaterialTheme.navigationIconStyle()
          } },
          scrollEffectStyle: MaterialTheme.navigationScrollStyle(),
          scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: this.scrollEffectStyle },
          systemMaterialEffect: { materialType: MaterialTheme.hdsMaterialType(), materialLevel: MaterialTheme.hdsMaterialLevel() }
        },
        content: { title: { mainTitle: $r('app.string.setting_backup') } }
      })
    }
    .width('100%').height('100%').backgroundColor(this.pageBackground())
    .bindSheet($$this.cloudDetailsVisible, this.CloudDetailsContent(), cloudBackupDetailsSheetOptions())
  }

  private showHuaweiAccountRequiredDialog(): void {
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(), title: $r('app.string.cloud_sync_require_huawei_account_title'),
      message: $r('app.string.cloud_sync_require_huawei_account_msg'), autoCancel: true,
      alignment: DialogAlignment.Bottom, gridCount: 4, offset: { dx: 0, dy: -20 },
      buttons: [{ value: $r('app.string.dialog_btn_confirm'), action: () => {} }], cancel: () => {}
    });
  }
}

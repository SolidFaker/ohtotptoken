import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { ScrollEffectType } from '@kit.UIDesignKit';
import { AppWindowInfo, MaterialPreference, otpType, ROUTE_NAMES, TokenConfig } from 'common';
import { BackupAndMigrationSheet } from '../../../main/ets/pages/setting/BackupAndMigrationSheet';
import { MaterialSheetStyle } from '../../../main/ets/components/MaterialSheetStyle';
import { CloudBackupDetailsSheet, cloudBackupDetailsSheetOptions } from '../../../main/ets/pages/setting/CloudBackupDetailsSheet';
import lazy { CloudBackupHistorySheet, cloudBackupHistorySheetOptions } from '../../../main/ets/pages/setting/CloudBackupHistorySheet';

function syntheticTokens(): TokenConfig[] {
  const token = new TokenConfig('JBSWY3DPEHPK3PXP', otpType.TOTP, 'OHOTP Synthetic', 'Device test only');
  token.TokenUUID = 'ohotp-synthetic-ui-only';
  return [token];
}

@Entry
@ComponentV2
struct LocalBackupTestPage {
  @Local visible: boolean = false;
  @Local cloudVisible: boolean = false;
  @Local historyVisible: boolean = false;
  @Local embedded: boolean = false;
  @Local dark: boolean = false;
  @Local largeFont: boolean = false;
  @Local landscape: boolean = false;
  @Local executing: boolean = false;
  @Local uriVisible: boolean = false;
  @Local slowCommit: boolean = false;
  @Local failCommit: boolean = false;
  @Local committed: number = 0;
  @Local navigationStatus: string = 'ready';
  @Local tokens: TokenConfig[] = syntheticTokens();
  @Local material: MaterialPreference = AppStorageV2.connect(MaterialPreference, () => new MaterialPreference())!;
  @Local info: AppWindowInfo = AppStorageV2.connect(AppWindowInfo, () => new AppWindowInfo())!;

  private options(): SheetOptions {
    const options = MaterialSheetStyle.options();
    options.backgroundColor = $r('app.color.window_background');
    options.showClose = !this.executing && !this.uriVisible;
    options.onWillDismiss = (action: DismissSheetAction) => {
      if (!this.executing && !this.uriVisible) { action.dismiss(); }
    };
    options.onWillSpringBackWhenDismiss = (action: SpringBackAction) => {
      if (this.executing || this.uriVisible) { action.springBack(); }
    };
    options.keyboardAvoidMode = SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL;
    return options;
  }

  @Builder
  Content(embedded: boolean) {
    BackupAndMigrationSheet({
      Tokens: this.tokens, scrollEffectStyle: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR, embedded: embedded,
      onLocalExecutionChange: (value: boolean) => { this.executing = value; },
      onUriImportVisibilityChange: (value: boolean) => { this.uriVisible = value; },
      backupReload: async (_tokens, _report) => {
        if (this.slowCommit) { await new Promise<void>((resolve) => setTimeout(resolve, 15000)); }
        if (this.failCommit) { throw new Error('Synthetic commit failure'); }
        this.committed++;
      }
    })
  }

  /** 历史已改为独立 bindSheet（CloudBackupHistorySheet）；本按钮直接挂载该面板并校验其栈根。 */
  private openHistorySheet(): void {
    this.historyVisible = true;
    this.navigationStatus = 'waiting';
    setTimeout(() => {
      if (!this.historyVisible) { return; }
      const ui = this.getUIContext();
      const node = ui.getFrameNodeById('cloud-backup-history-sheet');
      const navigation = node === null ? undefined : ui.getNavigationInfoByUniqueId(node.getUniqueId());
      const paths = navigation?.pathStack.getAllPathName() ?? [];
      if (paths.length !== 1 || paths[0] !== ROUTE_NAMES.ShowCloudBackupHistoryPage) {
        this.navigationStatus = 'history stack unavailable';
        return;
      }
      this.navigationStatus = 'history sheet ok';
    }, 1000);
  }

  @Builder
  CloudContent() {
    CloudBackupDetailsSheet({
      scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
      onClose: () => { this.cloudVisible = false; }
    })
  }

  @Builder
  HistoryContent() {
    CloudBackupHistorySheet({
      scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
      onClose: () => { this.historyVisible = false; }
    })
  }

  build() {
    Column({ space: 8 }) {
      Text('OHOTP Synthetic — no token persistence').fontSize(18).id('ohotp-test-title')
      Text(`OHOTP Synthetic commits: ${this.committed}`).id('ohotp-test-commits')
      Text(`OHOTP Synthetic navigation: ${this.navigationStatus}`).id('ohotp-test-navigation')
      Row({ space: 8 }) {
        Button('Backup sheet').id('ohotp-test-open').onClick(() => { this.embedded = false; this.visible = true; })
        Button('Embedded').id('ohotp-test-embedded').onClick(() => { this.embedded = !this.embedded; })
      }
      Row({ space: 8 }) {
        Button('Cloud detail').id('ohotp-test-cloud').onClick(() => { this.cloudVisible = true; })
        Button('History').id('ohotp-test-history').onClick(() => { this.openHistorySheet(); })
        Button('Rotate').id('ohotp-test-rotate').onClick(() => {
          this.landscape = !this.landscape;
          this.info.WindowClass?.setPreferredOrientation(this.landscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
        })
      }
      Row({ space: 8 }) {
        Button('Dark').id('ohotp-test-dark').onClick(() => {
          this.dark = !this.dark;
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          ctx.getApplicationContext().setColorMode(this.dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
            ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        })
        Button('Font 2x').id('ohotp-test-font').onClick(() => {
          this.largeFont = !this.largeFont;
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          ctx.getApplicationContext().setFontSizeScale(this.largeFont ? 2 : 1);
        })
        Button('Material').id('ohotp-test-material').onClick(() => {
          this.material.app_appearance_immersive_enable = !this.material.app_appearance_immersive_enable;
        })
      }
      Row({ space: 8 }) {
        Button('Empty').id('ohotp-test-empty').onClick(() => { this.tokens = this.tokens.length ? [] : syntheticTokens(); })
        Button('Slow commit').id('ohotp-test-slow').onClick(() => { this.slowCommit = !this.slowCommit; })
        Button('Fail commit').id('ohotp-test-fail').onClick(() => { this.failCommit = !this.failCommit; })
      }
      if (this.embedded) {
        this.Content(true)
      } else {
        Text('OHOTP Synthetic backing content').fontSize(30).fontColor($r('sys.color.font_primary')).layoutWeight(1)
      }
    }
    .width('100%').height('100%').padding({ top: 20, bottom: this.info.AvoidBottomHeight })
    .backgroundColor($r('app.color.window_background'))
    .bindSheet($$this.visible, this.Content(false), this.options())
    .bindSheet($$this.cloudVisible, this.CloudContent(), cloudBackupDetailsSheetOptions())
    .bindSheet($$this.historyVisible, this.HistoryContent(), cloudBackupHistorySheetOptions())
  }
}

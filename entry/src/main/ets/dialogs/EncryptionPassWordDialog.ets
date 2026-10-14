import { AppStorageV2, CustomContentDialogV2, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppWindowInfo } from 'common';

@Preview
@ComponentV2
export struct EncryptionPassWordDialog {
  @Param title: ResourceStr = $r('app.string.dialog_backup_password');
  @Param description: ResourceStr = '';
  @Param showConfirmPassword: boolean = false;
  @Param submit: ((text: string) => Promise<boolean>) | undefined = undefined;
  @Param isActive: () => boolean = () => true;
  @Param submitError: ResourceStr = $r('app.string.local_backup_password_failed');
  @Event cancel: () => void = () => {};
  @Event confirm: (text: string) => void = () => {};
  @Event accepted: () => void = () => {};

  @Local private textValue: string = '';
  @Local private confirmTextValue: string = '';
  @Local private passwordMismatch: boolean = false;
  @Local private passwordEmpty: boolean = false;
  @Local private busy: boolean = false;
  @Local private failed: boolean = false;
  @Local private contentLimit: number = 480;
  private mounted: boolean = false;
  private editing: boolean = false;
  private mainWindow: window.Window | undefined;
  private keyboardChanged: (height: number) => void = (height: number) => this.updateContentLimit(height);

  aboutToAppear(): void {
    this.mounted = true;
    const info = AppStorageV2.connect(AppWindowInfo, () => new AppWindowInfo())!;
    this.contentLimit = Math.max(120, info.HeightVp - 180);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((main: window.Window) => {
      if (!this.mounted) { return; }
      this.mainWindow = main;
      main.on('keyboardHeightChange', this.keyboardChanged);
      this.updateContentLimit(0);
    }).catch(() => {});
  }

  private updateContentLimit(keyboardHeight: number): void {
    if (!this.mounted || this.mainWindow === undefined) { return; }
    try {
      const windowHeight = this.getUIContext().px2vp(this.mainWindow.getWindowProperties().windowRect.height);
      const height = windowHeight - this.getUIContext().px2vp(keyboardHeight);
      // 部分安全键盘悬浮且不发送高度变更；编辑态仍须给内部滚动一个可达上限。
      this.contentLimit = this.editing ? Math.max(100, Math.min(height - 180, windowHeight * 0.28)) :
        Math.max(120, height - 180);
    } catch (_) {}
  }

  aboutToDisappear(): void {
    this.mounted = false;
    try { this.mainWindow?.off('keyboardHeightChange', this.keyboardChanged); } catch (_) {}
    this.mainWindow = undefined;
    this.resetInput();
  }

  private resetInput(): void {
    this.textValue = '';
    this.confirmTextValue = '';
    this.passwordMismatch = false;
    this.passwordEmpty = false;
  }

  private close(): void { this.getDialogController()?.close(); }

  private async submitPassword(): Promise<void> {
    if (this.busy || !this.isActive()) { return; }
    if (this.showConfirmPassword && this.textValue.length === 0) { this.passwordEmpty = true; return; }
    if (this.showConfirmPassword && this.textValue !== this.confirmTextValue) { this.passwordMismatch = true; return; }
    let password = this.textValue;
    this.resetInput();
    this.failed = false;
    this.busy = true;
    try {
      if (this.submit !== undefined) {
        const accepted = await this.submit(password);
        password = '';
        if (!this.mounted || !this.isActive()) { return; }
        if (!accepted) { this.failed = true; return; }
        this.accepted();
      } else {
        this.confirm(password);
        this.close();
      }
    } catch (_) {
      if (this.mounted && this.isActive()) { this.failed = true; }
    } finally {
      password = '';
      this.busy = false;
    }
  }

  @Builder
  contentBuilder(): void {
    Scroll() {
      Column({ space: 12 }) {
        if (this.description !== '') {
          Text(this.description).width('100%').fontColor($r('sys.color.font_secondary'))
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
        }
        TextInput({ placeholder: $r('app.string.dialog_backup_password_placeholder'), text: this.textValue })
          .id('local-backup-password').constraintSize({ minHeight: 48 })
          .accessibilityText($r('app.string.dialog_backup_password_placeholder'))
          .type(InputType.Password).showPasswordIcon(true).enabled(!this.busy)
          .onEditChange((editing: boolean) => { this.editing = editing; this.updateContentLimit(0); })
          .showError(this.passwordEmpty ? $r('app.string.dialog_backup_password_empty') : undefined)
          .onChange((value: string) => {
            this.textValue = value;
            this.passwordMismatch = false;
            this.passwordEmpty = false;
            this.failed = false;
          })
        if (this.showConfirmPassword) {
          TextInput({ placeholder: $r('app.string.dialog_backup_password_confirm_placeholder'), text: this.confirmTextValue })
            .id('local-backup-password-confirm').constraintSize({ minHeight: 48 })
            .accessibilityText($r('app.string.dialog_backup_password_confirm_placeholder'))
            .type(InputType.Password).showPasswordIcon(true).enabled(!this.busy)
            .onEditChange((editing: boolean) => { this.editing = editing; this.updateContentLimit(0); })
            .showError(this.passwordMismatch ? $r('app.string.dialog_backup_password_mismatch') : undefined)
            .onChange((value: string) => { this.confirmTextValue = value; this.passwordMismatch = false; })
        }
        if (this.failed) {
          Text(this.submitError).id('local-backup-password-error').width('100%')
            .fontColor($r('sys.color.ohos_id_color_warning')).fontSize($r('sys.float.ohos_id_text_size_body2'))
        }
        if (this.busy) {
          LoadingProgress().width(32).height(32)
          Text($r('app.string.local_backup_processing')).fontColor($r('sys.color.font_secondary'))
        }
        Button($r('app.string.setting_backup_confirm'))
          .id('local-backup-password-submit').width('100%').constraintSize({ minHeight: 48 })
          .labelStyle({ maxLines: 4 }).enabled(!this.busy).onClick(() => this.submitPassword())
        Button($r('app.string.setting_backup_cancel'))
          .id('local-backup-password-cancel').width('100%').constraintSize({ minHeight: 48 })
          .labelStyle({ maxLines: 4 }).backgroundColor(Color.Transparent).fontColor($r('sys.color.font_emphasize'))
          .onClick(() => { this.cancel(); this.resetInput(); if (this.submit === undefined) { this.close(); } })
      }
      .width('100%')
    }
    .width('100%').constraintSize({ maxHeight: this.contentLimit }).scrollBar(BarState.Auto)
  }

  build() {
    CustomContentDialogV2({
      primaryTitle: this.title,
      contentBuilder: () => { this.contentBuilder(); }
    })
  }
}

import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window, AppStorageV2 } from '@kit.ArkUI';
import {
  AppWindowInfo, CloudBackupAccountPort, CloudBackupManager, setDialogSystemMaterialProvider,
  TokenGroupKvBackend, TokenGroupStore
} from 'common';
import { MaterialPolicy } from '../../../main/ets/utils/MaterialPolicy';
import { MaterialTheme } from '../../../main/ets/components/MaterialTheme';

class TestGroupBackend implements TokenGroupKvBackend {
  async getValue<T>(_key: string): Promise<T | null> { return null; }
  async setValue<T>(_key: string, _value: T): Promise<void> {}
}

class SignedOutTestAccount implements CloudBackupAccountPort {
  isUserLogin(): boolean { return false; }
  unionId(): string { return ''; }
}

/** 仅 ohosTest 打包：不初始化账号/TokenStore/持久化偏好，不加载真实首页。 */
export default class LocalBackupTestAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('appContext', this.context);
    TokenGroupStore.getInstance().useKvBackendForTest(new TestGroupBackend());
    TokenGroupStore.getInstance().state.groups = [];
    // 跳过生产 cloudFileDir 初始化，历史页在未登录门禁返回，不访问真实云目录。
    CloudBackupManager.getInstance().useDepsForTest({
      cloudDir: 'ohotp-synthetic-no-io', account: new SignedOutTestAccount()
    });
    MaterialPolicy.getInstance().init();
    setDialogSystemMaterialProvider(() => MaterialTheme.dialogSystemMaterial());
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    const main = await stage.getMainWindow();
    await stage.loadContent('pages/LocalBackupTestPage');
    const state = AppStorageV2.connect(AppWindowInfo, () => new AppWindowInfo())!;
    state.Context = this.context;
    state.WindowClass = main;
    state.uiContext = main.getUIContext();
    const sync = (): void => {
      const rect = main.getWindowProperties().windowRect;
      state.Size = { width: rect.width, height: rect.height };
      state.WidthVp = main.getUIContext().px2vp(rect.width);
      state.HeightVp = main.getUIContext().px2vp(rect.height);
      state.AvoidBottomHeight = main.getUIContext().px2vp(main.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
    };
    sync();
    main.on('windowSizeChange', sync);
  }
}

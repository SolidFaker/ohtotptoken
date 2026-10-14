import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferenceManager } from './PreferenceManager';
import { CloudBackupDiagnostics, DiagnosticKind, DiagnosticStage, DiagnosticResult, DiagnosticReason,
  DiagnosticErrorDomain } from './CloudBackupDiagnostics';
const PREF_KEY_LOGGED_IN = 'huawei_logged_in';
const PREF_KEY_USER_ACCOUNT = 'huawei_user_account';

/** 华为账号授权错误码，映射到对应的 i18n 错误提示资源 */
export enum HuaweiAccountErrorCode {
  ERROR_CODE_LOGIN_OUT = 1001502001,
  ERROR_CODE_NETWORK_ERROR = 1001502005,
  ERROR_CODE_INTERNAL_ERROR = 1001502009,
  ERROR_CODE_USER_CANCEL = 1001502012,
  ERROR_CODE_SYSTEM_SERVICE = 12300001,
  ERROR_CODE_REQUEST_REFUSE = 1001500002,
}

// 只保留已定义的业务分支；授权错误码不进入诊断输出。
function knownLoginErrorCode(code: number): number {
  switch (code) {
    case HuaweiAccountErrorCode.ERROR_CODE_LOGIN_OUT:
    case HuaweiAccountErrorCode.ERROR_CODE_NETWORK_ERROR:
    case HuaweiAccountErrorCode.ERROR_CODE_INTERNAL_ERROR:
    case HuaweiAccountErrorCode.ERROR_CODE_USER_CANCEL:
    case HuaweiAccountErrorCode.ERROR_CODE_SYSTEM_SERVICE:
    case HuaweiAccountErrorCode.ERROR_CODE_REQUEST_REFUSE:
      return code;
    default: return 0;
  }
}

export class HuaweiAccountLoginError extends Error {
  code: number = 0;

  constructor(code: number) {
    super('Huawei account authorization failed');
    this.code = knownLoginErrorCode(code);
  }
}

// 纯数值边界：不接收异常对象、不转换字符串，不读取 accessor/message/stack。
export function normalizeHuaweiAccountLoginError(code: number | undefined): HuaweiAccountLoginError {
  return new HuaweiAccountLoginError(typeof code === 'number' ? code : 0);
}

export class HuaweiUserInfo {
  nickname: string = '';
  avatarUri: string = '';
  unionId: string = '';

  constructor(nickname: string, avatarUri: string, unionId: string) {
    this.nickname = nickname;
    this.avatarUri = avatarUri;
    this.unionId = unionId;
  }
}

/**
 * 华为账号登录管理单例。
 * 职责：华为账号授权登录/登出、登录态持久化（Preference）、
 * 登录态校验（getHuaweiIDState）、AppStorage 状态同步。
 * 云备份的加密密钥与华为账号绑定，登录态是云备份功能的前置条件。
 */
export class HuaweiAccountManager {
  private static instance: HuaweiAccountManager;
  private prefMgr = PreferenceManager.getInstance();
  public userLogin: boolean = false;
  public userAccount: HuaweiUserInfo = new HuaweiUserInfo('', '', '');

  private constructor() {}

  static getInstance(): HuaweiAccountManager {
    if (!HuaweiAccountManager.instance) {
      HuaweiAccountManager.instance = new HuaweiAccountManager();
    }
    return HuaweiAccountManager.instance;
  }

  /** 根据错误码返回对应的 i18n 资源引用，用于 UI 错误提示；ERROR_CODE_REQUEST_REFUSE 返回 null 表示静默处理 */
  static getLoginErrorResource(code: number): Resource | null {
    if (code === HuaweiAccountErrorCode.ERROR_CODE_LOGIN_OUT) {
      return $r('app.string.huawei_account_error_not_logged_in');
    } else if (code === HuaweiAccountErrorCode.ERROR_CODE_NETWORK_ERROR) {
      return $r('app.string.huawei_account_error_network');
    } else if (code === HuaweiAccountErrorCode.ERROR_CODE_INTERNAL_ERROR) {
      return $r('app.string.huawei_account_error_internal');
    } else if (code === HuaweiAccountErrorCode.ERROR_CODE_USER_CANCEL) {
      return $r('app.string.huawei_account_error_user_cancel');
    } else if (code === HuaweiAccountErrorCode.ERROR_CODE_SYSTEM_SERVICE) {
      return $r('app.string.huawei_account_error_system_service');
    } else if (code === HuaweiAccountErrorCode.ERROR_CODE_REQUEST_REFUSE) {
      return null;
    }
    return $r('app.string.huawei_account_login_failed');
  }

  /** 判断错误码是否为用户主动取消登录 */
  static isUserCancel(code: number): boolean {
    return code === HuaweiAccountErrorCode.ERROR_CODE_USER_CANCEL;
  }

  /**
   * 初始化：从 Preference 恢复上次的登录态和用户信息，
   * 若有保存的登录态则调用 checkAuthState 校验授权是否仍有效，
   * 最后同步状态到 AppStorage 供 UI 绑定。
   */
  async init(): Promise<void> {
    const savedLogin: boolean = await this.prefMgr.getValue<boolean>(PREF_KEY_LOGGED_IN) ?? false;
    const savedAccount: HuaweiUserInfo | null = await this.prefMgr.getValue<HuaweiUserInfo>(PREF_KEY_USER_ACCOUNT);
    if (savedLogin && savedAccount) {
      this.userLogin = true;
      this.userAccount = savedAccount;
      this.checkAuthState();
    }
    this.updateAppStorage();
  }

  /**
   * 校验已保存账号的授权状态：通过 unionId 查询华为 ID 服务，
   * 若返回非 AUTHORIZED 则标记为未登录（可能用户在其他设备解除了授权）。
   */
  private checkAuthState(): void {
    const stateRequest: authentication.StateRequest = {
      idType: authentication.IdType.UNION_ID,
      idValue: this.userAccount.unionId,
    };
    new authentication.HuaweiIDProvider().getHuaweiIDState(stateRequest)
      .then((result: authentication.StateResult) => {
        if (result.state !== authentication.State.AUTHORIZED) {
          this.userLogin = false;
        }
        this.updatePreference();
        this.updateAppStorage();
      })
      .catch(() => {
        const diagnostic = CloudBackupDiagnostics.begin(DiagnosticKind.SYNC);
        CloudBackupDiagnostics.mark(diagnostic, DiagnosticStage.ACCOUNT_STATE, DiagnosticResult.FAIL,
          { reason: DiagnosticReason.UNAVAILABLE, errorDomain: DiagnosticErrorDomain.APP });
        CloudBackupDiagnostics.end(diagnostic);
      });
  }

  /** 获取当前登录用户信息，未登录返回 undefined */
  getUserInfo(): HuaweiUserInfo | undefined {
    if (this.userLogin) {
      return this.userAccount;
    }
    return undefined;
  }

  /**
   * 华为账号登录：发起 AuthorizationWithHuaweiID 授权请求，
   * 获取昵称、头像、unionID，更新内存/Preference/AppStorage 三层状态。
   * @param uiContext 页面 UIContext，用于创建 AuthenticationController
   */
  async login(uiContext: UIContext): Promise<HuaweiUserInfo> {
    const credential = await this.getAuthCredential(uiContext);
    this.userAccount = new HuaweiUserInfo(
      credential.nickName ?? '',
      credential.avatarUri ?? '',
      credential.unionID ?? ''
    );
    this.userLogin = true;
    this.updatePreference();
    this.updateAppStorage();
    return this.userAccount;
  }

  /**
   * 构建华为账号授权请求并执行：
   * - 请求 profile scope 获取用户基本信息
   * - 请求 serviceauthcode 权限用于后端服务验证
   * - forceAuthorization=true 强制弹出授权页面
   * - 使用随机 UUID 作为 state 参数防止 CSRF 攻击
   */
  private async getAuthCredential(uiContext: UIContext): Promise<authentication.AuthorizationWithHuaweiIDCredential> {
    try {
      const authRequest = new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
      authRequest.scopes = ['profile'];
      authRequest.permissions = ['serviceauthcode'];
      authRequest.forceAuthorization = true;
      authRequest.state = util.generateRandomUUID();
      const controller = new authentication.AuthenticationController(uiContext.getHostContext());
      const result = await controller.executeRequest(authRequest);
      const response = result as authentication.AuthorizationWithHuaweiIDResponse;
      const state = response.state;
      if (state !== undefined && authRequest.state !== state) {
        throw new HuaweiAccountLoginError(0);
      }
      const credential = response.data;
      if (!credential) { throw new HuaweiAccountLoginError(0); }
      return credential;
    } catch (error) {
      // 仅此 SDK 边界读取业务 code；不会送入日志，任何读取失败也使用固定错误。
      let safeError = normalizeHuaweiAccountLoginError(undefined);
      try { safeError = normalizeHuaweiAccountLoginError((error as BusinessError)?.code); } catch (_) { /* 固定 fallback。 */ }
      const cancelled = HuaweiAccountManager.isUserCancel(safeError.code);
      const diagnostic = CloudBackupDiagnostics.begin(DiagnosticKind.SYNC);
      CloudBackupDiagnostics.mark(diagnostic, DiagnosticStage.ACCOUNT_AUTHORIZE,
        cancelled ? DiagnosticResult.CANCELLED : DiagnosticResult.FAIL,
        { reason: cancelled ? DiagnosticReason.CANCELLED : DiagnosticReason.UNAVAILABLE,
          errorDomain: DiagnosticErrorDomain.APP });
      CloudBackupDiagnostics.end(diagnostic);
      throw safeError;
    }
  }

  /** 登出：清空内存用户信息、更新 Preference 和 AppStorage（不会撤销华为 ID 授权） */
  async logout(): Promise<void> {
    this.userLogin = false;
    this.userAccount = new HuaweiUserInfo('', '', '');
    this.updatePreference();
    this.updateAppStorage();
  }

  /** 账号选择器回调：用户在系统账号选择器中确认后调用，标记为已登录 */
  selectHuaweiAccountToLogin(): void {
    this.userLogin = true;
    this.updatePreference();
    this.updateAppStorage();
  }

  /** 持久化登录态到 Preference：登录时保存，登出时清空用户信息 */
  private updatePreference(): void {
    this.prefMgr.setValue(PREF_KEY_LOGGED_IN, this.userLogin);
    this.prefMgr.setValue(PREF_KEY_USER_ACCOUNT, this.userLogin ? this.userAccount : null);
  }

  /** 同步登录态到 AppStorage，供 UI 组件通过 AppStorageV2.connect 响应式绑定 */
  private updateAppStorage(): void {
    AppStorage.setOrCreate('huawei_is_logged_in', this.userLogin);
    AppStorage.setOrCreate('huawei_user', this.userLogin ? this.userAccount : null);
  }
}

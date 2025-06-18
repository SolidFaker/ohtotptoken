import { KvManager } from "./KvManager";
import { TokenConfig } from "./TokenConfig";
import { RdbManager } from "./RdbManager";
import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';

export class TokenStore {
  private kvMgr: KvManager = KvManager.getInstance();
  private rdbMgr: RdbManager = RdbManager.getInstance();
  private token_array: TokenConfig[] = [];
  private appCtx: common.UIAbilityContext | undefined = undefined;
  private init_done: boolean = false;
  private static instance: TokenStore;

  private token_prefix: string = "_token_uuid_";

  private constructor() {
  }

  private async emitTokenChanged(): Promise<void> {
    this.appCtx?.eventHub.emit('onTokenChanged');
  }

  public static getInstance(): TokenStore {
    if (!TokenStore.instance) {
      TokenStore.instance = new TokenStore();
    }
    return TokenStore.instance;
  }

  public async initTokenStore(): Promise<void> {
    if (this.init_done) {
      return;
    }
    await this.kvMgr.initKvManager();
    await this.LoadTokenByDataBase();
    this.init_done = true;
  }

  public async LoadTokenByDataBase(): Promise<void> {
     this.token_array = await this.kvMgr.getTokenArray(this.token_prefix)
     this.appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
     this.sortTokens();
  }

  public async getTokens(): Promise<TokenConfig[]> {
    return this.token_array;
  }

  public async queryToken(token_uuid: string): Promise<TokenConfig> {
    let token = await this.kvMgr.getValue<TokenConfig>(`${this.token_prefix}${token_uuid}`);
    return token ?? new TokenConfig();
  }

  public sortTokens(): void {
    this.token_array = this.token_array.sort((a, b) => a.RankScore - b.RankScore)
    this.emitTokenChanged();
  }

  private async saveToken(token: TokenConfig): Promise<void> {
    await this.kvMgr.setValue<TokenConfig>(`${this.token_prefix}${token.TokenUUID}`, token);
  }

  public async updateTokenRank(from: number, to: number): Promise<void> {
    this.token_array[from].RankScore = to;
    await this.saveToken(this.token_array[from]);
    if (from > to) {
      for (let i = to; i < from; i++) {
        this.token_array[i].RankScore++;
        await this.saveToken(this.token_array[i]);
      }
    } else {
      for (let i = from + 1; i <= to; i++) {
        this.token_array[i].RankScore--;
        await this.saveToken(this.token_array[i]);
      }
    }
    this.sortTokens();
  }

  public async updateToken(token: TokenConfig): Promise<void> {
    let token_new = token;
    const token_uuids = this.token_array.map(t => t.TokenUUID);
    if (!token_uuids.includes(token_new.TokenUUID)) {
      token_new.RankScore = this.token_array.length;
      this.token_array.push(token_new);
    } else {
      const token_index = token_uuids.findIndex(uuid => uuid === token_new.TokenUUID);
      token_new.RankScore = this.token_array[token_index].RankScore;
      this.token_array[token_index] = token_new;
    }
    await this.saveToken(token_new);
    this.emitTokenChanged();
  }

  public async deleteToken(token_uuid: string): Promise<void> {
    const token_uuids = this.token_array.map(t => t.TokenUUID);
    const token_index = token_uuids.findIndex(uuid => uuid === token_uuid);
    for (let i = token_index; i < this.token_array.length; i++) {
      this.token_array[i].RankScore--;
      await this.saveToken(this.token_array[i]);
    }
    this.token_array = this.token_array.filter(t => t.TokenUUID !== token_uuid);
    await this.kvMgr.deleteValue(`${this.token_prefix}${token_uuid}`);
    this.emitTokenChanged();
  }

  /**
   * 手动触发同步.
   *
   */
  async DataSync(): Promise<void> {
    await this.kvMgr.DataSync();
  }
  /**
   * 备份整个kv数据库到目标文件.
   *
   * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
   */
  public BuckupToFile(backupFile:string): void {
    this.kvMgr.BuckupToFile(backupFile);
  }
  /**
   * 从备份文件中还原整个数据库.
   *
   * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
   */
  public RestoreByFile(backupFile:string): void {
    this.kvMgr.RestoreByFile(backupFile);
  }


  /**
   * 备份整个kv加密数据库到非加密数据库
   *
   */
  public async BuckupToKVAsync(): Promise<number>  {
    return await this.kvMgr.DataSyncToNoEncryptDatabase();
  }
  /**
   * 从非加密数据库KV还原到kv
   *
   */
  public async RestoreByKVAsync(): Promise<number> {
    return await this.kvMgr.DataSyncToEncryptDatabase();
  }
  /**
   * 检查是否有还原数据可用 返回可用条数（还原场景专用）.
   *
   */
  public async RestoreByKVCheckAsync(): Promise<number> {
    return await this.kvMgr.DataSyncToEncryptDatabaseCheckNumber(this.token_prefix);
  }
  /**
   * 设置主密码
   *
   */
  public async SetMasterKeyAsync(masterKey:string): Promise<string>  {
    return await this.kvMgr.EncryptionMasterKeyAndCreateRecoverySecretKey(masterKey);
  }
  /**
   * 校验主密码（如果成功自动派生密钥）
   *
   */
  public async CheckMasterKeySync(masterKey:string): Promise<boolean>  {
    return await this.kvMgr.CheckMasterKey(masterKey);
  }
  /**
   * 尝试使用恢复密钥还原主密码
   *
   */
  public async CheckRecoverySecretKey(recoveryKey:string): Promise<boolean>  {
    return await this.kvMgr.CheckRecoverySecretKey(recoveryKey);
  }
}
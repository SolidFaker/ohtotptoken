import { bundleManager, common } from '@kit.AbilityKit';
import { distributedKVStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreference } from './AppPreference';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { TokenConfig } from './TokenConfig';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from "@kit.CoreFileKit";
import { asset } from '@kit.AssetStoreKit';
import { buffer, util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { decryptFile, encryptFile,encryptStringData,decryptStringData,encryptUint8ArrayData,decryptUint8ArrayData } from "./CryptoUtils";
import { base32Decode, base32Encode,stringToArray } from './TokenUtils';
import { faceDetector } from '@kit.CoreVisionKit';

export class KvManager {
  //单版本分布式键值数据库
  private _kvMgr: distributedKVStore.KVManager | undefined = undefined;
  private _kvStore: distributedKVStore.SingleKVStore | undefined = undefined;
  private _kvStoreNoE: distributedKVStore.SingleKVStore | undefined = undefined;

  //token加密密钥存储的name
  private readonly _tokenEncryptionSecretKeyName="tokenData_alias";
  //token加密密钥存储的name(主密钥场景下的)
  private readonly _tokenMasterKeyEncryptionSecretKeyName="tokenData_alias_master_key";
  //token恢复密钥存储的name（主密钥增强场景）
  private readonly _tokenEncryptionMasterRecoverySecretKeyName="tokenData_alias_recovery";
  //用来校验还原场景下主密钥是否正确的密文(主密钥场景下的) 如果用户设置主密钥能正常解密这个内容说明设置的密钥是对的
  private readonly _tokenMasterKeyEncryptionSecretKeyNameTest="tokenData_alias_master_key_test";
  private static instance: KvManager;

  private constructor() {

  }

  //#region 基础部分

  public static getInstance(): KvManager {
    if (!KvManager.instance) {
      KvManager.instance = new KvManager();
    }
    return KvManager.instance;
  }

  private async initKvStore(ctx: common.UIAbilityContext): Promise<distributedKVStore.SingleKVStore[]> {
    //初始化键值数据库
    if (!this._kvMgr) {
      let bundleName = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).name;
      const kvManagerConfig: distributedKVStore.KVManagerConfig = {
        context: ctx,
        bundleName: bundleName,
      }
      this._kvMgr = distributedKVStore.createKVManager(kvManagerConfig);
    }
    let dbs =[];
    const options: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: true, //no加密
      backup: true, //设置数据库文件是否备份
      autoSync: true, //自动同步
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,//表示单版本数据库。 数据不分设备，设备之间修改相同的Key会覆盖。
      securityLevel: distributedKVStore.SecurityLevel.S4, //表示数据库的安全级别为高级别，数据的泄露、篡改、破坏、销毁可能会给个人或组织导致严峻的不利影响。
    };
    const noEncryptoptions: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: false, //no加密
      backup: true, //设置数据库文件是否备份
      autoSync: true, //自动同步
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,//表示单版本数据库。 数据不分设备，设备之间修改相同的Key会覆盖。
      securityLevel: distributedKVStore.SecurityLevel.S4, //表示数据库的安全级别为高级别，数据的泄露、篡改、破坏、销毁可能会给个人或组织导致严峻的不利影响。
    };
    dbs[0]=await this._kvMgr.getKVStore('main_store', options);
    dbs[1]=await this._kvMgr.getKVStore('main_store_noE', noEncryptoptions);
    return dbs;
  }

  async initKvManager(): Promise<void> {
    let ctx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (this._kvStore) {
      return;
    }
    await this.initKvStore(ctx).then((store) => {
      this._kvStore = store[0];
      this._kvStoreNoE = store[1];
      //订阅同步完成事件
      this._kvStore.on('syncComplete', (data: [string, number][]) => {
        console.info(`syncComplete ${data}`);
        ctx.eventHub.emit('KVStoreSyncComplete');
      });

      this._kvStore.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_LOCAL, (data: distributedKVStore.ChangeNotification) => {
        console.info(`dataChange callback call data: ${data}`);
        //ctx.eventHub.emit('KVStoreSyncComplete');
      });
    }).catch((reason: BusinessError) => {
      console.error(reason.message);
    });
  }
  /**
   * 备份整个kv数据库到目标文件.
   *
   * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
   */
  BuckupToFile(backupFile:string)
  {
    try {
      if (fs.accessSync(backupFile)) {//如果文件存在需要删除然后重新备份
        let files = [backupFile];
        try {
          this._kvStore?.deleteBackup(files).then((data) => {
            hilog.info(0,"BuckUP",`Succeed in deleting Backup. Data:filename is ${data[0]},result is ${data[1]}.`);
          }).catch((err: BusinessError) => {
            hilog.error(err.code,"BuckUP",`Fail to delete Backup. Code:${err.code},message:${err.message}`);
          })
        } catch (e) {
          let error = e as BusinessError;
          hilog.error(error.code,"BuckUP",`An unexpected error occurred. Code:${error.code},message:${error.message}`);
        }
      }
      this._kvStore?.backup(backupFile, (err) => {
        if (err) {
          hilog.error(err.code,"BuckUP",`Fail to backup data.code:${err.code},message:${err.message}`);
        } else {
          hilog.info(0,"BuckUP",'Succeeded in backupping data.');
        }
      });
    } catch (e) {
      let error = e as BusinessError;
      hilog.error(error.code,"BuckUP",`An unexpected error occurred. Code:${error.code},message:${error.message}`);
    }
  }
  /**
   * 从备份文件中还原整个数据库.
   *
   * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
   */
  RestoreByFile(backupFile:string)
  {
    try {
      if (fs.accessSync(backupFile)) { 
        this._kvStore?.restore(backupFile, (err) => {
          if (err) {
            hilog.error(err.code,"Restore",`Fail to restore data. Code:${err.code},message:${err.message}`);
          } else {
            hilog.info(0,"Restore",'Succeeded in restoring data.');
          }
        });
      }

    } catch (e) {
      let error = e as BusinessError;
      hilog.error(error.code,"Restore",`An unexpected error occurred. Code:${error.code},message:${error.message}`);
    }
  }

  async setValue<T>(key: string, value: T): Promise<void> {
    if (this._kvStore) {
      await this._kvStore.put(key, JSON.stringify(value));
    }
  }


  async getValue<T>(key: string): Promise<T | null> {
    if (this._kvStore) {
      return this._kvStore.get(key).then((data: boolean | string | number | Uint8Array) => {
        let value: T | null = null;
        if (data) {
          value = JSON.parse(data as string) as T;
        }
        return value;
      }).catch(() => {
        return null;
      });
    }
    return null;
  }

  // 使用getEntries模拟一个可以兼容的数组 这样可以规避多设备覆盖的问题
  async getTokenArray(prefix: string): Promise<TokenConfig[]> {
    let token_array: TokenConfig[] = [];
    if (this._kvStore) {
      try {
        // load from old version
        const old_prefixKey = "$.SA_token_uuids_";
        const old_entries = await this._kvStore.getEntries(old_prefixKey);
        for (let i = 0; i < old_entries.length; i++) {
          const old_key = old_entries[i].key;
          // remove old prefix list
          this.deleteValue(old_key);
          // convert old to new token store format
          const old_token_uuid = old_key.substring(old_prefixKey.length);
          const old_token_key = "token_" + old_token_uuid;
          const old_token_value = await this.getString(old_token_key);
          const new_token_key = prefix + old_token_uuid;
          await this.setString(new_token_key, old_token_value??'');
          await this.deleteValue(old_token_key);
        }

        const entries = await this._kvStore.getEntries(prefix);
        entries.forEach((item) => {
          const json = item.value.value as string;
          if (json.length > 0) {
            token_array.push(JSON.parse(item.value.value as string) as TokenConfig);
          }
        });
      } catch (e) {
        let error = e as BusinessError;
        console.error(`duplicated calls should be ok. code is ${error.code}, message is ${error.message}`);
      }
    }
    return token_array;
  }

  async setString(key: string, value: string): Promise<void> {
    if (this._kvStore) {
     this._kvStore.put(key, value, (err) => {
          if (err != undefined) {
            console.error(`Failed to put.code is ${err.code},message is ${err.message}`);
            return;
          }
          console.info("Succeeded in putting");
     });
    }
  }

  async getString(key: string): Promise<string|null> {
    if (this._kvStore) {
      return this._kvStore.get(key).then((data: boolean | string | number | Uint8Array) => {
        let value: string | null = null;
        if (data) {
          value = data as string;
        }
        return value;
      }).catch(() => {
        return null;
      });
    }
    return null;
  }

  async setStringNoE(key: string, value: string): Promise<void> {
    if (this._kvStoreNoE) {
      this._kvStoreNoE.put(key, value, (err) => {
        if (err != undefined) {
          console.error(`Failed to put.code is ${err.code},message is ${err.message}`);
          return;
        }
        console.info("Succeeded in putting");
      });
    }
  }

  async getStringNoE(key: string): Promise<string|null> {
    if (this._kvStoreNoE) {
      return this._kvStoreNoE.get(key).then((data: boolean | string | number | Uint8Array) => {
        let value: string | null = null;
        if (data) {
          value = data as string;
        }
        return value;
      }).catch(() => {
        return null;
      });
    }
    return null;
  }
  async deleteValue(key: string): Promise<void> {
    if (this._kvStore) {
      await this._kvStore.delete(key);
    }
  }

  //#endregion

  /**
   * 将数据同步到非加密数据库.
   *
   */
  async DataSyncToNoEncryptDatabase(): Promise<number> {
    if (this._kvStore && this._kvStoreNoE) {
      let secret_key=await this.queryEncryptTokenDataKey();
      if (secret_key!="") {
        let secret_keyBlob=base32Decode(secret_key);
        let symKeyBlob: cryptoFramework.DataBlob = { data: secret_keyBlob};
        let EncryptData_entries = await this._kvStore.getEntries('^');
        if (EncryptData_entries && EncryptData_entries.length>0) {
          let entries: distributedKVStore.Entry[] = [];
          for (let i = 0; i < EncryptData_entries.length; i++) {
            if (EncryptData_entries[i].key==this._tokenEncryptionSecretKeyName
              || EncryptData_entries[i].key==this._tokenMasterKeyEncryptionSecretKeyName
              || EncryptData_entries[i].key==this._tokenMasterKeyEncryptionSecretKeyNameTest
              || EncryptData_entries[i].key==this._tokenEncryptionMasterRecoverySecretKeyName) {
              continue;
            }
            let data=EncryptData_entries[i].value.value as string;
            let dataitem=await encryptStringData(data,symKeyBlob);
            if (dataitem==null) {
              continue;
            }
            let entry: distributedKVStore.Entry = {
              key: EncryptData_entries[i].key,
              value: {
                type: distributedKVStore.ValueType.BYTE_ARRAY,
                value: dataitem
              }
            }
            entries.push(entry);
          }
          if (entries.length>0)
          {
            //最后添加一段验证数据 此数据用在还原场景下 验证用户输入的主密码是否正确 
            let testData=await encryptStringData(Date().toString(),symKeyBlob);
            if (testData!=null) {
              let entry: distributedKVStore.Entry = {
                key: this._tokenMasterKeyEncryptionSecretKeyNameTest,
                value: {
                  type: distributedKVStore.ValueType.BYTE_ARRAY,
                  value: testData
                }
              }
              entries.push(entry);
            }

            this._kvStoreNoE.putBatch(entries, async (err: BusinessError) => {
              if (err != undefined) {
                hilog.error(err.code,"DataSyncToNoEncryptDatabase",`Failed to put Batch.code is ${err.code},message is ${err.message}`);
                return;
              }
            });
            return entries.length;
          }
          else
          {
            return entries.length;
          }

        }
      }

    }
    return 0;
  }
  /**
   * 非加密数据库将数据同步到加密数据库（还原场景专用）.
   *
   */
  async DataSyncToEncryptDatabase(): Promise<number> {
    if (this._kvStore && this._kvStoreNoE) {

      let secret_key=await this.queryEncryptTokenDataKey();
      try {
        if (secret_key!="") {
          let secret_keyBlob=base32Decode(secret_key);
          let symKeyBlob: cryptoFramework.DataBlob = { data: secret_keyBlob};
          let EncryptData_entries = await this._kvStoreNoE.getEntries('^');
          if (EncryptData_entries && EncryptData_entries.length>0) {
            let entries: distributedKVStore.Entry[] = [];
            for (let i = 0; i < EncryptData_entries.length; i++) {
              if (EncryptData_entries[i].key==this._tokenEncryptionSecretKeyName
                || EncryptData_entries[i].key==this._tokenMasterKeyEncryptionSecretKeyName
                || EncryptData_entries[i].key==this._tokenMasterKeyEncryptionSecretKeyNameTest
                || EncryptData_entries[i].key==this._tokenEncryptionMasterRecoverySecretKeyName) {
                continue;
              }
              let data=EncryptData_entries[i].value.value as Uint8Array;
              let dataitem=await decryptStringData(data,symKeyBlob);
              if (dataitem==null) {
                continue;//有一个解密失败就放弃当前解密
              }
              let entry: distributedKVStore.Entry = {
                key: EncryptData_entries[i].key,
                value: {
                  type: distributedKVStore.ValueType.STRING,
                  value: dataitem
                }
              }
              entries.push(entry);
            }
            if (entries.length>0)
            {
              this._kvStore.putBatch(entries, async (err: BusinessError) => {
                if (err != undefined) {
                  hilog.error(err.code,"DataSyncToNoEncryptDatabase",`Failed to put Batch.code is ${err.code},message is ${err.message}`);
                  return ;
                }
              });
              return entries.length;
            }
            else
            {
              return 0;
            }

          }

        }
      }
      catch (err)
      {
        hilog.error(err.code,"DataSyncToEncryptDatabase",`Failed to DataSync Batch.code is ${err.code},message is ${err.message}`);
      }
      finally {
        secret_key="";
      }
      return 0;
    }
    return 0;
  }
  /**
   * 检查是否有还原数据可用 返回可用条数（还原场景专用）.
   *
   */
  async DataSyncToEncryptDatabaseCheckNumber(token_prefix:string): Promise<number>{
    const query = new distributedKVStore.Query();
    query.prefixKey(token_prefix);
    let EncryptData_entries_count =await this._kvStoreNoE?.getResultSize(query);
    return EncryptData_entries_count??0;
  }
  /**
   * 获取加密用的密钥.
   *
   */
  async queryEncryptTokenDataKey(): Promise<string> {
    let query: asset.AssetMap = new Map();
    if (AppPreference.getPreference('app_use_master_key') as boolean) {//区分启用主密钥和不适用主密钥场景下的name 防止用户反复切换功能开关造成的数据丢失
      query.set(asset.Tag.ALIAS, stringToArray(this._tokenMasterKeyEncryptionSecretKeyName)); // 指定了关键资产别名，最多查询到一条满足条件的关键资产
    }
    else
    {
      query.set(asset.Tag.ALIAS, stringToArray(this._tokenEncryptionSecretKeyName)); // 指定了关键资产别名，最多查询到一条满足条件的关键资产
    }

    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);  // 此处表示需要返回关键资产的所有信息，即属性+明文
    try {
      let  res =await asset.query(query);
      if (res.length>0)//查得到就说明已经有了 如果用户选择了密钥派生 也会直接赋值到这里
      {
        // parse the secret.
        let secret: Uint8Array = res[0].get(asset.Tag.SECRET) as Uint8Array;
        // parse uint8array to string
        let secretStr: string = base32Encode(secret);
        return secretStr;
      }
    } catch (error) {
      let err = error as BusinessError;
      hilog.error(err.code,"DataSyncToNoEncryptDatabase",`Failed to query Asset. Code is ${err.code}, message is ${err.message}`);
    }
    if (AppPreference.getPreference("app_use_master_key"))//如果启用了kdf则永远需要用户主动kdf然后设置密码到ASk
    {
      return "";
    }
    else //否则就动态生成一个AESKEy
    {
      let tokenData_alias=await this.getStringNoE(this._tokenEncryptionSecretKeyName);//恢复场景从未加密数据读取之前生成的密钥
      if (tokenData_alias!=null) { //如果从未加密数据库里面找到了之前存的密钥
        let attr: asset.AssetMap = new Map();
        attr.set(asset.Tag.SECRET, base32Decode(tokenData_alias));
        attr.set(asset.Tag.ALIAS,stringToArray(this._tokenEncryptionSecretKeyName));
        attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        await asset.add(attr);
        return tokenData_alias??"";
      }
      else//否则生成一个aes128的key
      {
        // 创建SymKeyGenerator实例。
        let symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
        // 使用密钥生成器随机生成对称密钥。
        let promiseSymKey = symKeyGenerator.generateSymKey();
        let key = await  promiseSymKey;
        // 获取对称密钥的二进制数据，输出128位密钥。长度为16字节。
        let encodedKey = key.getEncoded();
        await this.UpdateOrAddAssetStoreKit(this._tokenEncryptionSecretKeyName,encodedKey.data);
        let secretStr: string = base32Encode(encodedKey.data);
        this.setStringNoE(this._tokenEncryptionSecretKeyName,secretStr)
        return secretStr;
      }

    }
    return "";
  }

  //#region 主密码相关

  /**
   * 根据用户生成的密钥生成AESKEy存储到ASK中 并且生成一个恢复密钥.
   *
   */
  async EncryptionMasterKeyAndCreateRecoverySecretKey(user_key:string): Promise<string>
  {
    let spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: user_key,
      salt: new Uint8Array(16),
      iterations: 10000,
      keySize: 16
    };
    let kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    let symKeyBlob = kdf.generateSecretSync(spec);

    let symKeyBlobStr: string= base32Encode(symKeyBlob.data);  //用户主密码派生的密钥
    await this.UpdateOrAddAssetStoreKit(this._tokenMasterKeyEncryptionSecretKeyName,symKeyBlob.data);//向ASK存储主密钥

    // 创建SymKeyGenerator实例。
    let symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    // 使用密钥生成器随机生成对称密钥。
    let promiseSymKey = symKeyGenerator.generateSymKey();
    let key = await  promiseSymKey;
    // 获取对称密钥的二进制数据，输出128位密钥。长度为16字节。
    let recoveryKey = key.getEncoded();
    let recoveryKeyStr: string= base32Encode(recoveryKey.data);  //用来加密主密钥的随机密钥 恢复密钥 给用户显示出来
    let encodedKey: cryptoFramework.DataBlob = { data: recoveryKey.data};
    let symKeyBlobEncryption =await encryptUint8ArrayData(symKeyBlob.data,encodedKey)//将主密钥加密
    let symKeyBlobEncryptionStr= base32Encode(symKeyBlobEncryption);
    await this.setStringNoE(this._tokenEncryptionMasterRecoverySecretKeyName,symKeyBlobEncryptionStr);//存储恢复密钥数据

    return recoveryKeyStr;//反馈恢复密钥

  }
  /**
   * 校验主密码.
   *
   */
  async CheckMasterKey(user_key:string): Promise<boolean>
  {
    let spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: user_key,
      salt: new Uint8Array(16),
      iterations: 10000,
      keySize: 16
    };
    let kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    let symKeyBlob = kdf.generateSecretSync(spec);

    let symKeyBlobStr: string= base32Encode(symKeyBlob.data);  //用户主密码派生的密钥

    //获取测试数据
    let testData= await this._kvStoreNoE?.getEntries(this._tokenMasterKeyEncryptionSecretKeyNameTest)
    if (testData && testData.length>0) {
      let testDataBold=testData[0].value.value as Uint8Array;
      let dataitem=await decryptStringData(testDataBold,symKeyBlob);
      if (dataitem!=null) {
        await this.UpdateOrAddAssetStoreKit(this._tokenMasterKeyEncryptionSecretKeyName,symKeyBlob.data);//向ASK存储主密钥
        return true;
      }
    }
    return false;
  }
  /**
   * 校验恢复密钥并恢复
   *
   */
  async CheckRecoverySecretKey(recoveryKeyStr:string): Promise<boolean>
  {
    try {
      let recoveryKeyBlob : Uint8Array= base32Decode(recoveryKeyStr);  //尝试解密用户输入的密钥
      let encodedKeyStrBlob: cryptoFramework.DataBlob = { data: recoveryKeyBlob};//用户恢复密钥生成的AESKEy
      let RecoverySecretKeyStr= await this.getStringNoE(this._tokenEncryptionMasterRecoverySecretKeyName);//获取存储的恢复密钥数据
      if (RecoverySecretKeyStr!=null) {
        let RecoverySecretKeyBlob=base32Decode(RecoverySecretKeyStr);  //获取存储的恢复密钥blob
        let symKeyBlobEncryption =await decryptUint8ArrayData(RecoverySecretKeyBlob,encodedKeyStrBlob)//将主密钥解密
        if (symKeyBlobEncryption!=null) {//解密成功
          await this.UpdateOrAddAssetStoreKit(this._tokenMasterKeyEncryptionSecretKeyName,symKeyBlobEncryption);//向ASK存储主密钥
          return true;
        }
        else
        {
          return false;
        }
      }

    }
    catch (error)
    {
      let err = error as BusinessError;
      hilog.error(err.code,"CheckRecoverySecretKey",`Failed to CheckRecoverySecretKey. Code is ${err.code}, message is ${err.message}`);
    }
    return false;



  }


  /**
   * 新增或更新ASK.
   *
   */
  async UpdateOrAddAssetStoreKit(Alias:string,Key:Uint8Array): Promise<void>
  {
    let query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToArray(Alias)); // 指定了关键资产别名，最多查询到一条满足条件的关键资产
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);  // 此处表示需要返回关键资产的所有信息，即属性+明文
    try {
      let  res =await asset.query(query);
      if (res.length>0)//查得到就说明已经有了 这个时候要走更新密钥
      {
        let updateQuery: asset.AssetMap = new Map();
        updateQuery.set(asset.Tag.ALIAS, stringToArray(Alias));
        let attrsToUpdate: asset.AssetMap = new Map();
        attrsToUpdate.set(asset.Tag.SECRET,Key);
        await asset.update(updateQuery, attrsToUpdate);
      }
    } catch (error) {
      let err = error as BusinessError;
      hilog.error(err.code,"UpdateOrAddAssetStoreKit",`Failed to query Asset. Code is ${err.code}, message is ${err.message}`);
    }
    try {
      //这个时候要走新增密钥
      let attr: asset.AssetMap = new Map();
      attr.set(asset.Tag.SECRET, Key);
      attr.set(asset.Tag.ALIAS,stringToArray(Alias));
      attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(attr);
    }
    catch (error) {
      let err = error as BusinessError;
      hilog.error(err.code,"UpdateOrAddAssetStoreKit",`Failed to Add Asset. Code is ${err.code}, message is ${err.message}`);
    }
  }
  //#endregion
  //手动同步
  async DataSync(): Promise<void> {
    if (AppPreference.getPreference('app_db_rds_sync_enable')) {
      try {
        let bundleInfo = AppStorage.get<bundleManager.BundleInfo>("BundleInfo");
        let dmInstance = distributedDeviceManager.createDeviceManager(bundleInfo?.name);
        let deviceInfoList: Array<distributedDeviceManager.DeviceBasicInfo> = dmInstance.getAvailableDeviceListSync();
        if (deviceInfoList.length > 0) {
          let deviceNetWorkIDList:string[] = [];
          for (let i = 0; i < deviceInfoList.length; i++) {
            deviceNetWorkIDList[i] = deviceInfoList[i].networkId as string;
          }
          // deviceInfoList.forEach(dev => {
          //   //目前仅同步
          //   // -14: PHONE。
          //   // -17: PAD。
          //   // -2607: 2in1。
          //   if (dev.deviceType === "PHONE" ||dev.deviceType === "PAD"||dev.deviceType === "2in1") {
          //     if (dev.networkId!=null) {
          //       deviceNetWorkIDList.push(dev.networkId as string );
          //     }
          //   }
          // });
          if (deviceNetWorkIDList.length > 0) {
            let formattedDate: string = Date.now().toString();
            this._kvStore?.put("LastSyncTime", formattedDate)
            const query = new distributedKVStore.Query();
            query.prefixKey("_token_uuid_");
            this._kvStore?.sync(deviceNetWorkIDList, query, distributedKVStore.SyncMode.PUSH_PULL, 1000*10);
            this._kvStoreNoE?.sync(deviceNetWorkIDList, query, distributedKVStore.SyncMode.PUSH_PULL, 1000*10);
          }
        }
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        console.error('getAvailableDeviceListSync errCode:' + e.code + ', errMessage:' + e.message);
      }

    }
  }
}
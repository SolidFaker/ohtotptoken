import { fileIo as fs, picker } from "@kit.CoreFileKit";
import { common } from '@kit.AbilityKit';
import { intArrayToString } from "./TokenUtils";
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';

const BUFFER_SIZE = 4096;

export async function readFileContent(uri: string): Promise<string> {
  let content = '';
  return await fs.open(uri, fs.OpenMode.READ_ONLY).then((f) => {
    let buffer = new ArrayBuffer(BUFFER_SIZE);
    let offset = 0;
    let readOut = 0;
    do {
      readOut = fs.readSync(f.fd, buffer, { offset: offset });
      content += intArrayToString(buffer.slice(0, readOut));
      offset += BUFFER_SIZE;
    } while (readOut == BUFFER_SIZE)
    fs.close(f.fd);
    return content;
  });
}

export async function writeFileContent(uri: string, content: string): Promise<void> {
  //调整为覆盖写入 只写入 并且创建新文件
  fs.open(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.CREATE).then((f) => {
    fs.write(f.fd, content).then(() => {
      fs.close(f.fd);
    });
  }).catch((reason: BusinessError)=>{
    console.log(reason.message)
  });
}
//写入文件确认文件是否重复 如果重复放弃写入
export async function writeFileContentCheckHashEqual(uri: string, content: string): Promise<void> {
  let isWrite=true;
  if (await fs.access(uri)) {
    let fileContent= await readFileContent(uri);
    let fileHash=await Sha256Hash(fileContent);
    let contentHash=await Sha256Hash(content);
    isWrite= !constantTimeCompare(fileHash,contentHash);//比对哈希不同才写入
  }

  if (isWrite)//比对哈希不同才写入
  {
    //调整为覆盖写入 只写入 并且创建新文件
    await fs.open(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.CREATE).then((f) => {
    }).catch((reason: BusinessError)=>{
      console.log(reason.message)
    });
  }

}
export async function Sha256Hash(content: string) {
  let mdAlgName = 'SHA256'; // 摘要算法名。
  let message = 'mdTestMessage'; // 待摘要的数据。
  let md = cryptoFramework.createMd(mdAlgName);
  // 数据量较少时，可以只做一次update，将数据全部传入，接口未对入参长度做限制。
  await md.update({ data: new Uint8Array(buffer.from(message, 'utf-8').buffer) });
  let mdResult = await md.digest();
  console.info('Md result:' + mdResult.data);
  return mdResult.data;
}
export async function showSelectFilePicker(max_num: number, filters: string[]): Promise<string[]> {
  const documentSelectOptions = new picker.DocumentSelectOptions();
  documentSelectOptions.maxSelectNumber = max_num;
  documentSelectOptions.fileSuffixFilters = filters;
  let context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  const documentViewPicker = new picker.DocumentViewPicker(context);
  return documentViewPicker.select(documentSelectOptions);
}

export async function showSaveFilePicker(name: string[], filters: string[]): Promise<string[]> {
  const documentSaveOptions = new picker.DocumentSaveOptions();
  documentSaveOptions.newFileNames = name;
  documentSaveOptions.fileSuffixChoices = filters;
  let context = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  const documentViewPicker = new picker.DocumentViewPicker(context);
  return documentViewPicker.save(documentSaveOptions);
}
//固定使用sha256比对是否相同hash 暂不考虑不同hash长度比对
function constantTimeCompare(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }

  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i]; // 按位异或后累积差异
  }

  return result === 0;
}
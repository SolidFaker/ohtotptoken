
import { systemDateTime } from '@kit.BasicServicesKit';
import { AegisIcon, AegisIconPack, BUILTIN_DEFAULT_PACK_ID, TokenIconPacks } from 'common';

export enum IconPickerDataType {
  AUTO = 0,
  ADD = 1,
  USER = 2,
  PACK = 3
}

const TEMPLATE_AUTO: string = 'AUTO';
const TEMPLATE_ADD: string = 'ADD';
const TEMPLATE_USER: string = 'USER';
const TEMPLATE_PACK: string = 'PACK';
const KEY_AUTO: string = '__auto__';
const KEY_ADD: string = '__add__';
const KEY_USER: string = 'user';
const KEY_PACK: string = 'pack';
/** 单个同步分片预算：最多检查步数与主动耗时（ACTIVE uptime）。 */
const MAX_ITEMS_PER_CHUNK: number = 128;
const CHUNK_BUDGET_MS: number = 4;
/** ACTIVE 时钟抽检间隔：每 N 步才取一次 uptime，避免逐条目 Native 调用放大分片耗时；预算为近似值，条目上限兜底。 */
const UPTIME_CHECK_STEP: number = 16;
/** 自定义包索引缓存上限（LRU；仅钉住已提交的活跃包，默认/用户索引单独保存）。 */
const MAX_CUSTOM_INDEX: number = 2;
const PULL_ITEM: number = 0;
const PULL_STEP: number = 1;
const PULL_DONE: number = 2;

@ObservedV2
export class IconGridItem {
  readonly key: string;
  readonly type: IconPickerDataType;
  readonly templateId: string;
  readonly path: string;
  readonly removable: boolean;

  constructor(key: string, type: IconPickerDataType, templateId: string, path: string = '', removable: boolean = false) {
    this.key = key;
    this.type = type;
    this.templateId = templateId;
    this.path = path;
    this.removable = removable;
  }
}

/** 轻量包描述符快照；构建时不遍历 icons。 */
export class IconPackDescriptor {
  readonly identityKey: string;
  readonly uuid: string;
  readonly name: string;
  readonly version: number;
  readonly onDevicePath: string;
  readonly invalid: boolean;
  readonly isDefault: boolean;

  constructor(uuid: string, name: string, version: number, onDevicePath: string, invalid: boolean, isDefault: boolean) {
    this.uuid = uuid;
    this.name = name;
    this.version = version;
    this.onDevicePath = onDevicePath;
    this.invalid = invalid;
    this.isDefault = isDefault;
    this.identityKey = encodeKeyParts([uuid, onDevicePath, String(version)]);
  }
}

/** true=请求已过期或页面已离开；页面以自身 generation 实现，模型另以 revision 防御失效后的在途提交。 */
export interface IconPickerCancellation {
  isCancelled: () => boolean;
}

/** 按请求注入的同步分片标记；begin/end 必须在 finally 成对。 */
export interface IconPickerSliceHooks {
  beginSlice: () => boolean;
  endSlice: (active: boolean) => void;
}

export const NO_OP_SLICE: IconPickerSliceHooks = {
  beginSlice: (): boolean => false,
  endSlice: (_active: boolean): void => {}
};

/** 长度前缀编码：key 组件（uuid/路径/版本等）内容任意也不会产生歧义或碰撞。 */
function encodeKeyParts(parts: string[]): string {
  let encoded: string = '';
  for (let i = 0; i < parts.length; i++) {
    encoded += parts[i].length + ':' + parts[i];
  }
  return encoded;
}

function baseNameLower(path: string): string {
  const lastSep = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  let name = path.substring(lastSep + 1);
  const dot = name.lastIndexOf('.');
  if (dot > 0) {
    name = name.substring(0, dot);
  }
  return name.toLowerCase();
}

function nowActiveMs(): number {
  // 与 IconPickerPerf 守护同一时钟（ACTIVE），不用 Date.now。
  try {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false);
  } catch (_e) {
    return 0;
  }
}

/** AegisIcon 路径游标：单次 stepNext 直接产出路径（PULL_ITEM）或消耗一次非路径推进（PULL_STEP，空路径 icon）；多路径不丢。 */
class AegisPathCursor {
  private readonly icons: AegisIcon[];
  private iconIdx: number = 0;
  private iter: IterableIterator<string> | undefined = undefined;
  current: string = '';

  constructor(icons: AegisIcon[]) {
    this.icons = icons;
  }

  /** @throws 图标包路径集合损坏时交由当前请求处理失败。 */
  stepNext(): number {
    if (this.iter !== undefined) {
      const step = this.iter.next();
      if (!step.done) {
        // SDK 迭代器 value 在 done=false 分支为具体值，联合类型需显式收窄
        this.current = step.value as string;
        return PULL_ITEM;
      }
      this.iter = undefined;
    }
    if (this.iconIdx >= this.icons.length) {
      return PULL_DONE;
    }
    // 创建迭代器与取首条路径合并为一次调用：常见单路径 icon 由两步降为一步
    const iter = this.icons[this.iconIdx].icon_pack_path.values();
    this.iconIdx++;
    const first = iter.next();
    if (first.done) {
      // 空路径 icon：计一次非路径推进，保持分片上限对"全空包"仍有界
      return PULL_STEP;
    }
    this.iter = iter;
    this.current = first.value as string;
    return PULL_ITEM;
  }
}

/** 用户区索引；仅在 invalidateUsers 后重建。 */
class UserIndex {
  built: boolean = false;
  headItems: IconGridItem[] = [];
  userItems: IconGridItem[] = [];
}

class PackIndex {
  built: boolean = false;
  items: IconGridItem[] = [];
  namesLower: string[] = [];
  // 空 query 整包结果缓存（仅指针数组），绑定组装时的模型 revision；暖切换直接复用，不重跑分片
  emptyQueryItems: IconGridItem[] | undefined = undefined;
  emptyQueryRevision: number = -1;
}

/** ensure* 结果：fresh=true 表示本次调用实际重建索引（构建 pull 中已同步把条目追加进 composed）。 */
class IndexBuild {
  readonly index: PackIndex;
  readonly fresh: boolean;

  constructor(index: PackIndex, fresh: boolean) {
    this.index = index;
    this.fresh = fresh;
  }
}

/** 每个 IconPicker 页面一个实例，离页调用 dispose()。 */
export class IconPickerModel {
  private descriptors: IconPackDescriptor[] = [];
  private defaultDescriptor: IconPackDescriptor =
    new IconPackDescriptor(BUILTIN_DEFAULT_PACK_ID, 'Default', 0, 'rawfile://icons', false, true);
  private defaultIndex: PackIndex = new PackIndex();
  private userIndex: UserIndex = new UserIndex();
  private customIndexes: Map<string, PackIndex> = new Map<string, PackIndex>();
  private lastPackKey: string = '';
  private lastQuery: string = '';
  private lastItems: IconGridItem[] | undefined = undefined;
  private revision: number = 0;
  private disposed: boolean = false;
  private yieldTimerId: number = -1;
  private pendingYields: Array<() => void> = [];

  constructor() {
    this.refreshDescriptors();
  }

  refreshDescriptors(): void {
    this.defaultDescriptor = new IconPackDescriptor(BUILTIN_DEFAULT_PACK_ID,
      TokenIconPacks.default_icon_pack.name, 0, 'rawfile://icons', false, true);
    const list: IconPackDescriptor[] = [this.defaultDescriptor];
    const packs = TokenIconPacks.aegis_icon_packs;
    for (let i = 0; i < packs.length; i++) {
      list.push(new IconPackDescriptor(packs[i].uuid, packs[i].name, packs[i].version,
        packs[i].on_device_path, packs[i].invalid, false));
    }
    this.descriptors = list;
  }

  /** 索引 0 为默认包，i+1 为 aegis_icon_packs[i]。 */
  listPackDescriptors(): IconPackDescriptor[] {
    return this.descriptors;
  }

  packKeyForIndex(index: number): string {
    if (index >= 0 && index < this.descriptors.length) {
      return this.descriptors[index].identityKey;
    }
    return this.defaultDescriptor.identityKey;
  }

  /** 包身份不存在时返回 -1（调用方按默认包处理）。 */
  resolvePackIndex(packKey: string): number {
    for (let i = 0; i < this.descriptors.length; i++) {
      if (this.descriptors[i].identityKey === packKey) {
        return i;
      }
    }
    return -1;
  }

  /** 准备一次请求的完整条目数组；过期/失效返回 undefined，结果原子提交，仅最新请求写入缓存。 */
  /**
   * @throws 默认包路径集合不可读或活跃自定义包消失时向上抛出，交由当前请求处理失败。
   */
  async prepare(packKey: string, query: string, cancellation: IconPickerCancellation,
    slice: IconPickerSliceHooks = NO_OP_SLICE): Promise<IconGridItem[] | undefined> {
    // 过期请求不得短路复用，也不得提交
    if (this.disposed || cancellation.isCancelled()) {
      return undefined;
    }
    const revisionAtStart = this.revision;
    if (this.lastItems !== undefined && this.lastPackKey === packKey && this.lastQuery === query) {
      return this.lastItems;
    }
    let pack = this.descriptorByPackKey(packKey);
    if (!pack.isDefault && this.findLiveAegisPack(pack) === undefined) {
      // 身份在两次请求之间消失：回退默认包
      pack = this.defaultDescriptor;
    }
    const emptyQuery = query === '';
    // 暖切换先于任何构建/分片排队：已构建索引的整包结果直接复用（revision 绑定，失效即弃）
    if (emptyQuery) {
      const cached = this.peekEmptyQueryItems(pack, revisionAtStart);
      if (cached !== undefined) {
        if (this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
          return undefined;
        }
        if (!pack.isDefault) {
          // 与 ensureCustomIndex 命中路径一致：暖复用同样触碰 LRU（失效请求已在上方返回，不触碰顺序）
          const warmIndex = this.customIndexes.get(pack.identityKey);
          if (warmIndex !== undefined) {
            this.customIndexes.delete(pack.identityKey);
            this.customIndexes.set(pack.identityKey, warmIndex);
          }
        }
        this.lastPackKey = pack.identityKey;
        this.lastQuery = query;
        this.lastItems = cached;
        return cached;
      }
    }
    // 空 query 先备好用户区索引，包索引构建 pull 内即可同步把条目追加进整包结果（免去构建后第二次全量扫描）
    let userIndex: UserIndex = this.userIndex;
    let composed: IconGridItem[] | undefined = undefined;
    if (emptyQuery) {
      const built = await this.ensureUserIndex(cancellation, slice, revisionAtStart);
      if (built === undefined) {
        return undefined;
      }
      userIndex = built;
      composed = [];
      // 头部固定 2 项，直接 push；用户区条目走同一分片预算拷贝
      composed.push(built.headItems[0]);
      composed.push(built.headItems[1]);
      const appended = await this.appendExisting(composed, built.userItems,
        cancellation, slice, revisionAtStart);
      if (appended !== true) {
        return undefined;
      }
      // 拷贝恢复点后再校验（含无让出的单分片完成路径）：失效不得进入包索引构建
      if (this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
        return undefined;
      }
    }
    let build: IndexBuild | undefined = undefined;
    if (pack.isDefault) {
      build = await this.ensureDefaultIndex(cancellation, slice, revisionAtStart, composed);
    } else {
      build = await this.ensureCustomIndex(pack, cancellation, slice, revisionAtStart, composed);
    }
    if (build === undefined) {
      return undefined;
    }
    const index = build.index;
    let items: IconGridItem[] | undefined = undefined;
    if (composed !== undefined && build.fresh) {
      // 本次构建已在分片内同步完成整包组装，无需再扫
      items = composed;
    }
    if (items === undefined) {
      // 非空 query（按名过滤）或索引已存在但整包缓存失效：按阶段分片组装
      items = await this.composeResult(index, userIndex, query, cancellation, slice, revisionAtStart);
      if (items === undefined) {
        return undefined;
      }
    }
    // 全部提交点统一守卫：离页、过期、模型失效（用户/包事件）都不得写入缓存
    if (this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
      return undefined;
    }
    this.lastPackKey = pack.identityKey;
    this.lastQuery = query;
    this.lastItems = items;
    if (emptyQuery) {
      // 仅缓存空 query 整包结果；非空 query 只留 lastItems
      index.emptyQueryItems = items;
      index.emptyQueryRevision = this.revision;
    }
    return items;
  }

  /** 用户图标增删：递增 revision 使在途结果失效，用户区索引与缓存结果整体丢弃。 */
  invalidateUsers(): void {
    this.revision++;
    this.userIndex = new UserIndex();
    this.lastPackKey = '';
    this.lastQuery = '';
    this.lastItems = undefined;
  }

  /** ICON_PACK_CHANGED：递增 revision，刷新描述符；包内容可能已变，全部自定义索引按事件失效。 */
  invalidatePacks(): void {
    this.revision++;
    this.refreshDescriptors();
    this.lastPackKey = '';
    this.lastQuery = '';
    this.lastItems = undefined;
    this.customIndexes.clear();
  }

  dispose(): void {
    this.disposed = true;
    if (this.yieldTimerId !== -1) {
      clearTimeout(this.yieldTimerId);
      this.yieldTimerId = -1;
    }
    this.flushYields();
    this.customIndexes.clear();
    this.defaultIndex = new PackIndex();
    this.userIndex = new UserIndex();
    this.descriptors = [];
    this.lastItems = undefined;
  }

  private descriptorByPackKey(packKey: string): IconPackDescriptor {
    const index = this.resolvePackIndex(packKey);
    if (index >= 0) {
      return this.descriptors[index];
    }
    return this.defaultDescriptor;
  }

  private findLiveAegisPack(pack: IconPackDescriptor): AegisIconPack | undefined {
    const packs = TokenIconPacks.aegis_icon_packs;
    for (let i = 0; i < packs.length; i++) {
      if (packs[i].uuid === pack.uuid && packs[i].on_device_path === pack.onDevicePath
        && packs[i].version === pack.version) {
        return packs[i];
      }
    }
    return undefined;
  }

  /** pull 返回 PULL_ITEM/PULL_STEP（继续）或 PULL_DONE（结束）；true=正常完成，undefined=已取消/失效/离页。 */
  private async runChunked(cancellation: IconPickerCancellation, slice: IconPickerSliceHooks,
    revisionAtStart: number, pull: () => number): Promise<boolean | undefined> {
    let finished: boolean = false;
    while (!finished) {
      let sliceActive: boolean = false;
      try {
        sliceActive = slice.beginSlice();
        const chunkStart = nowActiveMs();
        let inspected: number = 0;
        while (inspected < MAX_ITEMS_PER_CHUNK) {
          // 预算只作近似约束：单条目耗时无法预判，每 UPTIME_CHECK_STEP 步抽检一次，条目上限兜底
          if (inspected % UPTIME_CHECK_STEP === UPTIME_CHECK_STEP - 1
            && nowActiveMs() - chunkStart >= CHUNK_BUDGET_MS) {
            break;
          }
          inspected++;
          if (pull() === PULL_DONE) {
            finished = true;
            break;
          }
        }
      } finally {
        slice.endSlice(sliceActive);
      }
      if (finished) {
        break;
      }
      await this.yieldToMacroTask();
      if (this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
        return undefined;
      }
    }
    return true;
  }

  /** key 前缀（包身份+pack 段，或 user 段）对单个索引恒定，预计算后逐条目只需拼接路径段；与 encodeKeyParts 全拼结果完全一致。 */
  private makePackKey(keyPrefix: string, path: string): string {
    return keyPrefix + path.length + ':' + path;
  }

  /** @throws 默认包路径集合不可读时交由当前请求处理失败。 */
  private async ensureDefaultIndex(cancellation: IconPickerCancellation, slice: IconPickerSliceHooks,
    revisionAtStart: number, composed: IconGridItem[] | undefined): Promise<IndexBuild | undefined> {
    if (this.defaultIndex.built) {
      return new IndexBuild(this.defaultIndex, false);
    }
    const index = new PackIndex();
    const pack = this.defaultDescriptor;
    const keyPrefix = encodeKeyParts([pack.identityKey, KEY_PACK]);
    const paths = TokenIconPacks.default_icon_pack.default_icon_pack_path.values();
    const pull = (): number => {
      const step = paths.next();
      if (step.done) {
        return PULL_DONE;
      }
      const path = step.value as string;
      const item = new IconGridItem(this.makePackKey(keyPrefix, path),
        IconPickerDataType.PACK, TEMPLATE_PACK, path);
      index.items.push(item);
      index.namesLower.push(baseNameLower(path));
      if (composed !== undefined) {
        composed.push(item);
      }
      return PULL_ITEM;
    };
    const ok = await this.runChunked(cancellation, slice, revisionAtStart, pull);
    // await 恢复点后、任何实际赋值前再校验：失效可能发生在最后一个分片完成之后
    if (ok !== true || this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
      return undefined;
    }
    index.built = true;
    this.defaultIndex = index;
    return new IndexBuild(index, true);
  }

  private async ensureUserIndex(cancellation: IconPickerCancellation, slice: IconPickerSliceHooks,
    revisionAtStart: number): Promise<UserIndex | undefined> {
    if (this.userIndex.built) {
      return this.userIndex;
    }
    const index = new UserIndex();
    index.headItems.push(new IconGridItem(KEY_AUTO, IconPickerDataType.AUTO, TEMPLATE_AUTO));
    index.headItems.push(new IconGridItem(KEY_ADD, IconPickerDataType.ADD, TEMPLATE_ADD));
    const paths = TokenIconPacks.user_added_icon_packs.icon_path;
    const seen: Set<string> = new Set<string>();
    // user 段 key 前缀恒定，预计算避免逐条目重拼（重复路径在 seen 命中后不进编码）
    const keyPrefix = encodeKeyParts([KEY_USER]);
    let pos: number = 0;
    const pull = (): number => {
      if (pos >= paths.length) {
        return PULL_DONE;
      }
      const path = paths[pos];
      pos++;
      if (path === undefined || seen.has(path)) {
        return PULL_STEP;
      }
      seen.add(path);
      const key = this.makePackKey(keyPrefix, path);
      index.userItems.push(new IconGridItem(key, IconPickerDataType.USER, TEMPLATE_USER, path, true));
      return PULL_ITEM;
    };
    const ok = await this.runChunked(cancellation, slice, revisionAtStart, pull);
    // await 恢复点后、任何实际赋值前再校验：失效可能发生在最后一个分片完成之后
    if (ok !== true || this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
      return undefined;
    }
    index.built = true;
    this.userIndex = index;
    return index;
  }

  private async ensureCustomIndex(pack: IconPackDescriptor, cancellation: IconPickerCancellation,
    slice: IconPickerSliceHooks, revisionAtStart: number, composed: IconGridItem[] | undefined):
    Promise<IndexBuild | undefined> {
    const cached = this.customIndexes.get(pack.identityKey);
    if (cached !== undefined && cached.built) {
      // 失效请求不得触碰 LRU 顺序（invalidateUsers 后索引仍在，但 revision 已变）
      if (this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
        return undefined;
      }
      this.customIndexes.delete(pack.identityKey);
      this.customIndexes.set(pack.identityKey, cached);
      return new IndexBuild(cached, false);
    }
    const live = this.findLiveAegisPack(pack);
    if (live === undefined) {
      throw new Error('Icon pack is no longer available');
    }
    const index = new PackIndex();
    const keyPrefix = encodeKeyParts([pack.identityKey, KEY_PACK]);
    const cursor = new AegisPathCursor(live.icons);
    const seen: Set<string> = new Set<string>();
    const pull = (): number => {
      const step = cursor.stepNext();
      if (step === PULL_DONE) {
        return PULL_DONE;
      }
      if (step === PULL_ITEM && !seen.has(cursor.current)) {
        seen.add(cursor.current);
        const item = new IconGridItem(this.makePackKey(keyPrefix, cursor.current),
          IconPickerDataType.PACK, TEMPLATE_PACK, cursor.current);
        index.items.push(item);
        index.namesLower.push(baseNameLower(cursor.current));
        if (composed !== undefined) {
          composed.push(item);
        }
      }
      return PULL_STEP;
    };
    const ok = await this.runChunked(cancellation, slice, revisionAtStart, pull);
    // await 恢复点后、任何实际赋值前再校验：失效可能发生在最后一个分片完成之后
    if (ok !== true || this.disposed || cancellation.isCancelled() || this.revision !== revisionAtStart) {
      return undefined;
    }
    index.built = true;
    this.storeCustomIndex(pack.identityKey, index);
    return new IndexBuild(index, true);
  }

  /** 已构建索引且整包缓存绑定当前 revision 时返回可复用数组，否则 undefined。 */
  private peekEmptyQueryItems(pack: IconPackDescriptor, revisionAtStart: number): IconGridItem[] | undefined {
    const index = pack.isDefault ? this.defaultIndex : this.customIndexes.get(pack.identityKey);
    if (index === undefined || !index.built) {
      return undefined;
    }
    if (index.emptyQueryItems === undefined || index.emptyQueryRevision !== revisionAtStart) {
      return undefined;
    }
    return index.emptyQueryItems;
  }

  /** 指针 push 拷贝走同一分片预算（最多128项/约4ms，条目上限兜底）；小列表在首分片内完成，不产生宏任务让出。 */
  private async appendExisting(target: IconGridItem[], source: IconGridItem[],
    cancellation: IconPickerCancellation, slice: IconPickerSliceHooks,
    revisionAtStart: number): Promise<boolean | undefined> {
    let pos: number = 0;
    const pull = (): number => {
      if (pos >= source.length) {
        return PULL_DONE;
      }
      target.push(source[pos]);
      pos++;
      return PULL_ITEM;
    };
    return this.runChunked(cancellation, slice, revisionAtStart, pull);
  }

  /** 结果组装：只复用预构建条目对象（指针拷贝），不按请求新建。用于非空 query 过滤与整包缓存失效后的重组。 */
  private async composeResult(index: PackIndex, userIndex: UserIndex, query: string,
    cancellation: IconPickerCancellation, slice: IconPickerSliceHooks,
    revisionAtStart: number): Promise<IconGridItem[] | undefined> {
    const items: IconGridItem[] = [];
    const q = query.toLowerCase();
    let phase: number = query === '' ? 0 : 2;
    let pos: number = 0;
    const pull = (): number => {
      if (phase > 2) {
        return PULL_DONE;
      }
      const source = phase === 0 ? userIndex.headItems : (phase === 1 ? userIndex.userItems : index.items);
      if (pos >= source.length) {
        phase++;
        pos = 0;
        return phase > 2 ? PULL_DONE : PULL_STEP;
      }
      const item = source[pos];
      pos++;
      if (phase === 2 && query !== '' && !index.namesLower[pos - 1].includes(q)) {
        return PULL_STEP;
      }
      items.push(item);
      return PULL_ITEM;
    };
    const ok = await this.runChunked(cancellation, slice, revisionAtStart, pull);
    if (ok !== true) {
      return undefined;
    }
    return items;
  }

  /** 提交自定义索引：LRU 触碰后按插入序驱逐最旧者；只保护最近已提交的活跃包。 */
  private storeCustomIndex(identityKey: string, index: PackIndex): void {
    this.customIndexes.delete(identityKey);
    this.customIndexes.set(identityKey, index);
    while (this.customIndexes.size > MAX_CUSTOM_INDEX) {
      let evictKey: string = '';
      for (const key of this.customIndexes.keys()) {
        if (key !== this.lastPackKey) {
          evictKey = key;
          break;
        }
      }
      if (evictKey === '') {
        break;
      }
      this.customIndexes.delete(evictKey);
    }
  }

  /** 宏任务让出；dispose() 释放挂起等待者，离页后不残留定时器或悬空 Promise。 */
  private yieldToMacroTask(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.pendingYields.push(resolve);
      if (this.yieldTimerId === -1) {
        this.yieldTimerId = setTimeout(() => {
          this.yieldTimerId = -1;
          this.flushYields();
        }, 0);
      }
    });
  }

  private flushYields(): void {
    const waiting = this.pendingYields;
    this.pendingYields = [];
    for (const release of waiting) {
      release();
    }
  }
}

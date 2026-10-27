import { FrameCallback, UIContext } from '@kit.ArkUI';
import { systemDateTime } from '@kit.BasicServicesKit';
import { hiTraceMeter } from '@kit.PerformanceAnalysisKit';

const LOCAL_DIAG_BUILD: boolean = false;
const LEVEL = hiTraceMeter.HiTraceOutputLevel.INFO;
const SESSION_MS: number = 600000;
const REQUEST_MS: number = 5000;
const MAX_REQUESTS: number = 1000;

type PerfResult = 'READY' | 'FAILED' | 'CANCELLED' | 'TIMEOUT' | 'UNAVAILABLE' | 'LEFT';
type PerfPhase = 'open.data' | 'open.contentReady' | 'switch.data' | 'switch.commit' | 'switch.contentReady';

export interface IconPickerItemMeta {
  key: string;
  path: string;
}

export class IconPickerImageBinding {
  readonly nodeId: number;
  readonly sourceId: number;
  readonly key: string;
  readonly source: string;
  readonly width: number;
  readonly height: number;
  completed: boolean = false;
  failed: boolean = false;

  constructor(nodeId: number, sourceId: number, key: string, source: string, width: number, height: number) {
    this.nodeId = nodeId;
    this.sourceId = sourceId;
    this.key = key;
    this.source = source;
    this.width = width;
    this.height = height;
  }
}

class PerfRequest {
  readonly id: number;
  readonly phases: PerfPhase[];
  readonly pending: Set<PerfPhase> = new Set<PerfPhase>();
  readonly started: number;
  items: IconPickerItemMeta[] | undefined = undefined;
  sourceId: number = -1;
  dataReady: boolean = false;
  layoutReady: boolean = false;
  verifyPosted: boolean = false;
  contentPosted: boolean = false;
  expected: Map<string, IconPickerImageBinding> = new Map<string, IconPickerImageBinding>();
  waiting: Set<string> = new Set<string>();
  timer: number = -1;
  terminal: boolean = false;

  constructor(id: number, open: boolean, started: number) {
    this.id = id;
    this.started = started;
    this.phases = open ? ['open.data', 'open.contentReady'] :
      ['switch.data', 'switch.commit', 'switch.contentReady'];
  }
}

class PickerFrame extends FrameCallback {
  private action: () => void;

  constructor(action: () => void) {
    super();
    this.action = action;
  }

  onIdle(_timeLeft: number): void {
    this.action();
  }
}

/** 精确标记仅用于显式本地构建；源绑定记录不进入 trace 或日志。 */
export class IconPickerPerf {
  private static sessionStart: number = -1;
  private static stopped: boolean = false;
  private static requests: number = 0;
  private static sequence: number = 0;
  private static sourceSequence: number = 0;
  private static nodeSequence: number = 0;
  private static current: PerfRequest | undefined = undefined;
  private static context: UIContext | undefined = undefined;
  private static pageReady: boolean = false;
  private static presented: number = -1;
  private static scroller: Scroller | undefined = undefined;
  private static rangeSource: number = -1;
  private static first: number = -1;
  private static last: number = -1;
  private static bindings: Map<number, IconPickerImageBinding> | undefined = undefined;
  private static bindingsBySource: Map<number, Map<string, IconPickerImageBinding>> | undefined = undefined;
  private static readonly noBinding: IconPickerImageBinding = new IconPickerImageBinding(-1, -1, '', '', 0, 0);

  static isActive(): boolean {
    return LOCAL_DIAG_BUILD;
  }

  static disabledBinding(): IconPickerImageBinding {
    return IconPickerPerf.noBinding;
  }

  static nextSourceId(): number {
    return LOCAL_DIAG_BUILD ? ++IconPickerPerf.sourceSequence : -1;
  }

  static nextNodeId(): number {
    return LOCAL_DIAG_BUILD ? ++IconPickerPerf.nodeSequence : -1;
  }

  private static now(startup: boolean = false): number {
    try {
      return systemDateTime.getUptime(startup ? systemDateTime.TimeType.STARTUP : systemDateTime.TimeType.ACTIVE, false);
    } catch (_) {
      return -1;
    }
  }

  private static enabled(): boolean {
    if (!LOCAL_DIAG_BUILD || IconPickerPerf.stopped) {
      return false;
    }
    try {
      const now = IconPickerPerf.now(true);
      if (now < 0 || (IconPickerPerf.sessionStart >= 0 && now - IconPickerPerf.sessionStart >= SESSION_MS)) {
        IconPickerPerf.cancel('UNAVAILABLE');
        IconPickerPerf.stopped = true;
        return false;
      }
      if (!hiTraceMeter.isTraceEnabled()) {
        IconPickerPerf.cancel('UNAVAILABLE');
        return false;
      }
      return true;
    } catch (_) {
      IconPickerPerf.cancel('UNAVAILABLE');
      return false;
    }
  }

  static startNewSession(): void {
    if (!LOCAL_DIAG_BUILD) {
      return;
    }
    IconPickerPerf.cancel('UNAVAILABLE');
    IconPickerPerf.sessionStart = -1;
    IconPickerPerf.requests = 0;
    IconPickerPerf.stopped = false;
  }

  private static start(request: PerfRequest, phase: PerfPhase): void {
    if (request.terminal || request.pending.has(phase)) {
      return;
    }
    try {
      hiTraceMeter.startAsyncTrace(LEVEL, 'IconPicker.' + phase, request.id, 'IconPicker');
      request.pending.add(phase);
    } catch (_) {
      IconPickerPerf.cancel('UNAVAILABLE');
    }
  }

  private static finish(request: PerfRequest, phase: PerfPhase, result: PerfResult): void {
    if (!request.pending.delete(phase)) {
      return;
    }
    try {
      hiTraceMeter.finishAsyncTrace(LEVEL, 'IconPicker.' + phase, request.id);
      const marker = 'IconPicker.result.' + phase + '.' + result;
      hiTraceMeter.startAsyncTrace(LEVEL, marker, request.id, 'IconPicker');
      hiTraceMeter.finishAsyncTrace(LEVEL, marker, request.id);
    } catch (_) {
      // 缺失标记由本地解析器判无效，不改变业务流程。
    }
    if (request.phases.every((p: PerfPhase) => !request.pending.has(p)) &&
      (request.phases[0] !== 'open.data' || IconPickerPerf.pageReady)) {
      request.terminal = true;
      clearTimeout(request.timer);
      request.timer = -1;
      request.items = undefined;
      request.expected.clear();
      request.waiting.clear();
    }
  }

  private static begin(open: boolean): number {
    if (!IconPickerPerf.enabled()) {
      return -1;
    }
    if (IconPickerPerf.requests >= MAX_REQUESTS) {
      IconPickerPerf.cancel('UNAVAILABLE');
      IconPickerPerf.stopped = true;
      return -1;
    }
    IconPickerPerf.cancel(open ? 'LEFT' : 'CANCELLED');
    if (IconPickerPerf.sessionStart < 0) {
      IconPickerPerf.sessionStart = IconPickerPerf.now(true);
    }
    const started = IconPickerPerf.now();
    if (started < 0) {
      return -1;
    }
    const request = new PerfRequest(++IconPickerPerf.sequence, open, started);
    IconPickerPerf.current = request;
    IconPickerPerf.requests++;
    for (const phase of request.phases) {
      if (phase !== 'open.contentReady' || IconPickerPerf.pageReady) {
        IconPickerPerf.start(request, phase);
      }
    }
    request.timer = setTimeout(() => IconPickerPerf.timeout(request), REQUEST_MS);
    return request.id;
  }

  static beginOpen(): number {
    return IconPickerPerf.begin(true);
  }

  static beginSwitch(): number {
    return IconPickerPerf.begin(false);
  }

  static beginSearchRequest(previous: string, value: string): number {
    return previous === value ? -1 : IconPickerPerf.beginSwitch();
  }

  static notifyPageReady(context: UIContext): void {
    if (!LOCAL_DIAG_BUILD) {
      return;
    }
    IconPickerPerf.context = context;
    IconPickerPerf.pageReady = true;
    if (!IconPickerPerf.enabled()) {
      return;
    }
    const request = IconPickerPerf.current;
    if (request !== undefined && !request.terminal && request.phases[0] === 'open.data') {
      IconPickerPerf.start(request, 'open.contentReady');
      IconPickerPerf.scheduleVerify(request);
    }
  }

  static endDataReady(items: IconPickerItemMeta[] | undefined, sourceId: number, requestId: number = -1): void {
    const request = IconPickerPerf.request(requestId);
    if (request === undefined) {
      return;
    }
    request.items = items;
    request.sourceId = sourceId;
    request.dataReady = items !== undefined;
    IconPickerPerf.finish(request, request.phases[0], items === undefined ? 'FAILED' : 'READY');
    IconPickerPerf.commit(request);
    IconPickerPerf.scheduleVerify(request);
  }

  static notifyGridAttached(sourceId: number, scroller: Scroller | undefined): void {
    if (!LOCAL_DIAG_BUILD) {
      return;
    }
    IconPickerPerf.presented = sourceId;
    IconPickerPerf.scroller = scroller;
    const request = IconPickerPerf.request();
    if (request !== undefined) {
      IconPickerPerf.commit(request);
      IconPickerPerf.scheduleVerify(request);
    }
  }

  static notifyGridDetached(sourceId: number): void {
    if (LOCAL_DIAG_BUILD && IconPickerPerf.presented === sourceId) {
      IconPickerPerf.presented = -1;
      IconPickerPerf.scroller = undefined;
    }
  }

  static notifyGridLayout(sourceId: number, first: number, last: number): void {
    if (!LOCAL_DIAG_BUILD) {
      return;
    }
    IconPickerPerf.rangeSource = sourceId;
    IconPickerPerf.first = first;
    IconPickerPerf.last = last;
    const request = IconPickerPerf.request();
    if (request !== undefined) {
      IconPickerPerf.verifyLayout(request);
      IconPickerPerf.scheduleVerify(request);
    }
  }

  static notifyEmptyLayoutDone(sourceId: number): void {
    const request = IconPickerPerf.request();
    if (request === undefined || request.sourceId !== sourceId || request.items?.length !== 0) {
      return;
    }
    request.layoutReady = true;
    request.expected.clear();
    request.waiting.clear();
    IconPickerPerf.finish(request, 'switch.commit', 'READY');
    IconPickerPerf.content(request);
  }

  private static request(id: number = -1): PerfRequest | undefined {
    if (!IconPickerPerf.enabled()) {
      return undefined;
    }
    const request = IconPickerPerf.current;
    return request !== undefined && !request.terminal && (id < 0 || id === request.id) ? request : undefined;
  }

  private static commit(request: PerfRequest): void {
    if (request.dataReady && request.sourceId >= 0 && request.sourceId === IconPickerPerf.presented) {
      IconPickerPerf.finish(request, 'switch.commit', 'READY');
    }
  }

  private static scheduleVerify(request: PerfRequest): void {
    if (!request.dataReady || request.verifyPosted || request.layoutReady || IconPickerPerf.context === undefined) {
      return;
    }
    request.verifyPosted = true;
    IconPickerPerf.post(request, () => {
      request.verifyPosted = false;
      IconPickerPerf.verifyLayout(request);
    });
  }

  private static verifyLayout(request: PerfRequest): void {
      if (!request.dataReady || request.layoutReady || request.terminal) {
        return;
      }
      const scroller = IconPickerPerf.scroller;
      if (request.sourceId !== IconPickerPerf.presented || request.sourceId !== IconPickerPerf.rangeSource ||
        request.items === undefined || scroller === undefined || IconPickerPerf.first !== 0 ||
        IconPickerPerf.last < 0) {
        return;
      }
      try {
        if (Math.abs(scroller.currentOffset().yOffset) > 0.5) {
          return;
        }
        const keys: string[] = [];
        for (let i = 0; i <= IconPickerPerf.last && i < request.items.length; i++) {
          const rect = scroller.getItemRect(i);
          if (rect.width <= 0 || rect.height <= 0) {
            return;
          }
          if (request.items[i].path !== '') {
            keys.push(request.items[i].key);
          }
        }
        request.expected.clear();
        request.waiting.clear();
        const active = IconPickerPerf.bindingsBySource?.get(request.sourceId);
        for (const key of keys) {
          const binding = active?.get(key);
          if (binding !== undefined) {
            request.expected.set(key, binding);
          }
          if (binding === undefined || !binding.completed) {
            request.waiting.add(key);
          }
          if (binding?.failed) {
            IconPickerPerf.cancel('FAILED');
            return;
          }
        }
        request.layoutReady = true;
        IconPickerPerf.content(request);
      } catch (_) {
        IconPickerPerf.cancel('UNAVAILABLE');
      }
  }

  static createImageBinding(sourceId: number, item: IconPickerItemMeta,
    source: string = item.path, nodeId: number = -1, width: number = 40, height: number = 40): IconPickerImageBinding {
    if (!LOCAL_DIAG_BUILD) {
      return IconPickerPerf.noBinding;
    }
    if (IconPickerPerf.bindings === undefined) {
      IconPickerPerf.bindings = new Map<number, IconPickerImageBinding>();
    }
    const id = nodeId < 0 ? IconPickerPerf.nextNodeId() : nodeId;
    const previous = IconPickerPerf.bindings.get(id);
    if (previous !== undefined && previous.sourceId === sourceId && previous.key === item.key &&
      previous.source === source && previous.width === width && previous.height === height) {
      return previous;
    }
    if (previous !== undefined) {
      IconPickerPerf.removeBinding(previous);
    }
    const binding = new IconPickerImageBinding(id, sourceId, item.key, source, width, height);
    IconPickerPerf.bindings.set(id, binding);
    if (IconPickerPerf.bindingsBySource === undefined) {
      IconPickerPerf.bindingsBySource = new Map<number, Map<string, IconPickerImageBinding>>();
    }
    let byKey = IconPickerPerf.bindingsBySource.get(sourceId);
    if (byKey === undefined) {
      byKey = new Map<string, IconPickerImageBinding>();
      IconPickerPerf.bindingsBySource.set(sourceId, byKey);
    }
    byKey.set(item.key, binding);
    const request = IconPickerPerf.current;
    if (request !== undefined && !request.terminal && request.layoutReady &&
      request.sourceId === sourceId && (request.expected.has(item.key) || request.waiting.has(item.key))) {
      request.expected.set(item.key, binding);
      request.waiting.add(item.key);
    }
    return binding;
  }

  static notifyImageAttached(_binding: IconPickerImageBinding): void {
    // 创建时即登记；迟到的挂载回调不能重新激活旧源绑定。
  }

  private static removeBinding(binding: IconPickerImageBinding): void {
    if (IconPickerPerf.bindings?.get(binding.nodeId) !== binding) {
      return;
    }
    IconPickerPerf.bindings.delete(binding.nodeId);
    const byKey = IconPickerPerf.bindingsBySource?.get(binding.sourceId);
    if (byKey?.get(binding.key) === binding) {
      byKey.delete(binding.key);
      if (byKey.size === 0) {
        IconPickerPerf.bindingsBySource?.delete(binding.sourceId);
      }
    }
    const request = IconPickerPerf.current;
    if (request !== undefined && !request.terminal && request.expected.get(binding.key) === binding) {
      request.expected.delete(binding.key);
      request.waiting.add(binding.key);
    }
  }

  static notifyImageDetached(binding: IconPickerImageBinding): void {
    if (LOCAL_DIAG_BUILD) {
      IconPickerPerf.removeBinding(binding);
    }
  }

  static notifyImageComplete(binding: IconPickerImageBinding, status?: number, width?: number, height?: number): void {
    if (!LOCAL_DIAG_BUILD || status !== 1 || IconPickerPerf.bindings?.get(binding.nodeId) !== binding) {
      return;
    }
    binding.completed = width !== undefined && height !== undefined && width > 0 && height > 0;
    if (binding.completed) {
      binding.failed = false;
    }
    const request = IconPickerPerf.current;
    if (request === undefined || request.terminal || request.sourceId !== binding.sourceId ||
      !request.layoutReady || !request.waiting.has(binding.key)) {
      return;
    }
    if (binding.completed && request.expected.get(binding.key) === binding) {
      request.waiting.delete(binding.key);
      if (request.waiting.size === 0) {
        IconPickerPerf.content(request);
      }
    }
  }

  static notifyImageError(binding: IconPickerImageBinding): void {
    if (!LOCAL_DIAG_BUILD || IconPickerPerf.bindings?.get(binding.nodeId) !== binding) {
      return;
    }
    binding.failed = true;
    const request = IconPickerPerf.current;
    if (request !== undefined && !request.terminal && request.layoutReady &&
      request.expected.get(binding.key) === binding) {
      IconPickerPerf.cancel('FAILED');
    }
  }

  private static content(request: PerfRequest): void {
    if (!request.layoutReady || request.contentPosted || !IconPickerPerf.pageReady || request.waiting.size > 0) {
      return;
    }
    request.contentPosted = true;
    IconPickerPerf.post(request, () => {
      request.contentPosted = false;
      if (request.waiting.size === 0 && request.sourceId === IconPickerPerf.presented &&
        (request.items?.length === 0 || (IconPickerPerf.rangeSource === request.sourceId && IconPickerPerf.first === 0))) {
        IconPickerPerf.finish(request, request.phases[request.phases.length - 1], 'READY');
      }
    });
  }

  private static post(request: PerfRequest, action: () => void): void {
    try {
      IconPickerPerf.context?.postFrameCallback(new PickerFrame(() => {
        if (IconPickerPerf.request(request.id) === request) {
          action();
        }
      }));
    } catch (_) {
      IconPickerPerf.cancel('UNAVAILABLE');
    }
  }

  private static timeout(request: PerfRequest): void {
    if (IconPickerPerf.request(request.id) !== request) {
      return;
    }
    const now = IconPickerPerf.now();
    if (now < 0) {
      IconPickerPerf.cancel('UNAVAILABLE');
    } else if (now - request.started < REQUEST_MS) {
      request.timer = setTimeout(() => IconPickerPerf.timeout(request), REQUEST_MS - (now - request.started));
    } else {
      IconPickerPerf.cancel(request.dataReady && request.sourceId !== IconPickerPerf.presented ? 'FAILED' : 'TIMEOUT');
    }
  }

  private static cancel(result: PerfResult): void {
    const request = IconPickerPerf.current;
    if (request === undefined || request.terminal) {
      return;
    }
    for (const phase of request.phases) {
      IconPickerPerf.finish(request, phase, result);
    }
    request.terminal = true;
    clearTimeout(request.timer);
    request.items = undefined;
    request.expected.clear();
    request.waiting.clear();
  }

  static notifyLeave(): void {
    if (!LOCAL_DIAG_BUILD) {
      return;
    }
    IconPickerPerf.cancel('LEFT');
    IconPickerPerf.current = undefined;
    IconPickerPerf.bindings?.clear();
    IconPickerPerf.bindingsBySource?.clear();
    IconPickerPerf.context = undefined;
    IconPickerPerf.pageReady = false;
    IconPickerPerf.presented = -1;
    IconPickerPerf.rangeSource = -1;
    IconPickerPerf.scroller = undefined;
  }

  static beginPrepareSlice(): boolean {
    if (!LOCAL_DIAG_BUILD || IconPickerPerf.sessionStart < 0 || !IconPickerPerf.enabled()) {
      return false;
    }
    try {
      hiTraceMeter.startSyncTrace(LEVEL, 'IconPicker.prepare.cpu');
      return true;
    } catch (_) {
      return false;
    }
  }

  static endPrepareSlice(active: boolean): void {
    if (active) {
      try {
        hiTraceMeter.finishSyncTrace(LEVEL);
      } catch (_) {
        // 诊断失败不影响数据准备。
      }
    }
  }
}

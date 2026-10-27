import { common } from '@kit.AbilityKit';
import { FrameCallback, LengthMetrics } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  copyFileToDir, dialogSystemMaterial, EVENT_NAMES, getImageDimensions, savePixelMapToFile,
  showSelectFilePicker, showSnackBar, SnackBarNotifyType, TokenIconPacks
} from 'common';
import { CropModel, CropView } from './ImageCropView';
import { IconPickerGridItem } from './IconPickerGridItem';
import { IconGridItem, IconPackDescriptor, IconPickerModel, IconPickerSliceHooks } from '../utils/IconPickerModel';
import { IconPickerPerf } from '../utils/IconPickerPerf';

const MAX_ICON_SIZE: number = 256;
const DOMAIN: number = 0xFF00;
const TAG: string = 'IconPicker';

@ObservedV2
export class IconPickerViewState {
  @Trace searchText: string = '';
  @Trace packIndex: number = 0;
  @Trace revision: number = 0;
  @Trace pending: boolean = true;
  @Trace failed: boolean = false;
  private immediate: boolean = true;
  private perfId: number = -1;

  selectPack(index: number): void {
    if (index === this.packIndex && !this.failed) {
      return;
    }
    this.perfId = IconPickerPerf.beginSwitch();
    this.packIndex = index;
    this.request(true);
  }

  search(value: string, submit: boolean = false): void {
    if (value === this.searchText && !submit) {
      return;
    }
    this.perfId = IconPickerPerf.beginSwitch();
    this.searchText = value;
    this.request(submit || value === '');
  }

  refresh(): void {
    this.perfId = IconPickerPerf.beginSwitch();
    this.request(true);
  }

  private request(immediate: boolean): void {
    this.immediate = immediate;
    this.failed = false;
    this.pending = true;
    this.revision++;
  }

  delay(): number {
    return this.immediate ? 0 : 100;
  }

  requestId(): number {
    return this.perfId;
  }
}

class PickerLayoutFrame extends FrameCallback {
  private action: () => void;

  constructor(action: () => void) {
    super();
    this.action = action;
  }

  onIdle(_timeLeft: number): void {
    this.action();
  }
}

@Preview
@ComponentV2
export struct IconPicker {
  @Require @Param issuer: string = '';
  @Param currentIconPath: string = '';
  @Param showCancelButton: boolean = true;
  @Param showSearch: boolean = true;
  @Param scroller: Scroller = new Scroller();
  @Param viewState: IconPickerViewState = new IconPickerViewState();
  @Event cancel: () => void = () => {};
  @Event confirm: (path: string) => void = () => {};
  @Event onPacksChanged: (packs: IconPackDescriptor[]) => void = () => {};

  @Local activeItems: IconGridItem[] = [];
  @Local selectedIconPath: string = '';
  @Local showCropCover: boolean = false;
  @Local cropModel: CropModel = new CropModel();
  @Local showPendingCover: boolean = false;
  @Local poolLimit: number = 96;
  @Local committedGeneration: number = -1;
  @Local sourceId: number = -1;
  @Local preparing: boolean = false;

  private model: IconPickerModel = new IconPickerModel();
  private alive: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private coverTimer: number = -1;
  private committedRevision: number = -1;
  private requestedPerfId: number = -1;
  private perfSources: Map<string, number> = new Map<string, number>();
  private layoutPosted: number = -1;
  private visibleFirst: number = -1;
  private visibleLast: number = -1;
  private appCtx: common.UIAbilityContext | undefined = undefined;
  private packChanged: () => void = () => this.refreshPacks();
  private slice: IconPickerSliceHooks = {
    beginSlice: (): boolean => IconPickerPerf.beginPrepareSlice(),
    endSlice: (active: boolean): void => IconPickerPerf.endPrepareSlice(active)
  };

  aboutToAppear(): void {
    this.alive = true;
    this.selectedIconPath = this.currentIconPath;
    this.requestedPerfId = IconPickerPerf.beginOpen();
    this.appCtx = AppStorage.get<common.UIAbilityContext>('appContext');
    this.appCtx?.eventHub.on(EVENT_NAMES.ICON_PACK_CHANGED, this.packChanged);
    this.queueRequest(0);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.generation++;
    clearTimeout(this.timer);
    clearTimeout(this.coverTimer);
    this.timer = -1;
    this.coverTimer = -1;
    this.appCtx?.eventHub.off(EVENT_NAMES.ICON_PACK_CHANGED, this.packChanged);
    this.model.dispose();
    this.perfSources.clear();
    IconPickerPerf.notifyLeave();
  }

  @Monitor('viewState.revision')
  onRequestChanged(): void {
    this.requestedPerfId = this.viewState.requestId();
    this.queueRequest(this.viewState.delay());
  }

  private queueRequest(delay: number): void {
    if (!this.alive) {
      return;
    }
    clearTimeout(this.timer);
    clearTimeout(this.coverTimer);
    const generation = ++this.generation;
    this.viewState.pending = true;
    this.timer = setTimeout(() => {
      this.timer = -1;
      if (!this.current(generation)) {
        return;
      }
      this.getUIContext().runScopedTask(() => {
        this.prepare(generation);
      });
    }, delay);
  }

  private current(generation: number): boolean {
    return this.alive && this.generation === generation;
  }

  private async prepare(generation: number): Promise<void> {
    const pack = this.model.packKeyForIndex(this.viewState.packIndex);
    const query = this.viewState.searchText;
    const revision = this.viewState.revision;
    const perfId = this.requestedPerfId;
    try {
      const promise = this.model.prepare(pack, query, {
        isCancelled: (): boolean => !this.current(generation) || revision !== this.viewState.revision
      }, this.slice);
      let completed = false;
      promise.then(() => completed = true).catch(() => completed = true);
      this.coverTimer = setTimeout(() => {
        this.coverTimer = -1;
        if (!completed && this.current(generation)) {
          this.getUIContext().runScopedTask(() => this.showPendingCover = true);
        }
      }, 0);
      const items = await promise;
      if (items === undefined || !this.current(generation) || revision !== this.viewState.revision) {
        return;
      }
      this.getUIContext().runScopedTask(() => {
        if (IconPickerPerf.isActive()) {
          let source = this.perfSources.get(pack);
          if (source === undefined) {
            source = IconPickerPerf.nextSourceId();
            this.perfSources.set(pack, source);
          }
          this.sourceId = source;
        }
        this.activeItems = items;
        this.committedRevision = revision;
        this.committedGeneration = generation;
        if (IconPickerPerf.isActive()) {
          IconPickerPerf.endDataReady(items, this.sourceId, perfId);
          IconPickerPerf.notifyGridAttached(this.sourceId, this.scroller);
        }
        this.postLayout(generation);
      });
    } catch (error) {
      if (this.current(generation)) {
        this.showPendingCover = false;
        this.viewState.failed = true;
        this.viewState.pending = true;
        hilog.error(DOMAIN, TAG, 'Unable to prepare icon choices');
        showSnackBar((error as BusinessError).message, SnackBarNotifyType.ERROR);
      }
    }
  }

  onDidBuild(): void {
    this.postLayout(this.committedGeneration);
  }

  private postLayout(generation: number): void {
    if (!this.current(generation) || this.layoutPosted === generation) {
      return;
    }
    this.layoutPosted = generation;
    this.getUIContext().postFrameCallback(new PickerLayoutFrame(() => {
      if (!this.current(generation) || this.committedGeneration !== generation ||
        this.committedRevision !== this.viewState.revision) {
        return;
      }
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
      this.getUIContext().runScopedTask(() => {
        this.showPendingCover = false;
        this.viewState.pending = false;
        if (IconPickerPerf.isActive()) {
          if (this.activeItems.length === 0) {
            IconPickerPerf.notifyEmptyLayoutDone(this.sourceId);
          } else {
            this.reportVisibleLayout();
          }
        }
      });
    }));
  }

  private reportVisibleLayout(): void {
    if (!IconPickerPerf.isActive() || this.viewState.pending || this.visibleFirst !== 0) {
      return;
    }
    try {
      let last = -1;
      for (let i = 0; i <= this.visibleLast && i < this.activeItems.length; i++) {
        const rect = this.scroller.getItemRect(i);
        if (rect.width <= 0 || rect.height <= 0) {
          return;
        }
        last = i;
      }
      if (last >= 0) {
        IconPickerPerf.notifyGridLayout(this.sourceId, 0, last);
      }
    } catch (_) {
      // 布局测量失败只使本次诊断超时，不影响选择器。
    }
  }

  private canAct(generation: number): boolean {
    return this.current(generation) && !this.viewState.pending &&
      this.committedRevision === this.viewState.revision;
  }

  private select(path: string, generation: number): void {
    if (this.canAct(generation)) {
      this.selectedIconPath = path;
    }
  }

  private refreshPacks(): void {
    if (!this.alive) {
      return;
    }
    const previous = this.model.listPackDescriptors()[this.viewState.packIndex];
    this.model.invalidatePacks();
    let index = previous === undefined ? 0 : this.model.resolvePackIndex(previous.identityKey);
    if (index < 0 && previous !== undefined) {
      index = this.model.listPackDescriptors().findIndex((pack: IconPackDescriptor) =>
        pack.uuid === previous.uuid || pack.onDevicePath === previous.onDevicePath);
    }
    this.viewState.packIndex = index < 0 ? 0 : index;
    this.onPacksChanged(this.model.listPackDescriptors());
    this.viewState.refresh();
  }

  private remove(path: string, generation: number): void {
    if (!this.canAct(generation)) {
      return;
    }
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      message: $r('app.string.icon_alert_remove_confirm_msg'),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.dialog_btn_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.dialog_btn_confirm'),
        fontColor: Color.Red,
        action: () => {
          if (!this.alive || !TokenIconPacks.user_added_icon_packs.icon_path.includes(path)) {
            return;
          }
          TokenIconPacks.user_added_icon_packs.removeIcon(path);
          TokenIconPacks.removePickerPreviewPath(path);
          this.model.invalidateUsers();
          this.viewState.refresh();
        }
      }
    });
  }

  private async addIconToUserPack(uri: string, generation: number): Promise<void> {
    if (!this.current(generation)) {
      return;
    }
    const path = await copyFileToDir(uri, TokenIconPacks.user_added_icon_packs.user_icon_path);
    if (!this.current(generation)) {
      return;
    }
    TokenIconPacks.user_added_icon_packs.addIconByPath(path);
    try {
      await TokenIconPacks.preparePickerPreviewPaths([path]);
    } finally {
      if (this.current(generation)) {
        this.model.invalidateUsers();
        this.viewState.refresh();
      }
    }
  }

  private async add(generation: number): Promise<void> {
    if (!this.canAct(generation) || this.preparing) {
      return;
    }
    this.preparing = true;
    try {
      const uris = await showSelectFilePicker(1, ['png', 'jpg', 'jpeg', 'svg', 'webp']);
      if (uris.length === 0 || !this.current(generation)) {
        return;
      }
      const uri = uris[0];
      if (uri.toLowerCase().endsWith('.svg')) {
        await this.addIconToUserPack(uri, generation);
        return;
      }
      const size = await getImageDimensions(uri);
      if (!this.current(generation)) {
        return;
      }
      if (size !== null && (size.width > MAX_ICON_SIZE || size.height > MAX_ICON_SIZE)) {
        this.cropModel = new CropModel();
        this.cropModel.setImage(uri).setFrameWidth(1000).setFrameRatio(1);
        this.showCropCover = true;
      } else {
        await this.addIconToUserPack(uri, generation);
      }
    } catch (error) {
      if (this.current(generation)) {
        hilog.error(DOMAIN, TAG, 'Unable to add icon');
        showSnackBar((error as BusinessError).message, SnackBarNotifyType.ERROR);
      }
    } finally {
      if (this.alive) {
        this.preparing = false;
      }
    }
  }

  @LocalBuilder
  CropCoverBuilder() {
    Column() {
      CropView({ model: this.cropModel })
        .layoutWeight(1)
        .width('100%')
      Row() {
        Button($r('app.string.dialog_btn_cancel'))
          .fontColor(Color.White)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onClick(() => this.showCropCover = false)
        Button($r('app.string.dialog_btn_confirm'))
          .fontColor(Color.White)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onClick(async () => {
            const generation = this.generation;
            try {
              const image = await this.cropModel.crop();
              if (!this.current(generation)) {
                image.release();
                if (this.alive) {
                  this.showCropCover = false;
                }
                return;
              }
              const path = await savePixelMapToFile(image, TokenIconPacks.user_added_icon_packs.user_icon_path);
              image.release();
              if (!this.current(generation)) {
                return;
              }
              TokenIconPacks.user_added_icon_packs.addIconByPath(path);
              try {
                await TokenIconPacks.preparePickerPreviewPaths([path]);
              } finally {
                if (this.current(generation)) {
                  this.model.invalidateUsers();
                  this.showCropCover = false;
                  this.viewState.refresh();
                }
              }
            } catch (_) {
              hilog.error(DOMAIN, TAG, 'Unable to crop icon');
            }
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 30 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  build() {
    Column() {
      if (this.showSearch) {
        Search({ placeholder: $r('app.string.dialog_icon_search_placeholder'), value: this.viewState.searchText })
          .width('100%')
          .onChange((value: string) => this.viewState.search(value))
          .onSubmit((value: string) => this.viewState.search(value, true))
      }
      Stack({ alignContent: Alignment.Top }) {
        Grid(this.scroller) {
          Repeat<IconGridItem>(this.activeItems)
            .each((item: RepeatItem<IconGridItem>) => {
              IconPickerGridItem({ repeatItem: item, selectedIconPath: this.selectedIconPath,
                generation: this.committedGeneration, sourceId: this.sourceId,
                select: (path: string, generation: number) => this.select(path, generation),
                add: (generation: number) => this.add(generation),
                remove: (path: string, generation: number) => this.remove(path, generation) })
            })
            .key((item: IconGridItem): string => item.key)
            .templateId((item: IconGridItem): string => item.templateId)
            .template('AUTO', (item: RepeatItem<IconGridItem>) => {
              IconPickerGridItem({ repeatItem: item, selectedIconPath: this.selectedIconPath,
                generation: this.committedGeneration, sourceId: this.sourceId,
                select: (path: string, generation: number) => this.select(path, generation) })
            }, { cachedCount: 1 })
            .template('ADD', (item: RepeatItem<IconGridItem>) => {
              IconPickerGridItem({ repeatItem: item, generation: this.committedGeneration,
                pending: this.preparing || this.viewState.pending,
                add: (generation: number) => this.add(generation) })
            }, { cachedCount: 1 })
            .template('USER', (item: RepeatItem<IconGridItem>) => {
              IconPickerGridItem({ repeatItem: item, selectedIconPath: this.selectedIconPath,
                generation: this.committedGeneration, sourceId: this.sourceId,
                select: (path: string, generation: number) => this.select(path, generation),
                remove: (path: string, generation: number) => this.remove(path, generation) })
            }, { cachedCount: this.poolLimit })
            .template('PACK', (item: RepeatItem<IconGridItem>) => {
              IconPickerGridItem({ repeatItem: item, selectedIconPath: this.selectedIconPath,
                generation: this.committedGeneration, sourceId: this.sourceId,
                select: (path: string, generation: number) => this.select(path, generation) })
            }, { cachedCount: this.poolLimit })
            .virtualScroll()
        }
        .columnsTemplate('repeat(auto-fit, 56vp)')
        .columnsGap(12)
        .rowsGap(8)
        .width('100%')
        .height('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .cachedCount(4, true)
        .syncLoad(false)
        .clip(false)
        .onScrollIndex((first: number, last: number) => {
          this.visibleFirst = first;
          this.visibleLast = last;
          if (this.canAct(this.committedGeneration)) {
            this.reportVisibleLayout();
          }
        })
        .onAreaChange((_old: Area, area: Area) => {
          const columns = Math.max(1, Math.floor((Number(area.width) - 24 + 12) / 68));
          const rows = Math.ceil(Number(area.height) / 64);
          this.poolLimit = Math.max(1, columns * (rows + 8));
        })
        Column() {
          Text($r('app.string.dialog_icon_empty'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .padding({ top: 48 })
        .visibility(this.activeItems.length === 0 && !this.viewState.pending ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
        Column() {
          LoadingProgress().width(32).height(32)
          Text($r('app.string.token_batch_loading'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.window_background'))
        .visibility(this.showPendingCover ? Visibility.Visible : Visibility.Hidden)
      }
      .layoutWeight(1)
      .width('100%')
      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        if (this.showCancelButton) {
          Button($r('app.string.dialog_btn_cancel'))
            .fontColor($r('app.color.item_fg'))
            .backgroundColor(Color.Transparent)
            .layoutWeight(1)
            .onClick(() => this.cancel())
        }
        Button($r('app.string.dialog_btn_confirm'))
          .fontColor(Color.White)
          .backgroundColor($r('app.color.button_blue'))
          .height(48)
          .borderRadius(24)
          .enabled(!this.viewState.pending)
          .layoutWeight(1)
          .onClick(() => {
            if (this.canAct(this.committedGeneration)) {
              this.confirm(this.selectedIconPath);
            }
          })
      }
      .width('100%')
      .padding({ top: LengthMetrics.vp(8).value })
    }
    .padding(10)
    .width('100%')
    .height('100%')
    .bindContentCover(this.showCropCover, this.CropCoverBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => this.showCropCover = false
    })
  }
}

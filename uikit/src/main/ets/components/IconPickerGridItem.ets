import { LengthMetrics } from '@kit.ArkUI';
import { TokenIconPacks } from 'common';
import { IconPickerDataType, IconGridItem } from '../utils/IconPickerModel';
import { IconPickerImageBinding, IconPickerItemMeta, IconPickerPerf } from '../utils/IconPickerPerf';

/** Image onComplete 事件字段，与 SDK 回调一致。 */
interface IconPickerImageCompleteEvent {
  width: number;
  height: number;
  componentWidth: number;
  componentHeight: number;
  loadingStatus: number;
  contentWidth: number;
  contentHeight: number;
}

/** Image onError 事件字段；message 不落日志。 */
interface IconPickerImageErrorEvent {
  componentWidth: number;
  componentHeight: number;
  message: string;
}

function pickerImageSource(path: string): ResourceStr {
  const previewPath: string = TokenIconPacks.getPickerPreviewPath(path);
  if (previewPath.startsWith('rawfile://')) {
    return $rawfile(previewPath.slice(10));
  }
  return previewPath;
}

@ComponentV2
export struct IconPickerGridItem {
  /** Repeat .each 注入；条目值只在渲染/事件期读取，避免冻结。 */
  @Param @Require repeatItem: RepeatItem<IconGridItem>;
  @Param selectedIconPath: string = '';
  @Param sourceId: number = -1;
  @Param pending: boolean = false;
  /** 父组件已提交代际；全部回调携带，过期事件由父组件丢弃。 */
  @Param generation: number = -1;
  @Event select: (path: string, generation: number) => void = () => {};
  @Event add: (generation: number) => void = () => {};
  @Event remove: (path: string, generation: number) => void = () => {};

  /** 实例级节点身份，创建时签发一次；同槽重绑定时 Perf 按 id 替换绑定。 */
  private readonly nodeId: number = IconPickerPerf.nextNodeId();
  /** 属性求值期更新的当前绑定（普通字段，不做状态）；仅 aboutToDisappear 解绑使用。 */
  private currentBinding: IconPickerImageBinding | undefined = undefined;

  aboutToDisappear(): void {
    if (this.currentBinding !== undefined) {
      // 节点销毁时解绑当前绑定；不挂 Image onDisAppear（重绑定后捕获的是最新绑定，可能错位）。
      IconPickerPerf.notifyImageDetached(this.currentBinding);
    }
  }

  /** 属性求值期调用（onComplete/onError 各一次）；绑定激活在创建期完成，无需 attached 事件或 @Monitor。 */
  private bindingFor(): IconPickerImageBinding {
    if (!IconPickerPerf.isActive()) {
      return IconPickerPerf.disabledBinding();
    }
    const item: IconGridItem = this.repeatItem.item;
    const meta: IconPickerItemMeta = { key: item.key, path: item.path };
    const binding = IconPickerPerf.createImageBinding(this.sourceId, meta,
      TokenIconPacks.getPickerPreviewPath(item.path), this.nodeId, 40, 40);
    this.currentBinding = binding;
    return binding;
  }

  /** 事件回调工厂：捕获求值期绑定，运行期不回读可变条目。 */
  private completeHandler(binding: IconPickerImageBinding): (event?: IconPickerImageCompleteEvent) => void {
    return (event?: IconPickerImageCompleteEvent): void => {
      IconPickerPerf.notifyImageComplete(binding, event?.loadingStatus, event?.width, event?.height);
    };
  }

  private errorHandler(binding: IconPickerImageBinding): (error: IconPickerImageErrorEvent) => void {
    return (_error: IconPickerImageErrorEvent): void => {
      IconPickerPerf.notifyImageError(binding);
    };
  }

  @Builder
  iconImage() {
    Image(pickerImageSource(this.repeatItem.item.path))
      .width(LengthMetrics.vp(40).value)
      .height(LengthMetrics.vp(40).value)
      .objectFit(ImageFit.Contain)
      .borderRadius(TokenIconPacks.user_added_icon_packs.raster_icons.has(this.repeatItem.item.path) ?
        LengthMetrics.vp(20).value : 0)
      // 绑定与处理器在属性求值期配对；两次求值返回同一绑定引用。
      .onComplete(this.completeHandler(this.bindingFor()))
      .onError(this.errorHandler(this.bindingFor()))
  }

  @Builder
  autoChoice() {
    Stack() {
      Shape() {
        Text($r('app.string.dialog_icon_select_auto'))
      }
      .align(Alignment.Center)
      .backgroundColor($r('app.color.item_bg'))
      .height(LengthMetrics.vp(40).value)
      .width(LengthMetrics.vp(40).value)
      .borderRadius(LengthMetrics.vp(20).value)
    }
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .alignContent(Alignment.Center)
    .borderRadius(LengthMetrics.vp(12).value)
    .backgroundColor(this.selectedIconPath === this.repeatItem.item.path ? $r('app.color.item_bg') : Color.Transparent)
    .border({
      width: this.selectedIconPath === this.repeatItem.item.path ? LengthMetrics.vp(2).value : 0,
      color: $r('app.color.button_blue')
    })
    .onClick(() => {
      this.select(this.repeatItem.item.path, this.generation);
    })
  }

  @Builder
  packChoice() {
    Stack() {
      this.iconImage()
    }
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .alignContent(Alignment.Center)
    .borderRadius(LengthMetrics.vp(12).value)
    .backgroundColor(this.selectedIconPath === this.repeatItem.item.path ? $r('app.color.item_bg') : Color.Transparent)
    .border({
      width: this.selectedIconPath === this.repeatItem.item.path ? LengthMetrics.vp(2).value : 0,
      color: $r('app.color.button_blue')
    })
    .onClick(() => {
      this.select(this.repeatItem.item.path, this.generation);
    })
  }

  @Builder
  userChoice() {
    Stack() {
      this.iconImage()
      this.removeBadge()
    }
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .alignContent(Alignment.Center)
    .borderRadius(LengthMetrics.vp(12).value)
    .backgroundColor(this.selectedIconPath === this.repeatItem.item.path ? $r('app.color.item_bg') : Color.Transparent)
    .border({
      width: this.selectedIconPath === this.repeatItem.item.path ? LengthMetrics.vp(2).value : 0,
      color: $r('app.color.button_blue')
    })
    .onClick(() => {
      this.select(this.repeatItem.item.path, this.generation);
    })
  }

  @Builder
  removeBadge() {
    Stack() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(LengthMetrics.vp(12).value)
          .fontColor([Color.White])
          .fontWeight(FontWeight.Medium)
          .rotate({ angle: 45 })
      }
      .backgroundColor(Color.Red)
      .width(LengthMetrics.vp(18).value)
      .height(LengthMetrics.vp(18).value)
      .align(Alignment.BottomStart)
      .onClick(() => {
        this.remove(this.repeatItem.item.path, this.generation);
      })
    }
    .width(LengthMetrics.vp(40).value)
    .height(LengthMetrics.vp(40).value)
  }

  /** 分支谓词与原实现一致：AUTO 圆形；否则按 removable 走 USER（带徽标）/PACK 纯图标子树。 */
  @Builder
  iconChoice() {
    if (this.repeatItem.item.type === IconPickerDataType.AUTO) {
      this.autoChoice()
    } else if (this.repeatItem.item.removable) {
      this.userChoice()
    } else {
      this.packChoice()
    }
  }

  @Builder
  addButton() {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(LengthMetrics.vp(24).value)
        .fontWeight(FontWeight.Medium)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .backgroundColor($r('app.color.item_bg'))
    .borderRadius(LengthMetrics.vp(12).value)
    .width(LengthMetrics.vp(56).value)
    .height(LengthMetrics.vp(56).value)
    .onClick(() => {
      if (!this.pending) {
        this.add(this.generation);
      }
    })
  }

  build() {
    GridItem() {
      if (this.repeatItem.item.type === IconPickerDataType.ADD) {
        this.addButton()
      } else {
        this.iconChoice()
      }
    }
  }
}

import {
  BottomBuilderShowType,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavDestination,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  AppStorageV2,
  SegmentButtonV2ItemOptions,
  SegmentButtonV2Items,
  TabSegmentButtonV2
} from '@kit.ArkUI';
import { IconPackDescriptor, IconPicker, IconPickerPerf, IconPickerViewState } from 'uikit';
import { AegisIconPack, AppWindowInfo, TokenIconPacks } from 'common';
import { MaterialTheme } from '../components/MaterialTheme';
import { PageScaffold } from '../components/PageScaffold';

/** 添加/编辑令牌页打开图标选择页时使用的路由参数。 */
export class IconPickerPageParams {
  issuer: string = '';
  currentIconPath: string = '';
  onSelected: (path: string) => void = () => {};

  constructor(issuer: string = '', currentIconPath: string = '', onSelected: (path: string) => void = () => {}) {
    this.issuer = issuer;
    this.currentIconPath = currentIconPath;
    this.onSelected = onSelected;
  }
}

function createIconPackSegmentItems(): SegmentButtonV2Items {
  const items: SegmentButtonV2ItemOptions[] = [{ text: TokenIconPacks.default_icon_pack.name }];
  TokenIconPacks.aegis_icon_packs.forEach((iconPack: AegisIconPack) => {
    items.push({ text: iconPack.name });
  });
  return new SegmentButtonV2Items(items);
}

@Entry
@Preview
@ComponentV2
export struct IconPickerPage {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param pageParams: IconPickerPageParams = new IconPickerPageParams();
  @Local pickerViewState: IconPickerViewState = new IconPickerViewState();
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private pageInfos: NavPathStack | null = null;
  private scroller: Scroller = new Scroller();
  @Local packSegmentItems: SegmentButtonV2Items = createIconPackSegmentItems();
  @Local packCount: number = TokenIconPacks.aegis_icon_packs.length + 1;

  private completeSelection(path: string): void {
    if (this.pickerViewState.pending) {
      return;
    }
    this.pageParams.onSelected(path);
    this.pageInfos?.pop();
  }

  aboutToDisappear(): void {
    IconPickerPerf.notifyLeave();
  }

  @LocalBuilder
  SearchBottomBuilder() {
    Column() {
      Search({
        placeholder: $r('app.string.dialog_icon_search_placeholder'),
        value: this.pickerViewState.searchText
      })
        .width('100%')
        .backgroundColor(MaterialTheme.surfaceBackground($r('sys.color.comp_background_tertiary')))
        .systemMaterial(MaterialTheme.systemMaterial(true))
        .onChange((value: string) => {
          this.pickerViewState.search(value);
        })
        .onSubmit((value: string) => {
          this.pickerViewState.search(value, true);
        })
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16 })
  }

  @LocalBuilder
  PackSegmentBuilder() {
    Column() {
      TabSegmentButtonV2({
        items: this.packSegmentItems,
        selectedIndex: this.pickerViewState.packIndex,
        backgroundSystemMaterial: MaterialTheme.systemMaterial(true),
        $selectedIndex: (index: number) => {
          this.pickerViewState.selectPack(index);
        }
      })
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16 })
  }

  @LocalBuilder
  TitleBottomBuilder() {
    Column() {
      this.SearchBottomBuilder()
      if (this.packCount > 1) {
        this.PackSegmentBuilder()
      }
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
      HdsNavigation() {
        PageScaffold({ avoidBottom: true }) {
        IconPicker({
          issuer: this.pageParams.issuer,
          currentIconPath: this.pageParams.currentIconPath,
          showCancelButton: false,
          showSearch: false,
          scroller: this.scroller,
          viewState: this.pickerViewState,
          onPacksChanged: (packs: IconPackDescriptor[]) => {
            const items: SegmentButtonV2ItemOptions[] = packs.map((pack: IconPackDescriptor): SegmentButtonV2ItemOptions => ({ text: pack.name }));
            this.packSegmentItems = new SegmentButtonV2Items(items);
            this.packCount = packs.length;
          },
          confirm: (path: string) => this.completeSelection(path)
        })
          .width('100%')
          .layoutWeight(1)
      }
    }
    .backgroundColor($r('app.color.window_background'))
    .mode(NavigationMode.Stack)
    .hideBackButton(false)
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            backIconStyle: MaterialTheme.navigationIconStyle(),
            menuStyle: MaterialTheme.navigationIconStyle()
          }
        },
        scrollEffectStyle: MaterialTheme.navigationScrollStyle(),
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          // 带 bottomBuilder 的标题栏直接启用光感，等级由系统自适应，不走应用能力降档。
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        backIcon: {
          label: $r('app.string.dialog_btn_cancel'),
          icon: $r('sys.symbol.chevron_left'),
          action: () => this.pageInfos?.pop()
        },
        title: { mainTitle: $r('app.string.add_token_choose_icon') },
        bottomBuilder: {
          builder: (): void => this.TitleBottomBuilder(),
          height: this.packCount > 1 ? 112 : 56,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        }
      }
    })
    .bindToScrollable([this.scroller])
    }
    .clip(false)
    .hideTitleBar(true)
    .backgroundColor($r('app.color.window_background'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
      // 只读测量：open.contentReady 自页面 onReady 起算（守护亦自此点起算）。
      IconPickerPerf.notifyPageReady(this.getUIContext());
    })
  }
}

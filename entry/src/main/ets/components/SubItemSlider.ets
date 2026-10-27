import { AppWindowInfo } from 'common';

import { AppStorageV2 } from "@kit.ArkUI";
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING, SETTING_ROW_ICON_OFFSET } from './SettingStyle';

export class SliderItem {
  name: ResourceStr = '';
  default: number = 0;
  min: number = 0;
  max: number = 0;
  step?: number = 1;

  constructor() {
  }
}

@Preview
@ComponentV2
export struct SubItemSlider {
  @Require @Param onChange: (index: number, value: number) => void = () => {};
  @Require @Param title: string | Resource = 'aaaa';
  @Require @Param items: SliderItem[] = [{name: "a", default: 2, min: 0, max: 10}];
  @Param disable: boolean = false;
  @Param icon: Resource | undefined = undefined;
  @Param description: string  | Resource = 'aaa';
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local collapsed: boolean = true;

  // 拖动气泡的实时值；右侧已提交数值直接读 item.default（随偏好@Trace联动，
  // 恢复默认等外部变更也能同步），不再用 @Local 快照，避免两处状态脱节
  @Local tips_value: number[] = this.items.map((item) => item.default);

  build() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 10 }) {
            if (this.icon != undefined) {
              SymbolGlyph(this.icon)
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor([$r('app.color.str_main')])
            }
            Text(this.title)
              .fontSize($r('sys.float.ohos_id_text_size_body1'))
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .fontWeight(FontWeight.Regular)
              .textAlign(TextAlign.Start)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          if (this.description != '') {
            Text(this.description)
              .width('100%')
              .padding({ left: this.icon !== undefined ? SETTING_ROW_ICON_OFFSET : 0 })
              .fontSize($r('sys.float.ohos_id_text_size_body2'))
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .fontWeight(FontWeight.Regular)
              .fontFamily('HarmonyHeiTi')
              .lineHeight(19)
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontColor([$r('sys.color.font_tertiary')])
            .fontSize(24)
            .align(Alignment.Center)
            .rotate(this.collapsed ? { angle: 0 } : { angle: 90 })
            .translate(this.collapsed ? {} : { x: -3 })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.window.uiContext?.animateTo({ duration: 200, curve: Curve.Sharp }, () => {
          this.collapsed = !this.collapsed;
        })
      })

      if (!this.collapsed) {
        Blank()
        ForEach(this.items, (item: SliderItem, index: number) => {
          Row() {
            Text(item.name)
              .width('30%')
              .textOverflow({ overflow: TextOverflow.MARQUEE })
            Slider({
              value: item.default,
              min: item.min,
              max: item.max,
              step: item.step
            })
              .width('60%')
              //.enableHapticFeedback(true)
              .showTips(true, this.tips_value[index].toFixed())
              .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK_UP)
              .onChange((value, mode) => {
                this.tips_value[index] = value;
                if (mode === SliderChangeMode.End) {
                  this.onChange(index, value);
                }
              })
            Text(item.default.toString())
              .width('10%')
              .textAlign(TextAlign.End)
              .textOverflow({ overflow: TextOverflow.MARQUEE })
          }
          .justifyContent(FlexAlign.SpaceAround)

        })
      }
    }
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .justifyContent(FlexAlign.Center)
  }
}

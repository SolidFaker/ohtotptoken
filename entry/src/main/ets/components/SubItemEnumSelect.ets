import { MaterialTheme } from './MaterialTheme';
import {EnumSelectOption} from 'common';
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING, SETTING_ROW_ICON_OFFSET } from './SettingStyle';

/**
 * 增强版选择组件，支持枚举值映射
 * 解决enum index与UI index不对等的问题
 *
 * @example
 * ```typescript
 * SubItemEnumSelect({
 *   title: '选择效果',
 *   options: [
 *     { label: '通用模糊', value: 1 },
 *     { label: '过渡模糊', value: 2 },
 *   ],
 *   selected: 1,
 *   onChange: (value: number) => {
 *     console.log('选择了:', value);
 *   }
 * })
 * ```
 */
@Preview
@ComponentV2
export struct SubItemEnumSelect {
  /** 选择变化时的回调函数，参数为选中的枚举值 */
  @Require @Param onChange: (selected: number) => void = () => {};
  /** 标题文本，支持字符串或资源引用 */
  @Require @Param title: string | Resource = '';
  /** 选项数组，包含label和value */
  @Require @Param options: EnumSelectOption[] = [];
  /** 当前选中的枚举值 */
  @Require @Param selected: number;
  /** 是否禁用选择 */
  @Param disable: boolean = false;
  /** 图标资源 */
  @Param icon: Resource | undefined = undefined;
  /** 描述文本，支持字符串或资源引用 */
  @Param description: string | Resource = '';

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

        Select(this.options.map((option: EnumSelectOption) => {
          return { value: option.label as string } as SelectOption;
        }))
          // 触发器不挂沉浸材质（内容区非官方允许生效区域）；下拉菜单保持材质。
          .enabled(!this.disable)
          .value(this.options.find((opt: EnumSelectOption) => opt.value === this.selected)?.label as string ?? '')
          .selected(this.options.findIndex((opt: EnumSelectOption) => opt.value === this.selected))
          .menuSystemMaterial(MaterialTheme.systemMaterial())
          .onSelect((index: number) => {
            const selectedValue = this.options[index]?.value;
            if (selectedValue !== undefined) {
              this.onChange(selectedValue);
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .justifyContent(FlexAlign.Center)
  }
}

import { MaterialTheme } from './MaterialTheme';
import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING, SETTING_ROW_ICON_OFFSET } from './SettingStyle';

/**
 * 基础选择组件
 * 提供下拉选择功能，适用于选项与索引一一对应的场景
 *
 * @example
 * ```typescript
 * SubItemSelect({
 *   title: '颜色模式',
 *   values: ['跟随系统', '深色模式', '浅色模式'],
 *   selected: 0,
 *   onChange: (index: number) => {
 *     console.log('选择了索引:', index);
 *   }
 * })
 * ```
 *
 * @remarks
 * 如果选项与枚举值不对应（如跳过某些值），建议使用SubItemEnumSelect组件
 */
@Preview
@ComponentV2
export struct SubItemSelect {
  /** 选择变化时的回调函数，参数为选中的索引 */
  @Require @Param onChange: (selected: number) => void = () => {};
  /** 标题文本，支持字符串或资源引用 */
  @Require @Param title: string | Resource = '';
  /** 选项文本数组，支持字符串或资源引用 */
  @Require @Param values: string[] | Resource[] = [];
  /** 当前选中的索引 */
  @Require @Param selected: number = 0;
  /** 是否禁用选择 */
  @Param disable: boolean = false;
  /** 图标资源 */
  @Param icon: Resource | undefined = undefined;
  /** 描述文本，支持字符串或资源引用 */
  @Param description: string  | Resource = '';

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

        // 触发器不挂沉浸材质（内容区非官方允许生效区域）；下拉菜单保持材质。
        Select(this.values.map((val: string | Resource) => {return { value: val as string } as SelectOption }))
          .enabled(!this.disable)
          .value(this.values[this.selected])
          .selected(this.selected)
          .menuSystemMaterial(MaterialTheme.systemMaterial())
          .onSelect((index) => {
            this.onChange(index);
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

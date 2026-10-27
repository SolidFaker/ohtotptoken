import { SETTING_ROW_MIN_HEIGHT, SETTING_ROW_PADDING, SETTING_ROW_ICON_OFFSET } from './SettingStyle';

@Preview
@ComponentV2
export struct SubItemToggle {
  @Require @Param onChange: (isOn: boolean) => void = () => {};
  @Require @Param title: string | Resource = '';
  @Require @Param isOn: boolean = false;
  @Param disable: boolean = false;
  @Param icon: Resource | undefined = undefined;
  @Param description: string  | Resource = '';
  @Param descriptionColor: ResourceColor = $r('sys.color.ohos_id_color_text_secondary');

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
              .fontColor(this.descriptionColor)
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

        // 不挂沉浸材质：内容区控件不在官方允许生效区域，材质白底+白色点光源会遮挡开关配色（暗色尤甚）。
        Toggle({ type: ToggleType.Switch, isOn: this.isOn })
          .id('ToggleSwitch')
          .width(36)
          .height(20)
          // 视觉尺寸保持紧凑，触摸热区按手机 UX 推荐扩展至 48vp × 48vp。
          .responseRegion({ x: -6, y: -14, width: 48, height: 48 })
          .onChange((isOn: boolean) => {
            this.onChange(isOn);
          })
          .enabled(!this.disable)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .padding(SETTING_ROW_PADDING)
    .constraintSize({ minHeight: SETTING_ROW_MIN_HEIGHT })
    .justifyContent(FlexAlign.Center)
  }
}

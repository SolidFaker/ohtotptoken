
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
          .layoutWeight(2)

        Blank()

        Toggle({ type: ToggleType.Switch, isOn: this.isOn })
          .id('ToggleSwitch')
          .width(36)
          .height(20)
          .onChange((isOn: boolean) => {
            this.onChange(isOn);
          })
          .enabled(!this.disable)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
      }
      .width('100%')
      if (this.description != '') {
        Text(this.description)
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor(this.descriptionColor)
          .fontWeight(FontWeight.Regular)
          .fontFamily('HarmonyHeiTi')
          .lineHeight(19)
          .width('100%')
      }
    }
    .padding(10)
  }
}
import { AppPreference, PREF_KEYS } from 'common';
import { colorHex, hexColor, mixRgba, scaleRgba, setRgba } from 'common';

@Preview
@CustomDialog
export struct ColorSelectDialog {
  controller?: CustomDialogController;
  confirm: (color: number) => void = () => {};

  @Prop old_color: number;
  @State picked_color: number = setRgba(255, 0, 0, 255);
  @State mixed_color: number = this.old_color;
  @State input_color: string = '';
  @State input_change: boolean = false;
  @StorageLink('background_blur_flag') backgroundBlurFlag: boolean = false;

  private canvas_context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));

  @State debug_x_pct: number = 0;
  @State debug_y_pct: number = 0;
  @State debug_scaled_color: number = 0;

  private update_canvas() {
    let color = this.canvas_context.createLinearGradient(0, 0, this.canvas_context.width, 0);
    color.addColorStop(0, 'rgb(0, 0, 0)');
    color.addColorStop(1, colorHex(this.picked_color));
    this.canvas_context.fillStyle = color;
    this.canvas_context.fillRect(0, 0, this.canvas_context.width, this.canvas_context.height);

    color = this.canvas_context.createLinearGradient(0, 0, 0, this.canvas_context.height);
    color.addColorStop(0, 'rgba(255, 255, 255, 1)');
    color.addColorStop(1, 'rgba(0, 0, 0, 0)');
    this.canvas_context.fillStyle = color;
    this.canvas_context.fillRect(0, 0, this.canvas_context.width, this.canvas_context.height);
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Stack() {
          TextInput({ placeholder: colorHex(this.mixed_color) })
            .fontWeight(FontWeight.Medium)
            .fontSize($r('sys.float.Subtitle_M'))
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .onChange((value) => {
              if (value.length > 0) {
                animateToImmediately({ curve: Curve.FastOutLinearIn }, () => {
                  this.input_change = true;
                })
              } else {
                animateToImmediately({ curve: Curve.FastOutLinearIn }, () => {
                  this.input_change = false;
                })
              }
              this.input_color = value;
            })
          if (this.input_change) {
            Row() {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(20)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor('#ff20c020')
            .margin({ right: 8 })
            .borderRadius(15)
            .width(30)
            .height(30)
            .onClick(() => {
              if (this.input_color.length > 0) {
                this.mixed_color = hexColor(this.input_color);
                animateToImmediately({ curve: Curve.FastOutSlowIn, duration: 100 }, () => {
                  this.input_change = false;
                })
              }
            })
          }
        }
        .alignContent(Alignment.End)
        .layoutWeight(1)
        Shape()
          .backgroundColor(this.mixed_color)
          .borderRadius(5)
          .borderWidth(1)
          .width(40)
          .height(40)


      }
      .padding({ top: 10, left: 10, right: 10})
      Stack() {
        Canvas(this.canvas_context)
          .margin({ left: 10, right: 10, top: 10 })
          .onReady(() => {
            this.update_canvas();
          })
          .onTouch((event) => {
            let x_pct = event.touches[0].x / this.canvas_context.width;
            let y_pct = event.touches[0].y / this.canvas_context.height;
            const scaled_color = scaleRgba(this.picked_color, x_pct);
            this.mixed_color = mixRgba(scaled_color, 0xffffffff, y_pct);

            this.debug_x_pct = x_pct;
            this.debug_y_pct = y_pct;
            this.debug_scaled_color = scaled_color;
          })
        if (AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON)) {
          Column() {
            Text(`x_pct: ${this.debug_x_pct}`)
            Text(`y_pct: ${this.debug_y_pct}`)
            Text(`picked_color: ${colorHex(this.picked_color)}`)
            Text(`scaled_color: ${colorHex(this.debug_scaled_color)}`)
          }

        }
      }
      .layoutWeight(1)


      Slider({
        value: 0,
        style: SliderStyle.InSet,
        min: 0,
        max: 100,
      })
        .onChange((value: number, mode: SliderChangeMode) => {
          this.picked_color = getBlockColor(value);
          this.update_canvas();
        })
        //.enableHapticFeedback(true)
        .selectedColor(Color.Transparent)
        .trackColor(new LinearGradient([
          { color: setRgba(255, 0, 0, 255), offset: 0 },
          { color: setRgba(255, 255, 0, 255), offset: 1 / 6 },
          { color: setRgba(0, 255, 0, 255), offset: 2 / 6 },
          { color: setRgba(0, 255, 255, 255), offset: 3 / 6 },
          { color: setRgba(0, 0, 255, 255), offset: 4 / 6 },
          { color: setRgba(255, 0, 255, 255), offset: 5 / 6 },
          { color: setRgba(255, 0, 0, 255), offset: 6 / 6 },
        ]))
        .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK_UP)
        .trackThickness($r('app.float.slider_track_thick_large'))
        .blockBorderColor(Color.White)
        .blockBorderWidth($r('app.float.slider_block_border_size'))
        .blockSize({
          width: $r('app.float.slider_block_size_large'),
          height: $r('app.float.slider_block_size_large'),
        })
        .blockColor(Color.Transparent)
        .width('100%')
      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        Button($r('app.string.dialog_btn_cancel'))
          .fontColor($r('app.color.item_fg'))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close()
            }
          })
          .width('100%')
        Button($r('app.string.dialog_btn_confirm'), { })
          .fontColor(Color.Red)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.confirm(this.mixed_color);
              this.controller?.close();
            }
          })
          .width('100%')
      }
    }
    .padding(10)
    .width('100%')
    .foregroundBlurStyle(this.backgroundBlurFlag ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }
}

function getColorFromRgb(rgb: number): number {
  const redArea: number = (rgb >>> 16) & 0xff;
  const greenArea: number = (rgb >>> 8) & 0xff;
  const blueArea: number = rgb & 0xff;
  const allColorCount = 255 * 6;
  let colorPercent: number = 0.00;
  if (redArea === 255 && blueArea === 0) {
    colorPercent = greenArea / allColorCount;
  } else if (greenArea === 255 && blueArea === 0) {
    colorPercent = ((255 - redArea) + 255) / allColorCount;
  } else if (redArea === 0 && greenArea === 255) {
    colorPercent = (blueArea + 255 * 2) / allColorCount;
  } else if (redArea === 0 && blueArea === 255) {
    colorPercent = ((255 - greenArea) + 255 * 3) / allColorCount;
  } else if (greenArea === 0 && blueArea === 255) {
    colorPercent = (redArea + 255 * 4) / allColorCount;
  } else if (redArea === 255 && greenArea === 0) {
    colorPercent = ((255 - blueArea) + 255 * 5) / allColorCount;
  }
  return colorPercent * 100;
}

function  getBlockColor(value: number): number {
  const colorPercent = value / 100;
  const colorAreaCount = 6;
  let selectedColor: number = 0;
  let colorAreaPercent: number = 0;
  if (colorPercent >= 0 && colorPercent <= 1 / colorAreaCount) {
    colorAreaPercent = colorPercent * colorAreaCount;
    selectedColor = setRgba(255, Math.floor(colorAreaPercent * 255), 0, 255);
  } else if (colorPercent >= 1 / colorAreaCount && colorPercent <= 2 / colorAreaCount) {
    colorAreaPercent = (colorPercent - 1 / colorAreaCount) * colorAreaCount;
    selectedColor = setRgba(Math.floor(((1 - colorAreaPercent) * 255)), 255, 0, 255);
  } else if (colorPercent >= 2 / colorAreaCount && colorPercent <= 3 / colorAreaCount) {
    colorAreaPercent = (colorPercent - 2 / colorAreaCount) * colorAreaCount;
    selectedColor = setRgba(0, 255, Math.floor(colorAreaPercent * 255), 255);
  } else if (colorPercent >= 3 / colorAreaCount && colorPercent <= 4 / colorAreaCount) {
    colorAreaPercent = (colorPercent - 3 / colorAreaCount) * colorAreaCount;
    selectedColor = setRgba(0, Math.floor(((1 - colorAreaPercent) * 255)), 255, 255);
  } else if (colorPercent >= 4 / colorAreaCount && colorPercent <= 5 / colorAreaCount) {
    colorAreaPercent = (colorPercent - 4 / colorAreaCount) * colorAreaCount;
    selectedColor = setRgba(Math.floor(colorAreaPercent * 255), 0, 255, 255);
  } else if (colorPercent >= 5 / colorAreaCount && colorPercent <= 6 / colorAreaCount) {
    colorAreaPercent = (colorPercent - 5 / colorAreaCount) * colorAreaCount;
    selectedColor = setRgba(255, 0, Math.floor(((1 - colorAreaPercent) * 255)), 255);
  }
  return selectedColor;
}
import { TokenIcon } from "../components/TokenIcon";
import { showSelectFilePicker } from "../utils/FileUtils";
import { AegisIconPack, TokenIconPacks } from "../utils/TokenUtils";
import { fileIo } from "@kit.CoreFileKit";

@Preview
@CustomDialog
export struct SelectIconDialog {
  @Prop @Require issuer: string = '';
  controller?: CustomDialogController;
  cancel?: () => void;
  confirm: (new_conf: string) => void = () => {};

  @State selected_icon_path: string = '';

  @State icon_matched_with_issuer: string[] = [TokenIconPacks.getIconByIssuer(this.issuer)];
  @State default_icon_pack_visible: boolean = true;
  @State aegis_icon_pack_visible: boolean[] = [];

  private default_icon_data: MyDataSource = new MyDataSource();
  private user_icon_data: MyDataSource = new MyDataSource();
  private aegis_icon_data: MyDataSource[] = [];

  aboutToAppear(): void {
    // find issuer's icon
    const default_icon = TokenIconPacks.default_icon_pack.getIconPathByIssuer(this.issuer);
    if (default_icon !== '' && !this.icon_matched_with_issuer.includes(default_icon)){
      this.icon_matched_with_issuer.push(default_icon);
    }
    TokenIconPacks.aegis_icon_packs.forEach((aegis_icon_pack) => {
      const aegis_icon = aegis_icon_pack.getIconPathByIssuer(this.issuer);
      this.aegis_icon_pack_visible.push(false);
      if (aegis_icon !== ''&& !this.icon_matched_with_issuer.includes(aegis_icon)) {
        this.icon_matched_with_issuer.push(aegis_icon);
      }
    });

    // fill data source
    TokenIconPacks.default_icon_pack.default_icon_pack_path.forEach((path) => {
      this.default_icon_data.pushData(path!);
    });

    TokenIconPacks.user_added_icon_packs.icon_path.forEach((path) => {
      this.user_icon_data.pushData(path!);
    });

    TokenIconPacks.aegis_icon_packs.forEach((aegis_icon_pack) => {
      let data_source = new MyDataSource();
      for (let icon of aegis_icon_pack.icons) {
        for (let path of icon.icon_pack_path) {
          data_source.pushData(path);
        }
        this.aegis_icon_data.push(data_source);
      }
    });
  }

  @Builder
  itemHead(text: ResourceStr) {
    Text(text)
      .margin({ left: 10, top: 10, bottom: 5 })
      .fontSize(14)
      .fontColor($r('sys.color.font_secondary'))
  }

  @Builder
  ItemIcon(path: string, visible: boolean, removable: boolean) {
    ListItem() {
      Stack( { alignContent: Alignment.TopStart } ) {
        if (path === '') {
          // Text($r('app.string.dialog_icon_default'))
          //   .margin({ top: 15 })
          TokenIcon({ issuer: this.issuer, icon_path: path, bypassColorFilter: true })
        } else {
          TokenIcon({ issuer: '', icon_path: path, bypassColorFilter: true })
        }

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(15)
            .fontColor([Color.White])
            .fontWeight(FontWeight.Medium)
            .rotate({ angle: 45 })
        }
        .backgroundColor(Color.Red)
        .width(20)
        .height(20)
        .margin({ left: 0, top: 0 })
        .visibility(removable ? Visibility.Visible : Visibility.Hidden)
        .onClick(() => {
          AlertDialog.show({
            message: $r('app.string.icon_alert_remove_confirm_msg'),
            autoCancel: true,
            alignment: DialogAlignment.Center,
            primaryButton: {
              defaultFocus: false,
              value: $r('app.string.dialog_btn_cancel'),
              action: () => {
                return
              }
            },
            secondaryButton: {
              value: $r('app.string.dialog_btn_confirm'),
              fontColor: Color.Red,
              action: () => {
                TokenIconPacks.user_added_icon_packs.removeIcon(path);
                this.user_icon_data.removeData(path);
              }
            }
          })
        })

        Radio({ value: '', group: 'icon' })
          .width(20)
          .height(20)
          .margin({ left: 20, top: 20 })
          .onChange((checked) => {
            if (checked) {
              this.selected_icon_path = path;
            }
          })
      }
      .visibility(visible ? Visibility.Visible : Visibility.Hidden)
    }
    .margin({ left: 10 })
  }

  @Builder
  ItemIconAddButton() {
    ListItem() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor([Color.Gray])
      }
      .backgroundColor(Color.Transparent)
      .shadow({ radius: 10, color: Color.Gray })
      .width(40)
      .height(40)
      .onClick(() => {
        showSelectFilePicker(1, ["PNG|.png", "JPEG|.jpg", "SVG|.svg"]).then((uris) => {
          fileIo.open(uris[0]).then((file) => {
            TokenIconPacks.user_added_icon_packs.addIcon(file);
            this.user_icon_data.pushData(TokenIconPacks.user_added_icon_packs.latest_icon_path);
          });

        });
      })
    }
    .margin({ left: 10 })
  }

  build() {
    Column() {
      List({ space: 10 }) {
        ListItemGroup({ header: this.itemHead($r('app.string.dialog_icon_recommend')) }) {
          ForEach(this.icon_matched_with_issuer, (icon_path: string) => {
            this.ItemIcon(icon_path, true, false)
          })
        }
        ListItemGroup({ header: this.itemHead(TokenIconPacks.user_added_icon_packs.name) }) {
          LazyForEach(this.user_icon_data, (path: string) => {
            this.ItemIcon(path, true, true)
          })
          this.ItemIconAddButton()
        }
        .onClick(() => {
          this.default_icon_pack_visible = !this.default_icon_pack_visible;
        })
        ListItemGroup({ header: this.itemHead(TokenIconPacks.default_icon_pack.name) }) {
          LazyForEach(this.default_icon_data, (path: string) => {
            this.ItemIcon(path, true, false)
          })
        }
        .onClick(() => {
          this.default_icon_pack_visible = !this.default_icon_pack_visible;
        })
        ForEach(TokenIconPacks.aegis_icon_packs, (aegis_icon_pack: AegisIconPack, index: number) => {
          ListItemGroup({ header: this.itemHead(aegis_icon_pack.name) }) {
            LazyForEach(this.aegis_icon_data[index], (path: string) => {
              this.ItemIcon(path, true, false)
            })
          }
          .onClick(() => {
            this.aegis_icon_pack_visible[index] = !this.aegis_icon_pack_visible[index];
          })
        }, (aegis_icon_pack: AegisIconPack) => {
          return aegis_icon_pack.on_device_path;
        })
      }
      .lanes({ minLength: 50, maxLength: 50 })
      .width('100%')
      .height('100%')
      .chainAnimation(true)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      Flex({ justifyContent: FlexAlign.SpaceAround }) {
        Button($r('app.string.dialog_btn_cancel'))
          .fontColor($r('app.color.item_fg'))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close();
            }
          })
          .width('100%')
        Button($r('app.string.dialog_btn_confirm'))
          .fontColor(Color.Red)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.controller != undefined) {
              this.confirm(this.selected_icon_path);
              this.controller.close();
            }
          })
          .width('100%')
      }
    }
    .padding(10)
    .width('100%')
  }
}

// BasicDataSource实现了IDataSource接口，用于管理listener监听，以及通知LazyForEach数据更新
class BasicDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private originDataArray: string[] = [];

  public totalCount(): number {
    return 0;
  }

  public getData(index: number): string {
    return this.originDataArray[index];
  }

  // 该方法为框架侧调用，为LazyForEach组件向其数据源处添加listener监听
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      console.info('add listener');
      this.listeners.push(listener);
    }
  }

  // 该方法为框架侧调用，为对应的LazyForEach组件在数据源处去除listener监听
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      console.info('remove listener');
      this.listeners.splice(pos, 1);
    }
  }

  // 通知LazyForEach组件需要重载所有子组件
  notifyDataReload(): void {
    this.listeners.forEach(listener => {
      listener.onDataReloaded();
    })
  }

  // 通知LazyForEach组件需要在index对应索引处添加子组件
  notifyDataAdd(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataAdd(index);
      // 写法2：listener.onDatasetChange([{type: DataOperationType.ADD, index: index}]);
    })
  }

  // 通知LazyForEach组件在index对应索引处数据有变化，需要重建该子组件
  notifyDataChange(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataChange(index);
      // 写法2：listener.onDatasetChange([{type: DataOperationType.CHANGE, index: index}]);
    })
  }

  // 通知LazyForEach组件需要在index对应索引处删除该子组件
  notifyDataDelete(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataDelete(index);
      // 写法2：listener.onDatasetChange([{type: DataOperationType.DELETE, index: index}]);
    })
  }

  // 通知LazyForEach组件将from索引和to索引处的子组件进行交换
  notifyDataMove(from: number, to: number): void {
    this.listeners.forEach(listener => {
      listener.onDataMove(from, to);
      // 写法2：listener.onDatasetChange(
      //         [{type: DataOperationType.EXCHANGE, index: {start: from, end: to}}]);
    })
  }

  notifyDatasetChange(operations: DataOperation[]): void {
    this.listeners.forEach(listener => {
      listener.onDatasetChange(operations);
    })
  }
}

class MyDataSource extends BasicDataSource {
  private dataArray: string[] = [];

  public totalCount(): number {
    return this.dataArray.length;
  }

  public getData(index: number): string {
    return this.dataArray[index];
  }

  public pushData(data: string): void {
    if (this.dataArray.findIndex(_ => _ === data) < 0) {
      this.dataArray.push(data);
      this.notifyDataAdd(this.dataArray.length - 1);
    }
  }

  public removeData(data: string): void {
    const index = this.dataArray.findIndex(_ => _ === data);
    this.dataArray = this.dataArray.filter(_ => _ !== data);
    this.notifyDataDelete(index);
  }
}

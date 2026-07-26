import { KEY_WHITELIST } from '../transfer/TransferModels';
import { transferManager } from '../transfer/TransferManager';

const ACCENT: string = '#0A59F7';
const TEXT_MAIN: string = '#1F2329';
const TEXT_SUB: string = '#8A8F99';
const DANGER: string = '#E84026';

/** 我的页：改设备名、白名单管理、关于（版本与端口说明） */
@Component
export struct MineTab {
  @StorageLink(KEY_WHITELIST) whitelist: string[] = [];
  @State deviceName: string = '';

  aboutToAppear(): void {
    this.deviceName = transferManager.deviceName;
  }

  private saveName(): void {
    const v = this.deviceName.trim();
    if (v.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '设备名不能为空' });
      return;
    }
    transferManager.deviceName = v;
    this.getUIContext().getPromptAction().showToast({ message: '已保存' });
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        // 设备名
        Column({ space: 10 }) {
          Text('设备名')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT_MAIN)
            .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.deviceName, placeholder: '输入设备名' })
              .layoutWeight(1)
              .height(44)
              .maxLength(30)
              .onChange((v: string) => {
                this.deviceName = v;
              })
            Button('保存')
              .height(44)
              .backgroundColor(ACCENT)
              .onClick(() => {
                this.saveName();
              })
          }
          .width('100%')
          Text('设备名会显示给局域网内其他设备')
            .fontSize(12).fontColor(TEXT_SUB)
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor(Color.White)

        // 白名单
        Column({ space: 10 }) {
          Row() {
            Text('受信任设备（白名单）')
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT_MAIN)
            Blank()
            Text(`${this.whitelist.length} 台`)
              .fontSize(13).fontColor(TEXT_SUB)
          }
          .width('100%')
          Text('白名单设备发来文件时免确认自动接收；在接收弹窗勾选「信任该设备」即可加入')
            .fontSize(12).fontColor(TEXT_SUB)
            .width('100%')
          if (this.whitelist.length === 0) {
            Text('暂无受信任设备')
              .fontSize(13).fontColor(TEXT_SUB)
              .width('100%')
              .padding({ top: 6, bottom: 6 })
          } else {
            ForEach(this.whitelist, (ip: string) => {
              Row() {
                Text(ip)
                  .fontSize(14).fontColor(TEXT_MAIN)
                  .layoutWeight(1)
                Text('移除')
                  .fontSize(13).fontColor(DANGER)
                  .onClick(() => {
                    transferManager.removeFromWhitelist(ip);
                  })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            }, (ip: string) => ip)
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor(Color.White)

        // 关于
        Column({ space: 8 }) {
          Text('关于')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT_MAIN)
            .width('100%')
          Text('发来 · 版本 1.0')
            .fontSize(13).fontColor(TEXT_SUB)
            .width('100%')
          Text('设备发现：UDP 广播 47800')
            .fontSize(13).fontColor(TEXT_SUB)
            .width('100%')
          Text('文件传输：TCP 47801~47811（端口占用自动后移）')
            .fontSize(13).fontColor(TEXT_SUB)
            .width('100%')
          Text('两台设备需连接同一 WiFi；支持断点续传，重发同一批文件自动续传')
            .fontSize(13).fontColor(TEXT_SUB)
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor(Color.White)
      }
      .width('100%')
      .padding(14)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }
}

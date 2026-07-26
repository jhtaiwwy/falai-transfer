import { common } from '@kit.AbilityKit';
import { DeviceItem, KEY_DEVICES, KEY_LOCAL_IP, KEY_PENDING_FILES, ResolvedFileItem } from '../transfer/TransferModels';
import { transferManager } from '../transfer/TransferManager';
import { pickMediaFiles, pickDocumentFiles } from '../transfer/FileIO';

const ACCENT: string = '#0A59F7';
const TEXT_MAIN: string = '#1F2329';
const TEXT_SUB: string = '#8A8F99';

/**
 * 传输页：本机卡片（设备名+IP）+「照片/视频」「选择文件」按钮 + 在线设备列表。
 * 设备卡片用 GridRow/GridCol 按宽度断点自适应列数（方案.md §5.1）：
 * xs[0,320) 一列、sm[320,600) 两列、md[600,+) 三列。
 */
@Component
export struct TransferTab {
  @StorageLink(KEY_DEVICES) devices: DeviceItem[] = [];
  @StorageLink(KEY_LOCAL_IP) localIp: string = '';

  private async pickMedia(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const files = await pickMediaFiles(context);
      if (files.length > 0) {
        AppStorage.setOrCreate<ResolvedFileItem[]>(KEY_PENDING_FILES, files);
      }
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '选择失败或已取消' });
    }
  }

  private async pickDocs(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const files = await pickDocumentFiles(context);
      if (files.length > 0) {
        AppStorage.setOrCreate<ResolvedFileItem[]>(KEY_PENDING_FILES, files);
      }
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '选择失败或已取消' });
    }
  }

  private osLabel(os: string): string {
    if (os === 'android') {
      return '安卓';
    }
    if (os === 'harmony') {
      return '鸿蒙';
    }
    return '未知';
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        // 本机卡片
        Column({ space: 6 }) {
          Text('本机')
            .fontSize(13).fontColor(TEXT_SUB)
          Row() {
            Column({ space: 4 }) {
              Text(transferManager.deviceName)
                .fontSize(18).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
              Text(`IP：${this.localIp.length > 0 ? this.localIp : '未连接网络'}`)
                .fontSize(13).fontColor(TEXT_SUB)
              Text(`接收端口：${transferManager.serverPort > 0 ? transferManager.serverPort : '启动中'}`)
                .fontSize(13).fontColor(TEXT_SUB)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Stack() {
              Text('鸿')
                .fontSize(20).fontColor(Color.White)
            }
            .width(48).height(48).borderRadius(24).backgroundColor(ACCENT)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor(Color.White)

        // 发送按钮
        Row({ space: 12 }) {
          Button('照片/视频')
            .layoutWeight(1).height(48).backgroundColor(ACCENT)
            .onClick(() => {
              this.pickMedia();
            })
          Button('选择文件')
            .layoutWeight(1).height(48).backgroundColor('#EAF1FE').fontColor(ACCENT)
            .onClick(() => {
              this.pickDocs();
            })
        }
        .width('100%')

        // 在线设备
        Row() {
          Text('在线设备')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(TEXT_MAIN)
          Blank()
          Text(`${this.devices.length} 台`)
            .fontSize(13).fontColor(TEXT_SUB)
        }
        .width('100%')

        if (this.devices.length === 0) {
          Column({ space: 6 }) {
            Text('暂未发现设备')
              .fontSize(14).fontColor(TEXT_SUB)
            Text('确保两台设备连接同一 WiFi；若路由器开了 AP 隔离，可在选择文件后手动输入对方 IP')
              .fontSize(12).fontColor(TEXT_SUB)
          }
          .width('100%')
          .padding(24)
          .borderRadius(14)
          .backgroundColor(Color.White)
        } else {
          GridRow({ columns: 12, gutter: 12 }) {
            ForEach(this.devices, (dev: DeviceItem) => {
              GridCol({ span: { xs: 12, sm: 6, md: 4, lg: 4 } }) {
                Column({ space: 6 }) {
                  Row({ space: 8 }) {
                    Stack() {
                      Text(dev.os === 'android' ? '安' : (dev.os === 'harmony' ? '鸿' : '设'))
                        .fontSize(13).fontColor(Color.White)
                    }
                    .width(32).height(32).borderRadius(16)
                    .backgroundColor(dev.os === 'harmony' ? ACCENT : '#34A853')
                    Text(dev.name)
                      .fontSize(15).fontColor(TEXT_MAIN).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')
                  Text(`${this.osLabel(dev.os)} · ${dev.ip}:${dev.tcpPort}`)
                    .fontSize(12).fontColor(TEXT_SUB)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding(14)
                .borderRadius(14)
                .backgroundColor(Color.White)
                .onClick(() => {
                  this.getUIContext().getPromptAction().showToast({ message: '请先选择要发送的文件' });
                })
              }
            }, (dev: DeviceItem) => dev.ip)
          }
          .width('100%')
        }
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

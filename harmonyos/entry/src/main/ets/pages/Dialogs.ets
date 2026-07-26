import { formatBytes, formatSpeed, formatEta, isVisualMedia, extLower } from '../core/Format';
import {
  DeviceItem, DIR_SEND, IncomingRequest, KEY_DEVICES, KEY_PENDING_FILES,
  KEY_PROGRESS, ResolvedFileItem, STATUS_CANCELED, STATUS_DONE, STATUS_FAILED,
  STATUS_PAUSED, STATUS_REJECTED, STATUS_TRANSFERRING, STATUS_WAITING, TransferProgress
} from '../transfer/TransferModels';
import { transferManager } from '../transfer/TransferManager';
import { discoveryService } from '../discovery/DiscoveryService';

const ACCENT: string = '#0A59F7';
const TEXT_MAIN: string = '#1F2329';
const TEXT_SUB: string = '#8A8F99';
const DANGER: string = '#E84026';

/**
 * 全屏弹窗组件：不依赖 CustomDialogController，直接以 Stack 叠层 + AppStorage 状态驱动，
 * 异步事件（收到传输请求、进度刷新）来了自然弹出/刷新，避免控制器生命周期问题。
 */

// ---------- 发送预览：文件列表（可移除单个）+ 设备列表 + 手动输 IP ----------

@Component
export struct PreviewOverlay {
  @StorageLink(KEY_PENDING_FILES) pending: ResolvedFileItem[] = [];
  @StorageLink(KEY_DEVICES) devices: DeviceItem[] = [];
  @State manualIp: string = '';

  private close(): void {
    AppStorage.setOrCreate<ResolvedFileItem[]>(KEY_PENDING_FILES, []);
  }

  private removeAt(index: number): void {
    this.pending = this.pending.filter((f: ResolvedFileItem, i: number) => i !== index);
    if (this.pending.length === 0) {
      this.close();
    }
  }

  private sendTo(dev: DeviceItem): void {
    const files = this.pending;
    this.close();
    transferManager.sendFiles(dev.ip, dev.tcpPort, dev.name, files);
  }

  private totalSize(): number {
    return this.pending.reduce((s: number, f: ResolvedFileItem) => s + f.size, 0);
  }

  build() {
    Column() {
      Column({ space: 12 }) {
        Row() {
          Text('发送预览')
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
          Blank()
          Text(`${this.pending.length} 个文件 · 共 ${formatBytes(this.totalSize())}`)
            .fontSize(13).fontColor(TEXT_SUB)
        }
        .width('100%')

        // 文件列表（可移除单个）
        List({ space: 8 }) {
          ForEach(this.pending, (file: ResolvedFileItem, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                if (isVisualMedia(file.name) && file.uri.length > 0) {
                  Image(file.uri)
                    .width(44).height(44).objectFit(ImageFit.Cover).borderRadius(6)
                } else {
                  Stack() {
                    Text(extLower(file.name).length > 0 ? extLower(file.name).toUpperCase() : 'FILE')
                      .fontSize(10).fontColor(TEXT_SUB)
                  }
                  .width(44).height(44).borderRadius(6).backgroundColor('#EEF0F3')
                }
                Column({ space: 2 }) {
                  Text(file.name)
                    .fontSize(14).fontColor(TEXT_MAIN).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(formatBytes(file.size))
                    .fontSize(12).fontColor(TEXT_SUB)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('移除')
                  .fontSize(13).fontColor(DANGER)
                  .onClick(() => {
                    this.removeAt(index);
                  })
              }
              .width('100%')
              .padding(8)
              .borderRadius(10)
              .backgroundColor('#F7F8FA')
            }
          }, (file: ResolvedFileItem) => file.uri.length > 0 ? file.uri : file.tempPath)
        }
        .width('100%')
        .height(180)

        Divider().color('#EEEFF1')

        Text('选择接收设备')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(TEXT_MAIN)

        if (this.devices.length === 0) {
          Text('暂未发现在线设备，可在下方手动输入 IP')
            .fontSize(13).fontColor(TEXT_SUB)
        } else {
          List({ space: 8 }) {
            ForEach(this.devices, (dev: DeviceItem) => {
              ListItem() {
                Row({ space: 10 }) {
                  Stack() {
                    Text(dev.os === 'android' ? '安' : (dev.os === 'harmony' ? '鸿' : '设'))
                      .fontSize(14).fontColor(Color.White)
                  }
                  .width(36).height(36).borderRadius(18).backgroundColor(ACCENT)
                  Column({ space: 2 }) {
                    Text(dev.name)
                      .fontSize(14).fontColor(TEXT_MAIN).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${dev.ip}:${dev.tcpPort}`)
                      .fontSize(12).fontColor(TEXT_SUB)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Text('发送')
                    .fontSize(14).fontColor(ACCENT).fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .padding(10)
                .borderRadius(10)
                .backgroundColor('#F7F8FA')
                .onClick(() => {
                  this.sendTo(dev);
                })
              }
            }, (dev: DeviceItem) => dev.ip)
          }
          .width('100%')
          .constraintSize({ maxHeight: 200 })
        }

        // 手动输 IP 兜底（AP 隔离场景，方案.md §4.1）
        Row({ space: 8 }) {
          TextInput({ placeholder: '手动输入设备 IP', text: this.manualIp })
            .layoutWeight(1)
            .height(40)
            .onChange((v: string) => {
              this.manualIp = v;
            })
          Button('添加')
            .height(40)
            .backgroundColor(ACCENT)
            .onClick(() => {
              const ok = discoveryService.addManualDevice(this.manualIp);
              this.getUIContext().getPromptAction().showToast({
                message: ok ? '已加入设备列表' : 'IP 格式不正确'
              });
              if (ok) {
                this.manualIp = '';
              }
            })
        }
        .width('100%')

        Button('取消')
          .width('100%')
          .height(44)
          .fontColor(TEXT_MAIN)
          .backgroundColor('#EEF0F3')
          .onClick(() => {
            this.close();
          })
      }
      .width('88%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }
}

// ---------- 传输进度：大圆环 + 速度/ETA + 暂停/继续/取消 ----------

@Component
export struct ProgressOverlay {
  @StorageLink(KEY_PROGRESS) progress: TransferProgress = new TransferProgress();

  private pct(): number {
    if (this.progress.totalBytes <= 0) {
      return 0;
    }
    return Math.min(100, this.progress.transferredBytes * 100 / this.progress.totalBytes);
  }

  private statusText(): string {
    switch (this.progress.status) {
      case STATUS_WAITING:
        return '等待对方确认…';
      case STATUS_TRANSFERRING:
        return '传输中';
      case STATUS_PAUSED:
        return '已暂停';
      case STATUS_DONE:
        return '传输完成';
      case STATUS_REJECTED:
        return '对方拒绝了请求';
      case STATUS_CANCELED:
        return '已取消';
      case STATUS_FAILED:
        return this.progress.error.length > 0 ? `传输失败: ${this.progress.error}` : '传输失败';
      default:
        return '';
    }
  }

  build() {
    Column() {
      Column({ space: 14 }) {
        Text(this.progress.direction === DIR_SEND ? `发送给 ${this.progress.peerName}` : `接收自 ${this.progress.peerName}`)
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

        Stack() {
          Progress({ value: this.pct(), total: 100, type: ProgressType.Ring })
            .width(170).height(170)
            .color(this.progress.status === STATUS_FAILED ? DANGER : ACCENT)
            .backgroundColor('#E8EAEE')
            .style({ strokeWidth: 12 })
          Column({ space: 4 }) {
            Text(`${Math.floor(this.pct())}%`)
              .fontSize(30).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
            Text(this.statusText())
              .fontSize(13).fontColor(TEXT_SUB)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width(130)
        }
        .width(170).height(170)

        if (this.progress.active) {
          Text(this.progress.currentFile)
            .fontSize(14).fontColor(TEXT_MAIN)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.progress.fileCount > 1
            ? `第 ${this.progress.fileIndex}/${this.progress.fileCount} 个文件 · ${formatBytes(this.progress.transferredBytes)} / ${formatBytes(this.progress.totalBytes)}`
            : `${formatBytes(this.progress.transferredBytes)} / ${formatBytes(this.progress.totalBytes)}`)
            .fontSize(13).fontColor(TEXT_SUB)
          if (this.progress.status !== STATUS_WAITING && this.progress.status !== STATUS_PAUSED) {
            Text(`${formatSpeed(this.progress.speedBps)} · ${formatEta(this.progress.etaSeconds)}`)
              .fontSize(14).fontColor(ACCENT).fontWeight(FontWeight.Medium)
          } else if (this.progress.status === STATUS_PAUSED) {
            Text('已暂停')
              .fontSize(14).fontColor(TEXT_SUB)
          }
        }

        // 按钮区：发送端可暂停/继续，双方可取消；结束后显示「完成」
        if (this.progress.active) {
          Row({ space: 12 }) {
            if (this.progress.direction === DIR_SEND) {
              if (this.progress.status === STATUS_PAUSED) {
                Button('继续')
                  .layoutWeight(1).height(44).backgroundColor(ACCENT)
                  .onClick(() => {
                    transferManager.resumeTransfer();
                  })
              } else {
                Button('暂停')
                  .layoutWeight(1).height(44).backgroundColor('#EEF0F3').fontColor(TEXT_MAIN)
                  .enabled(this.progress.status === STATUS_TRANSFERRING)
                  .onClick(() => {
                    transferManager.pauseTransfer();
                  })
              }
            }
            Button('取消传输')
              .layoutWeight(1).height(44).backgroundColor('#FDECE9').fontColor(DANGER)
              .onClick(() => {
                transferManager.cancelTransfer();
              })
          }
          .width('100%')
        } else {
          Button('完成')
            .width('100%').height(44).backgroundColor(ACCENT)
            .onClick(() => {
              transferManager.dismissProgress();
            })
        }
      }
      .width('84%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }
}

// ---------- 接收确认：「XXX 想发给你 N 个文件」+ 信任勾选 + 接受/拒绝 ----------

@Component
export struct IncomingOverlay {
  @Prop req: IncomingRequest = new IncomingRequest();
  @State trust: boolean = false;

  build() {
    Column() {
      Column({ space: 16 }) {
        Text('接收文件')
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
        Text(`${this.req.fromName} 想发给你 ${this.req.fileCount} 个文件（共 ${formatBytes(this.req.totalBytes)}）`)
          .fontSize(15).fontColor(TEXT_MAIN)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Checkbox()
            .select(this.trust)
            .onChange((v: boolean) => {
              this.trust = v;
            })
          Text('信任该设备，以后自动接收')
            .fontSize(14).fontColor(TEXT_SUB)
        }
        .width('100%')
        Row({ space: 12 }) {
          Button('拒绝')
            .layoutWeight(1).height(44).backgroundColor('#EEF0F3').fontColor(DANGER)
            .onClick(() => {
              transferManager.respondIncoming(false, false);
            })
          Button('接受')
            .layoutWeight(1).height(44).backgroundColor(ACCENT)
            .onClick(() => {
              transferManager.respondIncoming(true, this.trust);
            })
        }
        .width('100%')
      }
      .width('84%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }
}

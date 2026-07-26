import { formatBytes, formatSpeed, formatTime, formatDuration } from '../core/Format';
import { KEY_LOGS, TransferLogItem } from '../transfer/TransferModels';
import { logRepository } from '../data/LogRepository';

const ACCENT: string = '#0A59F7';
const TEXT_MAIN: string = '#1F2329';
const TEXT_SUB: string = '#8A8F99';
const DANGER: string = '#E84026';

/**
 * 日志页：卡片列表（左滑删除单条、顶部清空带二次确认）。
 * 用 List + lanes 做自适应列数（窄屏 1 列、折叠展开 2 列、平板 3 列），
 * 这样每条都是 ListItem，天然支持 swipeAction 左滑删除。
 */
@Component
export struct LogTab {
  @StorageLink(KEY_LOGS) logs: TransferLogItem[] = [];

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空日志',
      message: '确定清空全部传输日志吗？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: DANGER,
        action: () => {
          logRepository.clear();
        }
      }
    });
  }

  private onClickLog(log: TransferLogItem): void {
    if (log.contentUri.length > 0) {
      // TODO(一期)：接收成功的单文件可点击预览。鸿蒙没有公开的「系统查看器」直达 API，
      // 调起预览需要 fileShare 授权 + 拉起文件管理/图库，二期再做；先提示落点。
      this.getUIContext().getPromptAction().showToast({ message: '文件已保存到相册' });
    }
  }

  private descLine(log: TransferLogItem): string {
    let line = `${formatTime(log.timeMillis)} · ${log.resultText}`;
    if (log.durationMs > 0) {
      line += ` · ${formatDuration(log.durationMs)}`;
    }
    if (log.avgSpeedBps > 0) {
      line += ` · ${formatSpeed(log.avgSpeedBps)}`;
    }
    if (log.contentUri.length > 0) {
      line += ' · 点击预览';
    }
    return line;
  }

  @Builder
  buildDelete(log: TransferLogItem) {
    Button('删除')
      .height('100%')
      .backgroundColor(DANGER)
      .onClick(() => {
        logRepository.delete(log.id);
      })
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('传输日志')
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
        Blank()
        Text('清空')
          .fontSize(14).fontColor(this.logs.length > 0 ? DANGER : TEXT_SUB)
          .onClick(() => {
            if (this.logs.length > 0) {
              this.confirmClear();
            }
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      if (this.logs.length === 0) {
        Column() {
          Text('暂无传输记录')
            .fontSize(14).fontColor(TEXT_SUB)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 10 }) {
          ForEach(this.logs, (log: TransferLogItem) => {
            ListItem() {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(log.outgoing ? '发出' : '收到')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .borderRadius(6)
                    .backgroundColor(log.outgoing ? ACCENT : '#34A853')
                  Text(log.peerName)
                    .fontSize(15).fontColor(TEXT_MAIN).fontWeight(FontWeight.Medium)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(formatBytes(log.sizeBytes))
                    .fontSize(13).fontColor(TEXT_SUB)
                }
                .width('100%')
                Text(log.fileSummary)
                  .fontSize(14).fontColor(TEXT_MAIN)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.descLine(log))
                  .fontSize(12)
                  .fontColor(log.success ? TEXT_SUB : DANGER)
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .width('100%')
              .padding(14)
              .borderRadius(14)
              .backgroundColor(Color.White)
              .onClick(() => {
                this.onClickLog(log);
              })
            }
            .swipeAction({ end: (): void => this.buildDelete(log), edgeEffect: SwipeEdgeEffect.Spring })
          }, (log: TransferLogItem) => `${log.id}`)
        }
        .lanes({ minLength: 300, maxLength: 560 }, 10)
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding(14)
  }
}

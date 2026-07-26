import {
  IncomingRequest, KEY_INCOMING, KEY_PENDING_FILES, KEY_PROGRESS,
  ResolvedFileItem, TransferProgress
} from '../transfer/TransferModels';
import { TransferTab } from './TransferTab';
import { LogTab } from './LogTab';
import { MineTab } from './MineTab';
import { PreviewOverlay, ProgressOverlay, IncomingOverlay } from './Dialogs';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';

/**
 * 主页：底部三 Tab（传输/日志/我的，方案.md §6）。
 * 三个全屏弹窗（发送预览/传输进度/接收确认）以 Stack 叠层实现，
 * 由 AppStorage 状态驱动：异步事件（收到请求、进度刷新）到来时自动弹出。
 * 
 * HarmonyOS 6 (API 23+) 新特性：
 * - 沉浸光感：通过 systemMaterialEffect 实现真实物理光照模型
 * - 智能握持：通过 adaptToHandedness 实现握持手自适应
 * - 流畅动画：渐隐渐显 + 缩放 + 弹簧曲线
 */
@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @StorageLink(KEY_PROGRESS) progress: TransferProgress = new TransferProgress();
  @StorageLink(KEY_INCOMING) incoming: IncomingRequest | null = null;
  @StorageLink(KEY_PENDING_FILES) pendingFiles: ResolvedFileItem[] = [];
  
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  // 默认使用自适应效果
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @State customMaterialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  
  // 页面切换动画状态
  @State pageOpacity: number[] = [1.0, 0.0, 0.0]; // 三个页面的透明度
  @State pageScale: number[] = [1.0, 0.95, 0.95]; // 三个页面的缩放比例
  @State pageTranslateX: number[] = [0, 0, 0]; // 三个页面的水平位移

  aboutToAppear(): void {
    this.initMaterialEffect();
  }

  // 沉浸光感降级检测：如果设备不支持 IMMERSIVE，则使用 SMOOTH 效果
  private initMaterialEffect(): void {
    const supportedTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (supportedTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0) {
      // 设备支持沉浸光感，使用最强效果
      this.customMaterialType = hdsMaterial.MaterialType.IMMERSIVE;
      this.customMaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
    } else {
      // 设备不支持，降级使用平滑效果
      this.customMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
      this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }
  }

  // 页面切换动画处理
  private handleTabChange(toIndex: number): void {
    if (toIndex === this.currentTab) {
      return;
    }
    
    const fromIndex = this.currentTab;
    
    // 使用弹簧曲线实现流畅的切换动画
    this.getUIContext().animateTo({
      duration: 350,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        // 动画结束后重置非当前页面的状态
        for (let i = 0; i < 3; i++) {
          if (i !== toIndex) {
            this.pageOpacity[i] = 0.0;
            this.pageScale[i] = 0.95;
            this.pageTranslateX[i] = 0;
          }
        }
        this.currentTab = toIndex;
      }
    }, () => {
      // 旧页面淡出 + 缩小 + 位移
      this.pageOpacity[fromIndex] = 0.0;
      this.pageScale[fromIndex] = 0.92;
      this.pageTranslateX[fromIndex] = fromIndex < toIndex ? -40 : 40;
      
      // 新页面淡入 + 放大
      this.pageOpacity[toIndex] = 1.0;
      this.pageScale[toIndex] = 1.0;
      this.pageTranslateX[toIndex] = 0;
    });
  }

  build() {
    Stack() {
      // 使用 HdsTabs 组件实现沉浸光感和智能握持
      HdsTabs({ controller: this.hdsTabsController }) {
        TabContent() {
          TransferTab()
        }
        .tabBar('传输')
        .opacity(this.pageOpacity[0])
        .scale({ x: this.pageScale[0], y: this.pageScale[0] })
        .translate({ x: this.pageTranslateX[0] })
        
        TabContent() {
          LogTab()
        }
        .tabBar('日志')
        .opacity(this.pageOpacity[1])
        .scale({ x: this.pageScale[1], y: this.pageScale[1] })
        .translate({ x: this.pageTranslateX[1] })
        
        TabContent() {
          MineTab()
        }
        .tabBar('我的')
        .opacity(this.pageOpacity[2])
        .scale({ x: this.pageScale[2], y: this.pageScale[2] })
        .translate({ x: this.pageTranslateX[2] })
      }
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barFloatingStyle({
        // 智能握持：根据握持手自动调整导航栏位置
        adaptToHandedness: true,
        // 页签底部间距
        barBottomMargin: 28,
        // 沉浸光感效果
        systemMaterialEffect: {
          materialType: this.customMaterialType,
          materialLevel: this.customMaterialLevel
        }
      })
      .animationDuration(350) // 设置动画时长
      .onChange((index: number) => {
        this.handleTabChange(index);
      })

      // 发送预览弹窗（选好文件后弹出）
      if (this.pendingFiles.length > 0) {
        PreviewOverlay()
      }
      // 传输进度弹窗
      if (this.progress.show) {
        ProgressOverlay()
      }
      // 接收确认弹窗（最顶层）
      if (this.incoming != null) {
        IncomingOverlay({ req: this.incoming as IncomingRequest })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F3F4F6')
  }
}

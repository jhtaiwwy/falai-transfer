import { UIAbility, AbilityConstant, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppEnv } from '../core/AppEnv';
import { Protocol } from '../core/Protocol';
import { initAppStorage } from '../transfer/TransferModels';
import { transferManager } from '../transfer/TransferManager';
import { discoveryService } from '../discovery/DiscoveryService';
import { logRepository } from '../data/LogRepository';

/** 应用入口：启动日志、传输服务（TCP 47801 起）、UDP 发现（47800） */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppEnv.init(this.context);
    initAppStorage();
    logRepository.init();
    transferManager.init(this.context);
    transferManager.start();
    // 广播里携带设备名与服务端实际端口（47801 起自动后移，方案.md §4.1）
    discoveryService.start(
      () => transferManager.deviceName,
      () => transferManager.serverPort > 0 ? transferManager.serverPort : Protocol.TRANSFER_PORT
    );
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error(`[falai] loadContent 失败: ${err.code} ${err.message}`);
      }
    });
    // 接收图片/视频落相册需要 WRITE_IMAGEVIDEO（user_grant，module.json5 仅声明不够，
    // 必须运行时申请，否则 createAsset 报 Permission denied）
    this.requestMediaPermission();
  }

  private requestMediaPermission(): void {
    const atManager = abilityAccessCtrl.createAtManager();
    const permissions: Permissions[] = ['ohos.permission.WRITE_IMAGEVIDEO'];
    atManager.requestPermissionsFromUser(this.context, permissions).then((result) => {
      if (result.authResults[0] !== 0) {
        console.warn('[falai] WRITE_IMAGEVIDEO 未授权，接收图片/视频时将保存失败');
      }
    }).catch((err: BusinessError) => {
      console.error(`[falai] 申请权限失败: ${err.code} ${err.message}`);
    });
  }

  onDestroy(): void {
    discoveryService.stop();
    transferManager.stop();
  }
}

import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 全局运行环境：EntryAbility.onCreate 时注入 context，
 * 各服务模块（日志、文件、传输）通过这里拿沙箱目录，避免层层透传。
 */
export class AppEnv {
  private static appContext: common.Context | null = null;

  static init(context: common.Context): void {
    AppEnv.appContext = context;
  }

  static context(): common.Context {
    return AppEnv.appContext as common.Context;
  }

  static cacheDir(): string {
    return AppEnv.context().cacheDir;
  }

  static filesDir(): string {
    return AppEnv.context().filesDir;
  }

  /** 断点续传会话临时目录：cacheDir/incoming（方案.md §4.2） */
  static incomingDir(): string {
    return `${AppEnv.cacheDir()}/incoming`;
  }

  /** 系统默认设备名（用户可在「我的」页修改，存 preferences） */
  static defaultDeviceName(): string {
    try {
      const name = deviceInfo.marketName;
      if (name != null && name.length > 0) {
        return name;
      }
    } catch (e) {
      console.error(`[falai] 读取设备名失败: ${e}`);
    }
    return 'HarmonyOS 设备';
  }
}

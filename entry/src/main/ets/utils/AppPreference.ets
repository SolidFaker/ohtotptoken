import { PreferenceManager } from "./PreferenceManager";
import { AppStorageV2 } from "@kit.ArkUI";

export type SettingValue = boolean | string | number | SettingColorMode;
export enum SettingColorMode {
  System,
  Dark,
  Light,
}

@ObservedV2
export class TokenPreference {
  @Trace app_safety_hide_token_enable = false;
  @Trace app_appearance_show_next_token_enable = false;
  @Trace app_appearance_swap_host_user_enable = false;
  @Trace app_appearance_item_height = 60;
  @Trace app_appearance_item_space = 10;
  @Trace app_appearance_logo_size = 40;
  @Trace app_appearance_logo_background = false;
  @Trace app_appearance_logo_background_size = 45;
  @Trace app_appearance_logo_background_radius = 5;
  @Trace app_appearance_logo_background_color = '#ffececec';
  @Trace app_appearance_logo_dark_filter = false;
  @Trace app_appearance_logo_dark_filter_color = "#FFD6D6D6";
  @Trace app_appearance_token_color = "#FF012EE0";
  @Trace app_appearance_token_counter_light_color_start = "#FF86c1ff";
  @Trace app_appearance_token_counter_light_color_end = "#FF254ff7";
  @Trace app_appearance_token_counter_dark_color_start = "#FF86c1ff";
  @Trace app_appearance_token_counter_dark_color_end = "#FF254ff7";
  @Trace app_appearance_token_counter_next_color_enable = false;
  @Trace app_appearance_token_counter_next_margin = 5;
  @Trace app_appearance_token_counter_next_light_color_start = "#FFF18585";
  @Trace app_appearance_token_counter_next_light_color_end = "#FFD71616";
  @Trace app_appearance_token_counter_next_dark_color_start = "#FFF18585";
  @Trace app_appearance_token_counter_next_dark_color_end = "#FFD71616";
  @Trace app_appearance_token_font_weight = 400;
  @Trace app_appearance_token_font_size = 30;
  @Trace app_appearance_issuer_font_size = 18;
  @Trace app_appearance_issuer_font_weight = 400;
  @Trace app_appearance_user_name_font_size = 10;
  @Trace app_appearance_user_name_font_weight = 400;
  @Trace app_appearance_item_max_width = 800;
}

export class AppPreference {
  private static prefMgr = PreferenceManager.getInstance();

  private static settings_default: Map<string, SettingValue> = new Map<string, SettingValue>([
    // 安全性-隐私模式设置
    ['app_safety_privacy_enable', false],
    // 安全性-应用锁定设置
    ['app_safety_lock_enable', false],
    // 安全性-隐藏令牌
    ['app_safety_hide_token_enable', false],
    // 安全性-自动解锁
    ['app_safety_auto_unlock_enable', false],
    // 安全性-后台模糊
    ['app_safety_background_blur_enable', false],
    // 外观-显示下一个令牌
    ['app_appearance_show_next_token_enable', false],
    // 外观-颜色模式
    ['app_appearance_color_mode', SettingColorMode.System],
    // 外观-图标包
    ['app_appearance_icon_pack_selected', 0],
    // 数据库是否启用云同步
    ['app_db_rds_cloud_sync_enable', false],
    // 数据库是否启用跨设备流转
    ['app_db_rds_sync_enable', false],
    // kv数据库同步时间
    ['app_db_kv_sync_time', ''],
    // kv数据库存档时间
    ['app_db_kv_archive_time', ''],
    // kv数据库存档正在进行
    ['app_db_kv_archive_is_running',false],
    // 是否显示引导提示
    ['app_show_guide_tips', true],
    // 是否处于debug模式
    ['app_debug_mode_on', false],
    // 是否使用主密码增强安全
    ['app_use_master_key', false],
    // 是否已经配置了朱密码
    ['app_use_master_key_set', false]
  ]);

  private static appearance_default: Map<string, SettingValue> = new Map<string, SettingValue>([
    // 外观-自定义
    ['app_appearance_swap_host_user_enable', false],
    ['app_appearance_logo_background', false],
    ['app_appearance_item_height', 60],
    ['app_appearance_item_space', 10],
    ['app_appearance_logo_size', 40],
    ['app_appearance_logo_background_size', 45],
    ['app_appearance_logo_background_radius', 5],
    ['app_appearance_logo_background_color', '#ffececec'],
    ['app_appearance_logo_dark_filter', false],
    ['app_appearance_logo_dark_filter_color', "#FFD6D6D6"],
    ['app_appearance_token_color', "#FF012EE0"],
    ['app_appearance_token_counter_light_color_start', "#FF86c1ff"],
    ['app_appearance_token_counter_light_color_end', "#FF254ff7"],
    ['app_appearance_token_counter_dark_color_start', "#FF86c1ff"],
    ['app_appearance_token_counter_dark_color_end', "#FF254ff7"],
    ['app_appearance_token_counter_next_color_enable', false],
    ['app_appearance_token_counter_next_margin', 5],
    ['app_appearance_token_counter_next_light_color_start', "#FFF18585"],
    ['app_appearance_token_counter_next_light_color_end', "#FFD71616"],
    ['app_appearance_token_counter_next_dark_color_start', "#FFF18585"],
    ['app_appearance_token_counter_next_dark_color_end', "#FFD71616"],
    ['app_appearance_token_font_weight', 400],
    ['app_appearance_token_font_size', 30],
    ['app_appearance_issuer_font_size', 18],
    ['app_appearance_issuer_font_weight', 400],
    ['app_appearance_user_name_font_size', 10],
    ['app_appearance_user_name_font_weight', 400],
    ['app_appearance_item_max_width', 800]
  ]);

  private static settings: Map<string, SettingValue> = new Map<string, SettingValue>([
    ...Array.from(AppPreference.settings_default.entries()),
    ...Array.from(AppPreference.appearance_default.entries())
  ]);

  public static getPreference(key: string): SettingValue {
    return AppPreference.settings.get(key) ?? '';
  }

  public static setPreference(key: string, value: SettingValue): void {
    AppPreference.settings.set(key, value);
    AppPreference.prefMgr.setValue<SettingValue>(key, value);
  }

  public static async loadSettings(): Promise<void> {
    const promises = Array.from(AppPreference.settings.keys()).map(async (k) => {
      await AppPreference.prefMgr.getValue<SettingValue>(k).then((val) => {
        if (val !== undefined && val !== null) {
          AppPreference.settings.set(k, val);
        }
      })
    });
    await Promise.all(promises);
    AppPreference.loadTokenAppearance();
  }

  private static loadTokenAppearance(): void {
    let token_appearance: TokenPreference = AppStorageV2.connect(TokenPreference, () => new TokenPreference())!;
    token_appearance.app_safety_hide_token_enable = AppPreference.getPreference('app_safety_hide_token_enable') as boolean;
    token_appearance.app_appearance_show_next_token_enable = AppPreference.getPreference('app_appearance_show_next_token_enable') as boolean;
    token_appearance.app_appearance_swap_host_user_enable = AppPreference.getPreference('app_appearance_swap_host_user_enable') as boolean;
    token_appearance.app_appearance_logo_background = AppPreference.getPreference('app_appearance_logo_background') as boolean;
    token_appearance.app_appearance_item_height = AppPreference.getPreference('app_appearance_item_height') as number;
    token_appearance.app_appearance_item_space = AppPreference.getPreference('app_appearance_item_space') as number;
    token_appearance.app_appearance_logo_size = AppPreference.getPreference('app_appearance_logo_size') as number;
    token_appearance.app_appearance_logo_background_size = AppPreference.getPreference('app_appearance_logo_background_size') as number;
    token_appearance.app_appearance_logo_background_radius = AppPreference.getPreference('app_appearance_logo_background_radius') as number;
    token_appearance.app_appearance_logo_background_color = AppPreference.getPreference('app_appearance_logo_background_color') as string;
    token_appearance.app_appearance_logo_dark_filter = AppPreference.getPreference('app_appearance_logo_dark_filter') as boolean;
    token_appearance.app_appearance_logo_dark_filter_color = AppPreference.getPreference('app_appearance_logo_dark_filter_color') as string;
    token_appearance.app_appearance_token_color = AppPreference.getPreference('app_appearance_token_color') as string;
    token_appearance.app_appearance_token_counter_light_color_start = AppPreference.getPreference('app_appearance_token_counter_light_color_start') as string;
    token_appearance.app_appearance_token_counter_light_color_end = AppPreference.getPreference('app_appearance_token_counter_light_color_end') as string;
    token_appearance.app_appearance_token_counter_dark_color_start = AppPreference.getPreference('app_appearance_token_counter_dark_color_start') as string;
    token_appearance.app_appearance_token_counter_dark_color_end = AppPreference.getPreference('app_appearance_token_counter_dark_color_end') as string;
    token_appearance.app_appearance_token_counter_next_color_enable = AppPreference.getPreference('app_appearance_token_counter_next_color_enable') as boolean;
    token_appearance.app_appearance_token_counter_next_margin = AppPreference.getPreference('app_appearance_token_counter_next_margin') as number;
    token_appearance.app_appearance_token_counter_next_light_color_start = AppPreference.getPreference('app_appearance_token_counter_next_light_color_start') as string;
    token_appearance.app_appearance_token_counter_next_light_color_end = AppPreference.getPreference('app_appearance_token_counter_next_light_color_end') as string;
    token_appearance.app_appearance_token_counter_next_dark_color_start = AppPreference.getPreference('app_appearance_token_counter_next_dark_color_start') as string;
    token_appearance.app_appearance_token_counter_next_dark_color_end = AppPreference.getPreference('app_appearance_token_counter_next_dark_color_end') as string;
    token_appearance.app_appearance_token_font_weight = AppPreference.getPreference('app_appearance_token_font_weight') as FontWeight;
    token_appearance.app_appearance_token_font_size = AppPreference.getPreference('app_appearance_token_font_size') as number;
    token_appearance.app_appearance_issuer_font_size = AppPreference.getPreference('app_appearance_issuer_font_size') as number;
    token_appearance.app_appearance_issuer_font_weight = AppPreference.getPreference('app_appearance_issuer_font_weight') as FontWeight;
    token_appearance.app_appearance_user_name_font_size = AppPreference.getPreference('app_appearance_user_name_font_size') as number;
    token_appearance.app_appearance_user_name_font_weight = AppPreference.getPreference('app_appearance_user_name_font_weight') as FontWeight;
    token_appearance.app_appearance_item_max_width = AppPreference.getPreference('app_appearance_item_max_width') as number;
  }

  public static resetAppearanceToDefault(): void {
    for (const entry of AppPreference.appearance_default) {
      AppPreference.setPreference(entry[0], entry[1]);
    }
    AppPreference.loadTokenAppearance();
  }

  public static saveSettings(): void {
    AppPreference.prefMgr.saveUserData();
  }

  private constructor() {
  }
}
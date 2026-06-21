import { PreferenceManager } from "./PreferenceManager";
import { AppStorageV2 } from "@kit.ArkUI";
import { ScrollEffectType } from "@kit.UIDesignKit";

/**
 * 事件名称常量
 */
export const BUILTIN_DEFAULT_PACK_ID = '__builtin_default_pack__';

export enum EVENT_NAMES {
  /** 顶部模糊效果类型变更事件 */
  TOP_EFFECT_TYPE_CHANGED = 'onTopEffectTypeChanged',
  /** Token变更事件 */
  TOKEN_CHANGED = 'onTokenChanged',
  /** 单条Token更新事件（精准刷新，携带 TokenConfig） */
  TOKEN_SINGLE_UPDATED = 'onTokenSingleUpdated',
  /** 时间戳变更事件 */
  TIMESTAMP_CHANGED = 'onTimestampChanged',
  /** 文件拖放事件 */
  FILE_DROP = 'onFileDrop',
  /** 图标包变更事件 */
  ICON_PACK_CHANGED = 'onIconPackChanged',
  /** KV数据库同步完成事件 */
  KV_STORE_SYNC_COMPLETE = 'KVStoreSyncComplete',
  /** RDB数据库同步完成事件 */
  RDB_STORE_SYNC_COMPLETE = 'RDBStoreSyncComplete',
  /** 数据同步权限更新事件 */
  DATASYNC_PERMISSIONS_UPDATE = 'DATASYNCPermissionsUpdate',
  /** 开始快速扫描事件 */
  START_QUICK_SCAN = 'startQuickScan',
  /** 卡片配置事件 */
  START_CARD_CONFIG = 'onStartCardConfig',
  /** 切换Token搜索事件 */
  TOGGLE_TOKEN_SEARCH = 'toggleTokenSearch',
  /** 握手偏好设置变更事件 */
  HOLDING_HAND_PREFERENCE_CHANGED = 'holdingHandPreferenceChanged',
  /** 启动Token排序页面事件 */
  START_TOKEN_SORT = 'onStartTokenSort',
}

/**
 * 偏好设置键名常量
 * 统一管理所有AppPreference.getPreference和setPreference使用的键名
 */
export enum PREF_KEYS {
  /** 调试模式开关 */
  DEBUG_MODE_ON = 'app_debug_mode_on',
  /** 交换主机和用户显示 */
  APPEARANCE_SWAP_HOST_USER_ENABLE = 'app_appearance_swap_host_user_enable',
  /** 启用图标背景 */
  APPEARANCE_LOGO_BACKGROUND = 'app_appearance_logo_background',
  /** 启用深色图标滤镜 */
  APPEARANCE_LOGO_DARK_FILTER = 'app_appearance_logo_dark_filter',
  /** 安全锁定开关 */
  SAFETY_LOCK_ENABLE = 'app_safety_lock_enable',
  /** 颜色模式 */
  APPEARANCE_COLOR_MODE = 'app_appearance_color_mode',
  /** 隐私模式开关 */
  SAFETY_PRIVACY_ENABLE = 'app_safety_privacy_enable',
  /** 自动解锁开关 */
  SAFETY_AUTO_UNLOCK_ENABLE = 'app_safety_auto_unlock_enable',
  /** 顶部模糊效果类型 */
  APPEARANCE_TOP_EFFECT_TYPE = 'app_appearance_top_effect_type',
  /** 背景模糊开关 */
  SAFETY_BACKGROUND_BLUR_ENABLE = 'app_safety_background_blur_enable',
  /** 快速扫描开关 */
  WANT_QUICK_SCAN = 'app_want_quick_scan',
  WANT_CARD_CONFIG = 'app_want_card_config',
  /** RDB数据库同步开关 */
  DB_RDS_SYNC_ENABLE = 'app_db_rds_sync_enable',
  /** RDB云端同步开关 */
  DB_RDS_CLOUD_SYNC_ENABLE = 'app_db_rds_cloud_sync_enable',
  /** 云端同步最后时间 */
  CLOUD_SYNC_LAST_TIME = 'app_cloud_sync_last_time',
  /** KV数据库同步时间 */
  DB_KV_SYNC_TIME = 'app_db_kv_sync_time',
  /** 选中的图标包（已废弃，仅用于迁移） */
  APPEARANCE_ICON_PACK_SELECTED = 'app_appearance_icon_pack_selected',
  /** 已启用的图标包列表（JSON 数组） */
  APPEARANCE_ICON_PACK_ENABLED = 'app_appearance_icon_pack_enabled',
  /** 隐藏Token开关 */
  SAFETY_HIDE_TOKEN_ENABLE = 'app_safety_hide_token_enable',
  /** 防窥保护开关 */
  SAFETY_DLP_ANTI_PEEP_ENABLE = 'app_safety_dlp_anti_peep_enable',
  /** 显示下一个Token开关 */
  APPEARANCE_SHOW_NEXT_TOKEN_ENABLE = 'app_appearance_show_next_token_enable',
  /** 握手感知开关 */
  APPEARANCE_HOLDING_HAND_ENABLE = 'app_appearance_holding_hand_enable',
  /** 显示引导提示开关 */
  SHOW_GUIDE_TIPS = 'app_show_guide_tips',
  /** Token项目高度 */
  APPEARANCE_ITEM_HEIGHT = 'app_appearance_item_height',
  /** Token项目间距 */
  APPEARANCE_ITEM_SPACE = 'app_appearance_item_space',
  /** Logo大小 */
  APPEARANCE_LOGO_SIZE = 'app_appearance_logo_size',
  /** Logo背景大小 */
  APPEARANCE_LOGO_BACKGROUND_SIZE = 'app_appearance_logo_background_size',
  /** Logo背景圆角 */
  APPEARANCE_LOGO_BACKGROUND_RADIUS = 'app_appearance_logo_background_radius',
  /** Logo背景颜色 */
  APPEARANCE_LOGO_BACKGROUND_COLOR = 'app_appearance_logo_background_color',
  /** Logo深色滤镜颜色 */
  APPEARANCE_LOGO_DARK_FILTER_COLOR = 'app_appearance_logo_dark_filter_color',
  /** Token颜色 */
  APPEARANCE_TOKEN_COLOR = 'app_appearance_token_color',
  /** 下一个Token颜色 */
  APPEARANCE_TOKEN_NEXT_COLOR = 'app_appearance_token_next_color',
  /** 深色模式Token颜色 */
  APPEARANCE_TOKEN_COLOR_DARK = 'app_appearance_token_color_dark',
  /** 深色模式下一个Token颜色 */
  APPEARANCE_TOKEN_NEXT_COLOR_DARK = 'app_appearance_token_next_color_dark',
  /** 浅色模式倒计时渐变起始颜色 */
  APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_START = 'app_appearance_token_counter_light_color_start',
  /** 浅色模式倒计时渐变结束颜色 */
  APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_END = 'app_appearance_token_counter_light_color_end',
  /** 深色模式倒计时渐变起始颜色 */
  APPEARANCE_TOKEN_COUNTER_DARK_COLOR_START = 'app_appearance_token_counter_dark_color_start',
  /** 深色模式倒计时渐变结束颜色 */
  APPEARANCE_TOKEN_COUNTER_DARK_COLOR_END = 'app_appearance_token_counter_dark_color_end',
  /** 下一个Token倒计时颜色开关 */
  APPEARANCE_TOKEN_COUNTER_NEXT_COLOR_ENABLE = 'app_appearance_token_counter_next_color_enable',
  /** 下一个Token倒计时边距 */
  APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN = 'app_appearance_token_counter_next_margin',
  /** 下一个Token浅色模式倒计时渐变起始颜色 */
  APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_START = 'app_appearance_token_counter_next_light_color_start',
  /** 下一个Token浅色模式倒计时渐变结束颜色 */
  APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_END = 'app_appearance_token_counter_next_light_color_end',
  /** 下一个Token深色模式倒计时渐变起始颜色 */
  APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_START = 'app_appearance_token_counter_next_dark_color_start',
  /** 下一个Token深色模式倒计时渐变结束颜色 */
  APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_END = 'app_appearance_token_counter_next_dark_color_end',
  /** Token字体粗细 */
  APPEARANCE_TOKEN_FONT_WEIGHT = 'app_appearance_token_font_weight',
  /** Token字体大小 */
  APPEARANCE_TOKEN_FONT_SIZE = 'app_appearance_token_font_size',
  /** 发行者字体大小 */
  APPEARANCE_ISSUER_FONT_SIZE = 'app_appearance_issuer_font_size',
  /** 发行者字体粗细 */
  APPEARANCE_ISSUER_FONT_WEIGHT = 'app_appearance_issuer_font_weight',
  /** 用户名字体大小 */
  APPEARANCE_USER_NAME_FONT_SIZE = 'app_appearance_user_name_font_size',
  /** 用户名字体粗细 */
  APPEARANCE_USER_NAME_FONT_WEIGHT = 'app_appearance_user_name_font_weight',
  /** Token项目最大宽度 */
  APPEARANCE_ITEM_MAX_WIDTH = 'app_appearance_item_max_width',
  /** Token列表项目左内边距（prefix） */
  APPEARANCE_TOKEN_LIST_ITEM_PREFIX_PADDING = 'app_appearance_token_list_item_prefix_padding',
  /** Token列表项目右内边距（suffix） */
  APPEARANCE_TOKEN_LIST_ITEM_SUFFIX_PADDING = 'app_appearance_token_list_item_suffix_padding',
  /** 外观列表链式动画开关 */
  APPEARANCE_CHAIN_ANIMATION_ENABLE = 'app_appearance_chain_animation_enable',
  /** 长按菜单触发时长（ms），范围 200-1000 */
  APPEARANCE_LONG_PRESS_DURATION = 'app_appearance_long_press_duration',
  /** 快速扫描URI */
  WANT_URI = 'app_want_uri',
  /** 是否启用华为云备份 */
  APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE="app_huawei_cloud_sync_enable",
  /** 主密码功能弃用告知已确认（一次性迁移标记） */
  MASTER_KEY_DEPRECATION_ACKNOWLEDGED = 'app_master_key_deprecation_acknowledged',
  /** ASSET Secret 迁移已完成（持久化标记，避免每次加载重复迁移） */
  ASSET_MIGRATION_DONE = 'app_asset_migration_done',
  /** 图标包云备份最后同步时间 */
  ICON_PACK_CLOUD_SYNC_TIME = 'app_icon_pack_cloud_sync_time',
}

/** 主密码旧偏好键名（已废弃，仅用于兼容性检测与清理） */
const DEPRECATED_MASTER_KEY_PREFS: string[] = [
  'app_use_master_key',
  'app_use_master_key_set',
  'app_master_key_migrated',
];

/**
 * 设置值的联合类型
 */
export type SettingValue = boolean | string | number | SettingColorMode;

/**
 * 颜色模式枚举
 */
export enum SettingColorMode {
  /** 跟随系统 */
  System,
  /** 深色模式 */
  Dark,
  /** 浅色模式 */
  Light,
}

/**
 * 顶部模糊效果类型枚举
 */
export enum SettingTopEffectType {
  /** 关闭模糊效果 */
  DISABLE,
  /** 通用模糊 */
  COMMON_BLUR,
  /** 过渡模糊 */
  GRADUAL_BLUR,
  /** 渐变模糊 */
  GRADIENT_BLUR,
  /** 沉浸式渐变模糊（需要API23支持） */
  IMMERSIVE_GRADIENT_BLUR
}

/**
 * 枚举选择选项接口
 * 用于SubItemEnumSelect组件，将UI显示文本与枚举值进行映射
 */
export interface EnumSelectOption {
  /** 显示文本，支持字符串或资源引用 */
  label: string | Resource;
  /** 对应的枚举值（number类型） */
  value: number;
}

/**
 * 当前支持的顶部模糊类型选项数组
 *
 * @example
 * 当API23支持后，可添加沉浸式渐变模糊选项
 */
export const AVAILABLE_TOP_EFFECT_TYPES: EnumSelectOption[] = [
  { label: $r('app.string.setting_top_effect_type_common_blur'), value: SettingTopEffectType.COMMON_BLUR },
  { label: $r('app.string.setting_top_effect_type_gradual_blur'), value: SettingTopEffectType.GRADUAL_BLUR },
  { label: $r('app.string.setting_top_effect_type_gradient_blur'), value: SettingTopEffectType.GRADIENT_BLUR },
  { label: $r('app.string.setting_top_effect_type_immersive_gradient_blur'), value: SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR },
];

/**
 * 底部Tabs类型枚举
 */
export enum SettingBottomTabsType {
  /** 平铺模式 */
  FLATTEN,
  /** 悬浮模式 */
  SUSPENSION,
}

/**
 * 当前支持的底部Tabs类型选项数组
 */
export const AVAILABLE_BOTTOM_TABS_TYPES: EnumSelectOption[] = [
  { label: $r('app.string.setting_bottom_tabs_type_flatten'), value: SettingBottomTabsType.FLATTEN },
  { label: $r('app.string.setting_bottom_tabs_type_suspension'), value: SettingBottomTabsType.SUSPENSION },
];

/**
 * 顶部效果类型到滚动效果类型的映射
 * 将SettingTopEffectType映射到ScrollEffectType
 */
export const SCROLL_EFFECT_TYPE_MAP: Map<SettingTopEffectType, ScrollEffectType> = new Map([
  [SettingTopEffectType.COMMON_BLUR, ScrollEffectType.COMMON_BLUR],
  [SettingTopEffectType.GRADUAL_BLUR, ScrollEffectType.GRADUAL_BLUR],
  [SettingTopEffectType.GRADIENT_BLUR, ScrollEffectType.GRADIENT_BLUR],
  [SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR, ScrollEffectType.IMMERSIVE_GRADIENT_BLUR],
]);

/**
 * Token外观配置类
 * 用于存储和管理令牌的外观相关设置
 */
@ObservedV2
export class TokenPreference {
  @Trace app_safety_hide_token_enable = false;
  @Trace app_safety_dlp_anti_peep_enable = false;
  @Trace app_appearance_show_next_token_enable = false;
  @Trace app_appearance_holding_hand_enable = false;
  @Trace app_appearance_swap_host_user_enable = false;
  @Trace app_appearance_item_height = 60;
  @Trace app_appearance_item_space = 10;
  @Trace app_appearance_logo_size = 40;
  @Trace app_appearance_logo_background = false;
  @Trace app_appearance_logo_background_size = 45;
  @Trace app_appearance_logo_background_radius = 5;
  @Trace app_appearance_logo_background_color = 0xffececec;
  @Trace app_appearance_logo_dark_filter = false;
  @Trace app_appearance_logo_dark_filter_color = 0xFFD6D6D6;
  @Trace app_appearance_token_color = 0xFF012EE0;
  @Trace app_appearance_token_color_dark = 0xFF638FF6;
  @Trace app_appearance_token_next_color = 0xFFD71616;
  @Trace app_appearance_token_next_color_dark = 0xFFD71616;
  @Trace app_appearance_token_counter_light_color_start = 0xFF86c1ff;
  @Trace app_appearance_token_counter_light_color_end = 0xFF254ff7;
  @Trace app_appearance_token_counter_dark_color_start = 0xFF86c1ff;
  @Trace app_appearance_token_counter_dark_color_end = 0xFF254ff7;
  @Trace app_appearance_token_counter_next_color_enable = false;
  @Trace app_appearance_token_counter_next_margin = 5;
  @Trace app_appearance_token_counter_next_light_color_start = 0xFFF18585;
  @Trace app_appearance_token_counter_next_light_color_end = 0xFFD71616;
  @Trace app_appearance_token_counter_next_dark_color_start = 0xFFF18585;
  @Trace app_appearance_token_counter_next_dark_color_end = 0xFFD71616;
  @Trace app_appearance_token_font_weight = 400;
  @Trace app_appearance_token_font_size = 30;
  @Trace app_appearance_issuer_font_size = 18;
  @Trace app_appearance_issuer_font_weight = 400;
  @Trace app_appearance_user_name_font_size = 10;
  @Trace app_appearance_user_name_font_weight = 400;
  @Trace app_appearance_item_max_width = 800;
  @Trace app_appearance_token_list_item_prefix_padding = 10;
  @Trace app_appearance_token_list_item_suffix_padding = 10;
  @Trace app_appearance_chain_animation_enable = true;
  @Trace app_appearance_long_press_duration = 300;
}

/**
 * 路由名称常量
 * 统一管理所有pushPathByName使用的路由名称
 */
export enum ROUTE_NAMES {
  /** 外观自定义页面 */
  AppearancePage = 'AppearancePage',
  /** 数据同步详情页面 */
  ShowDataSyncDetailsPage = 'ShowDataSyncDetailsPage',
  /** 华为云同步详情页面 */
  ShowCloudSyncDetailsPage = 'ShowCloudSyncDetailsPage',
  /** 云端备份历史页面 */
  ShowCloudBackupHistoryPage = 'ShowCloudBackupHistoryPage',
  /** 展示验证码页面 */
  ShowCodePage = 'ShowCodePage',
  /** 通用Web页面 */
  WebPage = 'WebPage',
  /** 卡片令牌配置页面 */
  TokenCardConfigPage = 'TokenCardConfigPage',
  /** Token排序页面 */
  TokenSortPage = 'TokenSortPage',
  /** Token搜索页面 */
  TokenSearchPage = 'TokenSearchPage',
  /** App首页 */
  IndexPage = 'pages/Index',
}

/**
 * 外部链接常量
 * 统一管理所有外部跳转URL
 */
export enum EXTERNAL_URLS {
  /** 问卷反馈 */
  FEEDBACK_SURVEY = 'https://wj.qq.com/s2/24518107/2b26/',
  /** GitHub反馈 */
  FEEDBACK_GITHUB = 'https://github.com/OHOTP/ohtotptoken/issues',
}

/**
 * 应用偏好设置管理类
 * 提供应用设置的读取、写入和持久化功能
 */
export class AppPreference {
  /** 偏好设置管理器实例 */
  private static prefMgr = PreferenceManager.getInstance();
  private static settings_default: Map<string, SettingValue> = new Map<string, SettingValue>([
    // 安全性-隐私模式设置
    [PREF_KEYS.SAFETY_PRIVACY_ENABLE, false],
    // 安全性-应用锁定设置
    [PREF_KEYS.SAFETY_LOCK_ENABLE, false],
    // 安全性-隐藏令牌
    [PREF_KEYS.SAFETY_HIDE_TOKEN_ENABLE, false],
    // 安全性-防窥保护
    [PREF_KEYS.SAFETY_DLP_ANTI_PEEP_ENABLE, false],
    // 安全性-自动解锁
    [PREF_KEYS.SAFETY_AUTO_UNLOCK_ENABLE, false],
    // 安全性-后台模糊
    [PREF_KEYS.SAFETY_BACKGROUND_BLUR_ENABLE, false],
    // 外观-显示下一个令牌
    [PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE, false],
    // 外观-颜色模式
    [PREF_KEYS.APPEARANCE_COLOR_MODE, SettingColorMode.System],
    // 外观-图标包
    [PREF_KEYS.APPEARANCE_ICON_PACK_SELECTED, 0],
    // 数据库是否启用云同步
    [PREF_KEYS.DB_RDS_CLOUD_SYNC_ENABLE, false],
    // 云端同步最后时间
    [PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0'],
    // 数据库是否启用跨设备流转
    [PREF_KEYS.DB_RDS_SYNC_ENABLE, false],
    // kv数据库同步时间
    [PREF_KEYS.DB_KV_SYNC_TIME, ''],
    [PREF_KEYS.SHOW_GUIDE_TIPS, true],
    // 主密码弃用告知已确认
    [PREF_KEYS.MASTER_KEY_DEPRECATION_ACKNOWLEDGED, false],
    // ASSET Secret 迁移已完成
    [PREF_KEYS.ASSET_MIGRATION_DONE, false],
    // 是否处于debug模式
    [PREF_KEYS.DEBUG_MODE_ON, false],
    // 快速扫描URI
    [PREF_KEYS.WANT_URI, ''],
  ]);
  private static appearance_default: Map<string, SettingValue> = new Map<string, SettingValue>([
    // 外观-自定义
    [PREF_KEYS.APPEARANCE_SWAP_HOST_USER_ENABLE, false],
    [PREF_KEYS.APPEARANCE_LOGO_BACKGROUND, false],
    [PREF_KEYS.APPEARANCE_ITEM_HEIGHT, 60],
    [PREF_KEYS.APPEARANCE_ITEM_SPACE, 10],
    [PREF_KEYS.APPEARANCE_LOGO_SIZE, 40],
    [PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_SIZE, 45],
    [PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_RADIUS, 5],
    [PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_COLOR, 0xffececec],
    [PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER, false],
    [PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER_COLOR, 0xFFD6D6D6],
    [PREF_KEYS.APPEARANCE_TOKEN_COLOR, 0xFF254ff7],
    [PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR, 0xFFD71616],
    [PREF_KEYS.APPEARANCE_TOKEN_COLOR_DARK, 0xFF638FF6],
    [PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR_DARK, 0xFFD71616],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_START, 0xFF86c1ff],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_END, 0xFF254ff7],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_START, 0xFF86c1ff],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_END, 0xFF254ff7],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_COLOR_ENABLE, false],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN, 5],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_START, 0xFFF18585],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_END, 0xFFD71616],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_START, 0xFFF18585],
    [PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_END, 0xFFD71616],
    [PREF_KEYS.APPEARANCE_TOKEN_FONT_WEIGHT, 400],
    [PREF_KEYS.APPEARANCE_TOKEN_FONT_SIZE, 30],
    [PREF_KEYS.APPEARANCE_ISSUER_FONT_SIZE, 18],
    [PREF_KEYS.APPEARANCE_ISSUER_FONT_WEIGHT, 400],
    [PREF_KEYS.APPEARANCE_USER_NAME_FONT_SIZE, 10],
    [PREF_KEYS.APPEARANCE_USER_NAME_FONT_WEIGHT, 400],
    [PREF_KEYS.APPEARANCE_ITEM_MAX_WIDTH, 800],
    [PREF_KEYS.APPEARANCE_TOKEN_LIST_ITEM_PREFIX_PADDING, 10],
    [PREF_KEYS.APPEARANCE_TOKEN_LIST_ITEM_SUFFIX_PADDING, 10],
    [PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE, true],
    [PREF_KEYS.APPEARANCE_LONG_PRESS_DURATION, 300],
    // 外观-顶部模糊类型
    [PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE, SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR],
    [PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false],
  ]);
  private static settings: Map<string, SettingValue> = new Map<string, SettingValue>([
    ...Array.from(AppPreference.settings_default.entries()),
    ...Array.from(AppPreference.appearance_default.entries())
  ]);

  /**
   * 获取偏好设置值
   * @param key - 设置键名
   * @returns 设置值，如果不存在则返回空字符串
   */
  public static getPreference(key: string): SettingValue {
    const cached = AppPreference.settings.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const persisted = AppPreference.prefMgr.getValueSync<SettingValue>(key);
    if (persisted !== null) {
      AppPreference.settings.set(key, persisted);
      return persisted;
    }
    return '';
  }

  /**
   * 设置偏好设置值
   * @param key - 设置键名
   * @param value - 设置值
   */
  public static setPreference(key: string, value: SettingValue): void {
    AppPreference.settings.set(key, value);
    AppPreference.prefMgr.setValue<SettingValue>(key, value);
  }

  /**
   * 从持久化存储加载所有设置
   * @returns Promise对象，表示加载操作完成
   */
   public static async loadSettings(): Promise<void> {
    await AppPreference.prefMgr.ensureInitialized();
    const allValues = AppPreference.prefMgr.getAllValues();
    for (const k of AppPreference.settings.keys()) {
      const raw = allValues[k];
      if (raw !== undefined && raw !== null && raw !== '') {
        try {
          const val: SettingValue = (typeof raw === 'string' ? JSON.parse(raw) : raw) as SettingValue;
          AppPreference.settings.set(k, val);
        } catch (_) {
        }
      }
    }
    AppPreference.loadTokenAppearance();
  }

  /**
   * 加载Token外观设置到AppStorageV2
   * 从偏好设置中读取外观相关配置并更新到TokenPreference对象
   */
  private static loadTokenAppearance(): void {
    let token_appearance: TokenPreference = AppStorageV2.connect(TokenPreference, () => new TokenPreference())!;
    token_appearance.app_safety_hide_token_enable =
      AppPreference.getPreference(PREF_KEYS.SAFETY_HIDE_TOKEN_ENABLE) as boolean;
    token_appearance.app_safety_dlp_anti_peep_enable =
      AppPreference.getPreference(PREF_KEYS.SAFETY_DLP_ANTI_PEEP_ENABLE) as boolean;
    token_appearance.app_appearance_show_next_token_enable =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE) as boolean;
    token_appearance.app_appearance_holding_hand_enable =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_HOLDING_HAND_ENABLE) as boolean;
    token_appearance.app_appearance_swap_host_user_enable =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_SWAP_HOST_USER_ENABLE) as boolean;
    token_appearance.app_appearance_logo_background =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND) as boolean;
    token_appearance.app_appearance_item_height =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_HEIGHT) as number;
    token_appearance.app_appearance_item_space = AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_SPACE) as number;
    token_appearance.app_appearance_logo_size = AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_SIZE) as number;
    token_appearance.app_appearance_logo_background_size =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_SIZE) as number;
    token_appearance.app_appearance_logo_background_radius =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_RADIUS) as number;
    token_appearance.app_appearance_logo_background_color =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_COLOR) as number;
    token_appearance.app_appearance_logo_dark_filter =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER) as boolean;
    token_appearance.app_appearance_logo_dark_filter_color =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER_COLOR) as number;
    token_appearance.app_appearance_token_color =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COLOR) as number;
    token_appearance.app_appearance_token_next_color =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR) as number;
    token_appearance.app_appearance_token_color_dark =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COLOR_DARK) as number;
    token_appearance.app_appearance_token_next_color_dark =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR_DARK) as number;
    token_appearance.app_appearance_token_counter_light_color_start =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_START) as number;
    token_appearance.app_appearance_token_counter_light_color_end =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_END) as number;
    token_appearance.app_appearance_token_counter_dark_color_start =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_START) as number;
    token_appearance.app_appearance_token_counter_dark_color_end =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_END) as number;
    token_appearance.app_appearance_token_counter_next_color_enable =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_COLOR_ENABLE) as boolean;
    token_appearance.app_appearance_token_counter_next_margin =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN) as number;
    token_appearance.app_appearance_token_counter_next_light_color_start =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_START) as number;
    token_appearance.app_appearance_token_counter_next_light_color_end =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_END) as number;
    token_appearance.app_appearance_token_counter_next_dark_color_start =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_START) as number;
    token_appearance.app_appearance_token_counter_next_dark_color_end =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_END) as number;
    token_appearance.app_appearance_token_font_weight =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_FONT_WEIGHT) as FontWeight;
    token_appearance.app_appearance_token_font_size =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_FONT_SIZE) as number;
    token_appearance.app_appearance_issuer_font_size =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_ISSUER_FONT_SIZE) as number;
    token_appearance.app_appearance_issuer_font_weight =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_ISSUER_FONT_WEIGHT) as FontWeight;
    token_appearance.app_appearance_user_name_font_size =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_USER_NAME_FONT_SIZE) as number;
    token_appearance.app_appearance_user_name_font_weight =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_USER_NAME_FONT_WEIGHT) as FontWeight;
    token_appearance.app_appearance_item_max_width =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_ITEM_MAX_WIDTH) as number;
    token_appearance.app_appearance_token_list_item_prefix_padding =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_LIST_ITEM_PREFIX_PADDING) as number;
    token_appearance.app_appearance_token_list_item_suffix_padding =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOKEN_LIST_ITEM_SUFFIX_PADDING) as number;
    token_appearance.app_appearance_chain_animation_enable =
      AppPreference.getPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE) as boolean;
    token_appearance.app_appearance_long_press_duration =
      Math.max(200, Math.min(1000, AppPreference.getPreference(PREF_KEYS.APPEARANCE_LONG_PRESS_DURATION) as number));
  }

  /**
   * 重置外观设置为默认值
   * 将所有外观相关设置恢复为默认配置
   */
  public static resetAppearanceToDefault(): void {
    for (const entry of AppPreference.appearance_default) {
      AppPreference.setPreference(entry[0], entry[1]);
    }
    AppPreference.loadTokenAppearance();
  }

  public static loadEnabledPacks(): string[] {
    const raw = AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string;
    if (raw && raw !== '') {
      try {
        const parsed = JSON.parse(raw) as string[];
        if (parsed && parsed.length > 0) {
          return parsed;
        }
      } catch (_) {}
    }
    return [BUILTIN_DEFAULT_PACK_ID];
  }

  public static hasEnabledPacksMigrated(): boolean {
    const enabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED) as string;
    return enabled !== undefined && enabled !== null && enabled !== '';
  }

  public static getLegacySelectedPack(): number {
    return Number(AppPreference.getPreference(PREF_KEYS.APPEARANCE_ICON_PACK_SELECTED)) || 0;
  }

  public static saveEnabledPacks(packs: string[]): void {
    if (packs.length === 0) {
      packs = [BUILTIN_DEFAULT_PACK_ID];
    }
    AppPreference.setPreference(PREF_KEYS.APPEARANCE_ICON_PACK_ENABLED, JSON.stringify(packs));
  }

  public static saveSettings(): void {
    AppPreference.prefMgr.saveUserData();
  }

  /**
   * 检测旧版主密码偏好是否存在（兼容性检测）
   *
   * 用户从未使用过主密码功能时，旧键不存在，返回 false；
   * 升级后旧键仍残留在磁盘偏好文件中，返回 true。
   */
  static hasDeprecatedMasterKeyPrefs(): boolean {
    for (const key of DEPRECATED_MASTER_KEY_PREFS) {
      const val = AppPreference.prefMgr.getValueSync<boolean>(key);
      if (val !== null) {
        return true;
      }
    }
    return false;
  }

  /**
   * 清理旧版主密码偏好并标记弃用告知已确认
   */
  static cleanupDeprecatedMasterKeyPrefs(): void {
    for (const key of DEPRECATED_MASTER_KEY_PREFS) {
      AppPreference.prefMgr.deleteValue(key);
    }
    AppPreference.setPreference(PREF_KEYS.MASTER_KEY_DEPRECATION_ACKNOWLEDGED, true);
  }
}
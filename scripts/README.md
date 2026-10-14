# 辅助脚本

## 统一入口（npm scripts）

```sh
npm run check          # 字符串资源 + Steam 字段号 + 全部 node 回归（离线，无需设备）
npm test               # 仅 node --test "scripts/*.test.mjs"
npm run check:strings  # 字符串资源完整性
npm run check:fields   # Steam 字段号交叉校验（仓库内快照，干净 clone 可跑）
npm run probe:steam    # 真实服务端编码探针（需网络）
npm run golden:steam   # 重新生成 Steam 黄金向量（需 protobufjs）
```

以上命令不需要 HarmonyOS SDK 或 `npm install`。图标包导入回归需要生产 `@ohos/jszip@1.0.1` 的 JS 核心：本地可复用 `ohpm install` 生成的 entry/oh_modules；干净环境可按下文下载锁文件中的 HAR，并校验 SHA-512 后提取。CI 的 `Node offline checks` 已包含依赖准备；准备需要网络，回归执行本身不连接设备或业务服务。

ArkTS 侧单测/门禁仍走 DevEco：

```sh
hvigorw test -p module=entry@default --no-daemon
```

## 图标包生产 JSZip 依赖与真机验证

干净环境仅准备 JS 核心，不安装 SDK、不执行 HAR 安装脚本，也不修改 oh_modules：

```sh
export ICON_PACK_JSZIP_LIB="$(node scripts/prepare-icon-pack-jszip.mjs)"
node --test "scripts/*.test.mjs"
```

脚本只下载 entry 锁文件钉住的公开 OHPM HAR，校验完整性后提取至系统临时目录；`ICON_PACK_JSZIP_LIB` 指向包含 lib 的根目录。不要指向来源未知的可执行 JavaScript。CI 使用 `--github-env` 将路径写入作业环境。

真机仅使用可丢弃合成夹具，禁止用综合 `OpenHarmonyTestRunner` 替代专用入口：

```sh
devecocli build --modules entry@ohosTest
# 覆盖安装当前主 HAP 和 entry-ohosTest-signed.hap，不卸载、不清应用数据。
node scripts/verify-icon-pack-publication-device.mjs --device <target> --mode cloud --action run
node scripts/verify-icon-pack-publication-device.mjs --device <target> --mode cloud --action restart --checkpoint directory
node scripts/verify-icon-pack-publication-device.mjs --device <target> --action import
```

检查点白名单为 directory、zip、metadata、commit、commit-sync、prune；串行执行，不能同时启动两个 controller。脚本只输出固定标记和测试汇总；成功必须满足正常退出、未超时、tests=pass=期望值、failure/error/ignore=0、mode 标记和 report code。import 还必须输出只读回收审计标记。`--result <new-file.json>` 可另存不含设备选择器的脱敏结果，已有文件不会覆盖。检查点后的 force-stop 只证明进程重建可见性，不代表断电或双设备同步。

receipt 指向本次精确合成目录；失败清理只能用专用 `--mode <原模式> --action cleanup`。没有合法 receipt 时不得按前缀认领或批量删除目录。真实用户数据、偏好、水位、令牌与云备份不属于夹具回收范围。完整实测及未覆盖项见 [云备份验收记录](../docs/testing/cloud-backup-diagnostics.md#17-不可变代与导入门控单机原生验收2026-10-14)。

## Steam 字段号交叉校验

```sh
node scripts/verify-steam-field-numbers.mjs
```

校验对象是本仓库 ArkTS 手写实现（`entry/src/main/ets/steam/proto/SteamMessages.ets`），
参考来源是**仓库内快照** `scripts/reference/steam-field-numbers.json`
（由官方 `.proto` + protobufjs 生成代码抽取的「字段号 + wireType」集合），
因此干净 clone 上也能运行。

可选增强：把 `STEAM_PROTO_REF` 指向参考工程的 `steamapi` 目录
（默认 `.ai/Authenticator-main/entry/src/main/ets/pages/steamapi`），
脚本会额外校验快照是否与上游一致（防止 `.proto` 更新后快照过期）：

```sh
STEAM_PROTO_REF=/path/to/steamapi node scripts/verify-steam-field-numbers.mjs
node scripts/generate-steam-field-manifest.mjs   # 需要参考工程，重新生成快照
```

## 批量令牌操作回归

运行 `node --test scripts/*.test.mjs`（或 `npm test`）。覆盖生产 TokenStore/KvManager 的分块、事务回滚、事件次数及并发顺序。
真机 Hypium 构建、执行与数据保护约定见 [TOKEN_BATCH_TESTS.md](TOKEN_BATCH_TESTS.md)。

## 材质策略回归测试

需要 Node.js ≥ 22.13.0（使用 `node:module` 的 `stripTypeScriptTypes` API）。在仓库根目录运行：

```sh
node --test scripts/material-theme.test.mjs
```

脚本加载生产 `MaterialTheme.ets`，通过 SDK mock 验证材质偏好、低 API 防护及 HDS 等级策略委托。偏好 fixture 应与 `common/src/main/ets/utils/AppPreference.ets` 的 `MaterialPreference` 默认值同步。

该脚本尚未接入 CI/钩子，不替代 Hypium LocalUnit / Quality CI，也不验证设备渲染效果。真机或模拟器上的材质开关、五档厚度、交互光感、菜单/弹窗背板与低版本降级仍需单独验证并补充截图。

## Steam 黄金向量生成

```sh
npm i --no-save protobufjs@7.4.0
node scripts/steam-golden-vectors.mjs
```

用独立实现（protobufjs + node:crypto）产出 Steam 消息字节、HMAC 签名、Steam 动态码与 RSA 密文的期望值，用于交叉验证 `entry/src/main/ets/steam/` 下的 ArkTS 手写实现。输出需要手工同步到 `entry/src/test/SteamMessages.test.ets`、`SteamCrypto.test.ets`、`SteamClient.test.ets` 的常量中；RSA 每次运行都会重新生成密钥对，必须成对更新。

实现结构与协议说明见 [docs/STEAM_AUTHENTICATOR.md](../docs/STEAM_AUTHENTICATOR.md)。

## 字符串资源完整性校验

```sh
node scripts/check-string-keys.mjs
```

扫描全部 `$r('app.string.KEY')` 引用，检查 base 是否齐全（缺失即失败，退出码 1），并报告各语言缺失情况（缺失会回退到 base）。同时打印 `steam_*` 键在四种语言中的覆盖情况。

## Steam 实时探针（需网络）

```sh
node scripts/steam-live-probe.mjs
```

加载真实生产 ArkTS 源码（仅替换网络层），用不存在的假账号向 Steam 发一次失败登录，验证手写 protobuf 编码 + RSA 加密 + 表单编码能被真实服务端接受，并用「损坏载荷」做反向对照。需要 Node ≥ 22.13.0 且能访问 `api.steampowered.com`；请勿高频运行。





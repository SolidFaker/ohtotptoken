# 本地备份交互与宿主材质验收

## 基线与范围

- 实施基线：2026-10-11，`fix/cloud-cache-completion` / `fac0af6`。
- 只变更本地编排、专用 I/O、两个云页面的背景及相关 UI；不改云服务、TokenStore 双写/迁移、密码协议、URI 编解码、版本和签名。
- `.zcodeignore`、未跟踪原生目录、`build-profile.json5`（skip-worktree）保持不动。其他 OpenSpec 变更未完成项不在此补签。
- 所有夹具均为合成数据。没有读取正式备份、安装覆盖正式应用、清理或恢复真实云记录。

## SDK 契约核验

当前 bundled SDK compile 26.0.0，兼容 API 20。官方 CLI 文档检索并交叉检查 SDK 声明：

- `@ohos.file.fs.d.ts`：open 支持 URI（2491）；read 返回实际字节数（2664）；write 返回实际字节数（3557），offset 为文件指针偏移而非源缓冲偏移（5738–5758）。close 返回 Promise（381），空间/配额不足也可在关闭时报错。
- 专用 I/O 不传 offset；从有效字节视图裁剪源缓冲、循环补短写。读取到 EOF 后统一 UTF-8 解码，finally 等待 close。没有 unlink、读回权限、rename 或云端 staging 假设。
- `@ohos.file.picker.d.ts`：select/save Promise 返回 URI 数组（679/721）；取消按空数组处理，无依据将任意错误码当取消。reject 为固定选择失败提示。选择器创建的占位不由应用删除。
- `common.d.ts`：Sheet `showClose`（11821）、`onWillDismiss`（11863）、拖拽回弹 `onWillSpringBackWhenDismiss`（11873）、默认 `TRANSLATE_AND_SCROLL` 键盘避让（12017）。
- `@hms.hds.hdsBaseComponent.d.ets`：NavDestination `onBackPressed` 返回 true 消费返回事件（2786）。
- `@ohos.arkui.advanced.DialogV2.d.ets`：内置按钮 action 为 void，不能依靠 Promise 阻止自动关闭；密码框保留自绘按钮和显式关闭。
- 参考：[选择用户文件](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/select-user-file)。取消及材质最终表现仍需运行时验收。

## 规格到用例矩阵

| 规格/边界 | 自动证据 | 原生/视觉证据 |
|---|---|---|
| Sheet/分栏/独立宿主背景、三级背景一致 | scoped Node 源码检查、ArkTS 构建 | 连续导航、push/pop、叠层、深浅色待验收 |
| 明文改名/V2 改名/V0 有限候选、未知版本拒绝 | LocalBackupFormat / TokenBackup | BackupRoundTrip 待设备执行 |
| 缺可选字段、四种令牌、分组、重复 UUID | LocalBackupFormat / LocalBackupImport、既有 TokenStore/TokenGroupStore | 原生兼容回环待执行 |
| 读取/密码/校验/确认取消零写入 | LocalBackupFlow / LocalBackupImport | 选择器/密码重试/后台返回待执行 |
| 延迟/短写/零进展/关闭失败、中文跨块 | LocalBackupFileIo | 生产适配器自有文件回环待执行 |
| 从菜单开始互斥、迟到结果与失效宿主 | LocalBackupFlow / TokenBatchOperation | 快速连点、写入关闭、横屏键盘待执行 |
| 分组失败不写令牌、后续失败不虚报回滚 | LocalBackupImport | 故障 UI 提示待执行 |
| 敏感异常哨兵、无 hash/路径日志 | scoped Node 隐私检查 + 固定异常断言 | 无真实内容日志取样 |
| 双写/三重校验及 >900 字节降级不变 | 既有 TokenStore 单测 + 文件 diff | 原生 ASSET 降级待设备执行 |

## 取消与提交边界

提交前只读和内存准备，摘要仅显示唯一令牌数、可合并分组数、保护方式及更新说明。确认只消费准备快照，不重读文件。密码失败允许重试。取消清除会话引用，不声称 JavaScript 字符串可可靠零化。

分组先合并、再调用原批量令牌写入且始终传 report。分组失败不进入 token 写；任何提交失败均提示可能已有更新。无跨存储回滚/补偿删除。导出从写入开始不提供中途撤销，成功仅指写入和关闭完成，不代表远端云盘上传或断电持久性。

## 自动检查记录

- ArkTS-Check 已覆盖本次生产/测试变更，未发现类型错误；保留既有 API23/兼容API20、`@Entry` 导出提示及系统边界异常传播 lint 告警，不将其包装成零告警。
- LocalUnit 初轮 659 项中 1 项失败（关闭故障重复计数），将结果返回移至关闭后修正；2026-10-11 05:53:58 UTC 复测 659/659 通过。独立审核修正后的最终数字见下方补记。
- 首轮相关 Node 检查发现测试装载器不支持多行 import、close fake 与 SDK 同步 void 契约不一致；修改测试夹具后完整 Node 套件 188/188 通过。
- 行覆盖 77.70%，分支覆盖 72.88%，均高于 75.10% / 70.28% 基线；仅从未出现豁免清单移除现在受测的两个模块，不降低阈值。
- HAP 在兼容API20/编译API26现有配置下构建成功，signed/unsigned 产物均已生成。没有修改签名或版本配置，没有安装到正式设备。
- 云备份 scoped 隐私检查、字符串资源检查和 OpenSpec strict 校验通过。en_US 既有24个被引用的分组/收藏键缺失仍回退 base；新增25个本地备份键四目录一致。
- `git diff --check` 通过。OpenSpec 目录按现有 `.gitignore` 忽略，任务清单已更新本机文件，未强制加入版本控制。

## 独立审核与修正

主代理实现后由两路只读子代理分别审核 UI/生命周期和格式/I/O/隐私。已修正：

1. 2024 年 UUID 引入前备份的兼容：仅缺失字段在准备时生成一次，支持注入并校验碰撞；空串/非字符串仍按既有持久化边界拒绝。
2. V0 随机密文恰好以 JSON 标点开头时继续保留 `.bak`+块对齐候选；已识别未知 OTP 版本/截断头仍不回退。
3. 宽屏暂时覆盖不等于离开路由：使用栈顶判断失效，不因文件选择器或后台暂停丢弃当前会话。
4. 备份主 Sheet 与历史详情 Sheet 显式提供实体底色，由原生材质有效时接管，避免不支持材质设备无底透明。
5. `readLocalBackupSource` 与旧 restore 包装保留固定 CANCELLED 原因，不传递原始异常实例。
6. 系统操作菜单仅把已核实的“无 code + 固定 cancel”识别为取消；数字/字符串内部错误及未知失败均固定提示，不读取并转发异常文本。补 LocalUnit 取消/100001/401 用例。

审核提出的“导入明文字节保留到摘要”不成立：页面读取进度结束后，在调用 `showImportSummary` 前即 dispose source 并清除引用。

已知兼容界限：URI 旧解析漏洞能形成 NaN（JSON null）或负计数等无效状态，本入口按规格整批阻断，不静默改周期/位数/计数而改变 OTP 语义；不在本变更暗修 URI。现存已知有效历史字段（四种类型、算法枚举、缺 RankScore/分组/收藏等）保持兼容。

## 最终复测补记

2026-10-11 审核修正后：

| 检查 | 最终结果 |
|---|---|
| `sh hvigorw test -p module=entry@default --no-daemon` | 结果文件 mtime 06:22:56 UTC；Tests run 663 / Failure 0 / Error 0 / Pass 663 / Ignore 0 |
| `node scripts/check-coverage.mjs` | 行 5766/7419 = 77.72%；分支 1574/2156 = 73.01%；基线不降 |
| `node --test scripts/*.test.mjs` | 189 passed / 0 failed；含生产 I/O 原语、敏感异常哨兵及 hostile getter 测试 |
| ArkTS-Check | 本次全部变更 `.ets` 已检查，无类型错误；保留上述 warning |
| `sh hvigorw assembleHap --mode module -p product=default -p module=entry@default --no-daemon` | BUILD SUCCESSFUL，兼容API20配置不变 |
| scoped 隐私、字符串资源、`git diff --check` | 通过；语言既有缺口已单列 |
| `openspec validate improve-backup-material-and-interactions --strict` | valid |
| 两路独立审核 + 定向复核 | P0/P1/P2 开放数均为0；不是设备视觉验收替代品 |

菜单 Node 哨兵检查初次误匹配注释中的“AppStorage”，已把规则限定为实际成员访问；没有删除安全断言或减弱异常覆盖。

已新增并注册原生 `LocalBackupFileIoDeviceTest`，扩展 `BackupRoundTripDeviceTest`（含历史缺 UUID、四类型及 V0）。原生代码已做静态检查，但未部署/运行，因此10.1/10.2不勾选。8.2的自动化id/48vp/滚动与无障碍标签已实现，运行时视觉复核仍缺，因此整项不勾选。

## 2026-10-11 连接设备后的原生与交互验证

### 环境、部署与数据边界

- 用户明确授权连接设备测试；本次设备为 HUAWEI Mate 90 Pro Max 典藏版，系统返回 `OpenHarmony-7.0.0.109`、API26，屏幕1320×2848。设备上已有debug版1.3.0(1003003)、现有令牌及已登录账号，云备份开关开启。
- 保留数据覆盖安装本次 entry HAP，没有卸载或清库。首次启动了现有首页进行导航检查；首页原有自动备份逻辑可能随启动执行，本次未主动请求云备份、恢复、删除或清空，也不宣称排除了原有后台行为。
- 随后原生测试 `BackupRoundTripDeviceTest.beforeAll` 改为直接取测试 appContext、独占 cache 目录，不再启动 EntryAbility 或加载真实偏好。测试只写合成文件并清理，分组为空。
- 为避免使用现有令牌完成UI验收，新增仅ohosTest打包的 `LocalBackupTestAbility` / `LocalBackupTestPage`：合成TOTP、空分组、内存group后端和提交计数回调。没有初始化账号、TokenStore或偏好库。该宿主可证明真实组件、系统选择器、密码引擎和文件I/O交互，不能证明真实TokenStore/ASSET提交或生产AppShell全生命周期。
- 第一次hdc测试包安装因Windows正斜杠绝对路径被拼到工作目录而失败，但hdc仍返回0，导致旧测试模块运行时App died。已改用反斜杠路径、检查明确的install successfully并确认新suite数量；旧包结果作废，不归因为本次实现。后续当前包原生测试成功。
- 诊断期间曾误执行一次 `hilog -r`，清除了设备日志环形缓冲；没有清除应用数据或文件。后续仅查询固定测试tag，临时probe已全部移除。
- 测试结束已恢复竖屏/正常字号并force-stop应用进程，确认pid不存在；这样测试内存group后端和运行时外观不带入正常应用使用。保留应用数据与三个合成文件，不自动卸载测试模块。

### 原生证据

`aa test -b smartcityshenzhen.yylx.totptoken -m entry_test -s unittest OpenHarmonyTestRunner -s class BackupRoundTripDeviceTest,LocalBackupFileIoDeviceTest -s timeout 180000 -w 240`

当前包：**Tests run: 6, Failure: 0, Error: 0, Pass: 6, Ignore: 0**，`TestFinished-ResultCode: 0`。

覆盖生产UTF-8大内容读写与截断重写、固定失败反馈、明文/V2密码回环、错密码、旧V0、缺UUID/可选字段、TOTP/HOTP/Steam/Forti及准备快照取消。云crypto用例只在内存中使用合成标识，不访问云目录。实际ASSET/加密KV降级和迁移标志未在设备执行，故10.2整体保留未完成。

### UI 实测结果（合成宿主）

| 用例 | 结果与边界 |
|---|---|
| 菜单取消/连续打开、冲突入口 | 通过；菜单/密码等待阶段三个本地入口禁用，取消后恢复 |
| 空密码/两次不同 | 通过；错误可见，弹窗不消失，不打开选择器 |
| 密码框成功后关闭 | 初次失败：旧框留在选择器下方；修复为异步路径唯一父级ID关闭，`onDidDisappear`后才续流，复测成功 |
| 保存选择器取消 | 通过；返回页面无失效密码框，入口可用 |
| 导入选择器取消 | 通过；内存提交数不变，未自动读写 |
| 明文/迁移警告取消 | 通过；不进选择器，风险与非完整备份说明可读 |
| 明文实际保存并重新读取 | 通过；系统提供方确认写/close后显示“文件已保存”，摘要为1唯一令牌/0分组 |
| 加密实际保存、错密码重试 | 通过；错密码固定提示、提交数0，正确密码进入密码保护摘要，无残留密码框 |
| 摘要取消 | 通过；提交数仍0 |
| 摘要确认 | 内存回调只执行一次；不是生产KV/ASSET端到端验收 |
| 执行期间Back | 通过；15秒延迟提交期间进度层仍在，入口禁用 |
| 提交失败 | 通过；故障注入后提示“可能已更新、未自动回滚”，计数未增，入口恢复 |
| 迁移误选与显式URI出口 | 通过；识别TXT，转到空TextArea，不转交正文/不自动导入 |
| 零可导出令牌 | 通过；提示没有可导出本地令牌，无菜单/选择器 |
| 深色、2倍字体、竖屏安全键盘 | 发现按钮遮挡后修正；顶部对齐、编辑态有界Scroll后，两输入及确认/取消可滚到键盘上方，键盘不收起也能取消 |
| 材质开/关与实体兜底 | 本地Sheet浅色实体及深色材质显示正常；未证明云连续导航/历史详情叠层 |
| 横屏 | 无键盘时菜单/受限宽度密码框可用；安全悬浮键盘开启后仍遮挡弹窗中央，**失败/P2**，不可签收 |
| embedded独立宿主 | 同组件实体背景与入口显示可用；并非真实平板/PC分栏完整验收 |

### 本轮修复与已知未通过

1. 修复密码框双关闭/下一阶段竞态。异步submit由页面持有ID单一关闭，组件不重复调用controller.close；下一阶段只在onDidDisappear触发。取消/宿主失效清除续延引用，保留generation检查。定向子代理复核无新P1。
2. 密码框监听`keyboardHeightChange`并注销同一回调，按窗口有效高度限制Scroll；安全悬浮键盘不报告高度时，编辑态提供有界滚动兜底。顶部对齐后竖屏2倍字号可达。该改动未全局改变窗口键盘策略。
3. **仍开放P2：横屏安全悬浮键盘遮挡。** 此机键盘在中间悬浮且不提供可用于避让的高度，视口被覆盖；回竖屏或收键盘可继续。8.2/10.4/10.5均不能据此标完成。
4. 相邻旧Index密码入口仍使用旧confirm关闭行为，未将本次新流程扩展过去；后续应单独真机复核，不把新页通过推广为全入口通过。
5. 本次只新建三个明确合成文件（`OHOTP Synthetic … 20261011`前缀，plain/encrypted/migration），未选择覆盖已有文件。系统选择器给手输带后缀的明文名再次追加.json，属于测试文件命名现象。未获文件删除权限时不自动unlink提供方目标；文件保留给人工检查。

## 未验收设备矩阵

首轮实现时设备未连接；用户随后授权连接手机验证，实测结果以上节为准。

仍保留未完成：真实平板/PC分栏和低API设备、云连续导航与历史详情叠层的深色/材质关形态（生产入口浅色+材质开已于 2026-10-11 备份历史生产入口真机验收一节关闭）、生产AppShell窗口/后台失效全链路、真实ASSET/加密KV降级与迁移、文件实际慢写/close故障UI及回退演练。横屏安全悬浮键盘已复现失败，不是仅缺测试。

OpenSpec本轮仅将10.1新增原生I/O验收勾选，总进度 **37/43**；8.2及10.2–10.6仍未全满足。两次当前包原生测试均6/6；本轮代码修复后LocalUnit663/663、Node189/189、行77.72%/分支73.01%、两HAP构建成功，静态检查无类型错误（仍有兼容/lint warning）。

## 2026-10-11 云详情底部 Sheet 调整

用户实测明确选择让“华为云备份详情”也以“备份与迁移”的方式由下往上弹出。

- 入口现在绑定独立 `CloudBackupDetailsSheet`，复用 `MaterialSheetStyle.options()` / `SheetType.BOTTOM` / LARGE，保留实体兜底。不再往父备份页面的导航栈 push 云详情。
- Sheet 内独立 NavPathStack 承接详情和历史；根隐藏多余返回箭头，系统Back只关闭当前Sheet，历史返回仍回详情。旧AppShell独立路由保留默认实体背景。
- 未修改CloudBackupManager、同步、恢复、删除和原有忙碌/确认逻辑；本地流程未结束时仍不能打开云面板。
- 当前设备隔离宿主已实测新面板显示、系统Back、右上角关闭及重复打开。截图为无账号/无真实云数据状态：`ohtotp-cloud-sheet.png`（本机临时证据）。未用测试登录状态去访问真实云文件。
- 审核提出历史页系统Back分发待验证，已补隔离真机实测：测试页经 `getFrameNodeById('cloud-backup-details-sheet')` / `getNavigationInfoByUniqueId` 定位真实新Sheet的私有导航栈，确认根为云详情后主动push历史页；历史标题/登录提示显示，第一次系统Back回到云详情且Sheet仍在，第二次系统Back关闭Sheet回测试宿主（布局节点50 → 78 → 22）。保留默认导航分发，不增加可能造成双pop的关闭拦截。
- 此历史验证通过既有 `CloudBackupManager.useDepsForTest` 注入未登录账号和合成cloudDir，跳过生产云目录初始化并在未登录门禁返回；不登录真实账号、不访问真实云文件。它仅证明当前API26设备的导航，不证明真实历史记录加载/恢复/删除或其他API版本，不借此勾选原10.3。嵌套父Sheet的生产入口仍由代码接线与专项回归检查，隔离宿主直接复用新Sheet。
- 本次Node全套 **190/190**，主应用与ohosTest HAP构建成功，新增/受影响ArkTS无类型错误；保留兼容性warning。OpenSpec strict及scoped隐私检查通过。
- glm定向审核已完成并复核：本次呈现层无开放P1/P2。历史Back疑问由上述真机证据关闭；lazy注释已改为“延迟到备份页面首次构建”，不再误称进入详情时才加载。未设置showClose就没有X的推断已由审查方撤回，以实际存在且可点击的关闭按钮为准。
- 最终主应用与ohosTest包已保留数据覆盖安装，再次通过历史Back回详情、根Back关闭、重新打开及右上X关闭的断言式冒烟检查；测试结束后已force-stop测试进程，未卸载或清除应用数据，内存测试注入不留到下一次启动。
- 第12节三项完成，整体 **40/46**；此前横屏安全键盘P2及其他未验收项继续保留。

## 2026-10-11 备份历史生产入口真机验收

上一节的隔离宿主验证后，用户要求把“华为云备份详情”内的“备份历史”页面同步为同一底部材质面板呈现，并连接真实设备按生产入口验收。本轮未改任何代码：工作树中的 `CloudBackupDetailsSheet`（历史页在其私有 `NavPathStack` 上以 `inMaterialSheet: true` 呈现）即为验收对象。

### 环境与边界

- 设备仍为 HUAWEI Mate 90 Pro Max 典藏版（API26，1320×2848，无线连接）。本轮构建前门禁全绿：Node 190/190、LocalUnit 663/663、行/分支覆盖率未回退、主应用 HAP 构建成功。
- 保留数据覆盖安装新 HAP（`install bundle successfully`），未卸载、未清数据。设备上为真实已登录账号、云备份开关开启。
- 只做导航与呈现验收：打开历史列表（只读枚举）、打开单条记录详情 Sheet；**未点击恢复、删除、清空云端，未触发任何云写操作**。记录详情仅展示元数据，不解密令牌。
- 浅色模式、材质开关默认（开）状态；未验深色、材质关、宽屏分栏、低 API。测试结束 force-stop 应用进程，数据保留。

### 生产链路实测（全部通过）

| 步骤 | 结果 |
|---|---|
| 我的 → 备份与迁移 | 底部材质 Sheet 弹出（Sheet 1） |
| 华为云备份详情 | 嵌套底部 Sheet 弹出（Sheet 2，LARGE），标题“华为云备份详情”位于 y≈234 |
| 备份历史入口 | **在 Sheet 2 内呈现**：布局树含 `Navigation#cloud-backup-details-sheet`，历史标题与详情标题同帧（y=234），真实记录按“本设备”分组列出（2 条，各 4 令牌，元数据可读取） |
| 记录卡片 → 查看详情 | 第三层 Sheet（MEDIUM，顶边 y=1139，detents 可拖大）：备份时间/来源/设备/元数据/副本位置/大小/令牌数、隐私提示、恢复按钮、危险区删除按钮及不可撤销警告均渲染；未点击 |
| Back（记录详情） | 关闭记录详情，回到历史页，Sheet 2 仍在 |
| Back（历史页） | 回到云详情根页（标题回到 y=234 同帧），Sheet 2 不关闭 |
| 右上角 X（云详情） | Sheet 2 关闭并卸载（布局树仅剩 Sheet 1），备份与迁移面板仍在 |
| 重复打开云详情 | 再次正常弹出 |
| 系统级 Back（云详情根页） | `onBackPressed` 消费并关闭 Sheet 2，回到备份与迁移面板 |

结构证据方式：`uitest dumpLayout` 的 `SheetWrapper/SheetPage` 计数与 bounds 对照（1→2→3 层 Sheet 叠层及各顶边坐标），非截图判读。本地截图证据：`.zcode-tmp/{mine-tab,backup-sheet,cloud-details-sheet,cloud-details-operations,history-in-sheet,record-detail-sheet,back-to-details,cloud-sheet-closed}.jpeg`。测试期间 `hilog` 无该应用 error/exception/crash 匹配行。

本轮关闭了“云连续导航与历史详情叠层（生产入口、浅色）”的缺口；10.3 因深色、材质关及“合成账号”约束未全部满足，保持未勾选。

## 回退边界

可回退页面和会话接入，不回退可靠写入/固定错误映射；旧明文/V0/V2 协议不变，无需重写文件。TokenStore 的 ASSET+加密 KV、三重校验和迁移标志不变。正式回退演练尚未执行，不能用静态 diff 代替。

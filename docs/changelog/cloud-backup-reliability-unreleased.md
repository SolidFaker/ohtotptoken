# 云备份可靠性改进（未发布）

> 实现记录，不代表已发布或通过双设备真机验收。版本号未在本变更中调整。

## 简体中文

- 修正云备份文件写入参数，增加完整写入、读回校验和不覆盖发布；失败产物不再作为正常新备份展示。
- 修复鸿蒙 Buffer 内存池偏移被重复应用造成的编码越界，避免“立即备份”在打开文件前失败；新增直接执行生产编码器的回归测试及真机重复编码验收。
- 区分无法解密与确认损坏，账号或加密服务异常不再直接把有效头部的存档标为损坏；保留旧版格式读取。
- 为本安装创建的未完成云密文持久登记本地所有权，后续受保护操作仅恢复清理已登记产物；无可靠凭据的旧残留和其他设备文件不会按前缀误删。
- 补齐写入准备、恢复和前置拒绝诊断，修正关闭失败错误码与后台读取摘要，兼容系统日志进程名前缀；收敛账号、初始化及时间解析相邻路径的原始异常输出。
- 备份历史区分元数据待获取、读取失败、格式异常和设备名称缺失；仅本地、仅云端、两端副本与未知位置分别展示，不把副本位置当作本次同步完成。
- 恢复旧版普通读取能力：预缓存已结束且无冲突任务时，缓存失败或“仅云端”状态不再直接跳过读取；设备信息以实际文件读取结果为准。
- 删除仅云端备份不再无条件先下载内容，保留真实在途任务保护；清理结果区分忙碌、部分失败、删除失败和同步提交失败，并支持安全重试。
- 新增单条备份详情及明确的恢复/删除操作。当前账号的其他设备及来源未知记录也可单条删除，操作前明确确认，不影响本地令牌。
- 云备份页面与详情复用现有沉浸材质，保留关闭光感、低版本、深浅色及大字体的兼容布局。
- 增加默认关闭、本次启动最长十分钟的云备份诊断。诊断采用严格白名单，不记录账号、设备标识、密钥、备份内容、路径或原始异常；不自动上传。关闭详细诊断后仍可能记录同样受保护的限频失败摘要。

- 图标包云端状态区分“从未备份”与“无法确认”：伴生元数据确定不存在（无图标包内容按设计跳过、从不写出）时显示“未备份”“从未”；仅文件存在但读取或校验失败才保留“元数据尚未确认”，避免无图标包设备永久显示未知态。

- 图标包状态在未决时有界重试（含首次加载总共最多5次），打开瞬间的忙碌或守卫拦截不再让状态永久停留未知。

- 修复图标包状态行的渲染冻结：@Builder 按值传参不随状态刷新，改为直接绑定后“未备份/从未”即时生效。

## 繁體中文

- 修正雲端備份檔案寫入參數，加入完整寫入、讀回驗證與不覆蓋發佈；失敗產物不再當作正常的新備份顯示。
- 修復鴻蒙 Buffer 記憶體池位移被重複套用造成的編碼越界，避免「立即備份」在開啟檔案前失敗；新增直接執行正式編碼器的迴歸測試與真機重複編碼驗收。
- 區分無法解密與已確認損壞，帳號或加密服務異常不再直接將有效標頭的存檔標為損壞，保留舊版格式讀取。
- 為本次安裝建立的未完成雲端密文持久保存本機所有權憑據，後續受保護操作僅清理已登記產物；不按前綴誤刪無憑據的舊殘留或其他裝置檔案。
- 補齊寫入準備、還原與前置拒絕診斷，修正關閉失敗錯誤碼與背景讀取摘要，支援系統日誌程序名前綴；移除帳號、初始化及時間解析相鄰路徑的原始例外輸出。
- 備份歷史區分中繼資料待取得、讀取失敗、格式異常及裝置名稱缺失；僅本機、僅雲端、兩端副本及未知位置分別顯示，不以副本位置代表本次同步完成。
- 恢復舊版一般讀取能力：預先快取已結束且無衝突工作時，快取失敗或「僅雲端」狀態不再直接略過讀取；裝置資訊以實際檔案讀取結果為準。
- 刪除僅雲端備份不再無條件先下載內容，保留進行中工作的保護；清理結果區分忙碌、部分失敗、刪除失敗及同步提交失敗，並支援安全重試。
- 新增單筆備份詳細資料與清楚的還原／刪除操作。目前帳號的其他裝置及來源不明記錄亦可單筆刪除，操作前明確確認，不影響本機權杖。
- 雲端備份頁面與詳細資料沿用現有沉浸材質，保留關閉效果、舊版系統、深淺色及大字體的相容版面。
- 新增預設關閉、僅本次啟動最多十分鐘的雲端備份診斷。診斷採用嚴格白名單，不記錄帳號、裝置識別、金鑰、備份內容、路徑或原始例外；不自動上傳。關閉詳細診斷後仍可能記錄同樣受保護且限頻的失敗摘要。

- 圖示包雲端狀態區分「從未備份」與「無法確認」：伴生中繼資料確定不存在（無圖示包內容按設計跳過、從不寫出）時顯示「未備份」「從未」；僅檔案存在但讀取或校驗失敗才保留「中繼資料尚未確認」，避免無圖示包裝置永久顯示未知態。

- 圖示包狀態未決時有界重試（含首次載入總共最多5次），開啟瞬間的忙碌或守衛攔截不再讓狀態永久停留未知。

- 修復圖示包狀態行的渲染凍結：@Builder 按值傳參不隨狀態刷新，改為直接綁定後「未備份/從未」即時生效。

## English

- Correct cloud-backup file writes with full-write handling, read-back verification and non-overwriting publication. Incomplete artifacts are not presented as successful new backups.
- Fix encoding failures caused by applying HarmonyOS Buffer pool offsets twice. Immediate backup no longer fails before opening the file for this reason; regression tests execute the production encoder, with repeated native encoding verified on device.
- Distinguish decryption unavailability from confirmed corruption without dropping legacy-format support. Account or crypto-service failures no longer automatically invalidate readable backup metadata.
- Persist local ownership receipts before writing unfinished cloud ciphertext. Recovery cleans only registered artifacts belonging to this installation and account; anonymous legacy leftovers and other devices' files are not claimed by filename prefix.
- Add preparation, restoration and readiness diagnostics, preserve approved close/read error codes, accept bounded process-name log prefixes, and remove raw exception output from adjacent account, initialization and date-parsing paths.
- Distinguish unavailable metadata, read failures, invalid formats and missing device names. Local-only, cloud-only, dual-copy and unknown locations no longer imply that the latest synchronization has completed.
- Restore ordinary file-read fallback after prefetch has safely ended. Failed prefetch or cloud-only residency no longer skips a read; device metadata is determined from actual file contents.
- Remove unconditional downloading before deleting cloud-only backups while retaining protection for real in-flight work. Report busy, partial failure, deletion failure and synchronization-submission failure separately, with safe retries.
- Add per-backup details and clearly labeled restore/delete actions. Backups from other or unidentified devices within the current account can be deleted individually after explicit confirmation, without deleting local tokens.
- Reuse the existing immersive-material policy with solid-background fallbacks, dark/light themes, larger text and compatible-system layouts.
- Add opt-in cloud-backup diagnostics lasting at most ten minutes per app process. Strict allowlists exclude account/device identifiers, keys, backup content, paths and raw exceptions. Nothing is uploaded automatically. Disabling detailed diagnostics still permits equally protected, rate-limited failure summaries.

- Distinguish "never backed up" from "unconfirmed" in icon-pack cloud status. When the companion metadata file is definitively absent (the no-content path skips writing it by design), the panel shows "not backed up" and "never"; "metadata unconfirmed" applies only when the file exists but cannot be read or validated, so devices without icon packs no longer show a permanent unknown state.

- Retry the unresolved icon-pack status a bounded number of times (at most five attempts in total, including the initial load), so a momentary busy or guard rejection at page open no longer leaves it stuck as unknown.

- Fix the frozen icon-pack status rows: @Builder value parameters never refresh, so the rows now bind state directly and "not backed up / never" appears immediately.

## 验收边界 / Validation boundary

目标系统上的真实云目录发布、仅云端删除及双设备最终传播须独立验收。SDK `start()` 接受请求不表示云端操作已经完成；没有设备时不能将自动测试结果等同于真机通过。

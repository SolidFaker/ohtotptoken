# 云备份写入守护与备份失败可见性（未发布）

> 实现记录，不代表已发布或已通过真机验收。版本号未在本变更中调整。

## 简体中文

- 新增备份发布后一致性校验：备份发布到云端正式目录后立即重读该文件，校验备份头中的令牌数量与设备标识与本机快照一致；校验不通过判定本次备份失败，隔离并尝试清理拒绝文件，删除成功后提交同步传播，不再更新"最近成功备份"时间。未通过校验的文件持久隔离，删除失败或中断后也不能被当作有效备份恢复或计入轮换；已校验通过但同步提交失败的完整本地备份保留供重试。快速检查不等同正文解密或远端同步完成。
- 写入链路错误零容忍：暂存、加密、写入、关闭、回读校验、发布、发布后校验、同步提交任何阶段失败都使本次备份整体失败，未通过校验的正式文件不能被作为健康备份使用。
- 备份失败持久可见：华为云备份详情页新增"最近一次备份"失败状态行，展示失败阶段与原因，并提供"备份失败，请反馈开发者"问题反馈入口；失败状态在下次备份成功前持续保留，应用重启后仍可见。
- 备份轮换与清理归属守护：每设备 5 份轮换剪除只统计校验通过的本机备份，无法读取的记录（如历史事故残留）不再影响轮换判定；"清除本设备/同名设备云端备份"不再因存在来源不明的记录而整体失败，会跳过这些记录并明确提示保留数量。
- 云备份历史新增"来源未确认"记录的批量清理入口：逐条删除、二次确认，失败的条目保留并列出，本地删除完成即时移除；同步提交失败明确警告并提供重试，不提示完整云端清理成功。修复详情面板内的反馈导航与返回路径。
- 图标包云备份先在系统临时目录生成并校验新 ZIP，发布使用唯一不可变云端备份代，不移动或覆盖已有 ZIP；新代完整提交并校验后只回收明确更旧且超出保留范围的代。发布失败或重启后仍保留既有可恢复代，不先删除唯一好 ZIP。发布状态未定时明确提示重试，不冒充从未备份。目录收集失败停止发布，部分恢复不推进成功水位，故障解除后可重试同一云备份。新协议尚待真机定点中断及云目录 fsync 验收。
- 图标包导入校验 ZIP、原始中央目录路径、大小、文件数量和内容结构（须含 pack.json）；pack.json 读取按实际展开字节限停，多选与重复点击共享导入锁，同名同版本包不能并发绕过检查。拒绝只回收本操作创建的目录，清理失败如实提示；日志不输出原始异常、路径或图标包信息。
- 本安装的发布隔离凭据精确排除系统备份与换机迁移，不扩大排除用户文件目录。

## 繁體中文

- 新增備份發布後一致性校驗：備份發佈到雲端正式目錄後立即重讀該檔案，校驗備份標頭中的權杖數量與裝置識別與本機快照一致；校驗未通過判定本次備份失敗，隔離並嘗試清理拒絕檔案，刪除成功後提交同步傳播，不再更新「最近成功備份」時間。未通過校驗的檔案持久隔離，刪除失敗或中斷後也不能被當作有效備份還原或計入輪換；已校驗通過但同步提交失敗的完整本機備份保留供重試。快速檢查不等同正文解密或遠端同步完成。
- 寫入鏈路錯誤零容忍：暫存、加密、寫入、關閉、回讀校驗、發佈、發布後校驗、同步提交任何階段失敗都使本次備份整體失敗，未通過校驗的正式檔案不能作為健康備份使用。
- 備份失敗持久可見：華為雲備份詳情頁新增「最近一次備份」失敗狀態列，顯示失敗階段與原因，並提供「備份失敗，請回報開發者」問題回饋入口；失敗狀態在下一次備份成功前持續保留，應用重啟後仍可見。
- 備份輪換與清理歸屬守護：每裝置 5 份輪換剪除只統計校驗通過的本機備份，無法讀取的記錄（如歷史事故殘留）不再影響輪換判定；「清除本裝置/同名裝置雲端備份」不再因存在來源不明的記錄而整體失敗，會跳過這些記錄並明確提示保留數量。
- 雲端備份歷史新增「來源未確認」記錄的批次清理入口：逐條刪除、二次確認，失敗項目保留並列出，本機刪除完成即時移除；同步提交失敗明確警告並提供重試，不提示完整雲端清理成功。修復詳情面板內的回饋導航與返回路徑。
- 圖示包雲端備份先在系統臨時目錄產生並校驗新 ZIP，發佈使用唯一不可變雲端備份代，不移動或覆寫既有 ZIP；新代完整提交並校驗後只回收明確較舊且超出保留範圍的代。發佈失敗或重新啟動後仍保留既有可還原的一代，不先刪除唯一有效 ZIP。發佈狀態未定時明確提示重試，不冒充從未備份。目錄收集失敗停止發佈，部分還原不推進成功水位。新協定仍待真機定點中斷及雲端目錄 fsync 驗收。
- 圖示包匯入校驗 ZIP、原始中央目錄路徑、大小、檔案數量與內容結構（須含 pack.json）；pack.json 讀取按實際展開位元組限停，多選與重複點擊共用匯入鎖，同名同版本無法並行繞過檢查。拒絕僅回收本操作建立的目錄，清理失敗如實提示；日誌不輸出原始例外、路徑或圖示包資訊。
- 本安裝的發佈隔離憑據精確排除系統備份與換機移轉，不擴大排除使用者檔案目錄。

## English

- Add post-publish backup verification: after a backup is published to the cloud directory, the published file is re-read immediately and its header token count and device identifier are compared against the snapshot taken when the backup started. A failed check isolates the backup and attempts cleanup; completed deletion is submitted through sync — the "last successful backup" time is not updated. Unverified files remain durably isolated from restore and rotation even if deletion fails or the process stops. Fully verified local backups are kept when only sync submission fails, so sync can be retried. This quick check is not payload decryption or proof of remote sync completion.
- Zero tolerance for write-pipeline errors: a failure at any stage (staging, encryption, write, close, read-back verification, publish, post-publish verification, sync submission) fails the entire attempt, and unverified official-name files cannot be used as healthy backups.
- Persistent backup-failure visibility: the Huawei Cloud backup details page now shows a "last backup" failure row with the failing stage and reason, plus a "Backup failed — please report this" feedback entry. The failure state persists across restarts until the next successful backup clears it.
- Rotation and cleanup ownership guards: the per-device five-backup rotation only counts verified backups from this device; unreadable records (such as legacy incident leftovers) no longer affect rotation. "Clear this device / same-name device cloud backups" no longer fails entirely when records with unverified ownership exist — they are skipped and the kept count is reported.
- Add bulk cleanup for "source unverified" history records with confirmation. Failed deletions remain listed, while locally deleted items disappear immediately. Rejected sync submission shows a warning and retry entry, not a full cloud-cleanup success. Fix feedback navigation and return paths inside the details panel.
- Icon-pack backups are generated and verified in the system temporary directory. Publishing uses a unique immutable cloud generation without moving or overwriting existing ZIPs. After a complete new generation is committed and verified, only strictly older generations outside retention are reclaimed. Failed publishing or process restarts retain existing recoverable generations instead of deleting the only valid ZIP first. Unresolved publication state shows a retry message, not a never-backed-up state. Collection failures stop publishing; partial restores do not advance the successful watermark. Targeted interruption and cloud-directory fsync tests on a real device remain pending.
- Icon-pack import validates ZIP format, original central-directory paths, size, file count and structure (pack.json required). Metadata reading stops at the actual expanded-byte limit. Multiple selections and repeated clicks share an import lock, preventing concurrent same-name/same-version bypasses. Rejection cleans only directories owned by the operation; cleanup failures are reported. Logs contain no raw exceptions, paths or icon-pack identities.
- This installation's publication-isolation receipts are precisely excluded from system backups and device migration without excluding user file directories.

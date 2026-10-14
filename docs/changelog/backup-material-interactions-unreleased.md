# Unreleased — 备份材质与本地交互 / Backup material and local interactions

## 简体中文

- “华为云备份详情”改为与“备份与迁移”一致的底部上滑材质面板，历史页在面板内导航，关闭后返回原页面。材质宿主透出背板，旧独立路由保留实体底色。
- 本地导出使用系统操作菜单，补充密码恢复说明、未加密风险和迁移文件用途；迁移文件不等于完整备份。
- 导入优先识别内容，支持既有明文、V2 密码备份及保留原后缀的旧 V0 候选。正式写入前完整校验并显示无敏感正文的摘要；取消不提交。
- 防止重复操作，抑制失效页面的迟到回调；写入与关闭完成后才报告已保存。提交失败如实提示可能已有部分更新，不声称自动回滚。
- 不包含华为账号加密、加密协议升级或 URI 无损性修复。不改变 ASSET/加密 KV 双写及迁移校验。
- 原生设备、材质/键盘/宽屏视觉验收仍待完成，详见测试记录；本说明不表示已经发布。

## 繁體中文

- 「華為雲端備份詳細資訊」改為與「備份與移轉」一致的底部上滑材質面板；歷史頁在面板內導覽，關閉後返回原頁面。舊獨立路由保留實色背景。
- 本機匯出改用系統操作選單，補充密碼還原說明、未加密風險及移轉檔案用途；移轉檔案不是完整備份。
- 匯入優先辨識內容，保留明文、V2 密碼及原副檔名舊 V0 候選相容性。確認前完整驗證並顯示不含敏感內文的摘要；取消不提交。
- 防止重複操作，忽略失效頁面的延遲回呼；寫入並關閉完成才回報儲存成功。失敗時如實說明可能已有部分更新，不宣稱自動復原。
- 不包含華為帳號加密、加密協定升級或 URI 無損性修正；不改變 ASSET/加密 KV 雙寫及移轉驗證。
- 原生裝置與視覺驗收待完成；此說明不代表已發佈。

## English

- Huawei cloud backup details now opens in a bottom-up material sheet, matching Backup and Migration. History navigation stays inside the sheet, and closing it returns to the underlying page. Existing standalone routes keep a solid background.
- Local exports use a system action menu with password recovery guidance, unencrypted-file warnings, and clear migration limitations.
- Imports identify content before requesting a password, retain plaintext/V2 and original-extension legacy V0 support, and show a non-sensitive summary after full validation but before persistence.
- A single operation session prevents duplicate actions and ignores stale callbacks. Saving succeeds only after all writes and close finish; incomplete imports explicitly allow for partial updates rather than claiming rollback.
- This change does not add Huawei-account encryption, upgrade encryption protocols, fix URI fidelity, or change ASSET/encrypted-KV dual writes and migration checks.
- Native-device and visual acceptance remain pending. These unreleased notes do not imply publication.

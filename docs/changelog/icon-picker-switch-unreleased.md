# Unreleased — 图标包切换 / Icon pack switching

> 2026-10-16：功能修复与 cadence 图标回退收尾，版本为 1.3.0(1003007)，尚未发布。性能硬门槛及完整矩阵仍未通过，不将本次功能提交等同于性能验收完成。详见 [本地验收记录](../testing/icon-picker-performance.md)。

## 简体中文

- 修复图标选择器直接切换自定义图标包时，标签已切换但图标仍停留在前一个包的问题。
- 修复内置 cadence 图标错误引用不存在的 PNG 缩略图，改用现有 SVG 原图；其余内置图标继续使用 PNG 缩略图。
- 切换及搜索准备期间阻止选择或确认过期内容；保留搜索词、当前选择及切包回顶行为。
- 已改为按需准备图标包和复用网格，但整体性能目标尚未达到：当前测量中可见内容就绪仍有回退。因此不宣称“切换更流畅”或“性能优化完成”。
- 完整入口、用户图标编辑、主题/材质/宽屏及兼容性矩阵仍有未验证项，此说明不表示已具备发布条件。

## 繁體中文

- 修正圖示選擇器直接切換自訂圖示包時，標籤已切換但圖示仍停留在上一個包的問題。
- 修正內建 cadence 圖示引用不存在的 PNG 縮圖，改用現有 SVG 原圖；其餘內建圖示仍使用 PNG 縮圖。
- 切換及搜尋準備期間，禁止選取或確認過期內容；保留搜尋詞、目前選取項目與切包回頂行為。
- 已改為按需準備及網格重用，但整體效能目標尚未達成，可見內容就緒仍有退步；不宣稱切換更流暢或最佳化完成。
- 完整入口、使用者圖示編輯、主題/材質/寬螢幕及相容性矩陣仍未全部驗證；本變更尚未發佈。

## English

- Fixed custom icon-pack switching that changed the selected tab while leaving the previous pack's icons on screen.
- Fixed the built-in cadence icon referencing a missing PNG thumbnail by using its existing SVG source. Other built-in icons retain their PNG thumbnails.
- Stale items cannot be selected or confirmed while a switch or search is being prepared. Search text, the selected icon, and scroll-to-top behavior are retained.
- Pack data is now prepared on demand and grid cells are reused, but the overall performance targets have not been met. Visible-content readiness regressed in the current measurements; this is not a completed smoothness or performance improvement.
- Entry-point, custom-icon editing, appearance, window-layout, and compatibility checks remain incomplete. Version 1.3.0(1003007) records the functional fixes; it remains unreleased and does not complete performance acceptance.

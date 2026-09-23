# DiskManager

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

比對、同步與清理兩個儲存空間（外接硬碟、本機資料夾，或任意兩個資料夾）的 Mac app；最初是為了管理兩顆異地外接硬碟（A：8TB、B：10TB）。中英雙語介面（工具列可即時切換）。

A native macOS app (SwiftUI) to compare, sync (mirror / difference / union) and clean up two storage locations — external drives or any two folders — with preview-first, archive-instead-of-delete safety, junk & duplicate cleanup, and an optional AI chat panel (Claude / GPT, bring your own key).

## 下載與安裝

1. 到 [Releases](https://github.com/derekdylu/DiskManager/releases) 下載最新的 `DiskManager-<版本>.zip`，解壓後把 `DiskManager.app` 拖到「應用程式」。
2. 此 app 未經 Apple 公證（notarization），第一次開啟會被 Gatekeeper 擋下：在 Finder 對 app **按右鍵 › 打開**，或到**系統設定 › 隱私權與安全性**按「強制打開」。也可以在終端機執行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/DiskManager.app
   ```

3. 到**系統設定 › 隱私權與安全性 › 完整磁碟取用權**打開 DiskManager（說明見下方「權限」）。

系統需求：macOS 14 Sonoma 以上（Apple Silicon）。也可以自行從原始碼建置（見「使用方式」）。

## 同步分頁

版面由上到下三列：**操作模式** → **目標空間 A**（以它的狀態為準、絕不會被更動，介面上以強調色框出）→ **被操作空間 B**（會被更動的那一邊）。方向相反的需求按兩列之間的「對調」即可（已掃描的結果會沿用，不必重掃），所以不再有 B→A／A−B 這種鏡像重複的模式。聯集模式兩邊對等，不做顯著差異。

三種模式（即時切換，切換後用快取的掃描結果立即重算，不必重掃）：

| 模式 | 行為 |
|---|---|
| **鏡像** | 讓被操作空間 B 跟上目標空間 A（以 A 為準的單向鏡像） |
| **差集** | 只預覽 B 有、A 沒有的項目，確認後從 B 封存或移到垃圾桶；不複製、不覆蓋 |
| **聯集** | 兩邊互補檔案；同檔不同內容取「修改時間較新者」，被覆蓋的舊版先封存；無法判斷新舊或類型衝突的項目**不動並列出** |

鏡像模式下，被操作空間上多出的檔案依你選擇：**保留不動** / **移到封存資料夾**（預設）/ **丟到垃圾桶**。

預覽出來之後若更換 A 或 B 的資料夾，舊計畫會立即作廢，必須重新掃描才能執行。

### 預覽

- 掃描比對純唯讀，先給完整計畫才由你按「開始同步」。
- **樹狀差異清單**：像檔案瀏覽器一樣展開/收起資料夾，資料夾彙總容量與 +新增/~覆蓋/!多出 數量，可依動作篩選，可匯出完整清單（JSON 或純文字）。
- **儲存空間視覺化**：兩個儲存空間的用量條（含本次預計寫入量，空間不足會變紅並擋下）＋掃描範圍第一層資料夾的容量分佈圖。

### 安全設計

- 絕不直接刪除：多出／被汰換的檔案預設移到 `_DiskManager_Archive/<時間戳>/`。
- 原子覆寫（暫存檔＋rename），中途取消不留半套檔案；Finder「鎖定」檔案也會先暫時解鎖完成替換，再復原旗標。
- 保留修改時間與中繼資料；exFAT 自動退回資料＋時間戳，時間比對容差 2 秒。
- 比對時會依兩邊檔案系統處理檔名大小寫，避免 `Folder` / `folder` 在不分大小寫的磁碟上被誤當成兩份。
- 同步／掃描期間自動防止系統睡眠；工具列另有「螢幕常亮」開關。

## 清理分頁

掃出儲存空間中可清掉的垃圾，全部先列清單勾選，預設丟垃圾桶，直接刪除需再確認：

- **專案檔案（FCP／iMovie 可再生媒體）**：資源庫（.fcpbundle/.imovielibrary）內的 Render Files、Proxy Media、High Quality Media、Peaks/Analysis/Thumbnail 快取。**Original Media 絕不列入。**
- **磁碟映像檔**：.img/.dmg/.iso/.sparseimage 等（SD 卡備份映像），是否刪除由你判斷。
- **系統雜物**：.DS_Store、AppleDouble（`._` 檔，用 POSIX readdir 補掃——Foundation API 看不到它們）、Spotlight 索引、.fseventsd，以及舊版未完成的 `.dmtmp-*` 複製暫存檔。
- **縮圖與快取**：.thumbnails、Lightroom Previews.lrdata、Premiere Media Cache 等。
- **重複檔案**：≥10MB 的檔案以「大小＋頭尾 1MiB SHA-256 指紋」分組，一鍵「每組保留最新的一份」。
- **相似資料夾**：重複內容區有「單一檔案群組／資料夾群組」分區切換；資料夾至少 5 檔，且遞迴內容指紋重疊達 80% 以上才列為候選。顯示共通檔數、容量與兩夾總檔數，由你比對差異後勾選其中一夾。父子資料夾不會互相列為候選。沒有候選時分區仍會顯示掃描狀態。
- **匯出結果**：整份掃描報告可匯出 JSON（適合交給 AI 或程式分析）；重複內容另可匯出 TSV，包含所有重複檔案群組、相似資料夾群組、相似度、指紋、容量、修改時間與完整相對路徑；不受介面只顯示前 100 組的限制影響。
- **檢查項目**：掃描前勾選要檢查的類別（垃圾檔一列、重複比對一列），每列開頭的勾選框整列全選，「檢查項目」標題的勾選框全部全選；重複比對要讀檔算指紋，不需要時可不勾。
- **一鍵清除快取**按鈕：位在掃描完成後的操作區（底欄），把這次掃到的系統雜物＋縮圖快取確認一次後全部丟垃圾桶，不必逐項勾選。

每個大類別下再依**子類別**分組（例如系統雜物下分 .DS_Store／AppleDouble／Spotlight 索引…），各自顯示數量與容量、可整組勾選、展開才看個別檔案——不會被海量 .DS_Store 淹沒。

垃圾掃描會跳過 `_DiskManager_Archive`（安全網）與 `.Trashes`。

## AI 分析（右側聊天室）

工具列的「AI 分析」會在右側開啟聊天室，把結果交給 Claude 分析（哪些資料夾佔最多、多出的檔案能不能刪、重複檔該留哪份…）：

- **自備 API key**：可切換 **Claude（Anthropic）** 或 **GPT（OpenAI）**，按鑰匙圖示貼上對應的 API key。Key 只存在 macOS 鑰匙圈，只用來連線 `api.anthropic.com`／`api.openai.com`，費用由你的帳號計費。模型下拉選單同時列出兩家的模型（分 Claude／GPT 兩區），選哪個模型就用哪家的 key；預設 `claude-opus-5`。
- **附上目前結果**：把畫面上的比對計畫／清理報告直接轉成 JSON 附上。清單超過 1000 筆時只列出容量最大的 1000 筆並明確標示，各資料夾／類別的總計仍是完整的。
- **迴紋針**：附加之前匯出的 JSON／XML／TSV／TXT。單次附件上限 1 MB，超過會拒收並說明，不會默默截斷。
- 附件內容（含檔案路徑）會送到你選用的 Anthropic／OpenAI API；AI 只提供建議，不會也無法更動任何檔案。

## 使用方式

```bash
make app        # 打包出 build/DiskManager.app（可拖到「應用程式」）；圖示來自 scripts/AppIcon.png
```

### 權限：完整磁碟取用權

macOS 不允許 app 自己要求「完整磁碟取用權」，只能由你在**系統設定 › 隱私權與安全性 › 完整磁碟取用權**把 DiskManager 打開（授權後重新啟動 app）。沒有它時，掃描會對桌面／文件／下載／外接與網路磁碟區逐一跳出詢問，受保護的資料夾也會被跳過。工具列右側的盾牌顯示目前狀態，按一下直接開啟該設定頁；第一次掃描時若尚未授權也會提示。

`make app` 會自動用已安裝的 Apple Development／Developer ID 簽章（可用 `CODESIGN_IDENTITY=` 指定）。這很重要：完整磁碟取用權綁定 app 的簽章，ad-hoc 簽章每次重建都不同，授權會被 macOS 靜默作廢；用正式身分簽章則重建後仍有效。

## 開發

```bash
xed .           # 用 Xcode 開啟（SPM 專案）
swift run       # 直接執行
swift test      # 單元測試（掃描／比對／差集／聯集／垃圾掃描／相似資料夾／端到端同步）

# 規模煙霧測試（生成 8 萬個檔案實測掃描記憶體，較慢，平常跳過）
DM_SCALE_TEST=1 swift test --filter ScaleSmokeTests
```

注意：所有掃描／複製／刪除迴圈都必須在每個項目包 `autoreleasepool`——Foundation 的列舉與檔案 API 會產生大量 autorelease 物件，背景執行緒沒有排水點，掃大硬碟時記憶體會無限堆積（實測 8 萬檔案增量 43MB；修正前會爆到數 GB）。

結構：
- `Sources/DiskManagerCore/` — 純邏輯，UI 無關，全部可測：
  - `TreeScanner` 掃描、`Differ` 鏡像/聯集比對、`SyncEngine` 執行、`CopyFile`（copyfile(3) 包裝：進度、取消、中繼資料）
  - `JunkScanner` 垃圾分類＋重複檔指紋、`JunkEngine` 刪除執行
  - `ReportJSONExporter` 比對計畫／清理報告的 JSON 匯出（存檔用完整版，交給 AI 用的有筆數上限版）
- `Sources/DiskManager/` — SwiftUI 介面（雙語文字以 `tr(中, EN)` 成對寫在呼叫處）；AI 聊天室為 `ChatPanelView`／`ChatState`／`ClaudeClient`＋`OpenAIClient`（各自的串流 API，無第三方相依）／`KeychainStore`

### 多硬碟擴充預留

核心 API 都以「任意兩個資料夾 URL」為單位（`Differ.diff(source:dest:)`、`SyncEngine.execute(...)`），不綁定 A/B 概念；要擴充成 N 顆硬碟時，上層改為硬碟清單＋兩兩配對執行即可，核心不用動。搭配 Roadmap 的 manifest 資料庫（記錄「哪個檔案已備份到哪顆硬碟」）就能支援情境 1 與多碟。

## 已知限制

- 同步比對用「大小＋修改時間」，不做全檔雜湊；重複檔偵測用頭尾指紋（標示為「極可能重複」）。
- 資料夾本身的修改時間不同步。
- AppleDouble（`._`）檔不參與同步（Foundation 列舉不回傳；它們是中繼資料側車，copyfile 會在需要時自動重建），清理分頁可掃出並刪除。
- 聯集模式對「無法判斷新舊」的衝突一律不動，需人工處理。

## Roadmap

- **情境 1**：本機檔案要等 A、B 都備份完成才可安全刪除——需要 manifest 資料庫，讓只接一顆硬碟時也能判斷「這批檔案還缺哪邊的備份」。
- 多硬碟（N 顆）同步。
- 同步前的選用內容驗證（checksum）、同步歷史紀錄。

## 授權

[MIT](LICENSE)

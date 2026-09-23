import DiskManagerCore
import Foundation

// Core-layer enums are mapped to bilingual display text here

extension OrphanPolicy {
    @MainActor var localizedTitle: String {
        switch self {
        case .keep: return tr("保留不動", "Keep")
        case .archive: return tr("移到封存資料夾", "Archive")
        case .trash: return tr("丟到垃圾桶", "Trash")
        }
    }

    @MainActor var localizedExplanation: String {
        switch self {
        case .keep:
            return tr("多出的檔案原地保留（目的地不會是完整鏡像）。",
                      "Extra files stay untouched (destination won't be an exact mirror).")
        case .archive:
            return tr("多出的檔案移到目的地的「\(SyncEngine.archiveRootName)」資料夾，之後可自行檢查再刪。最安全，建議使用。",
                      "Extra files move to \"\(SyncEngine.archiveRootName)\" on the destination for later review. Safest option, recommended.")
        case .trash:
            return tr("多出的檔案丟到垃圾桶（清空前仍可救回）。",
                      "Extra files go to the Trash (recoverable until emptied).")
        }
    }
}

extension PlanItem.Reason {
    @MainActor var localizedLabel: String {
        switch self {
        case .new: return tr("新增", "New")
        case .sizeChanged: return tr("大小不同", "Size differs")
        case .timeChanged: return tr("時間不同", "Time differs")
        case .linkChanged: return tr("連結變更", "Link changed")
        case .typeConflict: return tr("類型衝突", "Type conflict")
        case .extraneous: return tr("多出", "Extra")
        }
    }
}

extension EntryKind {
    @MainActor var localizedLabel: String {
        switch self {
        case .file: return tr("檔案", "File")
        case .directory: return tr("資料夾", "Folder")
        case .symlink: return tr("符號連結", "Symlink")
        }
    }
}

extension JunkCategory {
    @MainActor var localizedTitle: String {
        switch self {
        case .fcpCache: return tr("專案檔案", "Project File")
        case .diskImages: return tr("磁碟映像檔", "Disk images")
        case .systemCruft: return tr("系統雜物", "System cruft")
        case .thumbnailCache: return tr("縮圖與快取", "Thumbnails & caches")
        case .duplicates: return tr("重複檔案", "Duplicates")
        case .similarFolders: return tr("相似資料夾", "Similar folders")
        }
    }

    @MainActor var localizedHint: String {
        switch self {
        case .fcpCache:
            return tr("FCP／iMovie 資源庫裡的 Render / Proxy / 最佳化媒體等，FCP 可重新產生（原始媒體 Original Media 絕不會列入）",
                      "Render / proxy / optimized media inside FCP / iMovie libraries that FCP can regenerate (Original Media is never listed)")
        case .diskImages:
            return tr("依副檔名列出（.img/.dmg/.iso…），是否還需要由你判斷",
                      "Listed by extension (.img/.dmg/.iso…) — you decide if they're still needed")
        case .systemCruft:
            return tr(".DS_Store、AppleDouble（._ 檔）、Spotlight 索引等，刪除無害",
                      ".DS_Store, AppleDouble (._ files), Spotlight index, etc. Safe to delete")
        case .thumbnailCache:
            return tr("縮圖資料夾、Lightroom 預覽、剪輯軟體媒體快取等，可重新產生",
                      "Thumbnail folders, Lightroom previews, editor media caches — regenerable")
        case .duplicates:
            return tr("同大小＋頭尾內容指紋相同（極可能重複），請自行確認後勾選要刪的份數",
                      "Same size + matching content fingerprint (almost certainly identical). Review and pick which copies to remove")
        case .similarFolders:
            return tr("遞迴內容有 80% 以上指紋相同的資料夾；只建議候選，請比對差異後再選一邊移除",
                      "Folders whose recursive contents have at least 80% matching fingerprints. Review differences, then choose at most one side to remove")
        }
    }
}

/// Display name for a subcategory key (JunkItem.detail); unknown keys (e.g. assorted file extensions) are shown verbatim
@MainActor
func junkSubcategoryLabel(_ key: String) -> String {
    switch key {
    case ".DS_Store": return tr(".DS_Store（Finder 資料夾設定）", ".DS_Store (Finder folder settings)")
    case "AppleDouble": return tr("AppleDouble（._ 中繼資料檔）", "AppleDouble (._ metadata files)")
    case "Thumbs.db": return tr("Thumbs.db（Windows 縮圖快取）", "Thumbs.db (Windows thumbnail cache)")
    case "desktop.ini": return tr("desktop.ini（Windows 資料夾設定）", "desktop.ini (Windows folder settings)")
    case ".Spotlight-V100": return tr("Spotlight 索引（.Spotlight-V100）", "Spotlight index (.Spotlight-V100)")
    case ".fseventsd": return tr("檔案系統事件紀錄（.fseventsd）", "File system event log (.fseventsd)")
    case ".TemporaryItems": return tr("暫存項目（.TemporaryItems）", "Temporary items (.TemporaryItems)")
    case ".DocumentRevisions-V100": return tr("文件版本紀錄（.DocumentRevisions-V100）", "Document revisions (.DocumentRevisions-V100)")
    case "DiskManager temporary file": return tr("DiskManager 未完成複製暫存檔", "DiskManager incomplete-copy temporary files")
    case "Render Files": return tr("Render Files（算圖檔）", "Render Files")
    case "Proxy Media": return tr("Proxy Media（代理媒體）", "Proxy Media")
    case "High Quality Media": return tr("High Quality Media（最佳化媒體）", "High Quality Media (optimized)")
    case "Peaks Data": return tr("Peaks Data（音訊波形）", "Peaks Data (audio waveforms)")
    case "Analysis Files": return tr("Analysis Files（分析檔）", "Analysis Files")
    case "Thumbnail Media": return tr("Thumbnail Media（縮圖媒體）", "Thumbnail Media")
    case ".thumbnails": return tr("縮圖資料夾（.thumbnails）", "Thumbnail folders (.thumbnails)")
    case "Previews.lrdata": return tr("Lightroom 預覽（Previews.lrdata）", "Lightroom previews (Previews.lrdata)")
    case "Smart Previews.lrdata": return tr("Lightroom 智慧預覽（Smart Previews.lrdata）", "Lightroom smart previews (Smart Previews.lrdata)")
    case "Media Cache", "Media Cache Files": return tr("\(key)（Premiere 媒體快取）", "\(key) (Premiere media cache)")
    case "Peak Files": return tr("Peak Files（Premiere 波形快取）", "Peak Files (Premiere waveform cache)")
    default: return key
    }
}

extension UnresolvedConflict {
    @MainActor var localizedReason: String {
        switch kind {
        case .typeMismatch:
            return tr("一邊是\(aKind.localizedLabel)、另一邊是\(bKind.localizedLabel)",
                      "\(aKind.localizedLabel) on one side, \(bKind.localizedLabel) on the other")
        case .ambiguous:
            return tr("大小不同但修改時間相同，無法判斷哪邊較新",
                      "Sizes differ but timestamps match — cannot tell which is newer")
        case .linkMismatch:
            return tr("符號連結指向不同位置", "Symlinks point to different targets")
        }
    }
}

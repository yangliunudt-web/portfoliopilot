import SwiftUI
import SwiftData

@Observable
final class AutoSaveManager {
    var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: "autoSaveEnabled") }
    }
    var autoSaveIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(autoSaveIntervalMinutes, forKey: "autoSaveIntervalMinutes") }
    }
    var autoBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: "autoBackupEnabled") }
    }
    var autoBackupDirectory: String {
        didSet { UserDefaults.standard.set(autoBackupDirectory, forKey: "autoBackupDirectory") }
    }
    var lastAutoSaveTime: Date? {
        didSet { UserDefaults.standard.set(lastAutoSaveTime, forKey: "lastAutoSaveTime") }
    }
    var lastBackupTime: Date? {
        didSet { UserDefaults.standard.set(lastBackupTime, forKey: "lastBackupTime") }
    }

    var modelContext: ModelContext?

    private var debounceTimer: Timer?

    private static func defaultBackupDir() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("PortfolioPilot/backups").path
    }

    init() {
        self.autoSaveEnabled = UserDefaults.standard.bool(forKey: "autoSaveEnabled")
        let interval = UserDefaults.standard.integer(forKey: "autoSaveIntervalMinutes")
        self.autoSaveIntervalMinutes = interval > 0 ? interval : 15
        self.autoBackupEnabled = UserDefaults.standard.bool(forKey: "autoBackupEnabled")
        let savedDir = UserDefaults.standard.string(forKey: "autoBackupDirectory") ?? ""
        self.autoBackupDirectory = savedDir.isEmpty ? Self.defaultBackupDir() : savedDir
        self.lastAutoSaveTime = UserDefaults.standard.object(forKey: "lastAutoSaveTime") as? Date
        self.lastBackupTime = UserDefaults.standard.object(forKey: "lastBackupTime") as? Date
    }

    /// 数据发生变更时调用，重置防抖计时器
    func notifyDataChanged() {
        guard autoSaveEnabled else { return }
        debounceTimer?.invalidate()
        let interval = max(1, autoSaveIntervalMinutes)
        debounceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval * 60), repeats: false) { [weak self] _ in
            self?.performAutoBackup()
        }
    }

    /// 手动保存/操作执行后立即备份，同时取消防抖等待
    func saveImmediately() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        performAutoBackup()
    }

    private func performAutoBackup() {
        guard let ctx = modelContext else { return }

        let assetRaw = UserDefaults.standard.string(forKey: "portfolioAssetsV3") ?? "[]"
        guard let assetList = AssetList(rawValue: assetRaw) else { return }
        let totalPrinc = UserDefaults.standard.double(forKey: "totalUserPrincipal")

        let totalValue = assetList.items.reduce(0.0) { $0 + $1.value }
        guard totalValue > 0 else { return }

        var snap: [String: Double] = [:]
        for item in assetList.items { snap[item.id.uuidString] = (item.value * 100).rounded() / 100 }
        for cat in AssetCategory.allCases {
            let catItems = assetList.items.filter { $0.category == cat }
            snap["CAT_\(cat.rawValue)_V"] = (catItems.reduce(0) { $0 + $1.value } * 100).rounded() / 100
            snap["CAT_\(cat.rawValue)_P"] = (catItems.reduce(0) { $0 + $1.principal } * 100).rounded() / 100
        }

        let recordTotal = (totalValue * 100).rounded() / 100
        let recordPrincipal = (totalPrinc * 100).rounded() / 100

        ctx.insert(PortfolioRecord(date: Date(), totalValue: recordTotal, principal: recordPrincipal, assetSnapshot: snap))
        lastAutoSaveTime = Date()

        if autoBackupEnabled {
            performFileExport(assetRaw: assetRaw, totalPrinc: totalPrinc)
        }
    }

    func performFileExport(assetRaw: String? = nil, totalPrinc: Double? = nil) {
        let dir = autoBackupDirectory
        guard !dir.isEmpty else { return }

        ensureDirectoryExists(dir)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "PortfolioPilot_Backup_\(formatter.string(from: Date())).json"
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent(filename)

        // 构建与手动导出一致的 BackupData 格式
        let assetListRaw = assetRaw ?? (UserDefaults.standard.string(forKey: "portfolioAssetsV3") ?? "[]")
        let assetList = AssetList(rawValue: assetListRaw) ?? AssetList(items: [])

        // 获取历史记录
        var historyItems: [HistoryItemJSON] = []
        if let ctx = modelContext {
            let descriptor = FetchDescriptor<PortfolioRecord>(sortBy: [SortDescriptor(\.date)])
            if let records = try? ctx.fetch(descriptor) {
                historyItems = records.map { HistoryItemJSON(date: $0.date, totalValue: $0.totalValue, principal: $0.principal, assetSnapshot: $0.assetSnapshot) }
            }
        }

        let backup = BackupData(
            totalUserPrincipal: totalPrinc ?? UserDefaults.standard.double(forKey: "totalUserPrincipal"),
            absThreshold: UserDefaults.standard.double(forKey: "absThreshold"),
            relThreshold: UserDefaults.standard.double(forKey: "relThreshold"),
            history: historyItems,
            assetList: assetList
        )

        guard let jsonData = try? JSONEncoder().encode(backup) else { return }

        do {
            try jsonData.write(to: fileURL)
            lastBackupTime = Date()
            cleanupOldBackups(in: dir)
        } catch {
            print("Auto-backup write failed: \(error.localizedDescription)")
        }
    }

    private func ensureDirectoryExists(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func cleanupOldBackups(in directory: String) {
        let dirURL = URL(fileURLWithPath: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("PortfolioPilot_Backup_") && $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return da > db
            }

        guard backups.count > 30 else { return }
        for file in backups.dropFirst(30) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    deinit {
        debounceTimer?.invalidate()
    }
}

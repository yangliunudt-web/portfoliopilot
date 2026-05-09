import SwiftUI
import SwiftData

@Observable
final class AutoSaveManager {
    var autoSaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: "autoSaveEnabled"); handleToggle() }
    }
    var autoSaveIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(autoSaveIntervalMinutes, forKey: "autoSaveIntervalMinutes"); restartTimer() }
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

    private var timer: Timer?

    init() {
        self.autoSaveEnabled = UserDefaults.standard.bool(forKey: "autoSaveEnabled")
        let interval = UserDefaults.standard.integer(forKey: "autoSaveIntervalMinutes")
        self.autoSaveIntervalMinutes = interval > 0 ? interval : 15
        self.autoBackupEnabled = UserDefaults.standard.bool(forKey: "autoBackupEnabled")
        self.autoBackupDirectory = UserDefaults.standard.string(forKey: "autoBackupDirectory") ?? ""
        self.lastAutoSaveTime = UserDefaults.standard.object(forKey: "lastAutoSaveTime") as? Date
        self.lastBackupTime = UserDefaults.standard.object(forKey: "lastBackupTime") as? Date

        if autoSaveEnabled { startTimer() }
    }

    func notifyManualSave() {
        lastAutoSaveTime = Date()
    }

    func handleToggle() {
        if autoSaveEnabled { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        let interval = max(1, autoSaveIntervalMinutes)
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.performAutoBackup()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        if autoSaveEnabled { startTimer() }
    }

    func performAutoBackup() {
        guard let ctx = modelContext else { return }

        // 从 UserDefaults 读取当前资产数据
        let assetRaw = UserDefaults.standard.string(forKey: "portfolioAssetsV3") ?? "[]"
        guard let assetList = AssetList(rawValue: assetRaw) else { return }
        let totalPrinc = UserDefaults.standard.double(forKey: "totalUserPrincipal")

        let totalValue = assetList.items.reduce(0.0) { $0 + $1.value }
        guard totalValue > 0 else { return }

        // 构建快照
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

        if autoBackupEnabled, !autoBackupDirectory.isEmpty {
            performFileExport(assetRaw: assetRaw, totalPrinc: totalPrinc)
        }
    }

    func performFileExport(assetRaw: String? = nil, totalPrinc: Double? = nil) {
        let dir = autoBackupDirectory
        guard !dir.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "PortfolioPilot_Backup_\(formatter.string(from: Date())).json"
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent(filename)

        let backup: [String: Any] = [
            "totalUserPrincipal": totalPrinc ?? UserDefaults.standard.double(forKey: "totalUserPrincipal"),
            "absThreshold": UserDefaults.standard.double(forKey: "absThreshold"),
            "relThreshold": UserDefaults.standard.double(forKey: "relThreshold"),
            "assetList": assetRaw ?? (UserDefaults.standard.string(forKey: "portfolioAssetsV3") ?? "[]"),
            "exportDate": formatter.string(from: Date())
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted) else { return }

        do {
            try jsonData.write(to: fileURL)
            lastBackupTime = Date()
            cleanupOldBackups(in: dir)
        } catch {
            print("Auto-backup write failed: \(error.localizedDescription)")
        }
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
        stopTimer()
    }
}

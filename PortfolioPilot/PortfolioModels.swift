import SwiftUI
import UniformTypeIdentifiers

// MARK: - 核心数据模型与备份结构

struct SmartCalculationResult {
    var plan: [String: Double]
    var strategyName: String
    var description: String
    var isRebalance: Bool = false
}

enum AssetCategory: String, Codable, CaseIterable, Identifiable {
    case aShares = "A股"
    case usStocks = "美股"
    case gold = "贵金属"
    case bonds = "债券"
    case cash = "现金"

    var id: String { self.rawValue }
    var color: Color {
        switch self {
        case .aShares: return .red
        case .usStocks: return .purple
        case .gold: return .yellow
        case .bonds: return .blue
        case .cash: return .gray
        }
    }
}

struct AssetItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var category: AssetCategory
    var value: Double
    var principal: Double
}

struct AssetList: Codable, RawRepresentable {
    var items: [AssetItem]
    init(items: [AssetItem]) { self.items = items }
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([AssetItem].self, from: data) else { return nil }
        self.items = result
    }
    var rawValue: String {
        guard let data = try? JSONEncoder().encode(items),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }
}

enum ChartTimeRange: String, CaseIterable, Identifiable {
    case oneMinute = "一分钟"
    case oneDay = "一天"
    case oneWeek = "一周"
    case twoWeeks = "两周"
    case oneMonth = "一月"
    case oneQuarter = "一季度"
    case oneYear = "一年"
    case all = "所有"
    case custom = "自定义"
    var id: String { self.rawValue }
}

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let principal: Double
}

struct BackupData: Codable {
    var totalUserPrincipal: Double
    var absThreshold: Double
    var relThreshold: Double
    var history: [HistoryItemJSON]
    var assetList: AssetList?

    // V1 兼容字段
    var bondValue: Double?; var nasdaqValue: Double?; var goldValue: Double?; var csiValue: Double?; var cashValue: Double?
    var bondPrincipal: Double?; var nasdaqPrincipal: Double?; var goldPrincipal: Double?; var csiPrincipal: Double?; var cashPrincipal: Double?
    var bondTarget: Double?; var nasdaqTarget: Double?; var goldTarget: Double?; var csiTarget: Double?; var cashTarget: Double?
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var backupData: BackupData?
    init(backupData: BackupData? = nil) { self.backupData = backupData }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents { self.backupData = try JSONDecoder().decode(BackupData.self, from: data) }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(backupData)
        return FileWrapper(regularFileWithContents: data)
    }
}

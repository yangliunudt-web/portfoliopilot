import Foundation
import SwiftData

// MARK: - 1. 备份用的中间数据结构
// (放在这里是因为 PortfolioRecord 需要用到它)
struct HistoryItemJSON: Codable {
    let date: Date
    let totalValue: Double
    let principal: Double
    let assetSnapshot: String
}

// MARK: - 2. 数据库模型
@Model
final class PortfolioRecord {
    var date: Date
    var totalValue: Double
    var principal: Double
    var assetSnapshot: String // 存储各资产的JSON快照
    
    // 标准初始化
    init(date: Date, totalValue: Double, principal: Double, assetSnapshot: [String: Double]) {
        self.date = date
        self.totalValue = totalValue
        self.principal = principal
        
        // 字典转 JSON 字符串存储
        if let data = try? JSONEncoder().encode(assetSnapshot),
           let str = String(data: data, encoding: .utf8) {
            self.assetSnapshot = str
        } else {
            self.assetSnapshot = "{}"
        }
    }
    
    // 新增：从备份数据还原时的初始化
    init(backupItem: HistoryItemJSON) {
        self.date = backupItem.date
        self.totalValue = backupItem.totalValue
        self.principal = backupItem.principal
        self.assetSnapshot = backupItem.assetSnapshot
    }
}

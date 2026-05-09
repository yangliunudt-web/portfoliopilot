import Foundation

struct CategoryState {
    let name: String
    let value: Double
    let principal: Double
    let targetRatio: Double
}

struct AIAdvisor {
    static func getAdvice(
        totalValue: Double,
        totalPrincipal: Double,
        categories: [CategoryState],
        absThreshold: Double,
        relThreshold: Double,
        apiBaseURL: String,
        apiKey: String,
        model: String
    ) async throws -> String {
        let base = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw AdvisorError.invalidURL
        }

        let currentRatio = totalValue > 0 ? totalValue / totalPrincipal - 1 : 0

        var categoryLines = ""
        for cat in categories {
            let pct = totalValue > 0 ? cat.value / totalValue : 0
            let deviation = pct - cat.targetRatio
            let yield = cat.principal > 0 ? (cat.value / cat.principal - 1) : 0
            categoryLines += """
            - \(cat.name): 市值 ¥\(String(format: "%.0f", cat.value)), 占 \(String(format: "%.1f", pct * 100))% (目标 \(String(format: "%.1f", cat.targetRatio * 100))%), 偏离 \(String(format: "%+.1f", deviation * 100))%, 收益率 \(String(format: "%+.1f", yield * 100))%
            """
        }

        let prompt = """
        你是专业投资组合顾问。根据以下持仓数据，给出最紧急、最有价值的一项操作建议。

        当前状态：
        总资产: ¥\(String(format: "%.0f", totalValue))
        总本金: ¥\(String(format: "%.0f", totalPrincipal))
        总收益率: \(String(format: "%+.1f", currentRatio * 100))%
        \(categoryLines)

        再平衡规则：
        - 目标占比 ≥ 20% 的大类，绝对偏离超过 \(String(format: "%.0f", absThreshold * 100))% 触发信号
        - 目标占比 < 20% 的小类，相对偏离超过 \(String(format: "%.0f", relThreshold * 100))% 触发信号

        请给出：
        1. 最紧急操作（具体到哪个大类，增仓还是减仓）
        2. 建议调整金额范围
        3. 简短的核心理由
        4. 如果当前无需操作，直接说明"当前无需调整"

        用中文回复，控制在 150 字以内，直接给建议不要寒暄。
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 300,
            "temperature": 0.3
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AdvisorError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let rbody = String(data: data, encoding: .utf8) ?? ""
            throw AdvisorError.httpError(httpResponse.statusCode, rbody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AdvisorError.parseFailed
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AdvisorError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 API 地址"
        case .invalidResponse: return "服务器响应异常"
        case .httpError(let code, _): return "API 错误 (\(code))"
        case .parseFailed: return "AI 回复解析失败"
        }
    }
}

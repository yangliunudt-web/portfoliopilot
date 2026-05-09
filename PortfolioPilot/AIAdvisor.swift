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
        你是投资组合再平衡顾问。目标是"最少操作、可接受平衡"，不要追求完美。

        \(categoryLines)

        规则：
        - 总资产 ¥\(String(format: "%.0f", totalValue))
        - 触发阈值：大仓位(≥20%)绝对偏离>\(String(format: "%.0f", absThreshold * 100))%，小仓位相对偏离>\(String(format: "%.0f", relThreshold * 100))%
        - 不触发 = 已经可接受，不需调整

        核心原则：
        1. 只处理触发阈值的大类，其余维持不动
        2. 调整后落在"阈值以内"即可，不需要精确回到目标比例
        3. 优先调整偏离最大的大类（一笔操作解决最大问题）
        4. 用最少的交易次数完成

        回复格式（只给最紧急的1-2项操作）：
        大类名：增仓/减仓 约¥xxx
        理由：一句话
        如无需调整就说"当前无需调整"

        100字以内。
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

        let rawBody = String(data: data, encoding: .utf8) ?? ""
        print("[AI Advisor] Raw response: \(rawBody.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[AI Advisor] Root JSON parse failed")
            throw AdvisorError.parseFailed
        }

        if let error = json["error"] as? [String: Any],
           let msg = error["message"] as? String {
            print("[AI Advisor] API error: \(msg)")
            throw AdvisorError.httpError(0, msg)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[AI Advisor] Content missing or empty in response")
            throw AdvisorError.parseFailed
        }

        print("[AI Advisor] Content: \(content.prefix(200))")
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

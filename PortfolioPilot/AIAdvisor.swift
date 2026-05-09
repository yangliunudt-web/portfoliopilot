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
            categoryLines += """
            - \(cat.name): 市值 ¥\(String(format: "%.0f", cat.value)), 占 \(String(format: "%.1f", pct * 100))% (目标 \(String(format: "%.1f", cat.targetRatio * 100))%), 偏离 \(String(format: "%+.1f", deviation * 100))%
            """
        }

        let prompt = """
        你是仓位再平衡助手，给出调仓建议。你的唯一依据是**各品类相对目标比例的偏离程度**。

        \(categoryLines)

        总资产 ¥\(String(format: "%.0f", totalValue))
        阈值：大仓位(≥20%)绝对偏离>\(String(format: "%.0f", absThreshold * 100))%触发，小仓位相对偏离>\(String(format: "%.0f", relThreshold * 100))%触发

        要求：
        1. 找出偏离最大的品类（不管正负），优先调整它
        2. 调整后只须回到阈值以内，不必精确命中目标
        3. 理由必须引用偏离数据，例如"A股偏离+8%，远超5%阈值，是当前最失衡的品类"
        4. 绝不以收益率高低作为理由
        5. 未触发的品类不调整

        回复格式（1-2项）：
        品类：增仓/减仓 约¥xxx
        理由：（偏离数据）
        如全部在阈值内就说"当前无需调整"

        80字以内。
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

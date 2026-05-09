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
            let overThreshold = abs(deviation) > (cat.targetRatio >= 0.20 ? absThreshold : absThreshold * cat.targetRatio / 0.20)
            categoryLines += """
            - \(cat.name): 占 \(String(format: "%.1f", pct * 100))% (目标 \(String(format: "%.1f", cat.targetRatio * 100))%), 偏离 \(String(format: "%+.1f", deviation * 100))%\(overThreshold ? " ⚠触发" : "")
            """
        }

        let prompt = """
        你是再平衡计算器。只处理标记了"触发"的品类，其他不动。

        \(categoryLines)

        总资产 ¥\(String(format: "%.0f", totalValue))
        阈值：大仓(≥20%目标)绝对偏离>\(String(format: "%.0f", absThreshold * 100))%，小仓相对偏离>\(String(format: "%.0f", relThreshold * 100))%

        严格执行：
        1. 触发品类中，正偏离值最大的一个 = 减仓来源
        2. 触发品类中，负偏离值最大的一个 = 加仓目标
        3. 调整金额 = 总资产 × 偏离百分比 的绝对值
        4. 成对输出：一侧减多少、另一侧加多少，金额一致
        5. 不对收益率或市场行情做任何评价

        回复：
        减 [品类]：约¥xxx
        加 [品类]：约¥xxx
        无触发就说"当前无需调整"
        40字以内。
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

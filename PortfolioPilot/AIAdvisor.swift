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
        你是仓位再平衡助手。核心原则：**每一分资金都要有去处，成对操作最快达到平衡**。

        \(categoryLines)

        总资产 ¥\(String(format: "%.0f", totalValue))
        阈值：大仓位(≥20%)绝对偏离>\(String(format: "%.0f", absThreshold * 100))%触发，小仓位相对偏离>\(String(format: "%.0f", relThreshold * 100))%触发

        要求：
        1. 找出正偏离最大（超配）和负偏离最大（低配）的品类
        2. 建议：从超配品类减仓 → 加到低配品类，形成完整的资金流向
        3. 调整后回到阈值以内即可，不必精确命中
        4. 理由必须引用偏离数据，不对收益率做任何评价

        回复格式：
        减 [超配品类]：约¥xxx
        加 [低配品类]：约¥xxx
        理由：（偏离数据对比）
        如全部在阈值内就说"当前无需调整"

        60字以内。
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

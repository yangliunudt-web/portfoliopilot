import SwiftUI
import AppKit

struct DetectedAsset: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var category: AssetCategory
    var value: Double
    var profit: Double
    var principal: Double { max(0, value - profit) }
}

final class ScreenshotAnalyzer {
    private let baseURL: String
    private let apiKey: String
    private let model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
    }

    func analyze(image: NSImage) async throws -> [DetectedAsset] {
        guard let imageData = resizeAndEncode(image) else {
            throw AnalyzerError.imageEncodingFailed
        }

        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let prompt = """
        你是一个专业的投资组合数据提取助手。请仔细识别图片中所有持仓条目。

        关键规则：
        1. 每行一个资产，提取 name（名称）、value（市值，取最大的数字列）、profit（收益）
        2. profit 提取规则（按优先级）:
           a. 优先取"持有收益"或"持仓收益"列（当前持仓的盈亏）
           b. 如果持有收益为空/不存在，取"累计收益"或"累计盈亏"列
           c. profit 可能是红色正数、绿色负数，或带 − 号的负数，如实保留正负
        3. 如果是余额宝/货币基金，profit 取"累计收益"（因为每天都有正收益）
        4. 如果找遍整个截图都找不到任何盈亏数字，profit 才设为 0
        6. category 只能是: "A股"、"美股"、"贵金属"、"债券"、"现金"

        返回格式：
        {"assets": [{"name": "沪深300ETF", "category": "A股", "value": 50000.00, "profit": 5000.00}]}
        只返回 JSON，不要解释。
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": imageData]]
                    ]
                ]
            ],
            "max_tokens": 2048,
            "temperature": 0.0
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalyzerError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 401 {
                throw AnalyzerError.unauthorized
            }
            throw AnalyzerError.httpError(httpResponse.statusCode, body)
        }

        return try parseResponse(data)
    }

    private func resizeAndEncode(_ image: NSImage) -> String? {
        let maxDim: CGFloat = 1024
        var size = image.size
        if size.width > maxDim || size.height > maxDim {
            let ratio = min(maxDim / size.width, maxDim / size.height)
            size = CGSize(width: size.width * ratio, height: size.height * ratio)
        }

        guard let tiff = image.tiffRepresentation,
              NSBitmapImageRep(data: tiff) != nil else { return nil }

        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let tiff2 = resized.tiffRepresentation,
              let bitmap2 = NSBitmapImageRep(data: tiff2),
              let png = bitmap2.representation(using: .png, properties: [:]) else { return nil }

        return png.base64EncodedString()
    }

    private func parseResponse(_ data: Data) throws -> [DetectedAsset] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AnalyzerError.parseFailed
        }

        // 提取 JSON 块
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let contentData = cleaned.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let assets = result["assets"] as? [[String: Any]] else {
            throw AnalyzerError.parseFailed
        }

        return assets.compactMap { item in
            guard let name = item["name"] as? String,
                  let catStr = item["category"] as? String,
                  let category = AssetCategory(rawValue: catStr),
                  let value = item["value"] as? Double else { return nil }
            let profit = item["profit"] as? Double ?? item["principal"] as? Double ?? 0
            return DetectedAsset(name: name, category: category, value: value, profit: profit)
        }
    }
}

enum AnalyzerError: LocalizedError {
    case imageEncodingFailed
    case invalidResponse
    case unauthorized
    case httpError(Int, String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "图片编码失败"
        case .invalidResponse: return "服务器响应异常"
        case .unauthorized: return "API Key 无效，请在设置中检查"
        case .httpError(let code, _): return "HTTP 错误 (\(code))"
        case .parseFailed: return "AI 返回结果解析失败，请重试"
        }
    }
}

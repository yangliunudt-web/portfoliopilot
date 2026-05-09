import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalAuthentication

struct ScreenshotImportView: View {
    @Environment(\.dismiss) private var dismiss

    var onDataChanged: (() -> Void)? = nil

    @AppStorage("portfolioAssetsV3") private var assetList = AssetList(items: [])
    @AppStorage("totalUserPrincipal") private var totalUserPrincipal: Double = 0
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://open.bigmodel.cn/api/paas/v4"
    @AppStorage("aiModel") private var aiModel = "glm-5v-turbo"

    @State private var image: NSImage?
    @State private var detectedAssets: [DetectedAsset] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var stage: Stage = .input

    enum Stage { case input, preview }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("截图导入").font(.title2).bold()
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding()

            Divider()

            switch stage {
            case .input:
                inputView
            case .preview:
                previewView
            }
        }
        .frame(minWidth: 550, minHeight: 500)
    }

    // MARK: - 输入页

    private var inputView: some View {
        VStack(spacing: 24) {
            Spacer()
            pasteZone
            hintText
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 250)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .contextMenu {
                        Button("清除图片") { image = nil }
                    }
            }
            if let error = errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            actionButton
            Spacer()
        }
        .padding(40)
    }

    private var pasteZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(image != nil ? .green.opacity(0.5) : .secondary.opacity(0.3))
                .frame(height: 140)

            VStack(spacing: 12) {
                Image(systemName: image != nil ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .font(.system(size: 36))
                    .foregroundStyle(image != nil ? .green : .secondary)
                Text(image != nil ? "图片已就绪" : "在此区域 Cmd+V 粘贴截图")
                    .font(.title3)
                    .foregroundStyle(image != nil ? .green : .secondary)
                if image == nil {
                    Button("或点击选择图片文件...") {
                        selectImageFile()
                    }
                    .font(.caption)
                }
            }
        }
        .onPasteCommand(of: [.image]) { providers in
            guard let provider = providers.first else { return }
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                if let data, let img = NSImage(data: data) {
                    DispatchQueue.main.async { self.image = img; self.errorMessage = nil }
                }
            }
        }
    }

    private var hintText: some View {
        Text("支持券商 App、支付宝基金、银行 App 等持仓页面截图。点击识别后使用 Apple Watch 或 Touch ID 验证即可。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.2)
                Text("AI 正在分析截图...").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 8) {
                Button(action: analyzeImage) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("开始识别")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .disabled(image == nil)
                .font(.title3)

                Text("将使用 Apple Watch 或 Touch ID 验证身份")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 预览页

    private var matchedCount: Int {
        detectedAssets.filter { detected in
            assetList.items.contains { existing in
                isAssetNameMatch(existing.name, detected.name)
            }
        }.count
    }
    private var newCount: Int { detectedAssets.count - matchedCount }

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("识别结果").font(.headline)

            HStack(spacing: 16) {
                if matchedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                        Text("\(matchedCount) 项匹配更新").font(.caption)
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.blue.opacity(0.1)).cornerRadius(4)
                }
                if newCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(.caption)
                        Text("\(newCount) 项新增").font(.caption)
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green.opacity(0.1)).cornerRadius(4)
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(detectedAssets) { asset in
                        let matched = assetList.items.first { existing in
                            isAssetNameMatch(existing.name, asset.name)
                        }
                        DetectedAssetRow(asset: asset, matchedExisting: matched)
                    }
                }
            }

            Divider()

            HStack {
                Button("返回重新选择") {
                    stage = .input; detectedAssets = []; errorMessage = nil
                }
                Spacer()
                Button("确认更新 (\(detectedAssets.count) 项)") {
                    applyChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    struct DetectedAssetRow: View {
        let asset: DetectedAsset
        let matchedExisting: AssetItem?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(asset.category.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(asset.name).font(.callout).bold()
                        Text(asset.category.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("市值: \(asset.value, format: .currency(code: "CNY"))")
                            .font(.callout).monospacedDigit()
                        Text("本金: \(asset.principal, format: .currency(code: "CNY"))")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                if let existing = matchedExisting {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                        Text("匹配: \(existing.name)")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Spacer()
                        if abs(existing.value - asset.value) > 0.01 {
                            Text("市值 \(existing.value, format: .currency(code: "CNY")) → \(asset.value, format: .currency(code: "CNY"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.05)).cornerRadius(4)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text("新资产，将自动添加到持仓")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.green.opacity(0.05)).cornerRadius(4)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - 模糊匹配

    /// 判断两个资产名称是否指向同一个资产，支持字号差异、空格、标点等变化
    private func isAssetNameMatch(_ a: String, _ b: String) -> Bool {
        // 归一化：去空格、去标点、小写
        let normalize: (String) -> String = { str in
            str.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "（", with: "")
                .replacingOccurrences(of: "）", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "·", with: "")
        }
        let na = normalize(a)
        let nb = normalize(b)

        // 完全一致或包含关系直接命中
        if na == nb || na.contains(nb) || nb.contains(na) { return true }

        // 字符 bigram Jaccard 相似度
        func bigrams(_ s: String) -> Set<String> {
            let chars = Array(s)
            guard chars.count >= 2 else { return [s] }
            return Set(stride(from: 0, to: chars.count - 1, by: 1).map { String(chars[$0...$0+1]) })
        }
        let bgA = bigrams(na)
        let bgB = bigrams(nb)
        guard !bgA.isEmpty, !bgB.isEmpty else { return false }
        let intersection = bgA.intersection(bgB)
        let union = bgA.union(bgB)
        let jaccard = Double(intersection.count) / Double(union.count)

        return jaccard >= 0.55
    }

    // MARK: - Apple Watch 认证

    private func authenticateWithWatch() async -> Bool {
        let context = LAContext()
        context.localizedReason = "使用 Apple Watch 或 Touch ID 验证身份以识别持仓截图"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            await MainActor.run { errorMessage = "设备不支持生物认证: \(error?.localizedDescription ?? "")" }
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证身份以使用 AI 截图识别")
        } catch {
            await MainActor.run { errorMessage = "验证取消或失败" }
            return false
        }
    }

    // MARK: - 逻辑

    private func analyzeImage() {
        guard let image else { return }
        isLoading = true; errorMessage = nil

        Task {
            // 1. Apple Watch 认证
            guard await authenticateWithWatch() else {
                isLoading = false
                return
            }
            // 2. 读取 KeyChain 中的 API Key
            let key = KeychainManager.load(key: "ai_api_key") ?? ""
            guard !key.isEmpty else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "未配置 API Key，请先在设置中填写"
                }
                return
            }

            // 3. 调用 AI
            do {
                let analyzer = ScreenshotAnalyzer(baseURL: aiBaseURL, apiKey: key, model: aiModel)
                let result = try await analyzer.analyze(image: image)
                await MainActor.run {
                    isLoading = false
                    detectedAssets = result
                    stage = .preview
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyChanges() {
        for detected in detectedAssets {
            // 名称模糊匹配现有资产
            if let idx = assetList.items.firstIndex(where: {
                isAssetNameMatch($0.name, detected.name)
            }) {
                let oldPrin = assetList.items[idx].principal
                assetList.items[idx].value = detected.value
                assetList.items[idx].principal = detected.principal
                totalUserPrincipal = ((totalUserPrincipal - oldPrin + detected.principal) * 100).rounded() / 100
            } else {
                assetList.items.append(AssetItem(name: detected.name, category: detected.category, value: detected.value, principal: detected.principal))
                totalUserPrincipal = ((totalUserPrincipal + detected.principal) * 100).rounded() / 100
            }
        }
        onDataChanged?()
    }

    private func selectImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            image = img; errorMessage = nil
        }
    }
}

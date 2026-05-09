import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScreenshotImportView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("portfolioAssetsV3") private var assetList = AssetList(items: [])
    @AppStorage("totalUserPrincipal") private var totalUserPrincipal: Double = 0
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    @AppStorage("aiModel") private var aiModel = "qwen-vl-max"

    @State private var image: NSImage?
    @State private var detectedAssets: [DetectedAsset] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var stage: Stage = .input

    enum Stage { case input, preview }

    private var apiKey: String {
        KeychainManager.load(key: "ai_api_key") ?? ""
    }

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
        Text("支持券商 App、支付宝基金、银行 App 等持仓页面截图。AI 会自动识别资产名称、大类、市值和本金。")
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
            Button(action: analyzeImage) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("开始识别")
                }
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(image == nil || apiKey.isEmpty)
            .font(.title3)

            if apiKey.isEmpty {
                Text("请先在「设置 → AI 截图识别」中配置 API Key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 预览页

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("识别结果").font(.headline)
            Text("共识别 \(detectedAssets.count) 项资产，请确认后更新").font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(detectedAssets) { asset in
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
            }

            Divider()

            HStack {
                Button("返回重新选择") {
                    stage = .input; detectedAssets = []; errorMessage = nil
                }
                Spacer()
                Button("确认更新") {
                    applyChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    // MARK: - 逻辑

    private func analyzeImage() {
        guard let image else { return }
        isLoading = true; errorMessage = nil

        Task {
            do {
                let analyzer = ScreenshotAnalyzer(baseURL: aiBaseURL, apiKey: apiKey, model: aiModel)
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
                $0.name.localizedCaseInsensitiveContains(detected.name) ||
                detected.name.localizedCaseInsensitiveContains($0.name)
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

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss; @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioRecord.date, order: .reverse) private var allHistory: [PortfolioRecord]
    var resetAction: () -> Void
    var autoSaveManager: AutoSaveManager

    @AppStorage("portfolioAssetsV3") private var assetList = AssetList(items: [])
    @AppStorage("totalUserPrincipal") private var totalUserPrincipal: Double = 0
    @AppStorage("absThreshold") private var absThreshold: Double = 0.05
    @AppStorage("relThreshold") private var relThreshold: Double = 0.25
    @AppStorage("bondTarget") private var bondTarget = 0.50; @AppStorage("nasdaqTarget") private var nasdaqTarget = 0.15; @AppStorage("goldTarget") private var goldTarget = 0.15; @AppStorage("csiTarget") private var csiTarget = 0.10; @AppStorage("cashTarget") private var cashTarget = 0.10

    @State private var showResetAlert = false; @State private var showExporter = false; @State private var showImporter = false
    @State private var backupDocument: BackupDocument?; @State private var showImportSuccess = false
    @State private var newAssetName = ""; @State private var newAssetCategory: AssetCategory = .usStocks
    @State private var newAssetValue: Double? = nil; @State private var newAssetPrincipal: Double? = nil
    @State private var assetToDelete: AssetItem? = nil

    @AppStorage("aiBaseURL") private var aiBaseURL = "https://open.bigmodel.cn/api/paas/v4"
    @AppStorage("aiModel") private var aiModel = "glm-5v-turbo"
    @AppStorage("aiTextModel") private var aiTextModel = "glm-4-flash"
    @AppStorage("ai_api_key") private var apiKey = ""
    @State private var apiKeyInput = ""
    @State private var keyRevealed = false
    @State private var testResult: String?

    var totalTarget: Double { bondTarget + nasdaqTarget + goldTarget + csiTarget + cashTarget }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                addAssetSection
                manageAssetsSection
                thresholdSection
                autoBackupSection
                aiSection
                dataManagementSection
            }
            .formStyle(.grouped).navigationTitle("设置").toolbar { ToolbarItem { Button("完成") { dismiss() } } }
            .alert("确认删除该资产？", isPresented: Binding(get: { assetToDelete != nil }, set: { if !$0 { assetToDelete = nil } }), presenting: assetToDelete) { asset in
                Button("取消", role: .cancel) { assetToDelete = nil }
                Button("删除", role: .destructive) {
                    if let idx = assetList.items.firstIndex(where: { $0.id == asset.id }) {
                        let prinToRemove = assetList.items[idx].principal
                        totalUserPrincipal = ((totalUserPrincipal - prinToRemove) * 100).rounded() / 100
                        assetList.items.remove(at: idx)
                    }
                    assetToDelete = nil
                }
            } message: { asset in Text("删除「\(asset.name)」会同步扣除其对应的外部投入本金，此操作不可撤销。") }
            .alert("确认清空？", isPresented: $showResetAlert) { Button("取消", role: .cancel) { }; Button("清空", role: .destructive) { resetAction(); dismiss() } }
            .fileExporter(isPresented: $showExporter, document: backupDocument, contentType: .json, defaultFilename: "PortfolioBackup.json") { _ in }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else {
                        print("Failed to access file: \(url)")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    guard let data = try? Data(contentsOf: url) else {
                        print("Failed to read file data from: \(url)")
                        return
                    }

                    guard let backup = try? JSONDecoder().decode(BackupData.self, from: data) else {
                        print("Failed to decode backup JSON from: \(url)")
                        print("   File size: \(data.count) bytes")
                        return
                    }

                    restoreData(from: backup)
                    showImportSuccess = true
                    print("Backup imported successfully")

                case .failure(let error):
                    print("File import error: \(error.localizedDescription)")
                }
            }
            .alert("导入成功", isPresented: $showImportSuccess) { Button("OK") { dismiss() } }
        }.frame(minWidth: 450, minHeight: 650)
        .onAppear {
            // 从 Keychain 迁移到 @AppStorage（仅首次）
            if apiKey.isEmpty, let oldKey = KeychainManager.load(key: "ai_api_key"), !oldKey.isEmpty {
                apiKey = oldKey
                KeychainManager.delete(key: "ai_api_key")
            }
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        Section(header: Text("大类目标比例 (需满100%)"), footer: Text("当前比例总计: \(totalTarget, format: .percent)").foregroundStyle(abs(totalTarget - 1.0) < 0.001 ? .green : .red)) {
            HStack { Text("A股"); Spacer(); TextField("%", value: $csiTarget, format: .percent).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(.roundedBorder) }
            HStack { Text("美股"); Spacer(); TextField("%", value: $nasdaqTarget, format: .percent).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(.roundedBorder) }
            HStack { Text("贵金属"); Spacer(); TextField("%", value: $goldTarget, format: .percent).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(.roundedBorder) }
            HStack { Text("债券"); Spacer(); TextField("%", value: $bondTarget, format: .percent).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(.roundedBorder) }
            HStack { Text("现金"); Spacer(); TextField("%", value: $cashTarget, format: .percent).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(.roundedBorder) }
        }
    }

    @ViewBuilder
    private var addAssetSection: some View {
        Section(header: Text("新增具体资产")) {
            HStack { Text("名称:").frame(width: 40, alignment: .trailing); TextField("如: 标普500 ETF", text: $newAssetName) }
            HStack { Text("归属:").frame(width: 40, alignment: .trailing); Picker("", selection: $newAssetCategory) { ForEach(AssetCategory.allCases) { cat in Text(cat.rawValue).tag(cat) } }.pickerStyle(.menu).labelsHidden() }
            HStack { Text("市值:").frame(width: 40, alignment: .trailing); TextField("初始数值 (可选)", value: $newAssetValue, format: .number.precision(.fractionLength(0...2))) }
            HStack { Text("本金:").frame(width: 40, alignment: .trailing); TextField("初始投入 (可选)", value: $newAssetPrincipal, format: .number.precision(.fractionLength(0...2))) }
            HStack {
                Spacer()
                Button("确认添加") {
                    guard !newAssetName.isEmpty else { return }
                    let rValue = ((newAssetValue ?? 0) * 100).rounded() / 100; let rPrin = ((newAssetPrincipal ?? 0) * 100).rounded() / 100
                    assetList.items.append(AssetItem(name: newAssetName, category: newAssetCategory, value: rValue, principal: rPrin))
                    totalUserPrincipal = ((totalUserPrincipal + rPrin) * 100).rounded() / 100
                    newAssetName = ""; newAssetValue = nil; newAssetPrincipal = nil
                }.buttonStyle(.borderedProminent).disabled(newAssetName.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var manageAssetsSection: some View {
        Section(header: Text("已有资产管理"), footer: Text("名称可直接编辑，点击垃圾桶删除资产。")) {
            ForEach($assetList.items) { $asset in
                HStack {
                    Circle().fill(asset.category.color).frame(width: 8, height: 8)
                    TextField("名称", text: $asset.name)
                        .textFieldStyle(.plain)
                        .bold()
                        .frame(minWidth: 60)
                    Text("(\(asset.category.rawValue))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(asset.value, format: .currency(code: "CNY")).font(.caption).monospacedDigit()
                    Button { assetToDelete = asset } label: { Image(systemName: "trash").foregroundColor(.red) }.buttonStyle(.plain).padding(.leading, 10)
                }
            }
        }
    }

    @ViewBuilder
    private var thresholdSection: some View {
        Section("再平衡阈值") {
            HStack { Text("重仓绝对阈值"); Spacer(); Text(absThreshold, format: .percent).foregroundStyle(.secondary); Stepper("", value: $absThreshold, in: 0...1, step: 0.01).labelsHidden() }
            HStack { Text("轻仓相对阈值"); Spacer(); Text(relThreshold, format: .percent).foregroundStyle(.secondary); Stepper("", value: $relThreshold, in: 0...1, step: 0.05).labelsHidden() }
        }
    }

    @ViewBuilder
    private var autoBackupSection: some View {
        Section {
            Toggle("启用自动备份", isOn: Binding(
                get: { autoSaveManager.autoSaveEnabled },
                set: { autoSaveManager.autoSaveEnabled = $0 }
            ))
            if autoSaveManager.autoSaveEnabled {
                HStack {
                    Text("静默等待时长")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { autoSaveManager.autoSaveIntervalMinutes },
                        set: { autoSaveManager.autoSaveIntervalMinutes = $0 }
                    )) {
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                Toggle("同时导出文件", isOn: Binding(
                    get: { autoSaveManager.autoBackupEnabled },
                    set: { autoSaveManager.autoBackupEnabled = $0 }
                ))
                if autoSaveManager.autoBackupEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("备份目录")
                            Spacer()
                            Button("选择文件夹...") { selectBackupDirectory() }
                                .font(.caption)
                        }
                        Text(autoSaveManager.autoBackupDirectory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let lastSave = autoSaveManager.lastAutoSaveTime {
                HStack {
                    Text("上次备份")
                    Spacer()
                    Text(lastSave, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("自动备份")
        } footer: {
            if autoSaveManager.autoSaveEnabled {
                Text("检测到数据变更后，静默等待上述时长，期间无新变更则自动执行一次备份。手动保存快照或执行资金调度时会立即备份。")
            }
        }
    }

    private func selectBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择备份目录"
        panel.message = "自动备份文件将保存到此目录"
        if panel.runModal() == .OK, let url = panel.url {
            autoSaveManager.autoBackupDirectory = url.path
        }
    }

    // MARK: - AI 截图识别

    @ViewBuilder
    private var aiSection: some View {
        Section {
            HStack {
                Text("API 地址")
                Spacer()
                TextField("https://...", text: $aiBaseURL)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .font(.caption)
            }
            HStack {
                Text("视觉模型")
                Spacer()
                TextField("glm-5v-turbo", text: $aiModel)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.caption)
            }
            HStack {
                Text("文本模型")
                Spacer()
                TextField("glm-4-flash", text: $aiTextModel)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.caption)
            }
            HStack {
                Text("API Key")
                Spacer()
                SecureField("点击「查看」以显示", text: $apiKeyInput)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .font(.caption)
                    .disabled(!keyRevealed)
                Button(keyRevealed ? "保存" : "查看") {
                    if keyRevealed {
                        apiKey = apiKeyInput
                        keyRevealed = false
                    } else {
                        apiKeyInput = apiKey
                        keyRevealed = true
                    }
                }.font(.caption2)
            }
            HStack {
                Spacer()
                Button("测试连接") { testAIConnection() }
                    .font(.caption)
                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("成功") ? .green : .red)
                }
            }
        } header: {
            Text("AI 截图识别")
        } footer: {
            Text("视觉模型用于截图识别，文本模型用于 AI 投资建议。支持所有 OpenAI 兼容接口。")
        }
    }

    private func testAIConnection() {
        guard !apiKey.isEmpty, !aiBaseURL.isEmpty else {
            testResult = "请填写 API 地址和 Key"
            return
        }
        testResult = nil
        Task {
            do {
                let base = aiBaseURL.hasSuffix("/") ? String(aiBaseURL.dropLast()) : aiBaseURL
                guard let url = URL(string: "\(base)/chat/completions") else {
                    await MainActor.run { testResult = "无效的 API 地址" }
                    return
                }
                print("[AI Test] URL: \(url.absoluteString)")
                print("[AI Test] Model: \(aiModel)")

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15

                // GLM-5V-Turbo 是视觉模型，需要携带图片才能正常响应
                let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                let body: [String: Any] = [
                    "model": aiModel,
                    "messages": [
                        [
                            "role": "user",
                            "content": [
                                ["type": "text", "text": "回复 OK"],
                                ["type": "image_url", "image_url": ["url": tinyPNG]]
                            ]
                        ]
                    ],
                    "max_tokens": 20
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let respBody = String(data: data, encoding: .utf8) ?? ""
                print("[AI Test] Status: \(code), Body: \(respBody.prefix(500))")

                await MainActor.run {
                    if code == 200 {
                        testResult = "连接成功，模型正常响应"
                    } else {
                        let msg = extractAPIError(from: data, body: respBody, code: code)
                        testResult = msg
                    }
                }
            } catch {
                print("[AI Test] Error: \(error)")
                let msg = error.localizedDescription
                await MainActor.run {
                    if let urlErr = error as? URLError, urlErr.code == .cannotFindHost {
                        testResult = "无法解析 API 地址，请检查域名"
                    } else if let urlErr = error as? URLError, urlErr.code == .secureConnectionFailed {
                        testResult = "SSL/TLS 连接失败，请检查 API 地址是否为 https"
                    } else if error.localizedDescription.contains("cancelled") {
                        testResult = "连接超时，请检查网络或 API 地址"
                    } else {
                        testResult = "连接失败: \(msg)"
                    }
                }
            }
        }
    }

    private func extractAPIError(from data: Data, body: String, code: Int) -> String {
        // 优先解析 JSON 中的错误字段
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                return "\(msg)"
            }
            if let err = json["error"] as? String {
                return "\(err)"
            }
            if let msg = json["msg"] as? String {
                return "\(msg)"
            }
            if let message = json["message"] as? String {
                return "\(message)"
            }
        }
        // 回退
        if body.isEmpty { return "HTTP \(code) — 无响应内容" }
        return "HTTP \(code): \(String(body.prefix(200)))"
    }

    @ViewBuilder
    private var dataManagementSection: some View {
        Section("数据管理") {
            Button { prepareExport() } label: { Label("导出备份数据", systemImage: "square.and.arrow.up") }
            Button { showImporter = true } label: { Label("导入备份数据", systemImage: "square.and.arrow.down") }
            NavigationLink("历史记录管理") { List { ForEach(allHistory) { item in HStack { Text(item.date, format: .dateTime.month().day().hour().minute()); Spacer(); VStack(alignment: .trailing) { Text("资: \(item.totalValue, format: .currency(code: "CNY"))"); Text("本: \(item.principal, format: .currency(code: "CNY"))").font(.caption).foregroundStyle(.secondary) } } }.onDelete { idx in for i in idx { modelContext.delete(allHistory[i]) } } } }
        }
        Section { Button(role: .destructive) { showResetAlert = true } label: { HStack { Image(systemName: "trash"); Text("清空所有数据") } } } footer: { Text("将删除历史记录并重置所有资产").font(.caption) }
    }

    func prepareExport() { let h = allHistory.map { HistoryItemJSON(date: $0.date, totalValue: $0.totalValue, principal: $0.principal, assetSnapshot: $0.assetSnapshot) }; backupDocument = BackupDocument(backupData: BackupData(totalUserPrincipal: totalUserPrincipal, absThreshold: absThreshold, relThreshold: relThreshold, history: h, assetList: assetList)); showExporter = true }

    func restoreData(from backup: BackupData) { resetAction(); totalUserPrincipal = backup.totalUserPrincipal; absThreshold = backup.absThreshold; relThreshold = backup.relThreshold; if let importedList = backup.assetList { assetList = importedList }; for item in backup.history { modelContext.insert(PortfolioRecord(backupItem: item)) } }
}

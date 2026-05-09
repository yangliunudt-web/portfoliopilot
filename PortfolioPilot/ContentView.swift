import SwiftUI
import SwiftData
import Charts

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioRecord.date, order: .reverse) private var history: [PortfolioRecord]

    @AppStorage("portfolioAssetsV3") private var assetList = AssetList(items: [])
    @AppStorage("totalUserPrincipal") private var totalUserPrincipal: Double = 0
    @AppStorage("absThreshold") private var absThreshold: Double = 0.05
    @AppStorage("relThreshold") private var relThreshold: Double = 0.25

    @AppStorage("bondTarget") private var bondTarget = 0.50
    @AppStorage("nasdaqTarget") private var nasdaqTarget = 0.15
    @AppStorage("goldTarget") private var goldTarget = 0.15
    @AppStorage("csiTarget") private var csiTarget = 0.10
    @AppStorage("cashTarget") private var cashTarget = 0.10

    @AppStorage("hasMigratedToV3") private var hasMigratedToV3: Bool = false
    @AppStorage("bondValue") private var oldBondValue: Double = 0; @AppStorage("bondPrincipal") private var oldBondPrincipal: Double = 0
    @AppStorage("nasdaqValue") private var oldNasdaqValue: Double = 0; @AppStorage("nasdaqPrincipal") private var oldNasdaqPrincipal: Double = 0
    @AppStorage("goldValue") private var oldGoldValue: Double = 0; @AppStorage("goldPrincipal") private var oldGoldPrincipal: Double = 0
    @AppStorage("csiValue") private var oldCsiValue: Double = 0; @AppStorage("csiPrincipal") private var oldCsiPrincipal: Double = 0
    @AppStorage("cashValue") private var oldCashValue: Double = 0; @AppStorage("cashPrincipal") private var oldCashPrincipal: Double = 0

    @State private var inputAmount: Double? = nil
    @State private var operationMode: OperationMode = .invest
    @State private var calculationResult: SmartCalculationResult?
    @State private var showSettings = false
    @State private var showScreenshotImport = false
    @State private var showRebalanceConfirm = false
    @State private var rebalancePlan: SmartCalculationResult?

    @State private var rawSelectedPieValue: Double?
    @State private var pinnedCategoryName: String? = nil
    @State private var rawSelectedDate: Date?
    @State private var rangeSelection: ClosedRange<Date>? = nil
    @State private var isDraggingRange = false

    @State private var selectedTimeRange: ChartTimeRange = .oneMonth
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

    @State private var autoSaveManager = AutoSaveManager()

    // AI 投资建议
    @State private var aiAdvice: String?
    @State private var isLoadingAdvice = false
    @State private var aiScheduleSuggestion: String?
    @State private var isLoadingScheduleAI = false
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://open.bigmodel.cn/api/paas/v4"
    @AppStorage("aiModel") private var aiModel = "glm-5v-turbo"
    @AppStorage("ai_api_key") private var apiKey = ""
    @AppStorage("aiTextModel") private var aiTextModel = "glm-4-flash"

    enum OperationMode: String, CaseIterable {
        case invest = "追加投资"
        case withdraw = "资金提现"
    }

    var currentTotalValue: Double { assetList.items.reduce(0) { $0 + $1.value } }

    var validChartData: [PortfolioRecord] {
        history.filter { $0.totalValue > 0 }.sorted { $0.date < $1.date }
    }

    var currentHoveredSector: (name: String, value: Double, percentage: Double)? {
        guard let sel = rawSelectedPieValue else { return nil }
        let catData = AssetCategory.allCases.map { cat in
            (name: cat.rawValue, value: assetList.items.filter { $0.category == cat }.reduce(0) { $0 + $1.value })
        }.filter { $0.value > 0 }

        var accumulated = 0.0
        let total = currentTotalValue
        for item in catData {
            let next = accumulated + item.value
            if sel >= accumulated && sel <= next {
                return (item.name, item.value, total > 0 ? item.value / total : 0)
            }
            accumulated = next
        }
        return nil
    }

    var activeCategoryName: String? {
        pinnedCategoryName ?? currentHoveredSector?.name
    }

    var currentChartDomain: ClosedRange<Date> {
        let end = selectedTimeRange == .custom ? customEndDate : Date()
        var start: Date

        switch selectedTimeRange {
        case .oneMinute: start = Calendar.current.date(byAdding: .minute, value: -1, to: end) ?? end
        case .oneDay: start = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
        case .oneWeek: start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        case .twoWeeks: start = Calendar.current.date(byAdding: .day, value: -14, to: end) ?? end
        case .oneMonth: start = Calendar.current.date(byAdding: .month, value: -1, to: end) ?? end
        case .oneQuarter: start = Calendar.current.date(byAdding: .month, value: -3, to: end) ?? end
        case .oneYear: start = Calendar.current.date(byAdding: .year, value: -1, to: end) ?? end
        case .custom: start = customStartDate
        case .all:
            start = validChartData.first?.date ?? Calendar.current.date(byAdding: .month, value: -1, to: end) ?? end
        }

        if start >= end { start = Calendar.current.date(byAdding: .minute, value: -1, to: end) ?? end }
        return start...end
    }

    var chartDataPoints: [ChartDataPoint] {
        if validChartData.isEmpty { return [] }

        let domain = currentChartDomain
        var baseRecords = validChartData.filter { $0.date >= domain.lowerBound && $0.date <= domain.upperBound }

        if let firstBefore = validChartData.last(where: { $0.date < domain.lowerBound }) {
            baseRecords.insert(firstBefore, at: 0)
        }

        var points = baseRecords.map { item -> ChartDataPoint in
            let vals = historyData(for: item)
            return ChartDataPoint(date: item.date, value: vals.value, principal: vals.principal)
        }

        if let last = points.last, last.date < domain.upperBound {
            points.append(ChartDataPoint(date: domain.upperBound, value: last.value, principal: last.principal))
        }

        return points
    }

    var selectedChartRecord: ChartDataPoint? {
        if let rawSelectedDate {
            return chartDataPoints.min(by: { abs($0.date.timeIntervalSince(rawSelectedDate)) < abs($1.date.timeIntervalSince(rawSelectedDate)) })
        } else {
            return chartDataPoints.last
        }
    }

    var rangeStats: (start: ChartDataPoint, end: ChartDataPoint, valueChange: Double, principalChange: Double, yield: Double, annualizedYield: Double)? {
        guard let range = rangeSelection else { return nil }
        let points = chartDataPoints
        guard points.count >= 2 else { return nil }

        // 找区间前后最近的数据点（确保一定有结果）
        let beforeIdx = points.lastIndex(where: { $0.date <= range.lowerBound }) ?? 0
        let afterIdx = points.firstIndex(where: { $0.date >= range.upperBound }) ?? (points.count - 1)
        let baselineIdx = max(0, beforeIdx)
        let endpointIdx = min(points.count - 1, afterIdx)

        let startPoint = points[baselineIdx]
        let endPoint = points[endpointIdx]

        let valueChange = endPoint.value - startPoint.value
        let principalChange = endPoint.principal - startPoint.principal

        let yield: Double
        if endPoint.principal > 0 {
            yield = (endPoint.value - endPoint.principal) / endPoint.principal
        } else if startPoint.value > 0 {
            yield = (endPoint.value - startPoint.value) / startPoint.value
        } else {
            yield = 0
        }

        let days = max(1, endPoint.date.timeIntervalSince(startPoint.date) / (24 * 60 * 60))
        let annualizedYield: Double
        if startPoint.value > 0 && endPoint.value > 0 {
            let totalReturn = endPoint.value / startPoint.value - 1
            annualizedYield = pow(1 + totalReturn, 365 / days) - 1
        } else {
            annualizedYield = 0
        }

        return (start: startPoint, end: endPoint, valueChange: valueChange, principalChange: principalChange, yield: yield, annualizedYield: annualizedYield)
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .onAppear {
            migrateOldDataIfNeeded()
            autoSaveManager.modelContext = modelContext
            // Keychain → @AppStorage 迁移
            if apiKey.isEmpty, let oldKey = KeychainManager.load(key: "ai_api_key"), !oldKey.isEmpty {
                apiKey = oldKey
                KeychainManager.delete(key: "ai_api_key")
            }
        }
    }

    // MARK: - 侧边栏

    private var sidebarContent: some View {
        Form {
            Section {
                Button(action: { showScreenshotImport = true }) {
                    Label("截图导入", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.borderless)
            }
            fundingSection
            positionSection
        }
        .formStyle(.grouped)
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button(action: { showSettings = true }) { Label("设置", systemImage: "gearshape") } } }
        .sheet(isPresented: $showSettings) { SettingsView(resetAction: resetAllData, autoSaveManager: autoSaveManager) }
        .sheet(isPresented: $showScreenshotImport) {
            ScreenshotImportView(onDataChanged: { saveRecord(); autoSaveManager.saveImmediately() })
        }
    }

    private var fundingSection: some View {
        Section(header: Text("资金调度").font(.headline)) {
            Picker("操作", selection: $operationMode) { ForEach(OperationMode.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
            HStack {
                Text("¥").foregroundStyle(.secondary).font(.title2)
                TextField("金额", value: $inputAmount, format: .number.precision(.fractionLength(0...2))).textFieldStyle(.plain).font(.title2)
                    .onChange(of: inputAmount) { _, val in if let val = val { calculatePreview(amount: val) } else { calculationResult = nil } }
                    .onChange(of: operationMode) { _, _ in if let val = inputAmount { calculatePreview(amount: val) } }
            }.padding(10).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))

            if let result = calculationResult, let amount = inputAmount, amount > 0 {
                StrategyPreviewCard(
                    result: result,
                    assetList: assetList.items,
                    onConfirm: { applySmartPlan(result: result, amount: amount) },
                    onAIOptimize: { fetchScheduleAI(result: result, amount: amount) },
                    aiSuggestion: aiScheduleSuggestion,
                    aiLoading: isLoadingScheduleAI
                )
            }
        }
    }

    func principalBinding(for id: UUID) -> Binding<Double> {
        Binding<Double>(
            get: { guard let idx = assetList.items.firstIndex(where: { $0.id == id }) else { return 0 }; return assetList.items[idx].principal },
            set: { newValue in
                guard let idx = assetList.items.firstIndex(where: { $0.id == id }) else { return }
                let roundedNewValue = (newValue * 100).rounded() / 100
                let diff = roundedNewValue - assetList.items[idx].principal
                assetList.items[idx].principal = roundedNewValue
                totalUserPrincipal = ((totalUserPrincipal + diff) * 100).rounded() / 100
                autoSaveManager.notifyDataChanged()
            }
        )
    }

    func valueBinding(for id: UUID) -> Binding<Double> {
        Binding<Double>(
            get: { guard let idx = assetList.items.firstIndex(where: { $0.id == id }) else { return 0 }; return assetList.items[idx].value },
            set: { newValue in
                guard let idx = assetList.items.firstIndex(where: { $0.id == id }) else { return }
                assetList.items[idx].value = (newValue * 100).rounded() / 100
                autoSaveManager.notifyDataChanged()
            }
        )
    }

    private var positionSection: some View {
        Section(header: Text("持仓分布").font(.headline)) {
            ForEach(AssetCategory.allCases) { category in
                let itemsInCategory = assetList.items.filter { $0.category == category }
                if !itemsInCategory.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(category.rawValue).font(.caption).bold().foregroundStyle(category.color)
                        ForEach(itemsInCategory) { item in
                            DualInputRow(name: item.name, value: valueBinding(for: item.id), principal: principalBinding(for: item.id), color: category.color)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            Divider()
            HStack {
                Text("外部总投入").bold(); Spacer()
                Text(totalUserPrincipal, format: .currency(code: "CNY")).font(.body.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4).background(Color(nsColor: .controlBackgroundColor).opacity(0.5)).cornerRadius(4)
            }
            Button("保存快照") { saveRecord(); autoSaveManager.saveImmediately() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding(.top, 5)

            if autoSaveManager.autoSaveEnabled, let lastTime = autoSaveManager.lastAutoSaveTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.caption2)
                    Text("上次自动备份: \(lastTime, format: .dateTime.hour().minute().second())")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 详情区

    private var detailContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                StatsDashboardView(totalValue: currentTotalValue, userPrincipal: totalUserPrincipal)
                if currentTotalValue > 0 {
                    let check = checkRebalanceNeed(total: currentTotalValue)
                    if check.isNeeded { RebalanceAlertView(deviations: check.deviations) { prepareRebalancePlan() } }
                    aiAdviceCard
                }
                HStack(alignment: .top, spacing: 20) {
                    pieChartSection
                    lineChartSection
                }
            }
            .padding()
        }
        .alert("确认执行再平衡？", isPresented: $showRebalanceConfirm) {
            Button("取消", role: .cancel) { }; Button("执行并更新") { if let plan = rebalancePlan { applySmartPlan(result: plan, amount: 0) } }
        } message: { if let plan = rebalancePlan { Text(plan.description) } }
    }

    // MARK: - 饼图

    private var pieChartSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("大类资产分布").font(.headline).foregroundStyle(.secondary)
            if currentTotalValue > 0 {
                let catData = AssetCategory.allCases.map { cat in
                    (name: cat.rawValue, value: assetList.items.filter { $0.category == cat }.reduce(0) { $0 + $1.value })
                }.filter { $0.value > 0 }

                Chart(catData, id: \.name) { item in
                    SectorMark(angle: .value("Value", item.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(AssetCategory(rawValue: item.name)?.color ?? .gray).cornerRadius(4)
                        .opacity(activeCategoryName == item.name ? 1.0 : (activeCategoryName == nil ? 1.0 : 0.3))
                }
                .chartAngleSelection(value: $rawSelectedPieValue)
                .onTapGesture {
                    if let hovered = currentHoveredSector {
                        pinnedCategoryName = (pinnedCategoryName == hovered.name) ? nil : hovered.name
                    } else {
                        pinnedCategoryName = nil
                    }
                }
                .frame(height: 240)
                .overlay {
                    VStack {
                        if let catName = activeCategoryName, let catVal = catData.first(where: { $0.name == catName })?.value {
                            Text(catName).font(.callout).foregroundStyle(.secondary)
                            Text(catVal, format: .currency(code: "CNY")).font(.title3).bold().contentTransition(.numericText())
                            Text(catVal / currentTotalValue, format: .percent.precision(.fractionLength(1)))
                                .font(.caption).foregroundStyle(AssetCategory(rawValue: catName)?.color ?? .secondary).padding(.top, 1)

                            Text(pinnedCategoryName != nil ? "(已固定，点击取消)" : "(点击图表固定走势)")
                                .font(.system(size: 10)).foregroundStyle(pinnedCategoryName != nil ? .blue : .gray.opacity(0.6)).padding(.top, 2)
                        } else {
                            Text("总资产").font(.callout).foregroundStyle(.secondary)
                            Text(currentTotalValue, format: .currency(code: "CNY")).font(.title3).bold().contentTransition(.numericText())
                            Text("(悬停/点击查看分类)")
                                .font(.system(size: 10)).foregroundStyle(.gray.opacity(0.6)).padding(.top, 2)
                        }
                    }
                    .contentShape(Circle())
                    .onTapGesture { pinnedCategoryName = nil }
                }
                Divider()
                VStack(spacing: 0) {
                    ForEach(AssetCategory.allCases) { cat in
                        let items = assetList.items.filter { $0.category == cat }
                        if !items.isEmpty {
                            let totalVal = items.reduce(0) { $0 + $1.value }
                            let totalPrin = items.reduce(0) { $0 + $1.principal }
                            AssetDetailRow(name: cat.rawValue, value: totalVal, principal: totalPrin, color: cat.color)
                        }
                    }
                }
            }
        }.padding().background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12).frame(maxWidth: 320)
    }

    // MARK: - 折线图

    private var lineChartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            chartHeader
            chartBody
            timeRangePicker
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chartHeader: some View {
        let displayRecord = selectedChartRecord
        let displayVal = displayRecord?.value ?? 0
        let displayPrin = displayRecord?.principal ?? 0
        let displayProfit = displayVal - displayPrin
        let titleName = activeCategoryName ?? "总资产"
        let catColor = activeCategoryName.flatMap { AssetCategory(rawValue: $0)?.color } ?? Color(hex: "#00C7BE")

        HStack(alignment: .bottom) {
            VStack(alignment: .leading) {
                Text(displayRecord?.date ?? Date.now, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    VStack(alignment: .leading) {
                        Text(titleName).font(.caption2).foregroundStyle(.secondary)
                        Text(displayVal, format: .currency(code: "CNY")).font(.title3).bold().foregroundStyle(catColor)
                    }
                    VStack(alignment: .leading) {
                        Text("投入本金").font(.caption2).foregroundStyle(.secondary)
                        Text(displayPrin, format: .currency(code: "CNY")).font(.title3).bold().foregroundStyle(.gray)
                    }
                    VStack(alignment: .leading) {
                        Text("浮动盈亏").font(.caption2).foregroundStyle(.secondary)
                        Text(displayProfit > 0 ? "+\(displayProfit.formatted(.currency(code: "CNY")))" : displayProfit.formatted(.currency(code: "CNY"))).font(.title3).bold().foregroundStyle(displayProfit >= 0 ? .red : .green)
                    }
                }
            }
            Spacer()
            HStack(spacing: 15) {
                HStack(spacing: 4) { Circle().fill(catColor).frame(width: 6, height: 6); Text(titleName).font(.caption) }
                HStack(spacing: 4) { Rectangle().fill(Color.gray).frame(width: 12, height: 2); Text("本金").font(.caption) }
            }
        }.padding(.bottom, 10)
    }

    @ViewBuilder
    private var chartBody: some View {
        let points = chartDataPoints
        if points.isEmpty {
            ContentUnavailableView("该时间段无数据", systemImage: "chart.xyaxis.line").frame(height: 350)
        } else {
            let catColor = activeCategoryName.flatMap { AssetCategory(rawValue: $0)?.color } ?? Color(hex: "#00C7BE")

            let allValues = points.flatMap { [$0.value, $0.principal] }
            let minY = max(0, (allValues.min() ?? 0) * 0.85)
            let maxY = (allValues.max() ?? 100) * 1.05
            let domainMin = minY
            let domainMax = maxY

            let lastPoint = points.last
            // 跳过连续相同值（回退数据），找第一个真正变化的点
            let firstChangedPoint = points.first(where: { p in
                guard p.value > 0 else { return false }
                if let idx = points.firstIndex(where: { $0.id == p.id }), idx + 1 < points.count {
                    return points[idx + 1].value != p.value
                }
                return true
            })
            let firstPoint = firstChangedPoint ?? points.first(where: { $0.value > 0 })
            let totalChange: Double = {
                guard let f = firstPoint, let l = lastPoint, abs(l.value - f.value) > 0.01 else { return 0 }
                if f.principal > 0 && f.principal != l.principal {
                    return (l.value / l.principal) - (f.value / f.principal)
                } else if f.value > 0 {
                    return (l.value / f.value) - 1
                }
                return 0
            }()

            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Chart {
                            // 本金虚线
                            ForEach(points) { point in
                                LineMark(x: .value("Date", point.date), y: .value("Principal", point.principal), series: .value("Type", "本金"))
                                    .interpolationMethod(.stepCenter)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                                    .foregroundStyle(.gray.opacity(0.6))
                            }

                            // 市值面积渐变
                            ForEach(points) { point in
                                AreaMark(
                                    x: .value("Date", point.date),
                                    yStart: .value("Min", domainMin),
                                    yEnd: .value("Value", point.value)
                                )
                                .interpolationMethod(.stepCenter)
                                .foregroundStyle(LinearGradient(
                                    colors: [catColor.opacity(0.5), catColor.opacity(0.1), .clear],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            }

                            // 市值主线
                            ForEach(points) { point in
                                LineMark(x: .value("Date", point.date), y: .value("Value", point.value), series: .value("Type", "市值"))
                                    .interpolationMethod(.stepCenter)
                                    .foregroundStyle(catColor)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                            }

                            // 鼠标竖线
                            if let sel = rawSelectedDate {
                                RuleMark(x: .value("Selected", sel))
                                    .foregroundStyle(Color.secondary.opacity(0.4))
                                    .lineStyle(StrokeStyle(lineWidth: 1))
                            }

                            // 框选高亮
                            if let range = rangeSelection {
                                RectangleMark(
                                    xStart: .value("RangeStart", range.lowerBound),
                                    xEnd: .value("RangeEnd", range.upperBound),
                                    yStart: .value("YMin", domainMin),
                                    yEnd: .value("YMax", domainMax)
                                )
                                .foregroundStyle(isDraggingRange ? Color.blue.opacity(0.15) : Color.blue.opacity(0.08))
                            }
                        }
                        .chartPlotStyle { plotArea in
                            plotArea.clipped()
                        }
                        .chartLegend(.hidden)
                        .chartXSelection(value: $rawSelectedDate)
                        .chartXScale(domain: currentChartDomain)
                        .chartYScale(domain: domainMin...domainMax)
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [4, 4]))
                                    .foregroundStyle(Color.gray.opacity(0.25))
                                AxisValueLabel()
                                    .font(.system(size: 10))
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: max(4, min(8, points.count / 2)))) { value in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4))
                                    .foregroundStyle(Color.gray.opacity(0.2))
                                AxisValueLabel {
                                    if let date = value.as(Date.self) {
                                        switch selectedTimeRange {
                                        case .oneMinute:
                                            Text(date, format: .dateTime.hour().minute().second())
                                        case .oneDay:
                                            Text(date, format: .dateTime.hour().minute())
                                        case .oneWeek, .twoWeeks:
                                            Text(date, format: .dateTime.month().day().hour())
                                        case .oneMonth, .oneQuarter:
                                            Text(date, format: .dateTime.month().day())
                                        case .oneYear, .all:
                                            Text(date, format: .dateTime.month())
                                        case .custom:
                                            Text(date, format: .dateTime.month().day())
                                        }
                                    }
                                }
                                .font(.system(size: 9))
                            }
                        }
                        .chartOverlay { _ in
                            GeometryReader { geo in
                                Color.clear.contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 2)
                                            .onChanged { value in
                                                isDraggingRange = true
                                                let pts = chartDataPoints
                                                guard pts.count >= 2, geo.size.width > 0 else { return }
                                                let r1 = max(0, min(1, value.startLocation.x / geo.size.width))
                                                let r2 = max(0, min(1, value.location.x / geo.size.width))
                                                let i1 = Int(r1 * Double(pts.count - 1))
                                                let i2 = Int(r2 * Double(pts.count - 1))
                                                rangeSelection = min(pts[i1].date, pts[i2].date)...max(pts[i1].date, pts[i2].date)
                                            }
                                        .onEnded { _ in isDraggingRange = false }
                                    )
                                    .simultaneousGesture(TapGesture().onEnded { rangeSelection = nil })
                            }
                        }

                        // 拖动日期标签
                        if isDraggingRange, let r = rangeSelection {
                            Text("\(r.lowerBound, format: .dateTime.month().day()) — \(r.upperBound, format: .dateTime.month().day())")
                                .font(.system(size: 10).monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(3)
                                .offset(x: 8, y: 8)
                        }
                    }
                }
                .frame(height: 350)

                // 底部：当前时间范围收益率
                HStack {
                    if let f = firstPoint, let l = lastPoint, f.principal > 0 {
                        Text("当前范围: \(f.date, format: .dateTime.month().day()) → \(l.date, format: .dateTime.month().day())")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("收益率 \(totalChange >= 0 ? "+" : "")\(totalChange * 100, specifier: "%.2f")%")
                            .font(.system(size: 9).bold()).foregroundStyle(totalChange >= 0 ? .red : .green)
                    }
                    Spacer()
                    if rangeSelection != nil {
                        Text("点击图表关闭框选")
                            .font(.system(size: 9)).foregroundStyle(.blue)
                    } else {
                        Text("拖拽框选区间")
                            .font(.system(size: 9)).foregroundStyle(.gray.opacity(0.4))
                    }
                }
                .padding(.top, 6)
            }
            .overlay(alignment: .topTrailing) {
                if let stats = rangeStats {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack {
                            Text("区间统计").font(.caption).bold()
                            Spacer()
                            Button("✕") { rangeSelection = nil }
                                .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
                        }
                        Divider()
                        statRow("市值变化", stats.valueChange, stats.valueChange >= 0 ? .red : .green)
                        statRow("本金变化", stats.principalChange, stats.principalChange >= 0 ? .red : .green)
                        statRow("浮动盈亏", stats.valueChange - stats.principalChange, (stats.valueChange - stats.principalChange) >= 0 ? .red : .green)
                        Divider()
                        statRow("收益率", stats.yield, stats.yield >= 0 ? .red : .green, isPercent: true)
                        statRow("年化率", stats.annualizedYield, stats.annualizedYield >= 0 ? .red : .green, isPercent: true)
                    }
                    .padding(10)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .frame(width: 200)
                    .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: Double, _ color: Color, isPercent: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if isPercent {
                Text("\(value >= 0 ? "+" : "")\(value * 100, specifier: "%.2f")%")
                    .font(.caption).bold().foregroundStyle(color).monospacedDigit()
            } else {
                Text("\(value >= 0 ? "+" : "")\(value.formatted(.currency(code: "CNY")))")
                    .font(.caption).bold().foregroundStyle(color).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var timeRangePicker: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Picker("时间范围", selection: $selectedTimeRange) {
                    ForEach(ChartTimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 600)

                if selectedTimeRange == .custom {
                    HStack {
                        DatePicker("开始", selection: $customStartDate, displayedComponents: .date).labelsHidden()
                        Text("-").foregroundStyle(.secondary)
                        DatePicker("结束", selection: $customEndDate, displayedComponents: .date).labelsHidden()
                    }
                    .font(.caption)
                    .onChange(of: customStartDate) { if customStartDate > customEndDate { customStartDate = customEndDate } }
                    .onChange(of: customEndDate) { if customEndDate < customStartDate { customEndDate = customStartDate } }
                }
            }
            Spacer()
        }
        .padding(.top, 5)
    }

    // MARK: - AI 投资建议

    private var aiAdviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AI 调仓建议").font(.headline)
                Spacer()
            }

            if let advice = aiAdvice {
                Text(advice)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(8)
            }

            if isLoadingAdvice {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("AI 思考中...").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(action: fetchAIAdvice) {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                        Text(aiAdvice == nil ? "获取 AI 调仓建议" : "刷新建议")
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func fetchScheduleAI(result: SmartCalculationResult, amount: Double) {
        guard !apiKey.isEmpty else {
            aiScheduleSuggestion = "请先在设置中配置 API Key"
            return
        }
        isLoadingScheduleAI = true
        aiScheduleSuggestion = nil

        // 构建 plan 摘要
        var planLines = ""
        for (key, amt) in result.plan where abs(amt) > 0.01 {
            if key.hasPrefix("NEW_") { continue }
            if let id = UUID(uuidString: key), let a = assetList.items.first(where: { $0.id == id }) {
                planLines += "\(a.name): \(amt >= 0 ? "+" : "")\(String(format: "%.0f", amt))\n"
            }
        }

        let prompt = """
        你是调仓优化助手。系统算出的各资产调整方案如下：

        操作：\(operationMode == .invest ? "追加 ¥\(String(format: "%.0f", amount))" : "提现 ¥\(String(format: "%.0f", amount))")
        各资产调整：
        \(planLines)

        约束（必须遵守）：
        1. 总金额守恒：所有资产的 ± 金额相加必须等于原始操作金额（追加=正，提现=负）
        2. 参考大类平衡：优先调整偏离目标比例最远的资产
        3. 合并同类调整：同一大类内可以合并，但总金额不能变
        4. 不做舍入：不能因为金额小而忽略，必须保持总额精确

        回复格式：
        资产名 ±¥xxx，资产名 ±¥xxx（总额=操作金额）
        30字以内。
        """

        Task {
            do {
                let base = aiBaseURL.hasSuffix("/") ? String(aiBaseURL.dropLast()) : aiBaseURL
                let url = URL(string: "\(base)/chat/completions")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 20
                let body: [String: Any] = [
                    "model": aiTextModel,
                    "messages": [["role": "user", "content": prompt]],
                    "max_tokens": 150,
                    "temperature": 0.2
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    await MainActor.run {
                        aiScheduleSuggestion = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        isLoadingScheduleAI = false
                    }
                } else {
                    await MainActor.run {
                        aiScheduleSuggestion = "AI 返回解析失败"
                        isLoadingScheduleAI = false
                    }
                }
            } catch {
                await MainActor.run {
                    aiScheduleSuggestion = "请求失败: \(error.localizedDescription)"
                    isLoadingScheduleAI = false
                }
            }
        }
    }

    private func fetchAIAdvice() {
        guard currentTotalValue > 0 else { return }
        isLoadingAdvice = true
        aiAdvice = nil
        Task { await fetchAdviceFromAI() }
    }

    private func fetchAdviceFromAI() async {
        guard !apiKey.isEmpty else {
            aiAdvice = "请先在设置中配置 AI API Key"
            isLoadingAdvice = false
            return
        }

        let categories: [CategoryState] = AssetCategory.allCases.map { cat in
            let items = assetList.items.filter { $0.category == cat }
            let val = items.reduce(0) { $0 + $1.value }
            let prin = items.reduce(0) { $0 + $1.principal }
            return CategoryState(name: cat.rawValue, value: val, principal: prin, targetRatio: targetRatio(for: cat))
        }

        Task {
            do {
                let result = try await AIAdvisor.getAdvice(
                    totalValue: currentTotalValue,
                    totalPrincipal: totalUserPrincipal,
                    categories: categories,
                    absThreshold: absThreshold,
                    relThreshold: relThreshold,
                    apiBaseURL: aiBaseURL,
                    apiKey: apiKey,
                    model: aiTextModel
                )
                await MainActor.run {
                    aiAdvice = result
                    isLoadingAdvice = false
                }
            } catch {
                await MainActor.run {
                    aiAdvice = "获取建议失败: \(error.localizedDescription)"
                    isLoadingAdvice = false
                }
            }
        }
    }

    // MARK: - 数据与逻辑

    func historyData(for record: PortfolioRecord) -> (value: Double, principal: Double) {
        if let catName = activeCategoryName {
            guard let data = record.assetSnapshot.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
                print("JSON decode failed for record: \(record.date). assetSnapshot: \(record.assetSnapshot)")
                return (0, 0)
            }

            let currentCatVal = assetList.items.filter { $0.category.rawValue == catName }.reduce(0) { $0 + $1.value }
            let currentCatPrin = assetList.items.filter { $0.category.rawValue == catName }.reduce(0) { $0 + $1.principal }
            let currentTotalVal = assetList.items.reduce(0) { $0 + $1.value }
            let legacyVal = fallbackValue(for: catName, dict: dict)

            // 有真实分类数据 → 直接用；否则按比例从总市值估算
            if let catVal = dict["CAT_\(catName)_V"], catVal > 0 {
                let val = catVal
                let prin = dict["CAT_\(catName)_P"] ?? currentCatPrin
                return (val, prin)
            } else if legacyVal > 0 {
                let val = legacyVal
                let prin = dict["CAT_\(catName)_P"] ?? currentCatPrin
                return (val, prin)
            } else if record.totalValue > 0, currentTotalVal > 0 {
                // 估算：按当前分类占比 × 历史总市值
                let ratio = currentCatVal / currentTotalVal
                let estimatedVal = record.totalValue * ratio
                let estimatedPrin = record.principal * ratio
                return (estimatedVal, estimatedPrin)
            }

            return (currentCatVal, currentCatPrin)
        } else {
            return (record.totalValue, record.principal)
        }
    }

    private func fallbackValue(for catName: String, dict: [String: Double]) -> Double {
        switch catName {
        case "债券": return dict["Bond"] ?? 0
        case "美股": return dict["Nasdaq"] ?? 0
        case "贵金属": return dict["Gold"] ?? 0
        case "A股": return dict["CSI"] ?? 0
        case "现金": return dict["Cash"] ?? 0
        default: return 0
        }
    }

    func targetRatio(for category: AssetCategory) -> Double {
        switch category {
        case .aShares: return csiTarget
        case .usStocks: return nasdaqTarget
        case .gold: return goldTarget
        case .bonds: return bondTarget
        case .cash: return cashTarget
        }
    }

    func calculatePreview(amount: Double) { guard amount > 0 else { calculationResult = nil; return }; calculationResult = calculateSmartLogic(amount: amount, isDeposit: operationMode == .invest) }

    func calculateSmartLogic(amount: Double, isDeposit: Bool) -> SmartCalculationResult {
        let curTotal = currentTotalValue; let futTotal = isDeposit ? curTotal + amount : curTotal - amount
        var categoryValues: [AssetCategory: Double] = [.aShares:0, .usStocks:0, .gold:0, .bonds:0, .cash:0]
        for item in assetList.items { categoryValues[item.category, default: 0] += item.value }
        var categoryGaps: [AssetCategory: Double] = [:]; var posGap = 0.0; var negGap = 0.0
        for cat in AssetCategory.allCases {
            let targetVal = futTotal * targetRatio(for: cat); let gap = targetVal - (categoryValues[cat] ?? 0)
            categoryGaps[cat] = gap; if gap > 0 { posGap += gap } else { negGap += abs(gap) }
        }
        var plan: [String: Double] = [:]; var name = ""; var desc = ""

        func distribute(cat: AssetCategory, amt: Double) {
            let items = assetList.items.filter { $0.category == cat }
            if items.isEmpty { plan["NEW_" + cat.rawValue] = (amt * 100).rounded() / 100; return }
            let catTotal = categoryValues[cat] ?? 0
            if catTotal <= 0 { let split = amt / Double(items.count); for a in items { plan[a.id.uuidString] = ((plan[a.id.uuidString] ?? 0) + split * 100).rounded() / 100 } }
            else { for a in items { let ratio = a.value / catTotal; plan[a.id.uuidString] = ((plan[a.id.uuidString] ?? 0) + (amt * ratio) * 100).rounded() / 100 } }
        }
        if isDeposit {
            if amount >= posGap { name = "强力填坑 + 均衡增长"; desc = "资金充足。优先补足短板，剩余按目标分配。"; let sur = amount - posGap; for cat in AssetCategory.allCases { let alloc = (categoryGaps[cat]! > 0 ? categoryGaps[cat]! : 0) + sur * targetRatio(for: cat); if alloc > 0 { distribute(cat: cat, amt: alloc) } } }
            else { name = "优先补短 (智能填坑)"; desc = "资金有限。全额用于补足占比不足的资产类别。"; for cat in AssetCategory.allCases { if categoryGaps[cat]! > 0 { distribute(cat: cat, amt: amount * (categoryGaps[cat]! / posGap)) } } }
        } else {
            if amount >= negGap { name = "强力削峰 + 均衡减仓"; desc = "优先卖出超涨资产类别，剩余部分按比例卖出。"; let rem = amount - negGap; for cat in AssetCategory.allCases { let over = categoryGaps[cat]! < 0 ? abs(categoryGaps[cat]!) : 0; let alloc = -1 * (over + rem * targetRatio(for: cat)); if alloc < 0 { distribute(cat: cat, amt: alloc) } } }
            else { name = "精准削峰"; desc = "仅从占比过高的大类中按比例卖出。"; for cat in AssetCategory.allCases { if categoryGaps[cat]! < 0 { distribute(cat: cat, amt: -1 * (amount * (abs(categoryGaps[cat]!) / negGap))) } } }
        }
        return SmartCalculationResult(plan: plan, strategyName: name, description: desc)
    }

    func prepareRebalancePlan() {
        let total = currentTotalValue; var desc = "建议按大类执行以下再平衡操作：\n"; var plan: [String: Double] = [:]
        var categoryValues: [AssetCategory: Double] = [.aShares:0, .usStocks:0, .gold:0, .bonds:0, .cash:0]
        for item in assetList.items { categoryValues[item.category, default: 0] += item.value }
        for cat in AssetCategory.allCases {
            let diff = total * targetRatio(for: cat) - (categoryValues[cat] ?? 0)
            if abs(diff) > 1 {
                desc += "\n- 大类 [\(cat.rawValue)] \(diff > 0 ? "需买入" : "需卖出"): \(String(format: "%.2f", abs(diff)))"
                let items = assetList.items.filter { $0.category == cat }
                if items.isEmpty { plan["NEW_" + cat.rawValue] = (diff * 100).rounded() / 100 }
                else {
                    let catTotal = categoryValues[cat] ?? 0
                    if catTotal <= 0 { let split = diff / Double(items.count); for a in items { plan[a.id.uuidString] = (split * 100).rounded() / 100 } }
                    else { for a in items { let ratio = a.value / catTotal; plan[a.id.uuidString] = ((diff * ratio) * 100).rounded() / 100 } }
                }
            }
        }
        rebalancePlan = SmartCalculationResult(plan: plan, strategyName: "大类再平衡", description: desc, isRebalance: true); showRebalanceConfirm = true
    }

    func applySmartPlan(result: SmartCalculationResult, amount: Double) {
        for (key, rawChange) in result.plan {
            if key.hasPrefix("NEW_") { continue }
            let change = (rawChange * 100).rounded() / 100
            if let id = UUID(uuidString: key), let idx = assetList.items.firstIndex(where: { $0.id == id }) {
                let oldVal = assetList.items[idx].value; let oldPrin = assetList.items[idx].principal
                if change < 0 {
                    let sellRatio = oldVal > 0 ? (abs(change) / oldVal) : 0
                    assetList.items[idx].principal = ((oldPrin - (oldPrin * sellRatio)) * 100).rounded() / 100
                } else { assetList.items[idx].principal = ((oldPrin + change) * 100).rounded() / 100 }
                assetList.items[idx].value = ((oldVal + change) * 100).rounded() / 100
            }
        }
        if !result.isRebalance {
            let roundedAmt = (amount * 100).rounded() / 100
            if operationMode == .invest { totalUserPrincipal = ((totalUserPrincipal + roundedAmt) * 100).rounded() / 100 }
            else { totalUserPrincipal = ((totalUserPrincipal - roundedAmt) * 100).rounded() / 100 }
        }
        saveRecord(); autoSaveManager.saveImmediately(); inputAmount = nil; calculationResult = nil; rebalancePlan = nil
    }

    func checkRebalanceNeed(total: Double) -> (isNeeded: Bool, deviations: [RebalanceDeviation]) {
        var devs: [RebalanceDeviation] = []
        var categoryValues: [AssetCategory: Double] = [.aShares:0, .usStocks:0, .gold:0, .bonds:0, .cash:0]
        for item in assetList.items { categoryValues[item.category, default: 0] += item.value }
        for cat in AssetCategory.allCases {
            let tgt = targetRatio(for: cat)
            let pct = total > 0 ? (categoryValues[cat] ?? 0) / total : 0
            let diff = pct - tgt
            var trig = false
            if tgt >= 0.20 { if abs(diff) > absThreshold { trig = true } }
            else if tgt > 0 { if abs(diff) / tgt > relThreshold { trig = true } }
            if trig {
                devs.append(RebalanceDeviation(
                    categoryName: cat.rawValue,
                    currentPct: pct,
                    targetPct: tgt,
                    deviation: diff,
                    suggestion: diff > 0 ? "减仓" : "增仓"
                ))
            }
        }
        return (!devs.isEmpty, devs)
    }

    func saveRecord() {
        guard currentTotalValue > 0 else { return }
        var snap: [String: Double] = [:]
        for item in assetList.items { snap[item.id.uuidString] = (item.value * 100).rounded() / 100 }
        for cat in AssetCategory.allCases {
            let catItems = assetList.items.filter { $0.category == cat }
            snap["CAT_\(cat.rawValue)_V"] = (catItems.reduce(0) { $0 + $1.value } * 100).rounded() / 100
            snap["CAT_\(cat.rawValue)_P"] = (catItems.reduce(0) { $0 + $1.principal } * 100).rounded() / 100
        }

        let recordTotal = (currentTotalValue * 100).rounded() / 100
        let recordPrincipal = (totalUserPrincipal * 100).rounded() / 100

        modelContext.insert(PortfolioRecord(date: Date(), totalValue: recordTotal, principal: recordPrincipal, assetSnapshot: snap))
    }

    func resetAllData() { try? modelContext.delete(model: PortfolioRecord.self); assetList.items.removeAll(); totalUserPrincipal = 0; inputAmount = nil; calculationResult = nil }

    private func migrateOldDataIfNeeded() {
        if !hasMigratedToV3 {
            assetList = AssetList(items: [
                AssetItem(name: "默认债券", category: .bonds, value: (oldBondValue * 100).rounded() / 100, principal: (oldBondPrincipal * 100).rounded() / 100),
                AssetItem(name: "默认美股", category: .usStocks, value: (oldNasdaqValue * 100).rounded() / 100, principal: (oldNasdaqPrincipal * 100).rounded() / 100),
                AssetItem(name: "默认贵金属", category: .gold, value: (oldGoldValue * 100).rounded() / 100, principal: (oldGoldPrincipal * 100).rounded() / 100),
                AssetItem(name: "默认A股", category: .aShares, value: (oldCsiValue * 100).rounded() / 100, principal: (oldCsiPrincipal * 100).rounded() / 100),
                AssetItem(name: "默认现金", category: .cash, value: (oldCashValue * 100).rounded() / 100, principal: (oldCashPrincipal * 100).rounded() / 100)
            ].filter { $0.value > 0 || $0.principal > 0 })
            hasMigratedToV3 = true
        }
    }
}

import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

// MARK: - 1. 核心数据模型与备份结构

// 智能计算结果结构
struct SmartCalculationResult {
    var plan: [String: Double]
    var strategyName: String
    var description: String
    var isRebalance: Bool = false
}

enum AssetCategory: String, Codable, CaseIterable, Identifiable {
    case aShares = "A股"
    case usStocks = "美股"
    case gold = "贵金属"
    case bonds = "债券"
    case cash = "现金"
    
    var id: String { self.rawValue }
    var color: Color {
        switch self {
        case .aShares: return .red
        case .usStocks: return .purple
        case .gold: return .yellow
        case .bonds: return .blue
        case .cash: return .gray
        }
    }
}

struct AssetItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var category: AssetCategory
    var value: Double
    var principal: Double
}

struct AssetList: Codable, RawRepresentable {
    var items: [AssetItem]
    init(items: [AssetItem]) { self.items = items }
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([AssetItem].self, from: data) else { return nil }
        self.items = result
    }
    var rawValue: String {
        guard let data = try? JSONEncoder().encode(items),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }
}

// 时间范围选择枚举
enum ChartTimeRange: String, CaseIterable, Identifiable {
    case oneMinute = "一分钟"
    case oneDay = "一天"
    case oneWeek = "一周"
    case twoWeeks = "两周"
    case oneMonth = "一月"
    case oneQuarter = "一季度"
    case oneYear = "一年"
    case all = "所有"
    case custom = "自定义"
    var id: String { self.rawValue }
}

// 用于图表渲染的中间结构体
struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let principal: Double
}

struct BackupData: Codable {
    var totalUserPrincipal: Double
    var absThreshold: Double
    var relThreshold: Double
    var history: [HistoryItemJSON]
    var assetList: AssetList?
    
    // V1 兼容字段
    var bondValue: Double?; var nasdaqValue: Double?; var goldValue: Double?; var csiValue: Double?; var cashValue: Double?
    var bondPrincipal: Double?; var nasdaqPrincipal: Double?; var goldPrincipal: Double?; var csiPrincipal: Double?; var cashPrincipal: Double?
    var bondTarget: Double?; var nasdaqTarget: Double?; var goldTarget: Double?; var csiTarget: Double?; var cashTarget: Double?
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var backupData: BackupData?
    init(backupData: BackupData? = nil) { self.backupData = backupData }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents { self.backupData = try JSONDecoder().decode(BackupData.self, from: data) }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(backupData)
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 2. 主视图 ContentView
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioRecord.date, order: .reverse) private var history: [PortfolioRecord]
    
    // 动态资产列表
    @AppStorage("portfolioAssetsV3") private var assetList = AssetList(items: [])
    @AppStorage("totalUserPrincipal") private var totalUserPrincipal: Double = 0
    @AppStorage("absThreshold") private var absThreshold: Double = 0.05
    @AppStorage("relThreshold") private var relThreshold: Double = 0.25
    
    // 目标比例 (按大类)
    @AppStorage("bondTarget") private var bondTarget = 0.50
    @AppStorage("nasdaqTarget") private var nasdaqTarget = 0.15
    @AppStorage("goldTarget") private var goldTarget = 0.15
    @AppStorage("csiTarget") private var csiTarget = 0.10
    @AppStorage("cashTarget") private var cashTarget = 0.10
    
    // 迁移标记
    @AppStorage("hasMigratedToV3") private var hasMigratedToV3: Bool = false
    @AppStorage("bondValue") private var oldBondValue: Double = 0; @AppStorage("bondPrincipal") private var oldBondPrincipal: Double = 0
    @AppStorage("nasdaqValue") private var oldNasdaqValue: Double = 0; @AppStorage("nasdaqPrincipal") private var oldNasdaqPrincipal: Double = 0
    @AppStorage("goldValue") private var oldGoldValue: Double = 0; @AppStorage("goldPrincipal") private var oldGoldPrincipal: Double = 0
    @AppStorage("csiValue") private var oldCsiValue: Double = 0; @AppStorage("csiPrincipal") private var oldCsiPrincipal: Double = 0
    @AppStorage("cashValue") private var oldCashValue: Double = 0; @AppStorage("cashPrincipal") private var oldCashPrincipal: Double = 0

    // 状态变量
    @State private var inputAmount: Double? = nil
    @State private var operationMode: OperationMode = .invest
    @State private var calculationResult: SmartCalculationResult?
    @State private var showSettings = false
    @State private var showRebalanceConfirm = false
    @State private var rebalancePlan: SmartCalculationResult?
    
    // 交互与时间筛选状态
    @State private var rawSelectedPieValue: Double?
    @State private var pinnedCategoryName: String? = nil
    @State private var rawSelectedDate: Date?
    @State private var rangeSelection: ClosedRange<Date>? = nil // 拖选区间
    @State private var isDraggingRange = false // 是否正在拖选区间

    @State private var selectedTimeRange: ChartTimeRange = .oneMonth // 默认显示近一月
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

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
        guard let range = rangeSelection,
              let startPoint = chartDataPoints.first(where: { $0.date >= range.lowerBound }),
              let endPoint = chartDataPoints.last(where: { $0.date <= range.upperBound }),
              startPoint.date < endPoint.date else { return nil }

        let valueChange = endPoint.value - startPoint.value
        let principalChange = endPoint.principal - startPoint.principal
        let profit = endPoint.value - endPoint.principal - (startPoint.value - startPoint.principal)
        let yield = endPoint.principal > 0 ? ((endPoint.value - endPoint.principal) - (startPoint.value - startPoint.principal)) / endPoint.principal : 0

        let days = endPoint.date.timeIntervalSince(startPoint.date) / (24 * 60 * 60)
        let annualizedYield: Double
        if days > 0 {
            let totalReturn: Double
            if startPoint.principal > 0 && endPoint.principal > 0 && startPoint.value > 0 {
                totalReturn = (endPoint.value / endPoint.principal) / (startPoint.value / startPoint.principal) - 1
            } else if startPoint.principal == 0 && endPoint.principal > 0 {
                totalReturn = (endPoint.value - endPoint.principal) / endPoint.principal
            } else {
                totalReturn = 0
            }
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
        .onAppear { migrateOldDataIfNeeded() }
    }
    
    // MARK: - UI 组件拆分
    
    private var sidebarContent: some View {
        Form {
            fundingSection
            positionSection
        }
        .formStyle(.grouped)
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button(action: { showSettings = true }) { Label("设置", systemImage: "gearshape") } } }
        .sheet(isPresented: $showSettings) { SettingsView(resetAction: resetAllData) }
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
                StrategyPreviewCard(result: result, assetList: assetList.items) { applySmartPlan(result: result, amount: amount) }
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
            }
        )
    }

    func valueBinding(for id: UUID) -> Binding<Double> {
        Binding<Double>(
            get: { guard let idx = assetList.items.firstIndex(where: { $0.id == id }) else { return 0 }; return assetList.items[idx].value },
            set: { newValue in guard let idx = assetList.items.firstIndex(where: { $0.id == id }) else { return }; assetList.items[idx].value = (newValue * 100).rounded() / 100 }
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
            Button("保存快照") { saveRecord() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding(.top, 5)
        }
    }
    
    private var detailContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                StatsDashboardView(totalValue: currentTotalValue, userPrincipal: totalUserPrincipal)
                if currentTotalValue > 0 {
                    let check = checkRebalanceNeed(total: currentTotalValue)
                    if check.isNeeded { RebalanceAlertView(messages: check.messages) { prepareRebalancePlan() } }
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
            let minY = allValues.min() ?? 0
            let maxY = allValues.max() ?? 100
            let diff = maxY - minY
            let pad = diff == 0 ? (minY * 0.05) : (diff * 0.15)
            let domainMin = max(0, minY - pad)
            let domainMax = maxY + pad

            GeometryReader { geometry in
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Principal", point.principal), series: .value("Type", "Principal"))
                            .interpolationMethod(.stepCenter)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(.gray.opacity(0.8))

                        AreaMark(
                            x: .value("Date", point.date),
                            yStart: .value("Min", domainMin),
                            yEnd: .value("Value", point.value)
                        )
                        .interpolationMethod(.stepCenter)
                        .foregroundStyle(LinearGradient(colors: [catColor.opacity(0.6), catColor.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom))

                        LineMark(x: .value("Date", point.date), y: .value("Value", point.value), series: .value("Type", "Value"))
                            .interpolationMethod(.stepCenter).foregroundStyle(catColor).lineStyle(StrokeStyle(lineWidth: 2))

                        if let rawSelectedDate { RuleMark(x: .value("Selected", rawSelectedDate)).foregroundStyle(Color.gray.opacity(0.5)) }
                        if let range = rangeSelection {
                            RectangleMark(
                                xStart: .value("RangeStart", range.lowerBound),
                                xEnd: .value("RangeEnd", range.upperBound),
                                yStart: .value("YMin", domainMin),
                                yEnd: .value("YMax", domainMax)
                            )
                            .foregroundStyle(Color.blue.opacity(0.1))
                        }
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
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(Color.gray.opacity(0.3))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                if selectedTimeRange == .oneMinute { Text(date, format: .dateTime.hour().minute().second()) }
                                else if selectedTimeRange == .oneDay { Text(date, format: .dateTime.hour().minute()) }
                                else { Text(date, format: .dateTime.month().day()) }
                            }
                        }
                    }
                }
                .chartOverlay { _ in
                    Color.clear
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    isDraggingRange = true
                                    let xPosition = value.startLocation.x
                                    let xDelta = value.location.x - value.startLocation.x
                                    let chartWidth = geometry.size.width
                                    let normalizedStart = max(0, min(1, xPosition / chartWidth))
                                    let normalizedEnd = max(0, min(1, (xPosition + xDelta) / chartWidth))

                                    let domain = currentChartDomain
                                    let startDate = domain.lowerBound.addingTimeInterval(normalizedStart * (domain.upperBound.timeIntervalSince(domain.lowerBound)))
                                    let endDate = domain.lowerBound.addingTimeInterval(normalizedEnd * (domain.upperBound.timeIntervalSince(domain.lowerBound)))

                                    rangeSelection = min(startDate, endDate)...max(startDate, endDate)
                                }
                                .onEnded { _ in
                                    isDraggingRange = false
                                    if let range = rangeSelection, range.upperBound.timeIntervalSince(range.lowerBound) < 60 {
                                        rangeSelection = nil
                                    }
                                }
                        )
                }
            } // GeometryReader 规范闭合
            .frame(height: 350)
            .overlay(alignment: .topTrailing) {
                if let stats = rangeStats {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Button("清除") { rangeSelection = nil }.font(.caption2).foregroundStyle(.blue)
                            Spacer()
                            Text("区间统计").font(.caption).foregroundStyle(.secondary).bold()
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("市值变化").font(.caption2).foregroundStyle(.secondary)
                                Text(stats.valueChange, format: .currency(code: "CNY"))
                                    .font(.caption).bold().foregroundStyle(stats.valueChange >= 0 ? .red : .green)
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("本金变化").font(.caption2).foregroundStyle(.secondary)
                                Text(stats.principalChange, format: .currency(code: "CNY"))
                                    .font(.caption).bold().foregroundStyle(stats.principalChange >= 0 ? .red : .green)
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("收益率").font(.caption2).foregroundStyle(.secondary)
                                Text(stats.yield, format: .percent.precision(.fractionLength(2)))
                                    .font(.caption).bold().foregroundStyle(stats.yield >= 0 ? .red : .green)
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("年化率").font(.caption2).foregroundStyle(.secondary)
                                Text(stats.annualizedYield, format: .percent.precision(.fractionLength(2)))
                                    .font(.caption).bold().foregroundStyle(stats.annualizedYield >= 0 ? .red : .green)
                            }
                        }
                        Text("\(stats.start.date, format: .dateTime.month().day()) → \(stats.end.date, format: .dateTime.month().day())")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8).background(Color(nsColor: .windowBackgroundColor)).cornerRadius(8).shadow(radius: 2)
                    .padding(8)
                }
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

    // MARK: - 数据读取与核心逻辑
    
    func historyData(for record: PortfolioRecord) -> (value: Double, principal: Double) {
        if let catName = activeCategoryName {
            guard let data = record.assetSnapshot.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
                print("⚠️ JSON decode failed for record: \(record.date). assetSnapshot: \(record.assetSnapshot)")
                return (0, 0)
            }
            
            let fallbackPrin = assetList.items.filter { $0.category.rawValue == catName }.reduce(0) { $0 + $1.principal }
            let fallbackVal = assetList.items.filter { $0.category.rawValue == catName }.reduce(0) { $0 + $1.value }
            let legacyVal = fallbackValue(for: catName, dict: dict)
            
            let val = dict["CAT_\(catName)_V"] ?? (legacyVal > 0 ? legacyVal : fallbackVal)
            let prin = dict["CAT_\(catName)_P"] ?? fallbackPrin
            
            return (val, prin)
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
    
    // 🔥 修复：明确规范换行，防止 Xcode 解析出问题
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
            if amount >= posGap { name = "🔥 强力填坑 + 均衡增长"; desc = "资金充足。优先补足短板，剩余按目标分配。"; let sur = amount - posGap; for cat in AssetCategory.allCases { let alloc = (categoryGaps[cat]! > 0 ? categoryGaps[cat]! : 0) + sur * targetRatio(for: cat); if alloc > 0 { distribute(cat: cat, amt: alloc) } } }
            else { name = "🛡️ 优先补短 (智能填坑)"; desc = "资金有限。全额用于补足占比不足的资产类别。"; for cat in AssetCategory.allCases { if categoryGaps[cat]! > 0 { distribute(cat: cat, amt: amount * (categoryGaps[cat]! / posGap)) } } }
        } else {
            if amount >= negGap { name = "🔪 强力削峰 + 均衡减仓"; desc = "优先卖出超涨资产类别，剩余部分按比例卖出。"; let rem = amount - negGap; for cat in AssetCategory.allCases { let over = categoryGaps[cat]! < 0 ? abs(categoryGaps[cat]!) : 0; let alloc = -1 * (over + rem * targetRatio(for: cat)); if alloc < 0 { distribute(cat: cat, amt: alloc) } } }
            else { name = "✂️ 精准削峰"; desc = "仅从占比过高的大类中按比例卖出。"; for cat in AssetCategory.allCases { if categoryGaps[cat]! < 0 { distribute(cat: cat, amt: -1 * (amount * (abs(categoryGaps[cat]!) / negGap))) } } }
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
                desc += "\n• 大类 [\(cat.rawValue)] \(diff > 0 ? "需买入" : "需卖出"): \(String(format: "%.2f", abs(diff)))"
                let items = assetList.items.filter { $0.category == cat }
                if items.isEmpty { plan["NEW_" + cat.rawValue] = (diff * 100).rounded() / 100 }
                else {
                    let catTotal = categoryValues[cat] ?? 0
                    if catTotal <= 0 { let split = diff / Double(items.count); for a in items { plan[a.id.uuidString] = (split * 100).rounded() / 100 } }
                    else { for a in items { let ratio = a.value / catTotal; plan[a.id.uuidString] = ((diff * ratio) * 100).rounded() / 100 } }
                }
            }
        }
        rebalancePlan = SmartCalculationResult(plan: plan, strategyName: "⚖️ 大类再平衡", description: desc, isRebalance: true); showRebalanceConfirm = true
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
        saveRecord(); inputAmount = nil; calculationResult = nil; rebalancePlan = nil
    }
    
    func checkRebalanceNeed(total: Double) -> (isNeeded: Bool, messages: [String]) {
        var msgs: [String] = []
        var categoryValues: [AssetCategory: Double] = [.aShares:0, .usStocks:0, .gold:0, .bonds:0, .cash:0]
        for item in assetList.items { categoryValues[item.category, default: 0] += item.value }
        for cat in AssetCategory.allCases {
            let tgt = targetRatio(for: cat); let pct = total > 0 ? (categoryValues[cat] ?? 0) / total : 0; let diff = pct - tgt; var trig = false
            if tgt >= 0.20 { if abs(diff) > absThreshold { trig = true } } else if tgt > 0 { if abs(diff)/tgt > relThreshold { trig = true } }
            if trig { msgs.append("大类 [\(cat.rawValue)] 偏离目标，建议\(diff > 0 ? "减仓" : "增仓")") }
        }
        return (!msgs.isEmpty, msgs)
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
        
        // 🔥 终极修复：直接传入 snap 字典！
        // 因为 PortfolioRecord 的 init 内部已经写好了 Dictionary 转 JSON String 的逻辑。
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

// MARK: - 3. 辅助组件

struct DualInputRow: View {
    let name: String; @Binding var value: Double; @Binding var principal: Double; var color: Color
    
    var body: some View {
        HStack(alignment: .center) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name)
                .frame(width: 80, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            
            VStack(spacing: 6) {
                HStack { Text("值").font(.caption).foregroundStyle(.secondary); TextField("", value: $value, format: .number.precision(.fractionLength(0...2))).textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit() }.padding(6).background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
                HStack { Text("本").font(.caption).foregroundStyle(.secondary); TextField("", value: $principal, format: .number.precision(.fractionLength(0...2))).textFieldStyle(.plain).multilineTextAlignment(.trailing).foregroundStyle(.secondary).monospacedDigit() }.padding(6).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(6)
            }
        }.padding(.vertical, 4)
    }
}

struct AssetDetailRow: View {
    let name: String; let value: Double; let principal: Double; let color: Color
    var ret: Double { principal > 0 ? (value - principal) / principal : 0 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack { Circle().fill(color).frame(width: 8, height: 8); Text(name).font(.callout) }; Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value, format: .currency(code: "CNY")).font(.callout).monospacedDigit()
                    HStack(spacing: 4) { Text("本: \(principal, format: .number.precision(.fractionLength(0...2)))"); Text(ret, format: .percent.precision(.fractionLength(1))).foregroundStyle(ret >= 0 ? .red : .green).padding(.horizontal, 3).background(ret >= 0 ? Color.red.opacity(0.1) : Color.green.opacity(0.1)).cornerRadius(3) }.font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8); Divider()
        }
    }
}

struct StatsDashboardView: View {
    let totalValue: Double; let userPrincipal: Double; var profit: Double { totalValue - userPrincipal }; var yield: Double { userPrincipal > 0 ? profit / userPrincipal : 0 }
    var body: some View { HStack(spacing: 15) { StatCard(title: "总资产", value: totalValue, color: .primary); StatCard(title: "投入本金", value: userPrincipal, color: .secondary); StatCard(title: "累计收益", value: profit, subText: String(format: "%.2f%%", yield * 100), color: profit >= 0 ? .red : .green) } }
}

struct StatCard: View {
    let title: String; let value: Double; var subText: String? = nil; var color: Color
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value, format: .currency(code: "CNY")).font(.title2).bold().foregroundStyle(color).monospacedDigit(); if let s = subText { Text(s).font(.caption).foregroundStyle(color.opacity(0.8)).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.1)).cornerRadius(4) } }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1) }
}

struct StrategyPreviewCard: View {
    let result: SmartCalculationResult
    let assetList: [AssetItem]
    let onConfirm: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "wand.and.stars").foregroundStyle(.purple); Text(result.strategyName).font(.headline) }
            Text(result.description).font(.caption).foregroundStyle(.secondary); Divider()
            ForEach(result.plan.keys.sorted(), id: \.self) { key in
                let amt = result.plan[key]!
                if abs(amt) > 0.01 {
                    HStack {
                        if key.hasPrefix("NEW_") { Text("[提示] 请先添加属于 [\(key.replacingOccurrences(of: "NEW_", with: ""))] 的资产").foregroundStyle(.orange) }
                        else if let id = UUID(uuidString: key), let asset = assetList.first(where: { $0.id == id }) { Text(asset.name); Spacer(); Text((amt > 0 ? "+" : "") + String(format: "%.2f", amt)).monospacedDigit().foregroundStyle(amt >= 0 ? .red : .green) }
                    }.font(.caption)
                }
            }
            Button("执行并更新", action: onConfirm).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding().background(Color.purple.opacity(0.05)).cornerRadius(8)
    }
}

struct RebalanceAlertView: View {
    let messages: [String]; let onFix: () -> Void
    var body: some View { HStack { VStack(alignment: .leading) { Label("触发大类再平衡信号", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.headline); ForEach(messages, id: \.self) { msg in Text("• " + msg).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button("查看大类调仓方案") { onFix() }.buttonStyle(.bordered) }.padding().background(Color.orange.opacity(0.08)).cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1)) }
}

// MARK: - 4. 设置页 SettingsView
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss; @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortfolioRecord.date, order: .reverse) private var allHistory: [PortfolioRecord]
    var resetAction: () -> Void
    
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
    
    var totalTarget: Double { bondTarget + nasdaqTarget + goldTarget + csiTarget + cashTarget }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                addAssetSection
                manageAssetsSection
                thresholdSection
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
                        print("❌ Failed to access file: \(url)")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    
                    guard let data = try? Data(contentsOf: url) else {
                        print("❌ Failed to read file data from: \(url)")
                        return
                    }
                    
                    guard let backup = try? JSONDecoder().decode(BackupData.self, from: data) else {
                        print("❌ Failed to decode backup JSON from: \(url)")
                        print("   File size: \(data.count) bytes")
                        return
                    }
                    
                    restoreData(from: backup)
                    showImportSuccess = true
                    print("✅ Backup imported successfully")
                    
                case .failure(let error):
                    print("❌ File import error: \(error.localizedDescription)")
                }
            }
            .alert("导入成功", isPresented: $showImportSuccess) { Button("OK") { dismiss() } }
        }.frame(minWidth: 450, minHeight: 650)
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
        Section(header: Text("已有资产管理"), footer: Text("点击垃圾桶图标即可删除资产。")) {
            ForEach($assetList.items) { $asset in
                HStack {
                    Circle().fill(asset.category.color).frame(width: 8, height: 8)
                    Text(asset.name).bold()
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

// MARK: - 扩展工具
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

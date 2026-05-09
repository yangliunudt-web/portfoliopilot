import SwiftUI

// MARK: - 辅助 UI 组件

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
    var onAIOptimize: (() -> Void)? = nil
    var aiSuggestion: String? = nil
    var aiLoading: Bool = false

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

            if onAIOptimize != nil {
                if aiLoading {
                    HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("AI 分析中...").font(.caption2).foregroundStyle(.secondary) }
                } else if let suggestion = aiSuggestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion).font(.caption).foregroundStyle(.blue).padding(6).background(Color.blue.opacity(0.05)).cornerRadius(4)
                        Button(action: { onAIOptimize?() }) {
                            HStack(spacing: 3) { Image(systemName: "arrow.clockwise"); Text("刷新建议").font(.caption2) }
                        }.buttonStyle(.borderless).foregroundStyle(.blue)
                    }
                } else {
                    Button(action: { onAIOptimize?() }) {
                        HStack(spacing: 3) { Image(systemName: "brain"); Text("AI 简化建议").font(.caption2) }
                    }.buttonStyle(.borderless).foregroundStyle(.blue)
                }
            }

            Button("执行并更新", action: onConfirm).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding().background(Color.purple.opacity(0.05)).cornerRadius(8)
    }
}

struct RebalanceDeviation {
    let categoryName: String
    let currentPct: Double
    let targetPct: Double
    let deviation: Double
    let suggestion: String
}

struct RebalanceAlertView: View {
    let deviations: [RebalanceDeviation]
    let onFix: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Label("触发大类再平衡信号", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)

                ForEach(deviations.indices, id: \.self) { i in
                    let d = deviations[i]
                    HStack(spacing: 6) {
                        Text("\(d.categoryName)")
                            .font(.caption).bold()
                        Text("当前 \(String(format: "%.1f", d.currentPct * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("→ 目标 \(String(format: "%.1f", d.targetPct * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("偏离 \(d.deviation >= 0 ? "+" : "")\(String(format: "%.1f", d.deviation * 100))%")
                            .font(.caption).bold()
                            .foregroundStyle(d.deviation >= 0 ? .red : .green)
                        Text(d.suggestion)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(d.deviation >= 0 ? Color.red.opacity(0.7) : Color.green.opacity(0.7))
                            .cornerRadius(3)
                    }
                }
            }
            Spacer()
            Button("查看大类调仓方案") { onFix() }.buttonStyle(.bordered)
        }
        .padding()
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}

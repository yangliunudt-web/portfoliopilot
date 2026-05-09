# PortfolioPilot

macOS 个人投资组合跟踪与智能再平衡助手，基于 SwiftUI + SwiftData 构建。

## 功能

- **多资产跟踪** — 支持 A股、美股、贵金属、债券、现金五大类资产，每类可添加多个具体持仓
- **可视化图表** — 甜甜圈图展示大类资产配置，折线图展示净值走势（支持拖拽区间统计）
- **智能再平衡** — 根据目标配置比例，自动计算追加/赎回的最优分配方案
- **再平衡预警** — 基于可配置的绝对/相对阈值，自动检测偏离并提示调仓
- **历史快照** — 一键保存组合状态，构建历史净值走势
- **数据备份** — 支持 JSON 格式完整导入/导出，数据安全无忧

## 技术栈

- SwiftUI (macOS 26.1+)
- SwiftData
- Charts

## 项目结构

```
PortfolioPilot/
├── PortfolioPilotApp.swift      # App 入口
├── ContentView.swift            # 主视图：侧边栏 + 图表 + 资金调度
├── PortfolioModels.swift        # 数据模型（AssetCategory, AssetItem 等）
├── PortfolioComponents.swift    # 可复用 UI 组件
├── SettingsView.swift           # 设置页（资产增删、比例配置、备份）
├── PortfolioRecord.swift        # SwiftData 历史快照模型
└── Color+Hex.swift              # Color 十六进制扩展
```

## 构建

在 Xcode 26.1+ 中打开 `PortfolioPilot.xcodeproj`，选择 `Product > Build`（Cmd+B）。

## 使用

1. **配置目标比例** — 设置 > 大类目标比例，调整五大类的理想占比
2. **添加资产** — 设置 > 新增具体资产，填入名称、大类、市值、本金
3. **记录净值** — 主界面侧边栏更新各资产市值，点击"保存快照"
4. **资金调度** — 输入金额，系统自动计算最优追加/提现方案
5. **再平衡** — 当大类偏离超过阈值，点击提示查看调仓方案

## 许可证

MIT

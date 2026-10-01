import SwiftUI
import ServiceManagement

extension Harness {
    var color: Color {
        switch self {
        case .codex: Color(white: 0.92)
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .pi: Color(red: 0.58, green: 0.49, blue: 0.93)
        case .devin: Color(red: 0.38, green: 0.65, blue: 0.98)
        case .droid: Color(red: 0.91, green: 0.77, blue: 0.29)
        case .commandCode: Color(red: 0.94, green: 0.45, blue: 0.62)
        }
    }
}

private enum Theme {
    static let background = Color(white: 0.045)
    static let surface = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.5)
    static let tertiary = Color.white.opacity(0.32)
    /// Left-to-right draw-in shared by the chart and the share bars.
    static let sweep = Animation.timingCurve(0.22, 0.8, 0.24, 1, duration: 0.7)
}

struct LedgerView: View {
    @Bindable var store: Store
    @State private var tab = Tab.plans
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    enum Tab: String, CaseIterable { case plans = "Plans", harness = "Harness", models = "Models" }

    var body: some View {
        let s = store.summary
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Pills(options: Period.allCases, selection: $store.period) { $0.rawValue }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .rotationEffect(.degrees(store.loading ? 360 : 0))
                        .animation(store.loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: store.loading)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .disabled(store.loading)
                .help("Refresh")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.usd(s.total.cost))
                    .font(.system(size: 42, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText(value: s.total.cost))
                    .animation(.snappy(duration: 0.35), value: s.total.cost)
                Text("\(s.total.calls.formatted()) calls · API estimate")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }

            DailyChart(series: s.chart, start: s.chartStart, span: store.period.chartDays)

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Totals")
                HStack(alignment: .top, spacing: 0) {
                    Stat(label: "Processed", value: Fmt.tokens(s.total.tokens))
                    Stat(label: "Cached", value: Fmt.tokens(s.total.cached))
                    Stat(label: "Input", value: Fmt.tokens(s.total.input))
                    Stat(label: "Output", value: Fmt.tokens(s.total.output))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle("Breakdown")
                    Spacer()
                    Pills(options: Tab.allCases, selection: $tab) { $0.rawValue }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    RowsList(rows: tab == .plans ? s.plans : tab == .harness ? s.harnesses : s.models,
                             total: s.total.cost,
                             plans: tab == .plans ? store.config.plans : [:],
                             period: store.period,
                             loading: store.loading)
                        // Fresh identity per view so the bars sweep in again.
                        .id("\(tab)|\(store.period)")
                }
                .scrollIndicators(.never)
                .frame(height: 250)
            }

            if s.total.unpricedTokens > 0 {
                Label("\(Fmt.tokens(s.total.unpricedTokens)) tokens on unknown models aren't in the total. Add prices under priceOverrides in Config.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Text(store.updated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                Spacer()
                Button {
                    let app = SMAppService.mainApp
                    if app.status == .enabled { try? app.unregister() } else { try? app.register() }
                    opensAtLogin = app.status == .enabled
                } label: {
                    Label("Open at login", systemImage: opensAtLogin ? "checkmark.circle.fill" : "circle")
                }
                Button("Config") { NSWorkspace.shared.open(Paths.config) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
        }
        .padding(18)
        .frame(width: 460)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        // Also darkens the menu window itself, so the panel looks the same when the Mac is in light mode.
        .preferredColorScheme(.dark)
    }
}

/// Segmented control styled as a dark pill track with a lifted selected segment.
private struct Pills<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var ns
    @State private var hovered: T?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : hovered == option ? Color.white.opacity(0.8) : Theme.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.white.opacity(0.11))
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option : (hovered == option ? nil : hovered) }
            }
        }
        // Scoped here so only the pill slides; the rest of the panel swaps instantly.
        .animation(.snappy(duration: 0.22), value: selection)
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold))
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 17, weight: .medium).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chart

private struct DailyChart: View {
    let series: [ChartSeries]
    let start: Date
    let span: Int
    @State private var hover: Int?

    private static let axisWidth: CGFloat = 46

    /// Rounds the peak up to 1/2/2.5/5 x 10^n so gridlines land on readable values.
    private var scale: (top: Double, step: Double) {
        let peak = series.flatMap(\.values).max() ?? 0
        guard peak > 0 else { return (60, 20) }
        let rough = peak / 3
        let mag = pow(10, floor(log10(rough)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= rough } ?? 10 * mag
        return (step * ceil(peak / step), step)
    }

    private func date(_ i: Int) -> Date { Calendar.current.date(byAdding: .day, value: i, to: start)! }

    var body: some View {
        let (top, step) = scale
        let hovered = hover.map { i in series.map { ($0.harness, $0.values[i]) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 } }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Daily cost")
                Spacer()
                if let hover, let hovered {
                    Text("\(date(hover).formatted(.dateTime.month(.abbreviated).day()))  ·  \(Fmt.usd(hovered.map(\.1).reduce(0, +)))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                } else {
                    Text("Last \(span) days · \(Fmt.usd(series.flatMap(\.values).reduce(0, +)))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }

            GeometryReader { g in
                let plot = CGRect(x: Self.axisWidth, y: 6, width: g.size.width - Self.axisWidth, height: g.size.height - 6)
                let y = { (v: Double) in plot.maxY - plot.height * v / top }
                let x = { (i: Int) in plot.minX + plot.width * CGFloat(i) / CGFloat(max(span - 1, 1)) }

                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: 0, through: top + step / 2, by: step)), id: \.self) { v in
                        Rectangle().fill(Theme.hairline)
                            .frame(width: plot.width, height: 1)
                            .position(x: plot.midX, y: y(v))
                        Text(v == 0 ? "0" : Fmt.usd(v))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: Self.axisWidth - 8, alignment: .trailing)
                            .position(x: (Self.axisWidth - 8) / 2, y: y(v))
                    }

                    PlotLayer(series: series, top: top)
                        .equatable()
                        .id(span)
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)

                    if let hover, let hovered {
                        Rectangle().fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: plot.height)
                            .position(x: x(hover), y: plot.midY)
                        ForEach(hovered, id: \.0) { h, v in
                            Circle().fill(h.color)
                                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                                .frame(width: 8, height: 8)
                                .position(x: x(hover), y: y(v))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p) where p.x >= plot.minX - 4:
                        let i = Int(((p.x - plot.minX) / plot.width * CGFloat(span - 1)).rounded())
                        hover = min(max(i, 0), span - 1)
                    default:
                        hover = nil
                    }
                }
            }
            .frame(height: 150)

            HStack {
                ForEach(Array([0, span / 3, 2 * span / 3, span - 1].enumerated()), id: \.offset) { n, i in
                    if n > 0 { Spacer() }
                    Text(date(i).formatted(.dateTime.month(.abbreviated).day()).uppercased())
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, Self.axisWidth)

            Legend(items: hovered ?? series.map { ($0.harness, nil) })
        }
    }
}

/// The curves and fills, rasterized on the GPU. Equatable so hovering never redraws it;
/// a new `.id` (period change) replays the left-to-right sweep.
private struct PlotLayer: View, Equatable {
    let series: [ChartSeries]
    let top: Double
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: Self, b: Self) -> Bool { a.series == b.series && a.top == b.top }

    var body: some View {
        ZStack {
            ForEach(series) { s in
                Curve(values: s.values, top: top, closed: true)
                    .fill(LinearGradient(colors: [s.harness.color.opacity(0.3), s.harness.color.opacity(0.01)],
                                         startPoint: .top, endPoint: .bottom))
                Curve(values: s.values, top: top, closed: false)
                    .stroke(s.harness.color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
        .mask(alignment: .leading) {
            Rectangle().scaleEffect(x: progress, y: 1, anchor: .leading)
        }
        .drawingGroup()
        .onAppear {
            if reduceMotion { progress = 1 } else { withAnimation(Theme.sweep) { progress = 1 } }
        }
    }
}

/// Monotone cubic (Fritsch-Carlson) curve: smooth, but never dips below zero or overshoots a peak.
private struct Curve: Shape {
    let values: [Double]
    let top: Double
    let closed: Bool

    func path(in r: CGRect) -> Path {
        let n = values.count
        guard n > 1, top > 0 else { return Path() }
        let p = values.enumerated().map { i, v in
            CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(n - 1), y: r.maxY - r.height * CGFloat(v / top))
        }
        let dx = (0..<n - 1).map { p[$0 + 1].x - p[$0].x }
        let s = (0..<n - 1).map { (p[$0 + 1].y - p[$0].y) / dx[$0] }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = s[0]; m[n - 1] = s[n - 2]
        for i in 1..<n - 1 { m[i] = s[i - 1] * s[i] <= 0 ? 0 : (s[i - 1] + s[i]) / 2 }
        for i in 0..<n - 1 {
            if s[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / s[i], b = m[i + 1] / s[i], h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * s[i]; m[i + 1] = t * b * s[i] }
        }
        var path = Path()
        path.move(to: p[0])
        for i in 0..<n - 1 {
            let d = dx[i] / 3
            path.addCurve(to: p[i + 1],
                          control1: CGPoint(x: p[i].x + d, y: p[i].y + m[i] * d),
                          control2: CGPoint(x: p[i + 1].x - d, y: p[i + 1].y - m[i + 1] * d))
        }
        if closed {
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            path.closeSubpath()
        }
        return path
    }
}

private struct Legend: View {
    let items: [(Harness, Double?)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { h, cost in
                HStack(spacing: 5) {
                    Circle().fill(h.color).frame(width: 7, height: 7)
                    Text(h.rawValue).foregroundStyle(Theme.secondary)
                    if let cost { Text(Fmt.usd(cost)).monospacedDigit() }
                }
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

// MARK: - Breakdown

private struct RowsList: View {
    let rows: [Row]
    let total: Double
    let plans: [String: Double]
    let period: Period
    let loading: Bool
    @State private var grow: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let top = rows.map(\.cost).max() ?? 0
        VStack(spacing: 0) {
            ForEach(rows) { row in
                UsageRow(row: row, total: total, share: top > 0 ? row.cost / top : 0, grow: grow,
                         monthly: plans[row.name], period: period)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            if rows.isEmpty {
                Text(loading ? "Scanning logs…" : "No usage in this period")
                    .font(.callout).foregroundStyle(Theme.secondary).padding(.vertical, 30)
            }
        }
        .onAppear {
            if reduceMotion { grow = 1 } else { withAnimation(Theme.sweep) { grow = 1 } }
        }
    }
}

private struct UsageRow: View {
    let row: Row
    let total: Double
    let share: Double
    let grow: CGFloat
    let monthly: Double?
    let period: Period

    private var unpriced: Bool { row.unpricedTokens == row.tokens && row.tokens > 0 }

    private var percent: String {
        guard total > 0, row.cost > 0 else { return "0%" }
        let pct = row.cost / total * 100
        return pct < 0.1 ? "<0.1%" : String(format: "%.1f%%", pct)
    }

    var body: some View {
        let color = row.harness?.color ?? Theme.secondary
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(row.name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(row.calls.formatted()) calls").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 8)
                Text(unpriced ? "no price" : Fmt.usd(row.cost))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(unpriced ? .orange : .primary)
            }
            HStack {
                Text("\(percent) of cost · \(Fmt.tokens(row.tokens)) tokens")
                Spacer()
                if let monthly, monthly > 0, period == .month {
                    Text("\(String(format: "%.1f", row.cost / monthly))× your \(Fmt.usd(monthly))")
                        .fontWeight(.semibold)
                        .foregroundStyle(row.cost > monthly ? .green : Theme.secondary)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 16)
            if !row.detail.isEmpty, row.detail != row.name {
                Text(row.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
            }
            // Transform-only scaling: no layout pass per animation frame.
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0.9), color.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 3)
                .scaleEffect(x: max(0.004, share * grow), y: 1, anchor: .leading)
                .padding(.leading, 16)
                .padding(.top, 2)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .help("\(Fmt.tokens(row.input)) in · \(Fmt.tokens(row.cached)) cached · \(Fmt.tokens(row.output)) out")
    }
}

import Foundation
import Observation

/// Parsed events per log file, reused while the file's size and mtime are unchanged.
private struct FileCache: Codable {
    struct Entry: Codable {
        var size: Int
        var modified: Date
        var events: [UsageEvent]
    }
    var files: [String: Entry] = [:]
}

enum Scanner {
    /// Returns every usage event, deduped, re-parsing only files that changed since the last scan.
    static func scan() -> [UsageEvent] {
        var cache = (try? Data(contentsOf: Paths.cache))
            .flatMap { try? PropertyListDecoder().decode(FileCache.self, from: $0) } ?? FileCache()
        var fresh = FileCache()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        func stamp(_ url: URL) -> (Int, Date)? {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
                  let size = v.fileSize, let mod = v.contentModificationDate else { return nil }
            return (size, mod)
        }
        for source in Source.all {
            for root in source.roots.map({ Paths.home.appendingPathComponent($0) }) {
                var files = [root]
                if (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))?
                        .compactMap { $0 as? URL } ?? []
                }
                for url in files where url.pathExtension == source.ext {
                    if let skip = source.skipSuffix, url.lastPathComponent.hasSuffix(skip) { continue }
                    guard var (size, mod) = stamp(url) else { continue }
                    // SQLite writes land in the -wal file first.
                    if let (wsize, wmod) = stamp(URL(fileURLWithPath: url.path + "-wal")) { size += wsize; mod = max(mod, wmod) }
                    if let hit = cache.files[url.path], hit.size == size, hit.modified == mod {
                        fresh.files[url.path] = hit
                    } else {
                        fresh.files[url.path] = .init(size: size, modified: mod, events: source.parse(url))
                    }
                    cache.files[url.path] = nil
                }
            }
        }
        // Keep entries for logs deleted since (e.g. Claude Code's 30-day cleanup) so history survives.
        let roots = Source.all.flatMap(\.roots).map { Paths.home.appendingPathComponent($0).path }
        for (path, entry) in cache.files
        where !FileManager.default.fileExists(atPath: path) && roots.contains(where: path.hasPrefix) {
            fresh.files[path] = entry
        }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        try? enc.encode(fresh).write(to: Paths.cache, options: .atomic)

        var seen = Set<String>()
        return fresh.files.values.flatMap(\.events).filter { seen.insert($0.id).inserted }
    }
}

enum Period: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 Days", month = "Month", all = "All"
    var id: Self { self }

    func contains(_ d: Date, now: Date = .now) -> Bool {
        let cal = Calendar.current
        switch self {
        case .today: return cal.isDateInToday(d)
        case .week: return d >= cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        case .month: return cal.isDate(d, equalTo: now, toGranularity: .month)
        case .all: return true
        }
    }

    /// How many days the daily chart covers, ending today.
    var chartDays: Int {
        switch self {
        case .today: 14
        case .week: 7
        case .month: 30
        case .all: 90
        }
    }
}

struct Row: Identifiable, Sendable {
    var id: String { name + detail }
    var name: String
    var detail: String = ""
    var harness: Harness?
    var tokens = 0
    var input = 0
    var cached = 0
    var output = 0
    var reasoning = 0
    var cost = 0.0
    var unpricedTokens = 0
    var calls = 0

    mutating func add(_ e: UsageEvent, cost c: Double?) {
        tokens += e.total
        input += e.input + e.cacheWrite
        cached += e.cacheRead
        output += e.output
        reasoning += e.reasoning
        calls += 1
        if let c { cost += c } else { unpricedTokens += e.total }
    }
}

/// One harness's cost per day across the chart window, oldest first, zero on idle days.
struct ChartSeries: Identifiable, Equatable, Sendable {
    var harness: Harness
    var values: [Double]
    var id: Harness { harness }
}

struct Summary: Sendable {
    var total = Row(name: "Total")
    var plans: [Row] = []
    var harnesses: [Row] = []
    var models: [Row] = []
    var chartStart: Date
    var chart: [ChartSeries] = []

    init(events: [UsageEvent], costs: [Double?], period: Period, config: Config) {
        let hidden = Set(config.hidden ?? [])
        var plans: [String: Row] = [:], planSplit: [String: [String: Double]] = [:]
        var harnesses: [Harness: Row] = [:], models: [String: Row] = [:]
        let cal = Calendar.current
        let span = period.chartDays
        chartStart = cal.date(byAdding: .day, value: 1 - span, to: cal.startOfDay(for: .now))!
        var buckets: [Harness: [Double]] = [:]
        for (e, c) in zip(events, costs) {
            let plan = config.plan(for: e)
            if hidden.contains(plan) || hidden.contains(e.provider) { continue }
            if e.time >= chartStart, let c, c > 0,
               let i = cal.dateComponents([.day], from: chartStart, to: e.time).day, i < span {
                buckets[e.harness, default: Array(repeating: 0, count: span)][i] += c
            }
            guard period.contains(e.time) else { continue }
            total.add(e, cost: c)
            plans[plan, default: Row(name: plan)].add(e, cost: c)
            planSplit[plan, default: [:]][e.harness.rawValue, default: 0] += c ?? 0
            harnesses[e.harness, default: Row(name: e.harness.rawValue, harness: e.harness)].add(e, cost: c)
            let detail = e.harness == .pi ? "Pi · \(e.provider)" : e.harness.rawValue
            models["\(e.harness)|\(e.provider)|\(e.model)", default: Row(name: e.model, detail: detail, harness: e.harness)].add(e, cost: c)
        }
        for (name, split) in planSplit {
            let sorted = split.sorted { $0.value > $1.value }
            plans[name]?.harness = sorted.first.flatMap { Harness(rawValue: $0.key) }
            if split.count > 1 {
                plans[name]?.detail = sorted.map { "\($0.key) \(Fmt.usd($0.value))" }.joined(separator: "  ·  ")
            }
        }
        let byCost: (Row, Row) -> Bool = { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
        self.plans = plans.values.sorted(by: byCost)
        self.harnesses = harnesses.values.sorted(by: byCost)
        self.models = models.values.sorted(by: byCost)
        chart = Harness.allCases.compactMap { h in buckets[h].map { ChartSeries(harness: h, values: $0) } }
    }
}

@MainActor @Observable
final class Store {
    var period: Period = .today
    var config = Config.load()
    var loading = false
    var updated: Date?
    /// Every period is summarized in the background after each scan, so switching periods is a lookup.
    private var summaries: [Period: Summary] = [:]
    private let empty = Summary(events: [], costs: [], period: .today, config: .default)

    var summary: Summary { summaries[period] ?? empty }

    init() {
        Task { await refresh() }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await refresh()
            }
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        config = Config.load()
        await Pricing.refreshIfStale()
        let config = config
        summaries = await Task.detached(priority: .utility) {
            let events = Scanner.scan()
            let costs = Pricing(overrides: config.priceOverrides).costs(events)
            var out: [Period: Summary] = [:]
            for p in Period.allCases { out[p] = Summary(events: events, costs: costs, period: p, config: config) }
            return out
        }.value
        updated = .now
    }
}

enum Fmt {
    static func usd(_ v: Double) -> String {
        v >= 1000 ? String(format: "$%.1fk", v / 1000) : v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return String(format: "%.2fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.1fK", d / 1e3)
        default: return "\(n)"
        }
    }
}

import Foundation

/// USD per token.
struct Price: Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

/// API list prices from LiteLLM's public price table, cached on disk and refreshed daily.
struct Pricing: Sendable {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    private var byName: [String: Price] = [:]
    private var overrides: [String: Price] = [:]

    init(overrides: [String: Config.ManualPrice]) {
        for (k, p) in overrides {
            self.overrides[k.lowercased()] = Price(
                input: p.input / 1e6, output: p.output / 1e6,
                cacheRead: (p.cacheRead ?? p.input * 0.1) / 1e6, cacheWrite: (p.cacheWrite ?? p.input) / 1e6)
        }
        guard let data = try? Data(contentsOf: Paths.prices),
              let table = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        // Prefer the first-party listing when several providers resell the same model.
        func rank(_ key: String) -> Int {
            if !key.contains("/") { return 0 }
            let first = ["openai/", "anthropic/", "xai/", "deepseek/", "zai/", "gemini/", "mistral/", "moonshot/"]
            if first.contains(where: key.hasPrefix) { return 1 }
            return key.hasPrefix("azure") ? 3 : 2
        }
        var bestRank: [String: Int] = [:]
        for (key, v) in table {
            guard let inp = (v["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let out = (v["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            let name = key.lowercased().split(separator: "/").last.map(String.init) ?? key
            let r = rank(key)
            if let b = bestRank[name], b <= r { continue }
            bestRank[name] = r
            byName[name] = Price(
                input: inp, output: out,
                cacheRead: (v["cache_read_input_token_cost"] as? NSNumber)?.doubleValue ?? inp * 0.1,
                cacheWrite: (v["cache_creation_input_token_cost"] as? NSNumber)?.doubleValue ?? inp)
        }
    }

    func price(for model: String) -> Price? {
        for name in Self.candidates(model) {
            if let p = overrides[name] ?? byName[name] { return p }
        }
        return nil
    }

    /// Costs for many events, resolving each distinct model's price once.
    func costs(_ events: [UsageEvent]) -> [Double?] {
        var memo: [String: Price?] = [:]
        return events.map { e in
            if memo[e.model] == nil { memo[e.model] = .some(price(for: e.model)) }
            return cost(e, price: memo[e.model]!)
        }
    }

    /// Harness-internal or free-preview models with no API equivalent; they cost nothing beyond the plan.
    static func isIncluded(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("free") // e.g. "x:free", "x-free" promos
            || m.hasPrefix("stealth/") // OpenRouter stealth previews are free while in testing
            || ["codex-auto-review", "summarizer"].contains(m)
            || m.hasPrefix("swe-") // Devin's in-house models
    }

    private func cost(_ e: UsageEvent, price: Price?) -> Double? {
        // Command Code logs what it actually billed for each call; that beats a list-price estimate.
        if e.harness == .commandCode, e.recordedCost > 0 { return e.recordedCost }
        guard let p = price else {
            if e.recordedCost > 0 { return e.recordedCost }
            return Self.isIncluded(e.model) ? 0 : nil
        }
        return Double(e.input) * p.input + Double(e.cacheRead) * p.cacheRead
            + Double(e.cacheWrite) * p.cacheWrite + Double(e.output) * p.output
    }

    /// "Claude-Opus-5.5-Medium" -> ["claude-opus-5.5-medium", "claude-opus-5.5", "claude-opus-5-5", ...]
    static func candidates(_ model: String) -> [String] {
        var base = model.lowercased()
        if let slash = base.lastIndex(of: "/") { base = String(base[base.index(after: slash)...]) }
        base = base.replacingOccurrences(of: #"\[.*\]$"#, with: "", options: .regularExpression)
        var names = [base]
        var stripped = base
        let suffix = #"-(low|medium|high|xhigh|max|min|minimal|none|fast|slow|thinking|\d{8})$"#
        while let r = stripped.range(of: suffix, options: .regularExpression) {
            stripped.removeSubrange(r)
            names.append(stripped)
        }
        for n in names {
            names.append(n.replacingOccurrences(of: ".", with: "-"))
            names.append(n.replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1.$2", options: .regularExpression))
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Downloads the price table if the cached copy is missing or older than a day.
    static func refreshIfStale() async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.prices.path)
        if let mod = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(mod) < 86_400 { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: sourceURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
        try? data.write(to: Paths.prices, options: .atomic)
    }
}

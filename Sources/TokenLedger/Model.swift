import Foundation

/// The agent app (CLI/harness) that made the model call.
enum Harness: String, Codable, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"
    case pi = "Pi"
    case devin = "Devin"
    case droid = "Droid"
    case commandCode = "Command Code"
}

/// One model call. `input` is always *uncached* input; `output` includes reasoning.
struct UsageEvent: Codable, Sendable {
    var id: String          // dedupe key across files (forks/resumes copy history)
    var time: Date
    var harness: Harness
    var provider: String
    var model: String
    var input: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
    var reasoning: Int
    var recordedCost: Double // cost the harness itself logged (Pi, Command Code), 0 otherwise

    var total: Int { input + cacheRead + cacheWrite + output }
}

struct Config: Codable, Sendable {
    /// Monthly subscription price per plan name.
    var plans: [String: Double]
    /// Pi provider id -> plan name. Unmapped providers are shown under their provider id.
    var piProviderPlans: [String: String]
    /// Manual prices in USD per million tokens, keyed by model id (lowercased).
    var priceOverrides: [String: ManualPrice]
    /// Plan/provider names left out of every total.
    var hidden: [String]?
    /// Harness name -> plan name, e.g. "Claude Code": "Claude Max". Overrides the built-in plan names.
    var harnessPlans: [String: String]?

    struct ManualPrice: Codable, Sendable {
        var input: Double
        var output: Double
        var cacheRead: Double?
        var cacheWrite: Double?
    }

    static let `default` = Config(
        plans: ["ChatGPT Plus": 20, "Claude Pro": 20, "Devin": 20],
        piProviderPlans: ["openai-codex": "ChatGPT Plus", "anthropic": "Claude Pro", "commandcode": "Command Code"],
        priceOverrides: [:],
        hidden: [],
        harnessPlans: [:]
    )

    func plan(for e: UsageEvent) -> String {
        if let custom = harnessPlans?[e.harness.rawValue] { return custom }
        return switch e.harness {
        case .codex: "ChatGPT Plus"
        case .claude: "Claude Pro"
        case .devin: "Devin"
        case .droid: "Factory"
        case .commandCode: "Command Code"
        case .pi: piProviderPlans[e.provider] ?? e.provider
        }
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenLedger")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let config = support.appendingPathComponent("config.json")
    static let cache = support.appendingPathComponent("events-cache.plist")
    static let prices = support.appendingPathComponent("litellm-prices.json")
}

extension Config {
    static func load() -> Config {
        if let data = try? Data(contentsOf: Paths.config),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) { return cfg }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Config.default).write(to: Paths.config)
        return .default
    }
}

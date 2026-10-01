import SwiftUI

@main
struct TokenLedgerApp: App {
    @State private var store = Store()

    init() {
        if CommandLine.arguments.contains("--report") { Self.report(); exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            LedgerView(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }

    /// `TokenLedger --report [today|7|month|all]` prints the same numbers the menu shows.
    static func report() {
        let args = CommandLine.arguments
        let period: Period = args.contains("all") ? .all : args.contains("today") ? .today : args.contains("7") ? .week : .month
        let config = Config.load()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await Pricing.refreshIfStale(); sem.signal() }
        sem.wait()
        let events = Scanner.scan()
        let s = Summary(events: events, costs: Pricing(overrides: config.priceOverrides).costs(events), period: period, config: config)
        func line(_ r: Row) -> String {
            let unpriced = r.unpricedTokens > 0 ? "  (unpriced \(Fmt.tokens(r.unpricedTokens)))" : ""
            return "  \(r.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(r.tokens) = in \(r.input) + cached \(r.cached) + out \(r.output)  \(Fmt.usd(r.cost))\(unpriced)"
        }
        print("\(period.rawValue): \(Fmt.tokens(s.total.tokens)) tokens, \(Fmt.usd(s.total.cost)) API value")
        print("Plans:"); s.plans.forEach { print(line($0)) }
        print("Harness:"); s.harnesses.forEach { print(line($0)) }
        print("Models:"); s.models.forEach { print(line($0) + "  [\($0.detail)]") }
    }
}

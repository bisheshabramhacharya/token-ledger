import Foundation
import SQLite3

/// Log files and the parser that turns each one into usage events.
struct Source: Sendable {
    let roots: [String]
    let ext: String
    var skipSuffix: String?
    let parse: @Sendable (URL) -> [UsageEvent]

    static let all: [Source] = [
        Source(roots: [".codex/sessions", ".codex/archived_sessions"], ext: "jsonl", parse: parseCodex),
        Source(roots: [".claude/projects"], ext: "jsonl", parse: parseClaude),
        Source(roots: [".pi/agent/sessions"], ext: "jsonl", parse: parsePi),
        Source(roots: [".commandcode/projects"], ext: "jsonl", skipSuffix: ".checkpoints.jsonl", parse: parseCommandCode),
        // Devin keeps every call in its session database; transcripts/ only covers some sessions.
        Source(roots: [".local/share/devin/cli/sessions.db"], ext: "db", parse: parseDevin),
        // Droid keeps running per-session totals, not per-call usage.
        Source(roots: [".factory/sessions"], ext: "json", parse: parseDroid),
    ]
}

// MARK: - Helpers

nonisolated(unsafe) private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let isoPlain = ISO8601DateFormatter()

private func date(_ any: Any?) -> Date? {
    if let s = any as? String { return isoFrac.date(from: s) ?? isoPlain.date(from: s) }
    if let n = any as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
    return nil
}

private func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }

/// Calls `body` with each JSON line that contains any of `needles` (cheap byte filter before decoding).
private func forEachJSONLine(_ url: URL, containing needles: [String], _ body: ([String: Any]) -> Void) {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
    let needleData = needles.map { Array($0.utf8) }
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        guard let base = buf.baseAddress else { return }
        var start = 0
        let count = buf.count
        while start < count {
            let rest = count - start
            let nl = memchr(base + start, 0x0A, rest)
            let end = nl.map { base.distance(to: $0) } ?? count
            let len = end - start
            if len > 0 {
                let line = base + start
                let hit = needleData.contains { n in n.withUnsafeBytes { memmem(line, len, $0.baseAddress, n.count) != nil } }
                if hit, let obj = try? JSONSerialization.jsonObject(
                    with: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: len, deallocator: .none)
                ) as? [String: Any] {
                    body(obj)
                }
            }
            start = end + 1
        }
    }
}

// MARK: - Codex (~/.codex/sessions/**/*.jsonl)

/// Codex logs cumulative `total_token_usage`; we take deltas so repeated events count once.
/// `input_tokens` includes cached tokens and `output_tokens` includes reasoning.
@Sendable func parseCodex(_ url: URL) -> [UsageEvent] {
    var events: [UsageEvent] = []
    var model: String?
    var prev: [String: Int] = [:]
    forEachJSONLine(url, containing: ["\"turn_context\"", "\"token_count\""]) { obj in
        guard let payload = obj["payload"] as? [String: Any] else { return }
        if obj["type"] as? String == "turn_context" {
            if let m = payload["model"] as? String {
                // Forked/resumed sessions start with copied token counts before the first turn_context.
                if model == nil { for i in events.indices { events[i].model = m } }
                model = m
            }
            return
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any],
              let time = date(obj["timestamp"]) else { return }
        let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
        var cur: [String: Int] = [:]
        for k in keys { cur[k] = int(total[k]) }
        var d: [String: Int] = [:]
        if cur["input_tokens"]! >= (prev["input_tokens"] ?? 0), cur["output_tokens"]! >= (prev["output_tokens"] ?? 0) {
            for k in keys { d[k] = cur[k]! - (prev[k] ?? 0) }
        } else if let last = info["last_token_usage"] as? [String: Any] {
            for k in keys { d[k] = int(last[k]) } // counter reset (e.g. compaction)
        }
        prev = cur
        guard (d["input_tokens"] ?? 0) + (d["output_tokens"] ?? 0) > 0 else { return }
        let cached = d["cached_input_tokens"] ?? 0
        events.append(UsageEvent(
            id: "codex|\(obj["timestamp"] as? String ?? "")|\(int(total["total_tokens"]))",
            time: time, harness: .codex, provider: "openai", model: model ?? "unknown",
            input: max(0, (d["input_tokens"] ?? 0) - cached), cacheRead: cached,
            cacheWrite: d["cache_write_input_tokens"] ?? 0, output: d["output_tokens"] ?? 0,
            reasoning: d["reasoning_output_tokens"] ?? 0, recordedCost: 0))
    }
    return events
}

// MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

@Sendable func parseClaude(_ url: URL) -> [UsageEvent] {
    var events: [UsageEvent] = []
    forEachJSONLine(url, containing: ["\"usage\""]) { obj in
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",
              let time = date(obj["timestamp"]) else { return }
        events.append(UsageEvent(
            id: "claude|\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")",
            time: time, harness: .claude, provider: "anthropic", model: model,
            input: int(usage["input_tokens"]), cacheRead: int(usage["cache_read_input_tokens"]),
            cacheWrite: int(usage["cache_creation_input_tokens"]), output: int(usage["output_tokens"]),
            reasoning: 0, recordedCost: 0))
    }
    return events
}

// MARK: - Pi (~/.pi/agent/sessions/**/*.jsonl)

/// Pi normalizes usage: `input` is uncached, `output` includes reasoning, and it records its own cost.
@Sendable func parsePi(_ url: URL) -> [UsageEvent] {
    var events: [UsageEvent] = []
    forEachJSONLine(url, containing: ["\"usage\""]) { obj in
        guard let msg = obj["message"] as? [String: Any],
              msg["role"] as? String == "assistant",
              let usage = msg["usage"] as? [String: Any],
              let time = date(msg["timestamp"]) ?? date(obj["timestamp"]) else { return }
        let input = int(usage["input"]), output = int(usage["output"])
        let cacheRead = int(usage["cacheRead"]), cacheWrite = int(usage["cacheWrite"])
        guard input + output + cacheRead + cacheWrite > 0 else { return }
        let cost = ((usage["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue ?? 0
        let key = msg["responseId"] as? String ?? "\(obj["timestamp"] ?? "")|\(input)|\(output)"
        events.append(UsageEvent(
            id: "pi|\(key)", time: time, harness: .pi,
            provider: msg["provider"] as? String ?? "unknown", model: msg["model"] as? String ?? "unknown",
            input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
            reasoning: int(usage["reasoning"]), recordedCost: cost))
    }
    return events
}

// MARK: - Command Code (~/.commandcode/projects/**/*.jsonl)

/// Command Code logs `inputTokens` including cache reads, plus the `costUsd` it billed.
@Sendable func parseCommandCode(_ url: URL) -> [UsageEvent] {
    var events: [UsageEvent] = []
    forEachJSONLine(url, containing: ["\"inputTokens\""]) { obj in
        guard let usage = obj["usage"] as? [String: Any],
              let time = date(obj["timestamp"]) else { return }
        let input = int(usage["inputTokens"]), cacheRead = int(usage["cacheReadTokens"])
        let meta = (obj["message"] as? [String: Any])?["meta"] as? [String: Any]
        let model = obj["model"] as? String ?? "unknown"
        events.append(UsageEvent(
            id: "cc|\(meta?["messageId"] as? String ?? "\(url.lastPathComponent)|\(obj["id"] ?? "")")",
            time: time, harness: .commandCode, provider: "commandcode", model: model,
            input: max(0, input - cacheRead), cacheRead: cacheRead, cacheWrite: int(usage["cacheWriteTokens"]),
            output: int(usage["outputTokens"]), reasoning: 0,
            recordedCost: (usage["costUsd"] as? NSNumber)?.doubleValue ?? 0))
    }
    return events
}

// MARK: - Devin CLI (~/.local/share/devin/cli/sessions.db)

/// Each assistant message node carries metrics; `input_tokens` excludes cache reads.
/// One response can be split across several nodes with the same request_id, so that is the dedupe key.
@Sendable func parseDevin(_ url: URL) -> [UsageEvent] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
    defer { sqlite3_close(db) }
    let sql = """
        SELECT json_extract(m, '$.request_id'), json_extract(m, '$.created_at'), json_extract(m, '$.generation_model'),
               json_extract(m, '$.metrics.input_tokens'), json_extract(m, '$.metrics.cache_read_tokens'),
               json_extract(m, '$.metrics.cache_creation_tokens'), json_extract(m, '$.metrics.output_tokens')
        FROM (SELECT json_extract(chat_message, '$.metadata') AS m FROM message_nodes)
        WHERE json_extract(m, '$.metrics') IS NOT NULL
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    var events: [UsageEvent] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let rid = text(0), let time = date(text(1)) else { continue }
        events.append(UsageEvent(
            id: "devin|\(rid)", time: time, harness: .devin, provider: "devin", model: text(2) ?? "unknown",
            input: Int(sqlite3_column_int64(stmt, 3)), cacheRead: Int(sqlite3_column_int64(stmt, 4)),
            cacheWrite: Int(sqlite3_column_int64(stmt, 5)), output: Int(sqlite3_column_int64(stmt, 6)),
            reasoning: 0, recordedCost: 0))
    }
    return events
}

// MARK: - Droid (~/.factory/sessions/*/<id>.settings.json)

/// Droid keeps only a running total per session, so each session is one event dated by its last write
/// and priced as its current model. `inputTokens` excludes cache reads; subagents have their own files.
/// Unverified whether `outputTokens` includes `thinkingTokens`; treated as included to avoid double counting.
@Sendable func parseDroid(_ url: URL) -> [UsageEvent] {
    let name = url.lastPathComponent
    guard name.hasSuffix(".settings.json"),
          let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let usage = obj["tokenUsage"] as? [String: Any],
          let time = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    else { return [] }
    let input = int(usage["inputTokens"]), output = int(usage["outputTokens"])
    let cacheRead = int(usage["cacheReadTokens"]), cacheWrite = int(usage["cacheCreationTokens"])
    guard input + output + cacheRead + cacheWrite > 0 else { return [] }
    return [UsageEvent(
        id: "droid|\(name.dropLast(".settings.json".count))", time: time, harness: .droid,
        provider: "factory", model: obj["model"] as? String ?? "unknown",
        input: input, cacheRead: cacheRead, cacheWrite: cacheWrite,
        output: output, reasoning: int(usage["thinkingTokens"]), recordedCost: 0)]
}

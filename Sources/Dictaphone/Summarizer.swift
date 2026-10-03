import Foundation
import FoundationModels

struct SummaryResult {
    var title: String?
    var summary: String?
    var actionItems: [String] = []
    var note: String?
}

/// Meeting summaries using Apple's on-device language model (private, offline, no API key).
/// Long meetings are summarized in chunks, then the chunk notes are combined (map-reduce).
enum Summarizer {
    static func summarize(lines: [String]) async -> SummaryResult {
        guard #available(macOS 26.0, *) else {
            return fallback(lines, note: "On-device summaries need macOS 26 or later.")
        }
        return await onDevice(lines)
    }

    @available(macOS 26.0, *)
    private static func onDevice(_ lines: [String]) async -> SummaryResult {
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason):
            return fallback(lines, note: "On-device summaries need Apple Intelligence turned on in System Settings (\(reason)).")
        @unknown default:
            return fallback(lines, note: "On-device summary model unavailable.")
        }
        do {
            var parts = chunk(lines, maxWords: 1000)
            if parts.count > 1 {
                var notes = try await mapNotes(parts)
                while words(notes) > 1000 && notes.count > 1 {
                    let regrouped = chunk(notes, maxWords: 1000)
                    if regrouped.count >= notes.count { break }
                    notes = try await mapNotes(regrouped)
                }
                parts = [notes.joined(separator: "\n")]
            }
            let reply = try await ask("""
                Below is a meeting transcript (or notes taken from it). Reply in EXACTLY this format and nothing else:
                TITLE: <a descriptive title of at most 8 words>
                SUMMARY: <2 to 4 sentences covering the main topics and decisions>
                ACTION ITEMS:
                - <task, with the owner's name if mentioned>
                (write "- None" if there are no tasks)

                \(parts[0])
                """)
            return parse(reply)
        } catch {
            log("summary failed: \(error)")
            return fallback(lines, note: "Summary failed: \(error.localizedDescription)")
        }
    }

    @available(macOS 26.0, *)
    private static func ask(_ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: "You write accurate, concise meeting notes. Never invent details.")
        return try await session.respond(to: prompt).content
    }

    @available(macOS 26.0, *)
    private static func mapNotes(_ parts: [String]) async throws -> [String] {
        var out: [String] = []
        for p in parts {
            out.append(try await ask("""
                Summarize this part of a meeting transcript as 3-6 concise bullet points. \
                Include decisions, and any tasks with who owns them.

                \(p)
                """))
        }
        return out
    }

    private static func words(_ a: [String]) -> Int { a.reduce(0) { $0 + $1.split(separator: " ").count } }

    private static func chunk(_ lines: [String], maxWords: Int) -> [String] {
        var out: [String] = [], cur: [String] = [], n = 0
        for l in lines {
            let w = l.split(separator: " ").count
            if n + w > maxWords && !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = []; n = 0 }
            cur.append(l); n += w
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n")) }
        return out
    }

    private static func parse(_ reply: String) -> SummaryResult {
        var r = SummaryResult()
        var section = ""
        var summary: [String] = []
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("TITLE:") {
                r.title = String(line.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " *\""))
                section = "title"
            } else if line.uppercased().hasPrefix("SUMMARY:") {
                summary.append(String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces))
                section = "summary"
            } else if line.uppercased().hasPrefix("ACTION ITEMS") {
                section = "actions"
            } else if section == "summary", !line.isEmpty {
                summary.append(line)
            } else if section == "actions", line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") {
                let item = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespaces))
                if !item.isEmpty, !["none", "none."].contains(item.lowercased()) { r.actionItems.append(item) }
            }
        }
        let s = summary.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        r.summary = s.isEmpty ? reply.trimmingCharacters(in: .whitespacesAndNewlines) : s
        if r.title?.isEmpty == true { r.title = nil }
        return r
    }

    /// No model available: pull out lines that sound like commitments.
    private static func fallback(_ lines: [String], note: String) -> SummaryResult {
        let pattern = try? NSRegularExpression(
            pattern: #"\b(i'll|i will|we'll|we will|need to|action item|follow up|follow-up|remind me|will send|going to)\b"#,
            options: .caseInsensitive)
        let items = lines.filter { l in
            pattern?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }.prefix(10).map { String($0) }
        return SummaryResult(title: nil, summary: nil, actionItems: Array(items), note: note)
    }
}

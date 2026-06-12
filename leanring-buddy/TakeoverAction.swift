//
//  TakeoverAction.swift
//  leanring-buddy
//
//  The action vocabulary for offline takeover mode. The local vision model
//  emits exactly one of these as JSON per turn; the controller guards it and
//  the executor performs it. Deliberately tiny — seven verbs a 3B model can
//  emit reliably.
//

import Foundation

enum TakeoverScrollDirection: String {
    case up, down, left, right
}

enum TakeoverAction {
    /// Left-click at a pixel in the screenshot's coordinate space.
    case click(x: Int, y: Int, targetLabel: String, why: String)
    /// Type literal text. Never presses Return — submission is a separate `key`.
    case type(text: String, why: String)
    /// A key or combo: "return", "esc", "cmd+s", "cmd+shift+t".
    case key(combo: String, why: String)
    /// Scroll at a point.
    case scroll(x: Int, y: Int, direction: TakeoverScrollDirection, amount: Int, why: String)
    /// Task complete — the loop exits cleanly.
    case done(summary: String)
    /// The model can't proceed — the loop exits and speaks the reason.
    case giveUp(reason: String)

    /// One-clause rationale, used for TTS narration and the audit trace.
    var narration: String {
        switch self {
        case .click(_, _, let targetLabel, let why): return why.isEmpty ? "clicking \(targetLabel)" : why
        case .type(_, let why): return why.isEmpty ? "typing" : why
        case .key(let combo, let why): return why.isEmpty ? "pressing \(combo)" : why
        case .scroll(_, _, let direction, _, let why): return why.isEmpty ? "scrolling \(direction.rawValue)" : why
        case .done(let summary): return summary
        case .giveUp(let reason): return reason
        }
    }

    /// Short label for the audit trace ("click Save (480,300)").
    var traceLabel: String {
        switch self {
        case .click(let x, let y, let targetLabel, _): return "click \(targetLabel) (\(x),\(y))"
        case .type(let text, _): return "type \"\(text.prefix(24))\""
        case .key(let combo, _): return "key \(combo)"
        case .scroll(_, _, let direction, let amount, _): return "scroll \(direction.rawValue) \(amount)"
        case .done(let summary): return "done: \(summary.prefix(40))"
        case .giveUp(let reason): return "give_up: \(reason.prefix(40))"
        }
    }

    /// True if two actions are "the same move" for stuck-detection: same verb,
    /// coordinates within ~10px, same text/combo.
    static func areEquivalent(_ lhs: TakeoverAction, _ rhs: TakeoverAction) -> Bool {
        switch (lhs, rhs) {
        case let (.click(ax, ay, _, _), .click(bx, by, _, _)):
            return abs(ax - bx) <= 10 && abs(ay - by) <= 10
        case let (.type(at, _), .type(bt, _)):
            return at == bt
        case let (.key(ac, _), .key(bc, _)):
            return ac.lowercased() == bc.lowercased()
        case let (.scroll(_, _, ad, _, _), .scroll(_, _, bd, _, _)):
            return ad == bd
        default:
            return false
        }
    }
}

/// Parses the single JSON action object out of a local model's raw output.
/// Tolerant of ```json fences and leading/trailing prose; rejects multi-action
/// output and out-of-vocab verbs.
enum TakeoverActionParser {
    enum ParseError: LocalizedError {
        case noJSONObject
        case unknownAction(String)
        case missingField(String)
        var errorDescription: String? {
            switch self {
            case .noJSONObject: return "no json action found in model output"
            case .unknownAction(let action): return "unknown action \"\(action)\""
            case .missingField(let field): return "action missing field \"\(field)\""
            }
        }
    }

    static func parse(_ rawModelOutput: String) throws -> TakeoverAction {
        guard let jsonObjectString = firstJSONObject(in: rawModelOutput),
              let jsonData = jsonObjectString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ParseError.noJSONObject
        }

        guard let actionName = object["action"] as? String else {
            throw ParseError.missingField("action")
        }

        func stringField(_ name: String) -> String { (object[name] as? String) ?? "" }
        func intField(_ name: String) -> Int? {
            if let intValue = object[name] as? Int { return intValue }
            if let doubleValue = object[name] as? Double { return Int(doubleValue) }
            if let stringValue = object[name] as? String { return Int(stringValue) }
            return nil
        }

        switch actionName.lowercased() {
        case "click":
            guard let x = intField("x"), let y = intField("y") else { throw ParseError.missingField("x/y") }
            return .click(x: x, y: y, targetLabel: stringField("target_label"), why: stringField("why"))
        case "type":
            return .type(text: stringField("text"), why: stringField("why"))
        case "key":
            let combo = stringField("combo")
            guard !combo.isEmpty else { throw ParseError.missingField("combo") }
            return .key(combo: combo, why: stringField("why"))
        case "scroll":
            guard let x = intField("x"), let y = intField("y") else { throw ParseError.missingField("x/y") }
            let direction = TakeoverScrollDirection(rawValue: stringField("dir").lowercased()) ?? .down
            let amount = intField("amount") ?? 3
            return .scroll(x: x, y: y, direction: direction, amount: max(1, min(amount, 5)), why: stringField("why"))
        case "done":
            return .done(summary: stringField("summary"))
        case "give_up", "giveup":
            return .giveUp(reason: stringField("reason"))
        default:
            throw ParseError.unknownAction(actionName)
        }
    }

    /// Returns the first balanced `{...}` substring, ignoring code fences.
    private static func firstJSONObject(in text: String) -> String? {
        let characters = Array(text)
        guard let openIndex = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var insideString = false
        var escaped = false
        var endIndex: Int?
        for index in openIndex..<characters.count {
            let character = characters[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { insideString.toggle(); continue }
            if insideString { continue }
            if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { endIndex = index; break }
            }
        }
        guard let closeIndex = endIndex else { return nil }
        return String(characters[openIndex...closeIndex])
    }
}

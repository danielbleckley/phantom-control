import Foundation

/// A parsed value from the Phantom ASCII control protocol.
/// Responses look like `info : { hwver : 135, name : "10706", res : 2560 x 1600, flags : { STR TRG } }`
/// with `\` line continuations and CRLF terminators.
public enum PhValue {
    case number(Double)
    case string(String)
    case dict([String: PhValue])
    case flags([String])
    case raw(String)

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .raw(let s), .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var intValue: Int? { doubleValue.map { Int($0) } }

    public var stringValue: String? {
        switch self {
        case .string(let s), .raw(let s): return s
        case .number(let n): return String(n)
        case .flags(let f): return f.joined(separator: " ")
        default: return nil
        }
    }

    public var dictValue: [String: PhValue]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    public var flagsValue: [String]? {
        switch self {
        case .flags(let f): return f
        case .raw(let s): return s.split(separator: " ").map(String.init)
        default: return nil
        }
    }

    /// Parses `2560 x 1600` style resolution values.
    public var sizeValue: (width: Int, height: Int)? {
        guard let s = stringValue else { return nil }
        let parts = s.lowercased().split(separator: "x").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }
}

public enum PhantomProtocol {

    /// Strips `\`-newline continuations and collapses the response into one logical line.
    public static func normalize(_ response: String) -> String {
        var s = response.replacingOccurrences(of: "\\\r\n", with: " ")
        s = s.replacingOccurrences(of: "\\\n", with: " ")
        s = s.replacingOccurrences(of: "\\\r", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Parses a full response like `key : value` (possibly several pairs) into a dictionary.
    /// For `get info` the result has one key `info` whose value is a dict.
    public static func parse(_ response: String) -> [String: PhValue] {
        let n = normalize(response)
        var scanner = ProtocolScanner(n)
        // Some replies (e.g. `fstat`) are a bare braced dict with no key.
        if n.hasPrefix("{") {
            if case .dict(let d) = scanner.parseValue(terminators: []) { return d }
            scanner = ProtocolScanner(n)
        }
        return scanner.parsePairs(terminators: [])
    }

    /// Depth-first search for the first occurrence of `key` anywhere in a parsed response.
    public static func find(_ key: String, in parsed: [String: PhValue]) -> PhValue? {
        if let v = parsed[key] { return v }
        for (_, v) in parsed {
            if case .dict(let d) = v, let found = find(key, in: d) { return found }
        }
        return nil
    }

    /// True when a control-channel response buffer is complete (balanced braces, CRLF-terminated).
    public static func isComplete(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        var depth = 0
        var inString = false
        for byte in data {
            let c = Character(UnicodeScalar(byte))
            if inString { if c == "\"" { inString = false }; continue }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
        }
        guard depth == 0 else { return false }
        // Must end with a newline that is not a continuation.
        guard let lastNL = data.lastIndex(where: { $0 == 0x0A }) else { return false }
        if lastNL != data.index(before: data.endIndex) {
            // trailing bytes after the last newline -> still receiving
            if data[data.index(after: lastNL)...].contains(where: { $0 != 0x0D && $0 != 0x20 }) { return false }
        }
        // A continuation backslash right before the newline means more is coming.
        var i = lastNL
        while i > data.startIndex {
            i = data.index(before: i)
            let b = data[i]
            if b == 0x0D || b == 0x20 || b == 0x09 { continue }
            return b != 0x5C // '\'
        }
        return true
    }
}

private struct ProtocolScanner {
    let chars: [Character]
    var pos = 0

    init(_ s: String) { chars = Array(s) }

    mutating func skipWS() { while pos < chars.count, chars[pos] == " " || chars[pos] == "," { pos += 1 } }

    mutating func parsePairs(terminators: Set<Character>) -> [String: PhValue] {
        var result: [String: PhValue] = [:]
        while true {
            skipWS()
            guard pos < chars.count, !terminators.contains(chars[pos]) else { break }
            guard let key = parseIdentifier() else { break }
            skipWS()
            if pos < chars.count, chars[pos] == ":" {
                pos += 1
                result[key] = parseValue(terminators: terminators)
            } else if pos < chars.count, chars[pos] == "{" {
                // `Ok! { cine : 0, res : 2560 x 1600 }` — braced payload after a bare token
                result[key] = parseValue(terminators: terminators)
            } else {
                // bare token — store as flag-style marker
                result[key] = .raw(key)
            }
        }
        return result
    }

    mutating func parseIdentifier() -> String? {
        skipWS()
        var out = ""
        while pos < chars.count {
            let c = chars[pos]
            if c == ":" || c == "{" || c == "}" || c == "," || c == " " { break }
            out.append(c); pos += 1
        }
        return out.isEmpty ? nil : out
    }

    mutating func parseValue(terminators: Set<Character>) -> PhValue {
        skipWS()
        guard pos < chars.count else { return .raw("") }
        let c = chars[pos]
        if c == "{" {
            pos += 1
            return parseBraced()
        }
        if c == "\"" {
            pos += 1
            var out = ""
            while pos < chars.count, chars[pos] != "\"" { out.append(chars[pos]); pos += 1 }
            if pos < chars.count { pos += 1 }
            return .string(out)
        }
        // Bare value: read until comma or closing brace. Handles `2560 x 1600`.
        var out = ""
        while pos < chars.count {
            let ch = chars[pos]
            if ch == "," || ch == "}" || terminators.contains(ch) { break }
            out.append(ch); pos += 1
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        if let n = Double(trimmed) { return .number(n) }
        return .raw(trimmed)
    }

    /// Already past `{`. Decides between key:value dict and bare flag list like `{ STR TRG ABL }`.
    mutating func parseBraced() -> PhValue {
        // Peek ahead for a ':' before the matching '}'
        var depth = 1
        var i = pos
        var sawColon = false
        var inString = false
        while i < chars.count, depth > 0 {
            let c = chars[i]
            if inString { if c == "\"" { inString = false }; i += 1; continue }
            if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1 }
            else if c == ":" && depth == 1 { sawColon = true; break }
            i += 1
        }
        if sawColon {
            let d = parsePairs(terminators: ["}"])
            skipWS()
            if pos < chars.count, chars[pos] == "}" { pos += 1 }
            return .dict(d)
        } else {
            var flags: [String] = []
            while pos < chars.count, chars[pos] != "}" {
                if let id = parseIdentifier() { flags.append(id) } else { pos += 1 }
                skipWS()
            }
            if pos < chars.count { pos += 1 }
            return .flags(flags)
        }
    }
}

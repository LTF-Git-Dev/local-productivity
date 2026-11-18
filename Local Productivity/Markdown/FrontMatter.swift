//
//  FrontMatter.swift
//  Local Productivity
//
//  Reads and edits single keys in a note's YAML front matter without disturbing the
//  rest of it. The app only ever needs simple scalars (a page icon, a date), so the
//  YAML is treated as lines of text rather than parsed and regenerated.
//

import Foundation

nonisolated enum FrontMatter {

    /// The scalar value of a top-level key, with surrounding quotes removed.
    static func value(for key: String, in yaml: String?) -> String? {
        guard let yaml else { return nil }
        for line in yaml.components(separatedBy: "\n") {
            guard let entry = entry(in: line), entry.key == key else { continue }
            let value = unquoted(entry.value)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `yaml` with `key` set to `value`, or removed when `value` is nil.
    /// Returns nil when no front matter is left.
    static func setting(_ value: String?, for key: String, in yaml: String?) -> String? {
        var lines = yaml.map { $0.components(separatedBy: "\n") } ?? []
        if lines == [""] { lines = [] }

        if let index = lines.firstIndex(where: { entry(in: $0)?.key == key }) {
            // A key can own indented or list lines beneath it; they go with it.
            var end = index + 1
            while end < lines.count, let first = lines[end].first, first == " " || first == "\t" || lines[end].hasPrefix("- ") {
                end += 1
            }
            if let value {
                lines.replaceSubrange(index..<end, with: ["\(key): \(quoted(value))"])
            } else {
                lines.removeSubrange(index..<end)
            }
        } else if let value {
            lines.append("\(key): \(quoted(value))")
        }

        if lines.allSatisfy({ $0.trimmingWhitespace.isEmpty }) { return nil }
        return lines.joined(separator: "\n")
    }

    private static func entry(in line: String) -> (key: String, value: String)? {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
              let colon = line.firstIndex(of: ":") else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return (line[..<colon].trimmingWhitespace, after.trimmingWhitespace)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner
    }

    private static func quoted(_ value: String) -> String {
        let needsQuotes = value.isEmpty
            || value != value.trimmingWhitespace
            || value.contains(": ") || value.contains(" #")
            || "[]{}>|*&!%@`#\"',?-".contains(value.first ?? "a")
        guard needsQuotes else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

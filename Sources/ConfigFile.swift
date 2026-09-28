import Foundation

/// Errors surfaced by the config edit primitives. Paths are carried through so
/// callers can report which file failed without re-deriving it.
enum ConfigError: Error {
    case missing(String)
    case unreadable(String, String)
    case malformed(String, String)
    case write(String, String)
}

/// A `provider/model` reference. Model ids themselves contain slashes
/// (`deepseek/deepseek-v4.1-flash`), so the split happens on the **first** `/`
/// only; everything after it is the model verbatim, colons and all
/// (`qwen3.8:latest`).
struct ToolModelRef: Equatable {
    var provider: String
    var model: String

    var qualified: String { "\(provider)/\(model)" }

    static func parse(_ raw: String) -> ToolModelRef? {
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        let provider = String(raw[raw.startIndex..<slash])
        let model = String(raw[raw.index(after: slash)...])
        return ToolModelRef(provider: provider, model: model)
    }
}

/// Byte-preserving edits to agent configuration files. Nothing here parses and
/// re-serializes a document: the value token is swapped in place and every other
/// byte is carried through untouched. Each mutation backs up the pre-write bytes
/// to `<path>.bak` and then writes via a same-directory temp file + rename.
enum ConfigFile {

    static func read(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.missing(path)
        }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(path, "\(error)")
        }
    }

    /// Copies the current bytes to `<path>.bak`. Called before any write so the
    /// backup is always the pre-write state.
    static func backup(_ path: String) throws {
        let contents = try read(path)
        do {
            try contents.write(toFile: path + ".bak", atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError.write(path + ".bak", "\(error)")
        }
    }

    /// Atomic within a filesystem: write a sibling temp file, then `rename` over
    /// the target. The temp file must live in the target's directory because
    /// `rename` across devices fails, and the system temp dir may be a different
    /// volume than the config file.
    static func atomicWrite(_ contents: String, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let dir = directory.isEmpty ? FileManager.default.currentDirectoryPath : directory
        let temp = "\(dir)/.ProviderCostController-\(UUID().uuidString).tmp"
        do {
            try contents.write(toFile: temp, atomically: false, encoding: .utf8)
            // rename replaces the inode, so a fresh temp file would reset the
            // target's mode to the default (~0644). Configs can hold API keys;
            // preserve whatever mode the user had rather than loosening it.
            if let mode = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp)
            }
            if rename(temp, path) != 0 {
                let message = String(cString: strerror(errno))
                try? FileManager.default.removeItem(atPath: temp)
                throw ConfigError.write(path, message)
            }
        } catch let error as ConfigError {
            throw error
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw ConfigError.write(path, "\(error)")
        }
    }

    /// Replaces the string value of a top-level key, or inserts the key when it
    /// is absent. Returns the new contents as well as writing them.
    static func setJSONString(_ key: String, to value: String, in path: String) throws -> String {
        let original = try read(path)
        let literalKey = jsonEscaped(key)

        // Top-level-key anchoring. The brief calls this "column 0", but the
        // binding fixtures (and the real configs) pretty-print top-level keys
        // with one indent and nest deeper keys under more. A literal
        // no-leading-whitespace match would therefore miss the top-level key
        // and insert a duplicate; the discriminator that actually protects a
        // nested `provider.omlx.model` is matching the document's top-level
        // indentation exactly, never a deeper indent. Do not loosen this to a
        // bare substring match.
        let detectedIndent = topLevelIndent(in: original)
        // Minified JSON (or otherwise unindented) has no line-start key to key
        // off. Matching nothing and inserting would leave a duplicate key, so
        // fail loudly instead. The carve-out matters: an empty `{}` has no keys
        // to duplicate and must still take the insert path.
        if detectedIndent == nil && containsKeyText(original) {
            throw ConfigError.malformed(path, "no top-level indentation to key off (minified JSON is not supported)")
        }
        let indent = detectedIndent ?? ""
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: indent))\"\(NSRegularExpression.escapedPattern(for: key))\"[ \\t]*:[ \\t]*\"([^\"]*)\""
        let regex = try compile(pattern, path: path)
        let full = NSRange(original.startIndex..., in: original)

        let updated: String
        if let match = regex.firstMatch(in: original, range: full),
           let valueRange = Range(match.range(at: 1), in: original) {
            updated = original.replacingCharacters(in: valueRange, with: jsonEscaped(value))
        } else {
            // Absent key must insert, never silently no-op: a fresh install may
            // have no top-level key at all, and reporting success while changing
            // nothing is worse than failing.
            updated = try insertingTopLevelEntry("\"\(literalKey)\": \"\(jsonEscaped(value))\"",
                                                 indent: indent, into: original, path: path)
        }

        try backup(path)
        try atomicWrite(updated, to: path)
        return updated
    }

    /// Replaces a top-level `key: value` line, or appends one when absent — the
    /// same absent-key rule as `setJSONString`. Returns the new contents.
    static func setYAMLScalar(_ key: String, to value: String, in path: String) throws -> String {
        let original = try read(path)

        // YAML top-level keys start at column 0; a nested key is indented, so
        // requiring no leading whitespace before the key is exactly the
        // protection a nested same-name key needs.
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key))[ \\t]*:.*$"
        let regex = try compile(pattern, path: path)
        let full = NSRange(original.startIndex..., in: original)

        let updated: String
        if let match = regex.firstMatch(in: original, range: full),
           let lineRange = Range(match.range, in: original) {
            updated = original.replacingCharacters(in: lineRange, with: "\(key): \(value)")
        } else {
            let separator = original.isEmpty || original.hasSuffix("\n") ? "" : "\n"
            updated = original + separator + "\(key): \(value)\n"
        }

        try backup(path)
        try atomicWrite(updated, to: path)
        return updated
    }

    /// True when the document contains a JSON string token before its final
    /// closing brace, i.e. it has keys even though no line-start key established
    /// a top-level indent. Distinguishes minified-from-empty for the carve-out.
    private static func containsKeyText(_ text: String) -> Bool {
        guard let closing = text.lastIndex(of: "}") else { return false }
        return text[..<closing].contains("\"")
    }

    /// The indentation shared by the document's top-level keys. In a
    /// pretty-printed object the first key line is a top-level key, and all
    /// top-level keys share its indent while nested keys are deeper. Returns nil
    /// for a minified document (no key starts its own line), where the caller
    /// falls back to a column-0 match.
    private static func topLevelIndent(in text: String) -> String? {
        let pattern = "(?m)^([ \\t]*)\"[^\"]*\"[ \\t]*:"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func insertingTopLevelEntry(_ entry: String, indent: String,
                                               into text: String, path: String) throws -> String {
        guard let closing = text.lastIndex(of: "}") else {
            throw ConfigError.malformed(path, "no final closing brace to insert before")
        }
        let body = text[..<closing]
        let trailing = body.reversed().prefix { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        let trimmed = body.dropLast(trailing.count)
        // An empty object (`{}`) takes no separating comma.
        let comma = trimmed.hasSuffix("{") ? "" : ","
        // Insert immediately before the final brace at the document's own
        // top-level indent; existing bytes keep their positions, only a
        // comma/newline/entry is added around them.
        return trimmed + comma + "\n" + indent + entry + String(trailing.reversed()) + "}" + text[text.index(after: closing)...]
    }

    private static func compile(_ pattern: String, path: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            throw ConfigError.malformed(path, "\(error)")
        }
    }

    private static func jsonEscaped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

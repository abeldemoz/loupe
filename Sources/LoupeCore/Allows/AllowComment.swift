/// `// loupe:allow <rule-id> -- <reason>`: excuses one violation of one rule, on the line it
/// annotates (trailing) or on the line below it (standalone).
struct AllowComment: Sendable, Equatable {
    static let marker = "loupe:allow"

    var location: SourceLocation
    /// Nil when the comment names no rule at all.
    var ruleID: String?
    /// Nil when there is no `-- reason`, or the reason is empty.
    var reason: String?
    /// Alone on its line, so it applies to the next line rather than its own.
    var isStandalone: Bool
    /// The comment as written, for messages.
    var text: String

    /// Parses a line comment, or returns nil when it isn't a `loupe:allow` comment.
    static func parse(comment: String, location: SourceLocation, isStandalone: Bool) -> AllowComment? {
        var body = Substring(comment)
        while body.first == "/" { body = body.dropFirst() }
        body = body.drop { $0 == " " || $0 == "\t" }
        guard body.hasPrefix(marker) else { return nil }
        let afterMarker = body.dropFirst(marker.count)
        guard afterMarker.isEmpty || afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let rest = afterMarker.drop { $0 == " " || $0 == "\t" }
        let ruleEnd = rest.firstIndex { $0 == " " || $0 == "\t" } ?? rest.endIndex
        let ruleID = String(rest[..<ruleEnd])
        var remainder = rest[ruleEnd...].drop { $0 == " " || $0 == "\t" }
        var reason: String?
        for separator in ["--", "—", "–"] where remainder.hasPrefix(separator) {
            remainder = remainder.dropFirst(separator.count)
            let trimmed = remainder.drop { $0 == " " || $0 == "\t" }
            let value = String(trimmed).trimmingTrailingWhitespace()
            reason = value.isEmpty ? nil : value
            break
        }
        return AllowComment(
            location: location,
            ruleID: ruleID.isEmpty ? nil : ruleID,
            reason: reason,
            isStandalone: isStandalone,
            text: String(body).trimmingTrailingWhitespace()
        )
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex, self[self.index(before: end)].isWhitespace { end = self.index(before: end) }
        return String(self[..<end])
    }
}

/// Path globs for `exclude` entries: `*` and `?` match within one path component, `**` matches any
/// number of whole components (including none).
enum Glob {
    static func matches(_ pattern: String, path: String) -> Bool {
        match(components(pattern), 0, components(path), 0)
    }

    private static func components(_ string: String) -> [Substring] {
        string.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    }

    private static func match(_ pattern: [Substring], _ p: Int, _ path: [Substring], _ s: Int) -> Bool {
        if p == pattern.count { return s == path.count }
        if pattern[p] == "**" {
            // `**` consumes zero or more components.
            for skip in s...path.count where match(pattern, p + 1, path, skip) { return true }
            return false
        }
        guard s < path.count, matchComponent(Array(pattern[p]), 0, Array(path[s]), 0) else { return false }
        return match(pattern, p + 1, path, s + 1)
    }

    private static func matchComponent(_ pattern: [Character], _ p: Int, _ text: [Character], _ t: Int) -> Bool {
        if p == pattern.count { return t == text.count }
        switch pattern[p] {
        case "*":
            for skip in t...text.count where matchComponent(pattern, p + 1, text, skip) { return true }
            return false
        case "?":
            return t < text.count && matchComponent(pattern, p + 1, text, t + 1)
        default:
            return t < text.count && pattern[p] == text[t] && matchComponent(pattern, p + 1, text, t + 1)
        }
    }
}

/// A position in a source file. `path` is absolute, so locations sort the same on every machine and
/// reports decide how to display them.
public struct SourceLocation: Hashable, Comparable, Sendable, Codable {
    public var path: String
    public var line: Int
    public var column: Int

    public init(path: String, line: Int, column: Int) {
        self.path = path
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        (lhs.path, lhs.line, lhs.column) < (rhs.path, rhs.line, rhs.column)
    }
}

public enum Severity: String, Sendable, Codable {
    /// A broken rule. Fails the run.
    case error
    /// Information for reviewers, such as an allow added in this branch. Never fails the run.
    case note
}

public struct Violation: Hashable, Sendable, Codable {
    public var ruleID: String
    public var severity: Severity
    public var location: SourceLocation
    /// What is wrong, using the real names from the code.
    public var summary: String
    /// Overrides the rule's general reason when this violation has a more specific one.
    public var why: String?
    /// What to do about it, again with real names.
    public var fix: String?

    public init(
        ruleID: String,
        severity: Severity = .error,
        location: SourceLocation,
        summary: String,
        why: String? = nil,
        fix: String? = nil
    ) {
        self.ruleID = ruleID
        self.severity = severity
        self.location = location
        self.summary = summary
        self.why = why
        self.fix = fix
    }
}

/// Everything a rule says about itself. `loupe rules`, `loupe explain` and the `rule:`/`why:` lines of
/// every message come from here, so the text can't drift apart.
public struct RuleInfo: Sendable {
    public var id: String
    public var family: String
    public var title: String
    /// The rule, stated as a requirement.
    public var rule: String
    public var why: String
    /// How to fix a violation in general. Each violation also carries a fix with real names.
    public var howToFix: String
    /// `allow-*` rules can't themselves be allowed.
    public var allowable: Bool

    public init(
        id: String, family: String, title: String, rule: String, why: String, howToFix: String,
        allowable: Bool = true
    ) {
        self.id = id
        self.family = family
        self.title = title
        self.rule = rule
        self.why = why
        self.howToFix = howToFix
        self.allowable = allowable
    }
}

/// Problems that stop Loupe from checking at all (exit code 2), as opposed to violations (exit code 1).
public struct LoupeError: Error, CustomStringConvertible, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

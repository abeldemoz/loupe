import Foundation

public enum LoupeVersion {
    public static let current = "0.1.0"
}

public struct CheckOptions: Sendable {
    /// The directory holding `.loupe.json`.
    public var directory: URL
    /// A git ref (e.g. `origin/develop`): report every `loupe:allow` added since its merge-base.
    public var base: String?

    public init(directory: URL, base: String? = nil) {
        self.directory = directory
        self.base = base
    }
}

public struct CheckReport: Sendable {
    public struct Stats: Sendable {
        public var packages: Int
        public var targets: Int
        public var files: Int
    }

    /// Errors and notes in stable order.
    public var findings: [Violation]
    /// Violations excused by `loupe:allow`.
    public var allowed: Int
    public var stats: Stats
    /// The directory holding `.loupe.json`.
    public var root: String

    public var errors: [Violation] { findings.filter { $0.severity == .error } }
    public var notes: [Violation] { findings.filter { $0.severity == .note } }
    public var hasErrors: Bool { findings.contains { $0.severity == .error } }
}

public enum Checker {
    /// Loads the config and the workspace, runs every rule and applies `loupe:allow`.
    /// Throws `LoupeError` when Loupe can't run at all (a bad config, a package that won't dump).
    public static func run(_ options: CheckOptions) async throws -> CheckReport {
        let (config, root) = try ConfigLoader.load(directory: options.directory)
        let workspace = try await WorkspaceBuilder.build(root: root, config: config)
        let report = check(workspace)
        guard let base = options.base else { return report }
        let addedLines = try await AddedLines.compute(base: base, in: root)
        return report.addingAllowNotes(addedLines: addedLines, workspace: workspace)
    }

    static func check(_ workspace: Workspace) -> CheckReport {
        var violations: [Violation] = []
        for family in RuleCatalog.families { violations += family.check(workspace) }
        let outcome = AllowRules.apply(files: workspace.files, to: violations)
        return CheckReport(
            findings: sorted(outcome.violations),
            allowed: outcome.suppressed,
            stats: .init(
                packages: workspace.packages.count, targets: workspace.targets.count,
                files: workspace.targets.reduce(0) { $0 + $1.sourceFiles.count }
            ),
            root: workspace.root
        )
    }

    static func sorted(_ violations: [Violation]) -> [Violation] {
        violations.sorted {
            ($0.location, $0.ruleID, $0.summary) < ($1.location, $1.ruleID, $1.summary)
        }
    }
}

extension CheckReport {
    /// Adds a note for every valid `loupe:allow` on a line the branch added, so each new exception is
    /// a visible decision for the reviewer.
    func addingAllowNotes(addedLines: AddedLines, workspace: Workspace) -> CheckReport {
        var notes: [Violation] = []
        for file in workspace.files {
            for allow in file.allows {
                guard let ruleID = allow.ruleID, let reason = allow.reason,
                      RuleCatalog.info(for: ruleID)?.allowable == true,
                      addedLines.contains(path: file.path, line: allow.location.line)
                else { continue }
                notes.append(
                    Violation(
                        ruleID: "allow-added", severity: .note, location: allow.location,
                        summary: "This branch adds `loupe:allow \(ruleID)`: \(reason)",
                        fix: nil
                    )
                )
            }
        }
        var copy = self
        copy.findings = Checker.sorted(findings + notes)
        return copy
    }
}

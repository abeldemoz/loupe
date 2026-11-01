import Foundation

public enum OutputFormat: String, CaseIterable, Sendable {
    /// Compiler-style messages with `rule:`, `why:` and `fix:` lines. Clickable in Xcode and editors.
    case text
    /// `::error file=…` workflow commands, which GitHub turns into annotations on the PR.
    case github
    case json
}

public struct Reporter: Sendable {
    public var format: OutputFormat
    /// Paths in output are shown relative to this directory: the working directory for text and
    /// json, the repository root for github (annotations are resolved from there).
    public var relativeTo: String
    public var color: Bool

    public init(format: OutputFormat, relativeTo: String, color: Bool = false) {
        self.format = format
        self.relativeTo = relativeTo
        self.color = color
    }

    public func render(_ report: CheckReport) -> String {
        switch format {
        case .text: renderText(report)
        case .github: renderGitHub(report)
        case .json: renderJSON(report)
        }
    }

    func displayPath(_ path: String) -> String {
        let base = relativeTo.hasSuffix("/") ? relativeTo : relativeTo + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    // MARK: Text

    private func style(_ text: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    private func renderText(_ report: CheckReport) -> String {
        var blocks: [String] = []
        for finding in report.findings {
            let location = "\(displayPath(finding.location.path)):\(finding.location.line):\(finding.location.column)"
            let severity = style(finding.severity.rawValue, finding.severity == .error ? "1;31" : "1;36")
            var lines = ["\(style(location, "1")): \(severity): [\(finding.ruleID)] \(finding.summary)"]
            let label = { (name: String) in self.style(name, "2") }
            if finding.severity == .error, let info = RuleCatalog.info(for: finding.ruleID) {
                lines.append("    \(label("rule:")) \(info.rule)")
                lines.append("    \(label("why: ")) \(finding.why ?? info.why)")
                lines.append("    \(label("fix: ")) \(finding.fix ?? info.howToFix)")
                lines.append("    \(label("more:")) loupe explain \(finding.ruleID)")
            } else if let fix = finding.fix {
                lines.append("    \(label("fix: ")) \(fix)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        blocks.append(summaryLine(report))
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func summaryLine(_ report: CheckReport) -> String {
        let errors = report.errors
        let checked = "Checked \(report.stats.packages) packages, \(report.stats.targets) targets, \(report.stats.files) source files."
        let allowed = report.allowed == 0 ? "" : " \(report.allowed) \(report.allowed == 1 ? "violation is" : "violations are") excused by loupe:allow."
        let notes = report.notes.isEmpty ? "" : " \(report.notes.count) new loupe:allow \(report.notes.count == 1 ? "needs" : "need") review."
        if errors.isEmpty {
            return style("Loupe: no violations.", "1;32") + " \(checked)\(allowed)\(notes)"
        }
        let files = Set(errors.map(\.location.path)).count
        return style("Loupe found \(errors.count) \(errors.count == 1 ? "violation" : "violations") in \(files) \(files == 1 ? "file" : "files").", "1;31")
            + " \(checked)\(allowed)\(notes)"
    }

    // MARK: GitHub

    private func renderGitHub(_ report: CheckReport) -> String {
        var lines: [String] = []
        for finding in report.findings {
            let command = finding.severity == .error ? "error" : "notice"
            var message = [finding.summary]
            if finding.severity == .error, let info = RuleCatalog.info(for: finding.ruleID) {
                message.append("rule: \(info.rule)")
                message.append("why: \(finding.why ?? info.why)")
                message.append("fix: \(finding.fix ?? info.howToFix)")
                message.append("more: loupe explain \(finding.ruleID)")
            } else if let fix = finding.fix {
                message.append("fix: \(fix)")
            }
            let properties = [
                "file=\(escapeProperty(displayPath(finding.location.path)))",
                "line=\(finding.location.line)",
                "col=\(finding.location.column)",
                "title=\(escapeProperty(finding.ruleID))",
            ].joined(separator: ",")
            lines.append("::\(command) \(properties)::\(escapeData(message.joined(separator: "\n")))")
        }
        var uncolored = self
        uncolored.color = false
        lines.append(uncolored.summaryLine(report))
        return lines.joined(separator: "\n") + "\n"
    }

    private func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private func escapeProperty(_ text: String) -> String {
        escapeData(text).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
    }

    // MARK: JSON

    private struct JSONReport: Encodable {
        struct Finding: Encodable {
            var rule: String
            var severity: String
            var file: String
            var line: Int
            var column: Int
            var message: String
            var rationale: String?
            var fix: String?
            var ruleStatement: String?
        }
        struct Summary: Encodable {
            var errors: Int
            var notes: Int
            var allowed: Int
            var packages: Int
            var targets: Int
            var files: Int
        }
        var version = 1
        var findings: [Finding]
        var summary: Summary
    }

    private func renderJSON(_ report: CheckReport) -> String {
        let findings = report.findings.map { finding -> JSONReport.Finding in
            let info = RuleCatalog.info(for: finding.ruleID)
            return JSONReport.Finding(
                rule: finding.ruleID, severity: finding.severity.rawValue,
                file: displayPath(finding.location.path), line: finding.location.line, column: finding.location.column,
                message: finding.summary,
                rationale: finding.severity == .error ? (finding.why ?? info?.why) : nil,
                fix: finding.severity == .error ? (finding.fix ?? info?.howToFix) : finding.fix,
                ruleStatement: finding.severity == .error ? info?.rule : nil
            )
        }
        let output = JSONReport(
            findings: findings,
            summary: .init(
                errors: report.errors.count, notes: report.notes.count, allowed: report.allowed,
                packages: report.stats.packages, targets: report.stats.targets, files: report.stats.files
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(output)) ?? Data(), as: UTF8.self) + "\n"
    }

    // MARK: Rule listings

    /// `loupe rules`.
    public static func renderRuleList() -> String {
        var lines: [String] = []
        var family: String?
        let width = RuleCatalog.all.map(\.id.count).max() ?? 0
        for info in RuleCatalog.all {
            if info.family != family {
                if family != nil { lines.append("") }
                lines.append(info.family)
                family = info.family
            }
            lines.append("  \(info.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(info.title)")
        }
        lines.append("")
        lines.append("`loupe explain <rule-id>` shows a rule's reasoning and how to fix it.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `loupe explain <rule-id>`.
    public static func renderExplanation(_ info: RuleInfo) -> String {
        """
        \(info.id): \(info.title)

        Rule
          \(info.rule)

        Why
          \(info.why)

        How to fix
          \(info.howToFix)

        \(info.allowable ? "To excuse a single violation (ask first; a reviewer will see it):\n  // loupe:allow \(info.id) -- <why this is the right exception>" : "This rule can't be allowed: fix the comment itself.")

        """
    }
}

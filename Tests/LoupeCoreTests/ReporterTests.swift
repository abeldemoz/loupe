import Foundation
import Testing
@testable import LoupeCore

@Suite struct ReporterTests {
    static let report = CheckReport(
        findings: [
            Violation(
                ruleID: "implementation-dependency", location: SourceLocation(path: "/repo/app/Core/Package.swift", line: 63, column: 17),
                summary: "'UseCasesImplementations' depends on 'ProductsImplementations'",
                why: "A Core feature implementations target may depend only on interfaces.",
                fix: "Replace \"ProductsImplementations\" with 'Products'."
            ),
            Violation(
                ruleID: "non-linux-import", location: SourceLocation(path: "/repo/app/Presentation/A.swift", line: 1, column: 8),
                summary: "Unconditional `import UIKit` in 'Presentation' can't be built on Linux",
                fix: "Wrap it in `#if canImport(UIKit)`.\nOr move the code.\n100% of 50, really: yes"
            ),
            Violation(
                ruleID: "allow-added", severity: .note, location: SourceLocation(path: "/repo/app/Core/B.swift", line: 9, column: 5),
                summary: "This branch adds `loupe:allow interface-function`: legacy", fix: nil
            ),
        ],
        allowed: 2,
        stats: .init(packages: 6, targets: 22, files: 58),
        root: "/repo/app"
    )

    @Test func text() throws {
        try assertGolden(Reporter(format: .text, relativeTo: "/repo/app").render(Self.report), named: "report.txt")
    }

    @Test func github() throws {
        try assertGolden(Reporter(format: .github, relativeTo: "/repo").render(Self.report), named: "report.github.txt")
    }

    @Test func json() throws {
        let output = Reporter(format: .json, relativeTo: "/repo/app").render(Self.report)
        try assertGolden(output, named: "report.json")
        let decoded = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        #expect((decoded?["findings"] as? [Any])?.count == 3)
    }

    @Test func aCleanRun() {
        let clean = CheckReport(findings: [], allowed: 0, stats: .init(packages: 1, targets: 2, files: 3), root: "/r")
        #expect(Reporter(format: .text, relativeTo: "/r").render(clean) == "Loupe: no violations. Checked 1 packages, 2 targets, 3 source files.\n")
    }

    @Test func colorIsOptIn() {
        let plain = Reporter(format: .text, relativeTo: "/repo/app").render(Self.report)
        let colored = Reporter(format: .text, relativeTo: "/repo/app", color: true).render(Self.report)
        #expect(!plain.contains("\u{1B}["))
        #expect(colored.contains("\u{1B}["))
    }

    @Test func githubEscapesWorkflowCommandCharacters() {
        let output = Reporter(format: .github, relativeTo: "/repo").render(Self.report)
        #expect(output.contains("%25 of 50"))
        #expect(output.contains("%0A"))
        #expect(output.split(separator: "\n").filter { $0.hasPrefix("::") }.count == 3)
    }

    @Test func ruleListingAndExplanation() throws {
        let list = Reporter.renderRuleList()
        #expect(list.contains("implementation-dependency"))
        try assertGolden(Reporter.renderExplanation(try #require(RuleCatalog.info(for: "undeclared-import"))), named: "explain-undeclared-import.txt")
    }
}

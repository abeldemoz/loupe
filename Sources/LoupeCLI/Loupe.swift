import ArgumentParser
import Foundation
import LoupeCore

@main
struct Loupe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loupe",
        abstract: "Checks that an iOS app follows its architecture.",
        discussion: """
            Exit codes: 0 no violations, 1 violations found, 2 Loupe couldn't run \
            (bad .loupe.json, a Package.swift that won't dump, a missing --base ref).
            """,
        version: LoupeVersion.current,
        subcommands: [Check.self, Rules.self, Explain.self],
        defaultSubcommand: Check.self
    )
}

extension OutputFormat: ExpressibleByArgument {}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the app against the architecture's rules.",
        discussion: "Reads .loupe.json from the given directory, then reports every violation at once, in a stable order."
    )

    @Argument(help: "The directory containing .loupe.json.")
    var path: String = "."

    @Option(help: "Output format: text, github (PR annotations) or json.")
    var format: OutputFormat = .text

    @Option(help: "A git ref such as origin/develop. Reports every loupe:allow added since its merge-base, for review.")
    var base: String?

    func run() async throws {
        let directory = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        let report: CheckReport
        do {
            report = try await Checker.run(CheckOptions(directory: directory, base: base))
        } catch let error as LoupeError {
            fail(error.message)
        }

        let cwd = Paths.canonical(FileManager.default.currentDirectoryPath)
        let relativeTo: String
        if format == .github {
            // Annotations resolve file paths from the repository root.
            relativeTo = await GitRoot.find(from: URL(fileURLWithPath: report.root)) ?? report.root
        } else {
            relativeTo = cwd
        }
        let useColor = format == .text && isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        print(Reporter(format: format, relativeTo: relativeTo, color: useColor).render(report), terminator: "")
        if report.hasErrors { throw ExitCode(1) }
    }
}

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List every rule Loupe checks.")

    func run() {
        print(Reporter.renderRuleList(), terminator: "")
    }
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Explain a rule: what it requires, why it exists and how to fix a violation.")

    @Argument(help: "A rule id, as shown in a violation's header or by `loupe rules`.")
    var ruleID: String

    func run() throws {
        guard let info = RuleCatalog.info(for: ruleID) else {
            let suggestions = RuleCatalog.suggestions(for: ruleID)
            fail("Unknown rule '\(ruleID)'." + (suggestions.isEmpty ? "" : " Did you mean \(suggestions.prefix(3).map { "'\($0)'" }.joined(separator: " or "))?") + " `loupe rules` lists them all.")
        }
        print(Reporter.renderExplanation(info), terminator: "")
    }
}

/// Reports a run error (exit code 2) on stderr.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("loupe: error: \(message)\n".utf8))
    Foundation.exit(2)
}

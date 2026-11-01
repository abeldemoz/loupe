import Foundation
import Testing
@testable import LoupeCore

/// Runs the real `loupe` binary, because exit codes and output streams are part of the contract:
/// CI and agents decide what to do from them.
@Suite struct CLITests {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// The built binary: `$LOUPE_BINARY`, or the debug build next to this package.
    static func binary() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["LOUPE_BINARY"] { return URL(fileURLWithPath: path) }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/loupe", ".build/out/Products/Debug/loupe", ".build/release/loupe"]
            .map { package.appendingPathComponent($0) }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        // The newest build is the one `swift test` just made.
        let newest = candidates.max {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        return try #require(newest, "No built loupe binary. Run `swift build` first, or set LOUPE_BINARY.")
    }

    /// Runs the binary without blocking a thread: tests run in parallel, and blocked workers would
    /// starve the queue that drains the child's pipes.
    static func run(_ arguments: [String], in directory: URL? = nil) async throws -> Output {
        let result = try await ProcessRunner.run(try binary().path, arguments, currentDirectory: directory)
        return Output(status: result.status, stdout: result.stdoutText, stderr: result.stderrText)
    }

    @Test func aCleanAppExitsZero() async throws {
        let app = try FixtureApp()
        let result = try await Self.run(["check"], in: app.root)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.hasPrefix("Loupe: no violations."))
        #expect(result.stderr.isEmpty)
    }

    @Test(arguments: ["text", "github", "json"])
    func violationsExitOneInEveryFormat(format: String) async throws {
        let app = try FixtureApp()
        try app.prepend("import UIKit", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        let result = try await Self.run(["check", "--format", format], in: app.root)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.stdout.contains("non-linux-import"))
        #expect(result.stderr.isEmpty)
    }

    @Test func pathsAreRelativeToTheWorkingDirectory() async throws {
        let app = try FixtureApp()
        try app.prepend("import UIKit", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        let fromRoot = try await Self.run(["check"], in: app.root)
        #expect(fromRoot.stdout.hasPrefix("Presentation/Sources/Presentation/ProductPresenter.swift:1:8: error: [non-linux-import]"))
        let fromAbove = try await Self.run(["check", app.root.lastPathComponent], in: app.root.deletingLastPathComponent())
        #expect(fromAbove.stdout.hasPrefix("\(app.root.lastPathComponent)/Presentation/Sources/Presentation/ProductPresenter.swift:1:8:"))
    }

    @Test func githubFormatPrintsAnnotationsRelativeToTheRepositoryRoot() async throws {
        let app = try FixtureApp()
        try app.git("init", "-q", "-b", "main")
        // The app lives in a subdirectory of the repository, like Credits' apple/.
        let nested = app.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: app.root.path) where name != "nested" && name != ".git" {
            try FileManager.default.moveItem(at: app.root.appendingPathComponent(name), to: nested.appendingPathComponent(name))
        }
        try Data("import UIKit\n".utf8).write(to: nested.appendingPathComponent("Presentation/Sources/Presentation/Extra.swift"))
        let result = try await Self.run(["check", "nested", "--format", "github"], in: app.root)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.stdout.contains("::error file=nested/Presentation/Sources/Presentation/Extra.swift,line=1,col=8,title=non-linux-import::"))
    }

    @Test func aRunErrorExitsTwoOnStderr() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        for format in ["text", "github", "json"] {
            let result = try await Self.run(["check", "--format", format], in: empty)
            #expect(result.status == 2, "\(format)")
            #expect(result.stderr.contains("loupe: error: No loupe.json found"))
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func versionAndHelp() async throws {
        let version = try await Self.run(["--version"])
        #expect(version.status == 0)
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == LoupeVersion.current)
        let help = try await Self.run(["--help"])
        #expect(help.stdout.contains("Exit codes: 0 no violations, 1 violations found, 2"))
    }

    @Test func rulesAndExplain() async throws {
        let rules = try await Self.run(["rules"])
        #expect(rules.status == 0)
        #expect(rules.stdout.contains("implementation-dependency"))

        let explain = try await Self.run(["explain", "interface-function"])
        #expect(explain.status == 0)
        #expect(explain.stdout.contains("How to fix"))
        #expect(explain.stdout.contains("// loupe:allow interface-function -- <why this is the right exception>"))

        let unknown = try await Self.run(["explain", "interface-fucntion"])
        #expect(unknown.status == 2)
        #expect(unknown.stderr.contains("Did you mean 'interface-function'?"))
    }
}

import Foundation

/// Which lines this branch added, for `--base`: new `loupe:allow` comments are surfaced for review.
struct AddedLines {
    private(set) var lines: [String: Set<Int>] = [:]
    /// Untracked files, where every line is new.
    private(set) var wholeFiles: Set<String> = []

    func contains(path: String, line: Int) -> Bool {
        wholeFiles.contains(path) || (lines[path]?.contains(line) ?? false)
    }

    static func compute(base: String, in directory: URL) async throws -> AddedLines {
        func git(_ arguments: [String]) async throws -> String {
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run("git", arguments, currentDirectory: directory)
            } catch {
                throw LoupeError("Couldn't run `git` for --base: \(error.localizedDescription)")
            }
            guard result.status == 0 else {
                throw LoupeError(
                    """
                    `git \(arguments.joined(separator: " "))` failed while resolving --base \(base):
                      \(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
                      --base needs a git checkout that contains \(base). In CI, fetch history first (`fetch-depth: 0` for actions/checkout, or `git fetch origin \(base.replacingOccurrences(of: "origin/", with: ""))`).
                    """
                )
            }
            return result.stdoutText
        }

        let top = try await git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let topURL = URL(fileURLWithPath: top).canonical
        let mergeBase = try await git(["merge-base", base, "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = try await git(["diff", "-U0", "--no-color", "--no-ext-diff", mergeBase])
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "--full-name"])

        var added = AddedLines()
        var current: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let name = line.dropFirst(4)
                current = name.hasPrefix("b/") ? topURL.appendingPathComponent(String(name.dropFirst(2))).path : nil
            } else if line.hasPrefix("@@"), let current {
                // @@ -a,b +c,d @@
                guard let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { continue }
                let numbers = plus.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                guard let start = numbers.first.flatMap({ Int($0) }) else { continue }
                let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
                if count > 0 { added.lines[current, default: []].formUnion(start..<(start + count)) }
            }
        }
        for name in untracked.split(separator: "\n") {
            added.wholeFiles.insert(topURL.appendingPathComponent(String(name)).path)
        }
        return added
    }

    /// The repository root containing `directory`, if it is in one.
    static func repositoryRoot(of directory: URL) async -> String? {
        guard let result = try? await ProcessRunner.run("git", ["rev-parse", "--show-toplevel"], currentDirectory: directory),
              result.status == 0
        else { return nil }
        let top = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : URL(fileURLWithPath: top).canonical.path
    }
}

/// The repository root containing a directory, for `--format github` paths.
public enum GitRoot {
    public static func find(from directory: URL) async -> String? {
        await AddedLines.repositoryRoot(of: directory)
    }
}

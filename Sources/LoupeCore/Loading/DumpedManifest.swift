import Foundation

/// The parts of `swift package dump-package` that Loupe reads. SwiftPM's own reading of the manifest
/// is the source of truth for the graph, so Loupe never has to restrict how manifests are written.
struct DumpedManifest: Decodable, Sendable {
    var name: String
    var products: [Product]
    var dependencies: [PackageDependency]
    var targets: [Target]

    struct Product: Decodable, Sendable {
        var name: String
        var targets: [String]
    }

    struct Target: Decodable, Sendable {
        var name: String
        /// `regular`, `test`, `executable`, `macro`, `plugin`, `system` or `binary`.
        var type: String
        var path: String?
        var sources: [String]?
        var dependencies: [Dependency]
    }

    enum Dependency: Decodable, Sendable, Equatable {
        case byName(String)
        case target(String)
        case product(name: String, package: String?)

        private enum Key: String, CodingKey { case byName, target, product }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if container.contains(.byName) {
                var items = try container.nestedUnkeyedContainer(forKey: .byName)
                self = .byName(try items.decode(String.self))
            } else if container.contains(.target) {
                var items = try container.nestedUnkeyedContainer(forKey: .target)
                self = .target(try items.decode(String.self))
            } else if container.contains(.product) {
                var items = try container.nestedUnkeyedContainer(forKey: .product)
                let name = try items.decode(String.self)
                let package = try items.decodeIfPresent(String.self)
                self = .product(name: name, package: package)
            } else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unrecognized target dependency")
                )
            }
        }
    }

    enum PackageDependency: Decodable, Sendable {
        /// `.package(path:)`, with the absolute path SwiftPM resolved.
        case local(identity: String, path: String)
        /// `.package(url:)`, or a registry package.
        case remote(identity: String, location: String?)

        private enum Key: String, CodingKey { case fileSystem, sourceControl, registry }

        private struct Entry: Decodable {
            var identity: String
            var path: String?
            var location: Location?

            struct Location: Decodable {
                var remote: [Remote]?
                var local: [String]?
                struct Remote: Decodable { var urlString: String? }
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if container.contains(.fileSystem) {
                var items = try container.nestedUnkeyedContainer(forKey: .fileSystem)
                let entry = try items.decode(Entry.self)
                self = .local(identity: entry.identity, path: entry.path ?? "")
            } else if container.contains(.sourceControl) {
                var items = try container.nestedUnkeyedContainer(forKey: .sourceControl)
                let entry = try items.decode(Entry.self)
                if let local = entry.location?.local?.first {
                    self = .local(identity: entry.identity, path: local)
                } else {
                    self = .remote(identity: entry.identity, location: entry.location?.remote?.first?.urlString)
                }
            } else {
                var items = try container.nestedUnkeyedContainer(forKey: .registry)
                let entry = try items.decode(Entry.self)
                self = .remote(identity: entry.identity, location: nil)
            }
        }
    }
}

enum PackageDumper {
    /// Runs `swift package dump-package` for one package. A failure is surfaced with SwiftPM's own
    /// output and the command to reproduce it, rather than swallowed into a decoding error.
    static func dump(packageDirectory: URL) async throws -> DumpedManifest {
        let arguments = ["package", "dump-package", "--package-path", packageDirectory.path]
        let command = ProcessRunner.shellCommand("swift", arguments)
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run("swift", arguments)
        } catch {
            throw LoupeError("Couldn't run `swift`: \(error.localizedDescription)\n  Loupe needs a Swift toolchain on PATH to read Package.swift files (`\(command)`).")
        }
        guard result.status == 0 else {
            let reason = result.status == 127
                ? "`swift` was not found on PATH. Loupe needs a Swift toolchain to read Package.swift files."
                : "SwiftPM could not read this manifest (exit status \(result.status))."
            throw LoupeError(
                """
                \(reason)
                  Reproduce with: \(command)
                  SwiftPM said:
                \(indented(result.stderrText.isEmpty ? result.stdoutText : result.stderrText))
                """
            )
        }
        do {
            return try JSONDecoder().decode(DumpedManifest.self, from: result.stdout)
        } catch {
            throw LoupeError("Couldn't understand the output of `\(command)`: \(error)\n  This Loupe may predate your Swift toolchain's manifest format; try a newer Loupe.")
        }
    }

    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
    }
}

import Foundation
import LoupeArchitecture

/// `.loupe.json`: maps an app's package and target names onto the canonical architecture's roles.
public struct LoupeConfig: Sendable, Equatable {
    public struct Package: Sendable, Equatable {
        /// Package directory, relative to `.loupe.json`.
        public var path: String
        /// The main target, when it isn't named like the package directory.
        public var target: String?
        public var testDoubles: String?
        public var testSupport: String?
        public var routingTestDoubles: String?

        public init(
            path: String, target: String? = nil, testDoubles: String? = nil, testSupport: String? = nil,
            routingTestDoubles: String? = nil
        ) {
            self.path = path
            self.target = target
            self.testDoubles = testDoubles
            self.testSupport = testSupport
            self.routingTestDoubles = routingTestDoubles
        }
    }

    public struct Exclude: Sendable, Equatable {
        public var glob: String
        public var reason: String

        public init(glob: String, reason: String) {
            self.glob = glob
            self.reason = reason
        }
    }

    public static let currentVersion = 1

    public var packages: [Role: Package]
    public var exclude: [Exclude]

    public init(packages: [Role: Package], exclude: [Exclude] = []) {
        self.packages = packages
        self.exclude = exclude
    }
}

public enum ConfigLoader {
    public static let fileName = ".loupe.json"

    /// What v0.1.0 read. Loupe doesn't load it, but it recognises it to say how to migrate.
    static let legacyFileName = "loupe.json"

    /// The keys each object in `.loupe.json` may have. Anything else is an error, so a typo can't
    /// quietly switch a rule off.
    static let topLevelKeys = ["$schema", "version", "packages", "exclude"]
    static let packageKeys = ["path", "target", "testDoubles", "testSupport", "routingTestDoubles"]
    static let excludeKeys = ["glob", "reason"]

    /// Which optional target keys each role takes.
    static func extraKeys(for role: Role) -> [String] {
        switch role {
        case .utilities: ["testSupport"]
        case .coreInterface, .crossInterface, .presentationInterface: ["testDoubles"]
        case .presentation: ["routingTestDoubles"]
        case .core: []
        }
    }

    /// Finds `.loupe.json` in `directory` and decodes it, reporting every problem at once.
    public static func load(directory: URL) throws -> (config: LoupeConfig, root: URL) {
        let url = directory.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(legacyFileName).path) {
                throw LoupeError(
                    """
                    No \(fileName) found in \(directory.path), but there is a \(legacyFileName)
                      Loupe reads a hidden config file, like other linters do. Rename it:
                      git mv \(legacyFileName) \(fileName)
                    """
                )
            }
            throw LoupeError(
                """
                No \(fileName) found in \(directory.path)
                  Loupe reads \(fileName) from the directory you pass to `loupe check` (default: the current directory).
                  Run it from the app's root, or pass the directory: `loupe check path/to/app`.
                  A minimal \(fileName) maps each package to its role in the architecture:
                  \(exampleConfig.replacingOccurrences(of: "\n", with: "\n  "))
                """
            )
        }
        return (try decode(data, fileURL: url), directory)
    }

    public static func decode(_ data: Data, fileURL: URL) throws -> LoupeConfig {
        let name = fileURL.lastPathComponent
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LoupeError("\(fileURL.path): not valid JSON (\(error.localizedDescription))")
        }
        var problems: [String] = []
        guard let top = object as? [String: Any] else {
            throw LoupeError("\(fileURL.path): the top level must be a JSON object")
        }
        reportUnknownKeys(in: top, allowed: topLevelKeys, at: nil, into: &problems)

        switch top["version"] {
        case let version as Int where version == LoupeConfig.currentVersion: break
        case let version as Int:
            problems.append("version: \(version) isn't supported by this Loupe (it reads version \(LoupeConfig.currentVersion)). Upgrade Loupe, or set \"version\": \(LoupeConfig.currentVersion).")
        default:
            problems.append("version: required. Add \"version\": \(LoupeConfig.currentVersion).")
        }

        var packages: [Role: LoupeConfig.Package] = [:]
        if let rawPackages = top["packages"] as? [String: Any] {
            let roleNames = Role.allCases.map(\.rawValue)
            for key in rawPackages.keys.sorted() {
                guard let role = Role(rawValue: key) else {
                    problems.append("packages.\(key): unknown role.\(suggestion(for: key, in: roleNames)) The roles are \(roleNames.joined(separator: ", ")).")
                    continue
                }
                guard let entry = rawPackages[key] as? [String: Any] else {
                    problems.append("packages.\(key): expected an object like {\"path\": \"\(key.prefix(1).uppercased() + key.dropFirst())\"}")
                    continue
                }
                let allowedKeys = ["path"] + (role == .core ? [] : ["target"]) + extraKeys(for: role)
                for unknown in entry.keys.sorted() where !allowedKeys.contains(unknown) {
                    if packageKeys.contains(unknown) {
                        problems.append("packages.\(key).\(unknown): not used by the \(role.noun) role. It takes: \(allowedKeys.joined(separator: ", ")).")
                    } else {
                        problems.append("packages.\(key).\(unknown): unknown key.\(suggestion(for: unknown, in: allowedKeys)) It takes: \(allowedKeys.joined(separator: ", ")).")
                    }
                }
                guard let path = entry["path"] as? String, !path.isEmpty else {
                    problems.append("packages.\(key).path: required, a directory relative to \(name), e.g. \"Core\".")
                    continue
                }
                func optionalString(_ field: String) -> String? {
                    guard let value = entry[field] else { return nil }
                    guard let string = value as? String, !string.isEmpty else {
                        problems.append("packages.\(key).\(field): expected a target name (a non-empty string)")
                        return nil
                    }
                    return string
                }
                packages[role] = LoupeConfig.Package(
                    path: path,
                    target: optionalString("target"),
                    testDoubles: optionalString("testDoubles"),
                    testSupport: optionalString("testSupport"),
                    routingTestDoubles: optionalString("routingTestDoubles")
                )
            }
            if rawPackages.isEmpty { problems.append("packages: map at least one package to a role.") }
        } else {
            problems.append("packages: required, an object mapping roles to packages.")
        }

        var excludes: [LoupeConfig.Exclude] = []
        if let rawExcludes = top["exclude"] {
            if let list = rawExcludes as? [Any] {
                for (index, item) in list.enumerated() {
                    guard let entry = item as? [String: Any] else {
                        problems.append("exclude[\(index)]: expected an object like {\"glob\": \"…\", \"reason\": \"…\"}")
                        continue
                    }
                    reportUnknownKeys(in: entry, allowed: excludeKeys, at: "exclude[\(index)]", into: &problems)
                    let glob = entry["glob"] as? String
                    let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if glob == nil || glob?.isEmpty == true {
                        problems.append("exclude[\(index)].glob: required, a path glob relative to \(name), e.g. \"Core/**/Generated.swift\".")
                    }
                    if reason == nil || reason?.isEmpty == true {
                        problems.append("exclude[\(index)].reason: required. Say why this path is exempt, so the exclusion never loses its explanation.")
                    }
                    if let glob, !glob.isEmpty, let reason, !reason.isEmpty {
                        excludes.append(.init(glob: glob, reason: reason))
                    }
                }
            } else {
                problems.append("exclude: expected an array of {\"glob\": …, \"reason\": …} objects")
            }
        }

        if !problems.isEmpty {
            let lines = problems.map { "  - \($0)" }.joined(separator: "\n")
            throw LoupeError("\(fileURL.path) is invalid:\n\(lines)")
        }
        return LoupeConfig(packages: packages, exclude: excludes)
    }

    private static func reportUnknownKeys(in object: [String: Any], allowed: [String], at path: String?, into problems: inout [String]) {
        for key in object.keys.sorted() where !allowed.contains(key) {
            let location = path.map { "\($0).\(key)" } ?? key
            problems.append("\(location): unknown key.\(suggestion(for: key, in: allowed)) Allowed: \(allowed.joined(separator: ", ")).")
        }
    }

    /// " Did you mean 'x'?" when `key` is close to one of `candidates`, else an empty string.
    static func suggestion(for key: String, in candidates: [String]) -> String {
        let best = candidates.min { editDistance(key.lowercased(), $0.lowercased()) < editDistance(key.lowercased(), $1.lowercased()) }
        guard let best, editDistance(key.lowercased(), best.lowercased()) <= max(2, best.count / 3) else { return "" }
        return " Did you mean '\(best)'?"
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static let exampleConfig = """
    {
      "version": 1,
      "packages": {
        "utilities": { "path": "Utilities", "testSupport": "TestSupport" },
        "coreInterface": { "path": "CoreInterface", "testDoubles": "CoreTestDoubles" },
        "crossInterface": { "path": "CrossInterface", "testDoubles": "CrossTestDoubles" },
        "presentationInterface": { "path": "PresentationInterface", "testDoubles": "PresentationTestDoubles" },
        "core": { "path": "Core" },
        "presentation": { "path": "Presentation", "routingTestDoubles": "RoutingTestDoubles" }
      }
    }
    """
}

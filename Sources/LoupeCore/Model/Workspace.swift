import Foundation
import LoupeArchitecture

struct TargetID: Hashable, Comparable, Sendable {
    let package: Role
    let name: String

    static func < (lhs: TargetID, rhs: TargetID) -> Bool {
        (lhs.package.rawValue, lhs.name) < (rhs.package.rawValue, rhs.name)
    }
}

/// One entry of a target's `dependencies:`, resolved to the targets it gives access to.
struct ResolvedDependency: Sendable {
    /// As written, e.g. `ProductsImplementations` or `.product(name: "CoreTestDoubles", package: "CoreInterface")`.
    let written: String
    let location: SourceLocation
    /// The workspace targets this dependency links in. A product can name several.
    let targets: [TargetID]
    /// The package this dependency comes through, when it isn't a target of the same package.
    let viaPackage: Role?
    /// For a `.product(name:package:)` that no mapped package provides: the package it names.
    let externalPackage: String?
}

struct WorkspaceTarget: Sendable {
    let id: TargetID
    /// Nil when the target isn't part of the architecture (an unknown target in a mapped package).
    let kind: TargetKind?
    /// SwiftPM's target type: `regular`, `test`, `executable`, `macro`, ...
    let type: String
    /// Where the target is declared in Package.swift: its `name:` literal.
    let location: SourceLocation
    /// The `path:` as written, nil when SwiftPM's default (`Sources/<name>`) applies.
    let declaredPath: String?
    let pathLocation: SourceLocation?
    let dependencies: [ResolvedDependency]
    let sourceFiles: [SourceFile]

    var name: String { id.name }
    var ref: TargetRef? { kind.map { TargetRef(name: name, kind: $0) } }
}

/// A `.package(...)` entry in a package's `dependencies:`.
struct PackageEdge: Sendable {
    enum Destination: Sendable {
        /// A local package that `.loupe.json` maps to a role.
        case mapped(Role)
        /// A local package `.loupe.json` doesn't know.
        case unmapped(path: String)
        /// A package fetched by URL or from a registry.
        case remote(identity: String, location: String?)
    }

    let destination: Destination
    /// As written, e.g. `.package(path: "../Core")`.
    let written: String
    let location: SourceLocation
}

struct WorkspacePackage: Sendable {
    let role: Role
    let config: LoupeConfig.Package
    /// Absolute path of the package directory.
    let directory: String
    let manifest: ManifestIndex
    let dumped: DumpedManifest
    let targets: [WorkspaceTarget]
    let edges: [PackageEdge]

    var name: String { dumped.name }
    var manifestPath: String { manifest.file.path }
}

/// Everything Loupe knows about an app after loading: the packages, their targets, the resolved
/// dependency graph and every parsed file, all with source locations. Rules read it and never touch
/// the filesystem.
struct Workspace: Sendable {
    let root: String
    let packages: [Role: WorkspacePackage]
    let targets: [WorkspaceTarget]
    private let targetsByID: [TargetID: WorkspaceTarget]
    /// First-party module names (target names) to the target that provides them.
    let modules: [String: TargetID]

    init(root: String, packages: [Role: WorkspacePackage]) {
        self.root = root
        self.packages = packages
        let all = packages.values.flatMap(\.targets).sorted { $0.id < $1.id }
        self.targets = all
        self.targetsByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var modules: [String: TargetID] = [:]
        for target in all { modules[target.name.replacingOccurrences(of: "-", with: "_")] = target.id }
        self.modules = modules
    }

    func target(_ id: TargetID) -> WorkspaceTarget? { targetsByID[id] }

    func target(named name: String, in role: Role) -> WorkspaceTarget? {
        targetsByID[TargetID(package: role, name: name)]
    }

    /// The `Package.swift` files and sources, for `loupe:allow` handling.
    var files: [SourceFile] {
        packages.values.sorted { $0.role.rawValue < $1.role.rawValue }.flatMap { package in
            [package.manifest.file] + package.targets.flatMap(\.sourceFiles)
        }
    }

    /// The workspace targets a target depends on directly, with the dependency that brought each in.
    func directDependencies(of target: WorkspaceTarget) -> [(dependency: ResolvedDependency, target: WorkspaceTarget)] {
        target.dependencies.flatMap { dependency in
            dependency.targets.compactMap { id in self.target(id).map { (dependency, $0) } }
        }
    }

    /// Paths for messages: relative to `root` when inside it.
    func relativePath(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}

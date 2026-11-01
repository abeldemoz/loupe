import Foundation
import LoupeArchitecture

/// Builds a `Workspace` from `loupe.json` and the packages on disk.
enum WorkspaceBuilder {
    /// Directories that never hold an app's own sources.
    private static let skippedDirectories: Set<String> = [".build", ".swiftpm", "DerivedData", "node_modules"]

    static func build(root: URL, config: LoupeConfig) async throws -> Workspace {
        let root = root.canonical
        let roles = config.packages.keys.sorted { $0.rawValue < $1.rawValue }

        var directories: [Role: URL] = [:]
        for role in roles {
            let package = config.packages[role]!
            let directory = root.appendingPathComponent(package.path, isDirectory: true).canonical
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LoupeError("loupe.json: packages.\(role.rawValue).path is \"\(package.path)\", but there is no such directory (looked in \(directory.path)).\n  Fix the path, or remove the \(role.rawValue) entry if this app has no such package.")
            }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
                throw LoupeError("loupe.json: packages.\(role.rawValue).path is \"\(package.path)\", but \(directory.path) has no Package.swift.")
            }
            directories[role] = directory
        }

        let dumps = try await dumpAll(directories)

        // Parse the manifests (small) and classify every target.
        var pending: [Role: PendingPackage] = [:]
        for role in roles {
            let directory = directories[role]!
            let manifestURL = directory.appendingPathComponent("Package.swift")
            let source = try String(contentsOf: manifestURL, encoding: .utf8)
            let manifest = ManifestIndex(file: SourceFile(path: manifestURL.path, source: source))
            pending[role] = try makePending(
                role: role, config: config.packages[role]!, directory: directory, dumped: dumps[role]!, manifest: manifest
            )
        }
        let roleByDirectory = Dictionary(uniqueKeysWithValues: directories.map { ($0.value.path, $0.key) })
        for role in roles {
            pending[role]!.resolve(directories: directories, roleByDirectory: roleByDirectory, others: pending)
        }

        // Find and parse the sources of every classified target, concurrently.
        var filesByTarget: [TargetID: [URL]] = [:]
        for role in roles {
            for target in pending[role]!.targets where target.kind != nil {
                filesByTarget[target.id] = sourceFiles(of: target, in: pending[role]!, root: root, exclude: config.exclude)
            }
        }
        let parsed = await parse(Array(Set(filesByTarget.values.flatMap { $0 })))

        var packages: [Role: WorkspacePackage] = [:]
        for role in roles {
            let package = pending[role]!
            let targets = package.targets.map { target in
                WorkspaceTarget(
                    id: target.id, kind: target.kind, type: target.type, location: target.location,
                    declaredPath: target.declaredPath, pathLocation: target.pathLocation,
                    dependencies: target.dependencies,
                    sourceFiles: (filesByTarget[target.id] ?? []).compactMap { parsed[$0.path] }
                )
            }
            packages[role] = WorkspacePackage(
                role: role, config: package.config, directory: package.directory.path, manifest: package.manifest,
                dumped: package.dumped, targets: targets, edges: package.edges
            )
        }
        return Workspace(root: root.path, packages: packages)
    }

    // MARK: Dumping

    private static func dumpAll(_ directories: [Role: URL]) async throws -> [Role: DumpedManifest] {
        let results = await withTaskGroup(of: (Role, Result<DumpedManifest, LoupeError>).self) { group in
            for (role, directory) in directories {
                group.addTask {
                    do {
                        return (role, .success(try await PackageDumper.dump(packageDirectory: directory)))
                    } catch let error as LoupeError {
                        return (role, .failure(error))
                    } catch {
                        return (role, .failure(LoupeError("\(error)")))
                    }
                }
            }
            var all: [Role: Result<DumpedManifest, LoupeError>] = [:]
            for await (role, result) in group { all[role] = result }
            return all
        }
        var dumps: [Role: DumpedManifest] = [:]
        var failures: [String] = []
        for role in results.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch results[role]! {
            case .success(let dumped): dumps[role] = dumped
            case .failure(let error): failures.append("packages.\(role.rawValue) (\(directories[role]!.lastPathComponent)): \(error.message)")
            }
        }
        if !failures.isEmpty { throw LoupeError(failures.joined(separator: "\n\n")) }
        return dumps
    }

    // MARK: Classification

    struct PendingTarget {
        let id: TargetID
        let kind: TargetKind?
        let type: String
        let location: SourceLocation
        let declaredPath: String?
        let pathLocation: SourceLocation?
        let dumped: DumpedManifest.Target
        var dependencies: [ResolvedDependency] = []
    }

    struct PendingPackage {
        let role: Role
        let config: LoupeConfig.Package
        let directory: URL
        let dumped: DumpedManifest
        let manifest: ManifestIndex
        var targets: [PendingTarget]
        var edges: [PackageEdge] = []
    }

    private static func makePending(
        role: Role, config: LoupeConfig.Package, directory: URL, dumped: DumpedManifest, manifest: ManifestIndex
    ) throws -> PendingPackage {
        let directoryName = directory.lastPathComponent
        let mainTarget = config.target ?? directoryName
        let names = Set(dumped.targets.map(\.name))

        // Every target name the config mentions must exist, or the config is out of date.
        var expected: [(key: String, name: String)] = []
        if role != .core { expected.append(("target", mainTarget)) }
        if let name = config.testDoubles { expected.append(("testDoubles", name)) }
        if let name = config.testSupport { expected.append(("testSupport", name)) }
        if let name = config.routingTestDoubles { expected.append(("routingTestDoubles", name)) }
        for (key, name) in expected where !names.contains(name) {
            let hint = key == "target"
                ? "Set packages.\(role.rawValue).target to the package's main target."
                : "Fix packages.\(role.rawValue).\(key), or remove it."
            throw LoupeError("loupe.json: packages.\(role.rawValue).\(key) is \"\(name)\", but \(config.path)/Package.swift declares no such target (it declares: \(dumped.targets.map(\.name).sorted().joined(separator: ", "))).\n  \(hint)")
        }

        let targets = dumped.targets.map { target -> PendingTarget in
            let entry = manifest.targets[target.name]
            return PendingTarget(
                id: TargetID(package: role, name: target.name),
                kind: classify(role: role, target: target, config: config, mainTarget: mainTarget),
                type: target.type,
                location: entry?.location ?? manifest.packageLocation,
                declaredPath: target.path,
                pathLocation: entry?.pathLocation,
                dumped: target
            )
        }
        return PendingPackage(role: role, config: config, directory: directory, dumped: dumped, manifest: manifest, targets: targets)
    }

    static func classify(role: Role, target: DumpedManifest.Target, config: LoupeConfig.Package, mainTarget: String) -> TargetKind? {
        let name = target.name
        if target.type == "test" {
            guard role == .core else { return .test(role) }
            let (feature, coreRole) = CoreNaming.split(name)
            if coreRole == .tests { return .coreFeature(feature, .tests) }
            // A test target with the wrong suffix is still a test target; `core-target-name` reports the name.
            if let (found, _) = CoreNaming.correctedName(for: name) {
                return .coreFeature(String(name.dropLast(found.count)), .tests)
            }
            return .coreFeature(name, .tests)
        }
        guard target.type == "regular" else { return nil }
        switch role {
        case .utilities:
            if name == mainTarget { return .utilities }
            if name == config.testSupport { return .testSupport }
        case .coreInterface, .crossInterface, .presentationInterface:
            if name == mainTarget { return .interface(role) }
            if name == config.testDoubles { return .interfaceTestDoubles(role) }
        case .presentation:
            if name == mainTarget { return .presentation }
            if name == config.routingTestDoubles { return .routingTestDoubles }
        case .core:
            let effective = CoreNaming.correctedName(for: name)?.corrected ?? name
            let (feature, coreRole) = CoreNaming.split(effective)
            return .coreFeature(feature, coreRole)
        }
        return nil
    }
}

extension WorkspaceBuilder.PendingPackage {
    /// Resolves package and target dependencies now that every package is known.
    mutating func resolve(
        directories: [Role: URL], roleByDirectory: [String: Role], others: [Role: WorkspaceBuilder.PendingPackage]
    ) {
        // Package-level edges, matched to their `.package(...)` lines for locations.
        var dependencyPackages: [(identity: String, destination: PackageEdge.Destination)] = []
        for dependency in dumped.dependencies {
            switch dependency {
            case .local(let identity, let path):
                let absolute = URL(fileURLWithPath: path).canonical.path
                let destination: PackageEdge.Destination = roleByDirectory[absolute].map { .mapped($0) } ?? .unmapped(path: absolute)
                let entry = manifest.packageDependencies.first { entry in
                    guard let relative = entry.path else { return false }
                    return URL(fileURLWithPath: relative, relativeTo: directory).canonical.path == absolute
                }
                edges.append(
                    PackageEdge(
                        destination: destination,
                        written: entry?.path.map { ".package(path: \"\($0)\")" } ?? ".package(path: \"\(absolute)\")",
                        location: entry?.location ?? manifest.packageLocation
                    )
                )
                dependencyPackages.append((identity, destination))
            case .remote(let identity, let location):
                let entry = manifest.packageDependencies.first { $0.url != nil && $0.url == location }
                let destination = PackageEdge.Destination.remote(identity: identity, location: location)
                edges.append(
                    PackageEdge(
                        destination: destination,
                        written: location.map { ".package(url: \"\($0)\", …)" } ?? ".package(…)",
                        location: entry?.location ?? manifest.packageLocation
                    )
                )
                dependencyPackages.append((identity, destination))
            }
        }

        let localNames = Set(targets.map(\.dumped.name))
        for index in targets.indices {
            let target = targets[index]
            let entries = manifest.targets[target.id.name]?.dependencies ?? []
            var used = Set<Int>()
            var resolved: [ResolvedDependency] = []
            for dependency in target.dumped.dependencies {
                let key: ManifestIndex.DependencyKey
                let written: String
                switch dependency {
                case .byName(let name): key = .byName(name); written = "\"\(name)\""
                case .target(let name): key = .target(name); written = ".target(name: \"\(name)\")"
                case .product(let name, let package):
                    key = .product(name: name, package: package)
                    written = ".product(name: \"\(name)\"" + (package.map { ", package: \"\($0)\"" } ?? "") + ")"
                }
                let entryIndex = entries.indices.first { !used.contains($0) && entries[$0].key == key }
                if let entryIndex { used.insert(entryIndex) }
                let location = entryIndex.map { entries[$0].location } ?? target.location

                var ids: [TargetID] = []
                var via: Role?
                var external: String?
                switch dependency {
                case .byName(let name), .target(let name):
                    if localNames.contains(name) {
                        ids = [TargetID(package: role, name: name)]
                    } else if case .byName = dependency {
                        (ids, via) = products(named: name, package: nil, in: dependencyPackages, others: others)
                    }
                case .product(let name, let package):
                    (ids, via) = products(named: name, package: package, in: dependencyPackages, others: others)
                    if via == nil { external = package }
                }
                resolved.append(
                    ResolvedDependency(written: written, location: location, targets: ids, viaPackage: via, externalPackage: external)
                )
            }
            targets[index].dependencies = resolved
        }
    }

    /// Finds a product by name among the mapped packages this package depends on.
    private func products(
        named name: String, package: String?, in dependencyPackages: [(identity: String, destination: PackageEdge.Destination)],
        others: [Role: WorkspaceBuilder.PendingPackage]
    ) -> ([TargetID], Role?) {
        for (identity, destination) in dependencyPackages {
            guard case .mapped(let role) = destination, let other = others[role] else { continue }
            if let package {
                let matches = [identity, other.dumped.name, other.directory.lastPathComponent].contains {
                    $0.caseInsensitiveCompare(package) == .orderedSame
                }
                guard matches else { continue }
            }
            if let product = other.dumped.products.first(where: { $0.name == name }) {
                return (product.targets.map { TargetID(package: role, name: $0) }, role)
            }
        }
        return ([], nil)
    }
}

extension WorkspaceBuilder {
    // MARK: Sources

    fileprivate static func sourceFiles(of target: PendingTarget, in package: PendingPackage, root: URL, exclude: [LoupeConfig.Exclude]) -> [URL] {
        let base: URL
        if let path = target.declaredPath {
            base = package.directory.appendingPathComponent(path)
        } else {
            base = package.directory.appendingPathComponent(target.type == "test" ? "Tests" : "Sources").appendingPathComponent(target.id.name)
        }
        let roots = target.dumped.sources.map { $0.map { base.appendingPathComponent($0) } } ?? [base]
        var found: [URL] = []
        for start in roots {
            if start.pathExtension == "swift" {
                found.append(start)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: start, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                } else if url.pathExtension == "swift" {
                    found.append(url)
                }
            }
        }
        let rootPath = root.path + "/"
        return found
            .filter { url in
                let relative = url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
                return !exclude.contains { Glob.matches($0.glob, path: relative) }
            }
            .sorted { $0.path < $1.path }
    }

    fileprivate static func parse(_ urls: [URL]) async -> [String: SourceFile] {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let sorted = urls.sorted { $0.path < $1.path }
        let chunkSize = max(1, (sorted.count + workers - 1) / workers)
        return await withTaskGroup(of: [SourceFile].self) { group in
            for start in stride(from: 0, to: sorted.count, by: chunkSize) {
                let chunk = Array(sorted[start..<min(start + chunkSize, sorted.count)])
                group.addTask {
                    chunk.compactMap { url in
                        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
                        return SourceFile(path: url.path, source: String(decoding: data, as: UTF8.self))
                    }
                }
            }
            var all: [String: SourceFile] = [:]
            for await files in group { for file in files { all[file.path] = file } }
            return all
        }
    }
}

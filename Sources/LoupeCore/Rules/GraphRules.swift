import Foundation
import LoupeArchitecture

/// Rules over the dependency graph in Package.swift: who may depend on whom.
struct GraphRules: Rule {
    static let thirdParty = RuleInfo(
        id: "third-party-dependency", family: "Dependency graph",
        title: "No third-party packages",
        rule: "Packages in the architecture may not depend on third-party packages (`.package(url:)`).",
        why: "Third-party frameworks are confined to Infrastructure so they can be swapped without touching any other package. Packages also have to build on Linux, which third-party code often doesn't.",
        howToFix: "Remove the `.package(url:)` entry and every target dependency on its products. Code that needs the library belongs in Infrastructure, behind a protocol declared in an interface package."
    )
    static let forbiddenPackage = RuleInfo(
        id: "forbidden-package-dependency", family: "Dependency graph",
        title: "Packages depend only on the packages their role allows",
        rule: "A package may depend only on the packages its role allows: interface packages on Utilities; Core on CoreInterface, CrossInterface and Utilities; Presentation on the interface packages and Utilities. No package may depend on Core or Presentation, and none on a package .loupe.json doesn't map.",
        why: "Implementations stay swappable, and recompile independently, only if nothing but the composition root depends on them. The composition root is the one place that wires implementations together.",
        howToFix: "Remove the `.package(path:)` entry and the target dependencies on its products. Depend on the matching interface package instead, and let the composition root inject the implementation."
    )
    static let interfaceDependency = RuleInfo(
        id: "interface-dependency", family: "Dependency graph",
        title: "Interface and base-layer targets depend only on Utilities",
        rule: "Interface targets (CoreInterface, CrossInterface, PresentationInterface, Core feature interfaces, Shared), Utilities and TestSupport may depend only on what the matrix allows: interfaces on Utilities, Core feature interfaces also on CoreInterface and Shared, Utilities on nothing.",
        why: "Interfaces are what implementations on both sides agree on. Keeping them stable and cheap to recompile lets each side change without touching the other.",
        howToFix: "Remove the dependency. If the interface needs a type from the target you depended on, that type probably belongs in an interface target instead."
    )
    static let implementationDependency = RuleInfo(
        id: "implementation-dependency", family: "Dependency graph",
        title: "Implementations depend only on interfaces",
        rule: "An implementations target (Presentation, `<Feature>Implementations`) may depend only on interface targets, plus SharedImplementations in Core. Never on another implementation, and never on a test doubles target.",
        why: "Implementations that know only interfaces can be swapped, and edited without recompiling any other implementation. A change to one feature's implementation then affects only that feature's tests.",
        howToFix: "Depend on the other feature's interface target instead and use only what it declares. If the interface doesn't declare what you need, add it there."
    )
    static let testDoublesDependency = RuleInfo(
        id: "test-doubles-dependency", family: "Dependency graph",
        title: "Test doubles depend only on their own interface",
        rule: "A test doubles target may depend only on its own interface target and what that interface may depend on. Nothing but test targets may depend on a test doubles target.",
        why: "Test doubles must compile with only the interface they stand in for, so editing a feature never breaks another feature's doubles, and test-only code never ships.",
        howToFix: "Remove the dependency. A double that needs a type from another interface is a sign that the type belongs in CoreInterface or Shared."
    )
    static let testTargetDependency = RuleInfo(
        id: "test-target-dependency", family: "Dependency graph",
        title: "Tests depend only on what they test",
        rule: "A Core feature's tests may depend on the feature's implementations and test doubles, any interface target, TestSupport, and, when the feature's implementations depend on them, SharedImplementations and the test doubles of the interfaces. Other test targets may depend on their own package's targets, interfaces and their test doubles, Utilities and TestSupport.",
        why: "Changes to a feature's tests must not break or recompile any other target, and the tests of one feature must not quietly rely on another feature's doubles or shared logic unless the feature itself depends on it.",
        howToFix: "Remove the dependency. If the feature genuinely needs the other feature, add the other feature's interface to its implementations target first; its test doubles then become available to its tests."
    )
    static let testSupportInNonTest = RuleInfo(
        id: "test-support-in-non-test-target", family: "Dependency graph",
        title: "TestSupport is for test targets only",
        rule: "Only `.testTarget` targets may depend on TestSupport.",
        why: "Test-support code must never ship. Linking it into a regular target puts test helpers into the app.",
        howToFix: "Remove TestSupport from the target's dependencies and move the test code that used it into a test target. If non-test code needs the helper, it belongs in Utilities."
    )
    static let sharedSingleConsumer = RuleInfo(
        id: "shared-single-consumer", family: "Dependency graph",
        title: "Shared code is used by at least two features",
        rule: "Shared needs at least 2 feature interface targets that depend on it, and SharedImplementations at least 2 feature implementations targets.",
        why: "Everything in Shared is recompiled into every feature that uses it, and an edit to SharedImplementations recompiles every feature implementation. Code used by one feature belongs in that feature, where an edit stays local.",
        howToFix: "Move the code that only one feature uses into that feature's target. Create or keep Shared only once a second feature needs the same type."
    )
    static let unmappedTarget = RuleInfo(
        id: "unmapped-target", family: "Dependency graph",
        title: "Every target has a role",
        rule: "Every target in a mapped package must be one the architecture knows: the package's main target, its test doubles or TestSupport target as named in .loupe.json, a test target, or (in Core) a feature target.",
        why: "Loupe decides which dependency and purity rules apply to a target from its role. A target it can't classify would escape every rule.",
        howToFix: "If it is the package's test doubles, TestSupport or routing test doubles target, name it in .loupe.json. Otherwise move it into the main target, or into a package outside the architecture."
    )

    var infos: [RuleInfo] {
        [Self.thirdParty, Self.forbiddenPackage, Self.interfaceDependency, Self.implementationDependency,
         Self.testDoublesDependency, Self.testTargetDependency, Self.testSupportInNonTest,
         Self.sharedSingleConsumer, Self.unmappedTarget]
    }

    func check(_ workspace: Workspace) -> [Violation] {
        var violations: [Violation] = []
        for package in workspace.packages.values.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
            violations += packageEdges(of: package, in: workspace)
            violations += targetEdges(of: package, in: workspace)
            violations += unmappedTargets(of: package, in: workspace)
        }
        violations += sharedConsumers(in: workspace)
        return violations
    }

    // MARK: Package edges

    private func packageEdges(of package: WorkspacePackage, in workspace: Workspace) -> [Violation] {
        var violations: [Violation] = []
        for edge in package.edges {
            switch edge.destination {
            case .remote(let identity, let url):
                let users = package.targets.filter { target in
                    target.dependencies.contains { $0.externalPackage?.caseInsensitiveCompare(identity) == .orderedSame }
                }.map(\.name).sorted()
                violations.append(
                    Violation(
                        ruleID: Self.thirdParty.id, location: edge.location,
                        summary: "\(quoted(package.name)) depends on the third-party package \(quoted(identity))\(url.map { " (\($0))" } ?? "")",
                        fix: "Remove \(edge.written) from \(workspace.relativePath(package.manifestPath))"
                            + (users.isEmpty ? "" : " and the dependencies on its products from: \(users.joined(separator: ", "))")
                            + ". Put the code that needs it in Infrastructure, behind a protocol declared in an interface package."
                    )
                )
            case .unmapped(let path):
                let name = URL(fileURLWithPath: path).lastPathComponent
                violations.append(
                    Violation(
                        ruleID: Self.forbiddenPackage.id, location: edge.location,
                        summary: "\(quoted(package.name)) depends on the local package \(quoted(name)), which .loupe.json doesn't map to a role",
                        fix: "Remove \(edge.written) and any dependencies on its products. If \(quoted(name)) is part of the architecture, map it in .loupe.json; if it isn't, nothing in the architecture may depend on it."
                    )
                )
            case .mapped(let role):
                guard role != package.role, !PackagePolicy.allowedDependencies(of: package.role).contains(role) else { continue }
                let users = package.targets.filter { target in target.dependencies.contains { $0.viaPackage == role } }.map(\.name).sorted()
                let name = workspace.packages[role]?.name ?? role.noun
                let why: String
                let advice: String
                if PackagePolicy.isCompositionRootOnly(role) {
                    why = "No package may depend on the \(role.title): only the composition root wires implementations together, which is what keeps them swappable and independently compilable."
                    advice = "Depend on the interface package instead (for example CoreInterface or PresentationInterface) and let the composition root inject the implementation."
                } else {
                    why = "A \(package.role.title) may depend only on \(PackagePolicy.allowedSummary(for: package.role))."
                    advice = "Move the code that needs \(quoted(name)) to a package that may depend on it."
                }
                violations.append(
                    Violation(
                        ruleID: Self.forbiddenPackage.id, location: edge.location,
                        summary: "\(quoted(package.name)) (\(package.role.title)) depends on \(quoted(name)) (\(role.title))",
                        why: why,
                        fix: "Remove \(edge.written) from \(workspace.relativePath(package.manifestPath))"
                            + (users.isEmpty ? "" : " and the dependencies on its products from: \(users.joined(separator: ", "))")
                            + ". \(advice)"
                    )
                )
            }
        }
        return violations
    }

    // MARK: Target edges

    private func targetEdges(of package: WorkspacePackage, in workspace: Workspace) -> [Violation] {
        var violations: [Violation] = []
        var seen = Set<String>()
        for target in package.targets {
            guard let from = target.ref else { continue }
            let implementationDependencies = implementationDependencies(of: from, in: workspace)
            for dependency in target.dependencies {
                // Already reported once, at the `.package(...)` line.
                if let via = dependency.viaPackage, via != package.role,
                   !PackagePolicy.allowedDependencies(of: package.role).contains(via) { continue }
                for id in dependency.targets {
                    guard id != target.id, let to = workspace.target(id)?.ref else { continue }
                    guard let denial = DependencyPolicy.evaluate(
                        from: from, to: to, implementationDependencies: implementationDependencies
                    ) else { continue }
                    let key = "\(dependency.location.line):\(from.name):\(to.name)"
                    guard seen.insert(key).inserted else { continue }
                    violations.append(violation(for: denial, from: from, to: to, dependency: dependency, workspace: workspace))
                }
            }
        }
        return violations
    }

    /// For a Core `<F>Tests` target, what `<F>Implementations` depends on.
    private func implementationDependencies(of from: TargetRef, in workspace: Workspace) -> [TargetRef] {
        guard case .coreFeature(let feature, .tests) = from.kind,
              let implementations = workspace.target(named: feature + CoreRole.implementations.suffix, in: .core)
        else { return [] }
        return workspace.directDependencies(of: implementations).compactMap(\.target.ref)
    }

    private func violation(
        for denial: Denial, from: TargetRef, to: TargetRef, dependency: ResolvedDependency, workspace: Workspace
    ) -> Violation {
        let ruleID: String
        switch denial.category {
        case .interface: ruleID = Self.interfaceDependency.id
        case .implementation: ruleID = Self.implementationDependency.id
        case .testDoubles: ruleID = Self.testDoublesDependency.id
        case .test: ruleID = Self.testTargetDependency.id
        case .testSupport: ruleID = Self.testSupportInNonTest.id
        }
        return Violation(
            ruleID: ruleID, location: dependency.location,
            summary: "\(quoted(from.name)) depends on \(quoted(to.name))",
            why: "A \(from.kind.title) may depend only on \(DependencyPolicy.allowedSummary(for: from.kind)). \(denial.reason)",
            fix: fix(from: from, to: to, dependency: dependency, workspace: workspace)
        )
    }

    private func fix(from: TargetRef, to: TargetRef, dependency: ResolvedDependency, workspace: Workspace) -> String {
        let remove = "Remove \(dependency.written) from the dependencies of \(quoted(from.name))"
        switch (from.kind, to.kind) {
        case (.coreFeature(_, .implementations), .coreFeature(let other, .implementations)):
            if let interface = workspace.target(named: other, in: .core) {
                return "In the dependencies of \(quoted(from.name)), replace \(dependency.written) with \(quoted(interface.name)) (the interface target of \(other)) and use only what it declares. If it doesn't declare what you need, add that to \(quoted(interface.name))."
            }
            return "\(other) has no interface target. Create \(quoted(other)) at Core/\(other)/\(other)/ with the protocols and data-only models \(quoted(from.name)) needs, make \(quoted(to.name)) conform to them, and depend on \(quoted(other)) instead."
        case (_, .testSupport):
            return "\(remove). Only test targets may use TestSupport; if non-test code needs the helper, move it to Utilities."
        case (.coreFeature(let feature, .tests), .coreFeature(let other, .testDoubles)):
            return "\(remove). \(quoted(feature + "Implementations")) doesn't depend on \(quoted(other)), so its tests have no use for \(other)'s doubles. If it should depend on \(other), add \(quoted(other)) to \(quoted(feature + "Implementations")) first."
        case (_, _) where to.kind.isTestDoubles && !from.kind.isTest:
            return "\(remove). Test doubles are for tests: depend on the real interface here, and put \(quoted(to.name)) on the test target that needs it."
        default:
            return "\(remove) (\(workspace.describe(dependency.location))), or move the code that needs \(quoted(to.name)) to a target that may depend on it."
        }
    }

    // MARK: Unmapped targets

    private func unmappedTargets(of package: WorkspacePackage, in workspace: Workspace) -> [Violation] {
        package.targets.compactMap { target in
            guard target.kind == nil else { return nil }
            return Violation(
                ruleID: Self.unmappedTarget.id, location: target.location,
                summary: "Target \(quoted(target.name)) in \(quoted(package.name)) (\(package.role.title)) has no role in the architecture",
                fix: "If it is this package's test doubles, TestSupport or routing test doubles target, name it in .loupe.json under packages.\(package.role.rawValue). Otherwise move its code into the package's main target, or into a package outside the architecture."
                    + (target.type == "regular" ? "" : " (Its type is \(target.type); only regular and test targets are part of the architecture.)")
            )
        }
    }

    // MARK: Shared

    private func sharedConsumers(in workspace: Workspace) -> [Violation] {
        guard let core = workspace.packages[.core] else { return [] }
        let shared = CoreNaming.sharedFeature
        var violations: [Violation] = []
        let checks: [(name: String, role: CoreRole, noun: String, dependentRole: CoreRole)] = [
            (shared, .interface, "feature interface target", .interface),
            (shared + CoreRole.implementations.suffix, .implementations, "feature implementations target", .implementations),
        ]
        for check in checks {
            guard let target = workspace.target(named: check.name, in: .core), target.kind != nil else { continue }
            let dependents = core.targets.filter { other in
                guard case .coreFeature(let feature, check.dependentRole)? = other.kind, feature != shared else { return false }
                return workspace.directDependencies(of: other).contains { $0.target.id == target.id }
            }.map(\.name).sorted()
            guard dependents.count < DependencyPolicy.minimumSharedDependents else { continue }
            let used = dependents.isEmpty ? "no \(check.noun)" : "only \(quoted(dependents[0]))"
            let move = dependents.isEmpty
                ? "Remove \(quoted(target.name)) until two features need it."
                : "Move what \(quoted(target.name)) holds into \(quoted(dependents[0])) (Core/\(dependents[0].replacingOccurrences(of: CoreRole.implementations.suffix, with: ""))/), where an edit stays local, and remove \(quoted(target.name)) until a second feature needs it."
            violations.append(
                Violation(
                    ruleID: Self.sharedSingleConsumer.id, location: target.location,
                    summary: "\(quoted(target.name)) is used by \(used); it needs at least \(DependencyPolicy.minimumSharedDependents) \(check.noun)s",
                    fix: move
                )
            )
        }
        return violations
    }
}

/// A target as the policy sees it: its name (for messages) and what it is.
public struct TargetRef: Hashable, Sendable {
    public var name: String
    public var kind: TargetKind

    public init(name: String, kind: TargetKind) {
        self.name = name
        self.kind = kind
    }
}

/// Which family of rule an edge falls under. LoupeCore maps each to a rule id.
public enum DependencyCategory: Sendable {
    /// Utilities, TestSupport and interface targets: the stable base layer.
    case interface
    case implementation
    case testDoubles
    case test
    case testSupport
}

public struct Denial: Equatable, Sendable {
    public var category: DependencyCategory
    /// Why this particular edge is wrong, in one sentence.
    public var reason: String
}

/// Package-level rules: which packages may depend on which.
public enum PackagePolicy {
    public static func allowedDependencies(of role: Role) -> Set<Role> {
        switch role {
        case .utilities: []
        case .coreInterface, .crossInterface, .presentationInterface: [.utilities]
        case .core: [.coreInterface, .crossInterface, .utilities]
        case .presentation: [.presentationInterface, .coreInterface, .crossInterface, .utilities]
        }
    }

    /// Implementations are wired together only by the composition root, so no package may depend on them.
    public static func isCompositionRootOnly(_ role: Role) -> Bool {
        role == .core || role == .presentation
    }

    public static func allowedSummary(for role: Role) -> String {
        let names = Role.allCases.filter { allowedDependencies(of: role).contains($0) }
        if names.isEmpty { return "no other package" }
        return englishList(names.map { "the \($0.noun) package" })
    }
}

/// Target-level rules: which kinds of target may depend on which. This is the whole matrix; the tests
/// pin every edge so a change here is always deliberate.
public enum DependencyPolicy {
    /// Shared and SharedImplementations each need at least this many dependents, or single-feature
    /// code drifts into them and every edit recompiles every feature.
    public static let minimumSharedDependents = 2

    /// - Parameters:
    ///   - implementationDependencies: for a Core `<F>Tests` target, what `<F>Implementations` depends
    ///     on. A feature's tests may use the test doubles of exactly those interfaces.
    /// - Returns: `nil` when the edge is allowed.
    public static func evaluate(
        from: TargetRef,
        to: TargetRef,
        implementationDependencies: [TargetRef] = []
    ) -> Denial? {
        if to.kind == .testSupport, !from.kind.isTest {
            return Denial(
                category: .testSupport,
                reason: "TestSupport is test-only code, so it must never be linked into a target that ships."
            )
        }
        if isAllowed(from: from, to: to, implementationDependencies: implementationDependencies) { return nil }
        return Denial(category: category(of: from.kind), reason: reason(from: from, to: to))
    }

    public static func category(of kind: TargetKind) -> DependencyCategory {
        switch kind {
        case .utilities, .testSupport, .interface, .coreFeature(_, .interface): .interface
        case .presentation, .coreFeature(_, .implementations): .implementation
        case .interfaceTestDoubles, .routingTestDoubles, .coreFeature(_, .testDoubles): .testDoubles
        case .test, .coreFeature(_, .tests): .test
        }
    }

    // MARK: The matrix

    private static func isAllowed(from: TargetRef, to: TargetRef, implementationDependencies: [TargetRef]) -> Bool {
        let target = to.kind
        switch from.kind {
        case .utilities:
            return false
        case .testSupport, .interface:
            return target == .utilities
        case .interfaceTestDoubles(let role):
            return target == .utilities || target == .interface(role)
        case .presentation:
            return target == .utilities || isCoreOrPresentationInterface(target)
        case .routingTestDoubles:
            return target == .utilities || target == .presentation
                || target == .interface(.presentationInterface) || target == .interface(.coreInterface)
        case .test(let role):
            return target.package == role || target == .utilities || target == .testSupport
                || isAnyInterface(target) || isAnyInterfaceTestDoubles(target)
        case .coreFeature(let feature, let role):
            return isAllowedInCore(feature: feature, role: role, target: target,
                                   implementationDependencies: implementationDependencies)
        }
    }

    private static func isAllowedInCore(
        feature: String, role: CoreRole, target: TargetKind, implementationDependencies: [TargetRef]
    ) -> Bool {
        let isSharedFeature = feature == CoreNaming.sharedFeature
        let shared = TargetKind.coreFeature(CoreNaming.sharedFeature, .interface)
        let ownInterface = TargetKind.coreFeature(feature, .interface)
        let interfaceBase = target == .utilities || target == .interface(.coreInterface)
        switch role {
        case .interface:
            return interfaceBase || (!isSharedFeature && target == shared)
        case .implementations:
            if isSharedFeature { return interfaceBase || target == shared }
            return isCoreInterfaceTarget(target) || target == .coreFeature(CoreNaming.sharedFeature, .implementations)
        case .testDoubles:
            return interfaceBase || target == ownInterface || (!isSharedFeature && target == shared)
        case .tests:
            if isCoreInterfaceTarget(target) || target == .testSupport { return true }
            if target == .coreFeature(feature, .implementations) || target == .coreFeature(feature, .testDoubles) {
                return true
            }
            // What the feature's implementations depend on is fair game for its tests: SharedImplementations,
            // and the test doubles of the interfaces.
            let dependedOn = Set(implementationDependencies.map(\.kind))
            if target == .coreFeature(CoreNaming.sharedFeature, .implementations) { return dependedOn.contains(target) }
            switch target {
            case .interfaceTestDoubles(let packageRole): return dependedOn.contains(.interface(packageRole))
            case .coreFeature(let other, .testDoubles): return dependedOn.contains(.coreFeature(other, .interface))
            default: return false
            }
        }
    }

    /// "Interface target" as Core means it: any Core feature interface, Shared, CoreInterface,
    /// CrossInterface or Utilities.
    private static func isCoreInterfaceTarget(_ kind: TargetKind) -> Bool {
        switch kind {
        case .utilities, .interface(.coreInterface), .interface(.crossInterface), .coreFeature(_, .interface): true
        default: false
        }
    }

    private static func isCoreOrPresentationInterface(_ kind: TargetKind) -> Bool {
        kind == .interface(.presentationInterface) || kind == .interface(.coreInterface)
            || kind == .interface(.crossInterface)
    }

    private static func isAnyInterface(_ kind: TargetKind) -> Bool {
        if case .interface = kind { return true }
        return false
    }

    private static func isAnyInterfaceTestDoubles(_ kind: TargetKind) -> Bool {
        if case .interfaceTestDoubles = kind { return true }
        return false
    }

    // MARK: Words

    /// What a kind of target may depend on, for the `rule:` line of a message.
    public static func allowedSummary(for kind: TargetKind) -> String {
        switch kind {
        case .utilities:
            "nothing. Every package may depend on Utilities, so it has to stay self-contained"
        case .testSupport:
            "Utilities only"
        case .interface:
            "Utilities only"
        case .interfaceTestDoubles:
            "its own interface target and Utilities"
        case .presentation:
            "interface targets (PresentationInterface, CoreInterface, CrossInterface) and Utilities"
        case .routingTestDoubles:
            "Presentation, the presentation interface, the core interface and Utilities"
        case .test:
            "targets in its own package, interface targets and their test doubles, Utilities and TestSupport"
        case .coreFeature(let feature, let role):
            switch role {
            case .interface where feature == CoreNaming.sharedFeature:
                "CoreInterface and Utilities"
            case .interface:
                "CoreInterface, Shared and Utilities"
            case .implementations where feature == CoreNaming.sharedFeature:
                "Shared, CoreInterface and Utilities"
            case .implementations:
                "interface targets (any feature's interface, Shared, CoreInterface, CrossInterface, Utilities) and SharedImplementations"
            case .testDoubles:
                "its own feature's interface and whatever that interface may depend on (CoreInterface, Shared, Utilities)"
            case .tests:
                "its own feature's implementations and test doubles, any interface target, TestSupport, and, when its implementations depend on them, SharedImplementations and the test doubles of the interfaces"
            }
        }
    }

    private static func reason(from: TargetRef, to: TargetRef) -> String {
        switch (from.kind, to.kind) {
        case (.coreFeature(_, .implementations), .coreFeature(_, .implementations)):
            "Feature implementations depend on each other's interfaces, never on each other's implementations, so one feature's implementation can change without recompiling any other feature."
        case (.coreFeature, .coreFeature(_, .tests)), (_, .test):
            "Test targets are leaves; nothing may depend on them."
        case (_, .coreFeature(_, .testDoubles)), (_, .interfaceTestDoubles), (_, .routingTestDoubles):
            from.kind.isTest
                ? "A feature's tests may only use the test doubles of its own feature and of the interfaces its implementations depend on, so unrelated features can't break its tests."
                : "Test doubles are test-only code; only test targets (and other test doubles of the same interface) may use them."
        case (_, .coreFeature(_, .implementations)), (_, .presentation):
            "Implementations are interchangeable only if nothing but the composition root depends on them. Depend on the interface target and let the composition root inject the implementation."
        case (.interface, _), (.coreFeature(_, .interface), _), (.utilities, _), (.testSupport, _):
            "Interface and base-layer targets must stay stable and cheap to recompile, so the implementations on both sides of them can change independently."
        default:
            "This edge isn't part of the architecture's dependency matrix."
        }
    }
}

/// "A", "A and B", "A, B and C".
public func englishList(_ items: [String]) -> String {
    switch items.count {
    case 0: ""
    case 1: items[0]
    default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

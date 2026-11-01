/// The role a Swift package plays in the architecture. `loupe.json` maps each app's package
/// directories onto these roles; the rules only ever talk about roles, so one rule set serves every app.
public enum Role: String, CaseIterable, Codable, Sendable {
    case utilities
    case coreInterface
    case crossInterface
    case presentationInterface
    case core
    case presentation

    /// Interface packages hold protocols and data-only models, plus a matching test doubles target.
    public var isInterfacePackage: Bool {
        switch self {
        case .coreInterface, .crossInterface, .presentationInterface: true
        case .utilities, .core, .presentation: false
        }
    }

    /// How messages refer to the role, e.g. "presentation interface".
    public var noun: String {
        switch self {
        case .utilities: "utilities"
        case .coreInterface: "core interface"
        case .crossInterface: "cross interface"
        case .presentationInterface: "presentation interface"
        case .core: "core"
        case .presentation: "presentation"
        }
    }

    public var title: String { "\(noun) package" }
}

/// The part a target plays inside a Core feature (`Core/<Feature>/<Feature><Role>/`).
public enum CoreRole: String, CaseIterable, Sendable {
    case interface
    case implementations
    case testDoubles
    case tests

    public var suffix: String {
        switch self {
        case .interface: ""
        case .implementations: "Implementations"
        case .testDoubles: "TestDoubles"
        case .tests: "Tests"
        }
    }
}

/// What a single target is, which decides the rules that apply to it.
public enum TargetKind: Hashable, Sendable {
    /// The main target of the utilities package.
    case utilities
    /// The target that holds test-only helpers. Only test targets may depend on it.
    case testSupport
    /// The main target of an interface package.
    case interface(Role)
    /// The test doubles target of an interface package.
    case interfaceTestDoubles(Role)
    /// The main target of the presentation package.
    case presentation
    /// Test doubles for the routing protocols that live in the presentation package.
    case routingTestDoubles
    /// A target of a Core feature (including the `Shared` pseudo-feature).
    case coreFeature(String, CoreRole)
    /// A test target in any package other than Core.
    case test(Role)

    /// The role of the package that contains a target of this kind.
    public var package: Role {
        switch self {
        case .utilities, .testSupport: .utilities
        case .interface(let role), .interfaceTestDoubles(let role), .test(let role): role
        case .presentation, .routingTestDoubles: .presentation
        case .coreFeature: .core
        }
    }

    public var isTest: Bool {
        switch self {
        case .test, .coreFeature(_, .tests): true
        default: false
        }
    }

    public var isTestDoubles: Bool {
        switch self {
        case .interfaceTestDoubles, .routingTestDoubles, .coreFeature(_, .testDoubles): true
        default: false
        }
    }

    /// Interface targets hold data-only models and protocols, and are held to the purity rules.
    public var isPureInterface: Bool {
        switch self {
        case .interface(let role): role.isInterfacePackage
        case .coreFeature(_, .interface): true
        default: false
        }
    }

    public var isShared: Bool { self == .coreFeature(CoreNaming.sharedFeature, .interface) }

    public var isSharedImplementations: Bool {
        self == .coreFeature(CoreNaming.sharedFeature, .implementations)
    }

    /// A short phrase for messages, e.g. "Core feature implementations target".
    public var title: String {
        switch self {
        case .utilities: "Utilities target"
        case .testSupport: "test support target"
        case .interface(let role): "\(role.noun) target"
        case .interfaceTestDoubles(let role): "\(role.noun) test doubles target"
        case .presentation: "presentation target"
        case .routingTestDoubles: "routing test doubles target"
        case .coreFeature(_, let role):
            if isShared { "Shared interface target" }
            else if isSharedImplementations { "SharedImplementations target" }
            else {
                switch role {
                case .interface: "Core feature interface target"
                case .implementations: "Core feature implementations target"
                case .testDoubles: "Core feature test doubles target"
                case .tests: "Core feature test target"
                }
            }
        case .test: "test target"
        }
    }
}

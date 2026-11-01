import LoupeArchitecture

/// A family of related checks over the loaded workspace.
protocol Rule: Sendable {
    /// Everything this family can report, in the order `loupe rules` lists it.
    var infos: [RuleInfo] { get }
    func check(_ workspace: Workspace) -> [Violation]
}

/// Every rule Loupe has. `loupe rules`, `loupe explain`, the `rule:`/`why:` lines of each message and
/// the `loupe:allow` validation all read this one list.
public enum RuleCatalog {
    static let families: [any Rule] = [GraphRules(), CoreLayoutRules(), ImportRules(), InterfacePurityRules()]

    public static let all: [RuleInfo] = families.flatMap(\.infos) + AllowRules.infos

    public static func info(for id: String) -> RuleInfo? {
        all.first { $0.id == id }
    }

    /// The closest rule ids to `id`, for "did you mean" hints.
    public static func suggestions(for id: String) -> [String] {
        all.map(\.id).filter { ConfigLoader.editDistance(id, $0) <= max(3, $0.count / 3) }
    }
}

extension Workspace {
    /// A target's declaration as users know it, e.g. `Core/Package.swift:63`.
    func describe(_ location: SourceLocation) -> String {
        "\(relativePath(location.path)):\(location.line)"
    }
}

/// Wraps names for messages.
func quoted(_ name: String) -> String { "'\(name)'" }

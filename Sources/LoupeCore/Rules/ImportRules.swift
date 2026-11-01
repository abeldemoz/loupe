import LoupeArchitecture
import SwiftSyntax

/// Rules over `import` statements: declared dependencies, and Linux availability.
struct ImportRules: Rule {
    static let undeclared = RuleInfo(
        id: "undeclared-import", family: "Imports",
        title: "Imports are declared dependencies",
        rule: "Every first-party module a file imports must be a direct dependency of its target in Package.swift.",
        why: "SwiftPM lets a target import anything reachable through its dependencies, so a forbidden dependency can hide as an undeclared transitive import. Requiring every import to be declared makes Package.swift the complete graph, which is what the dependency rules check.",
        howToFix: "Add the module to the target's `dependencies:`, or remove the import if the target doesn't need it. If the architecture doesn't allow the dependency, Loupe says so once you add it; remove the import instead."
    )
    static let nonLinux = RuleInfo(
        id: "non-linux-import", family: "Imports",
        title: "Packages build on Linux",
        rule: "A Swift package may unconditionally import only declared first-party modules and system modules that exist on Linux: \(ImportRules.linuxModules.sorted().joined(separator: ", ")). Any other import must sit inside `#if canImport(Module)`.",
        why: "Packages build and test on Linux CI. UI frameworks and Apple-only system frameworks live in the Xcode projects (UI, Infrastructure, the composition root), which is why those aren't packages. An allowlist fails closed: a framework nobody thought of is caught too.",
        howToFix: "If the import is an Apple-only framework, move the code that uses it to the UI layer or Infrastructure, or wrap the import and that code in `#if canImport(Module)`. If it is a first-party module, declare it as a dependency."
    )

    /// System modules that ship with the Swift toolchain on Linux and Apple platforms alike.
    static let linuxModules: Set<String> = [
        "Swift", "Foundation", "FoundationEssentials", "Dispatch", "Synchronization", "Observation",
        "RegexBuilder", "Testing", "XCTest",
    ]

    var infos: [RuleInfo] { [Self.undeclared, Self.nonLinux] }

    func check(_ workspace: Workspace) -> [Violation] {
        var violations: [Violation] = []
        for target in workspace.targets where target.kind != nil {
            guard let package = workspace.packages[target.id.package] else { continue }
            var declared: Set<String> = [target.name.replacingOccurrences(of: "-", with: "_")]
            for (_, dependency) in workspace.directDependencies(of: target) {
                declared.insert(dependency.name.replacingOccurrences(of: "-", with: "_"))
            }
            // How many files in this target import each undeclared module, so the fix can say that one
            // change in Package.swift resolves all of them.
            var undeclaredCounts: [String: Int] = [:]
            var found: [(file: SourceFile, statement: ImportStatement)] = []
            for file in target.sourceFiles {
                for statement in ImportStatement.collect(in: file) {
                    found.append((file, statement))
                    if workspace.modules[statement.module] != nil, !declared.contains(statement.module) {
                        undeclaredCounts[statement.module, default: 0] += 1
                    }
                }
            }
            for (file, statement) in found {
                let module = statement.module
                if let provider = workspace.modules[module] {
                    guard !declared.contains(module) else { continue }
                    let count = undeclaredCounts[module] ?? 1
                    violations.append(
                        Violation(
                            ruleID: Self.undeclared.id, location: statement.location,
                            summary: "\(quoted(target.name)) imports \(quoted(module)) but doesn't declare it as a dependency",
                            fix: "Add \(snippet(for: provider, from: target, in: package, workspace: workspace)) to the dependencies of \(quoted(target.name)) in \(workspace.relativePath(package.manifestPath)):\(target.location.line)"
                                + (count > 1 ? " (that one change fixes all \(count) files in \(quoted(target.name)) that import it)" : "")
                                + ", or remove the import if it isn't needed."
                        )
                    )
                } else if !Self.linuxModules.contains(module), !statement.guardedModules.contains(module) {
                    violations.append(
                        Violation(
                            ruleID: Self.nonLinux.id, location: statement.location,
                            summary: "Unconditional `import \(module)` in \(quoted(target.name)) can't be built on Linux",
                            why: "\(quoted(module)) is neither a declared first-party module nor one of the system modules available on Linux (\(Self.linuxModules.sorted().joined(separator: ", "))), and packages must build on Linux CI.",
                            fix: "If \(module) is an Apple-only framework, move the code that uses it to the UI layer or Infrastructure (Xcode projects), or wrap the import and that code in `#if canImport(\(module))` … `#endif`. If it is a first-party module, add it to the dependencies of \(quoted(target.name)) (only where the architecture allows)."
                        )
                    )
                }
                _ = file
            }
        }
        return violations
    }

    /// What to write in `dependencies:` to depend on `provider`.
    private func snippet(for provider: TargetID, from target: WorkspaceTarget, in package: WorkspacePackage, workspace: Workspace) -> String {
        if provider.package == package.role { return "\"\(provider.name)\"" }
        guard let other = workspace.packages[provider.package] else { return "\"\(provider.name)\"" }
        let product = other.dumped.products.first { $0.name == provider.name && $0.targets.contains(provider.name) }
            ?? other.dumped.products.first { $0.targets.contains(provider.name) }
        guard let product else {
            return "a product that exports \(quoted(provider.name)) (\(other.name)/Package.swift declares none)"
        }
        var text = ".product(name: \"\(product.name)\", package: \"\(other.name)\")"
        let declared = package.edges.contains { if case .mapped(let role) = $0.destination { role == other.role } else { false } }
        if !declared {
            let relative = "../" + URLComponentsHelper.lastComponent(other.directory)
            text += " (and `.package(path: \"\(relative)\")` to the package's dependencies, since it isn't declared yet)"
        }
        return text
    }
}

enum URLComponentsHelper {
    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// One `import` in a file, with the modules whose `#if canImport(...)` surround it.
struct ImportStatement {
    var module: String
    var location: SourceLocation
    var guardedModules: Set<String>

    static func collect(in file: SourceFile) -> [ImportStatement] {
        let collector = Collector(file: file)
        collector.walk(file.tree)
        return collector.statements
    }

    private final class Collector: SyntaxVisitor {
        let file: SourceFile
        var statements: [ImportStatement] = []
        private var guardStack: [Set<String>] = []

        init(file: SourceFile) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
            for clause in node.clauses {
                guardStack.append(clause.condition.map(Self.canImportGuards) ?? [])
                walk(clause)
                guardStack.removeLast()
            }
            return .skipChildren
        }

        override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
            if let first = node.path.first {
                statements.append(
                    ImportStatement(
                        module: first.name.text,
                        location: file.location(of: first),
                        guardedModules: guardStack.reduce(into: Set<String>()) { $0.formUnion($1) }
                    )
                )
            }
            return .skipChildren
        }

        /// Modules that must be importable for a `#if` condition to hold: `canImport(X)` and
        /// `canImport(X) && canImport(Y)`. Negations and `||` guarantee nothing.
        static func canImportGuards(_ condition: ExprSyntax) -> Set<String> {
            if let call = condition.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self), callee.baseName.text == "canImport",
               let module = call.arguments.first?.expression.as(DeclReferenceExprSyntax.self)
            {
                return [module.baseName.text]
            }
            if let tuple = condition.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
                return canImportGuards(only.expression)
            }
            if let sequence = condition.as(SequenceExprSyntax.self) {
                let operators = sequence.elements.compactMap { $0.as(BinaryOperatorExprSyntax.self)?.operator.text }
                guard !operators.contains("||") else { return [] }
                return sequence.elements.reduce(into: Set<String>()) { $0.formUnion(canImportGuards($1)) }
            }
            return []
        }
    }
}

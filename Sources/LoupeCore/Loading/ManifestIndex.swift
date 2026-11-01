import SwiftSyntax

/// Where things are written in a `Package.swift`. `dump-package` gives the graph but no positions, and
/// messages and `loupe:allow` comments need line numbers, so this walks the manifest's syntax tree to
/// find each target and each dependency by name.
struct ManifestIndex: Sendable {
    enum DependencyKey: Hashable, Sendable {
        case byName(String)
        case target(String)
        case product(name: String, package: String?)
    }

    struct DependencyEntry: Sendable {
        var key: DependencyKey
        var location: SourceLocation
    }

    struct TargetEntry: Sendable {
        var name: String
        /// Where the target's `name:` literal is.
        var location: SourceLocation
        var path: String?
        var pathLocation: SourceLocation?
        var dependencies: [DependencyEntry]
    }

    struct PackageDependencyEntry: Sendable {
        var path: String?
        var url: String?
        var location: SourceLocation
    }

    let file: SourceFile
    /// Where `Package(` is, the fallback for anything that can't be found.
    let packageLocation: SourceLocation
    let targets: [String: TargetEntry]
    let packageDependencies: [PackageDependencyEntry]

    init(file: SourceFile) {
        self.file = file
        let visitor = Visitor(file: file)
        visitor.walk(file.tree)
        packageLocation = visitor.packageLocation ?? SourceLocation(path: file.path, line: 1, column: 1)
        targets = Dictionary(visitor.targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        packageDependencies = visitor.packageDependencies
    }

    private final class Visitor: SyntaxVisitor {
        let file: SourceFile
        var targets: [TargetEntry] = []
        var packageDependencies: [PackageDependencyEntry] = []
        var packageLocation: SourceLocation?

        private static let targetFactories: Set<String> = [
            "target", "testTarget", "executableTarget", "macro", "plugin", "systemLibrary", "binaryTarget",
        ]

        init(file: SourceFile) {
            self.file = file
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self), reference.baseName.text == "Package",
               packageLocation == nil
            {
                packageLocation = file.location(of: node)
            }
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return .visitChildren }
            let name = member.declName.baseName.text
            if Self.targetFactories.contains(name) {
                recordTarget(node)
            } else if name == "package" {
                packageDependencies.append(
                    PackageDependencyEntry(
                        path: stringArgument("path", in: node),
                        url: stringArgument("url", in: node),
                        location: file.location(of: node)
                    )
                )
            }
            return .visitChildren
        }

        private func recordTarget(_ call: FunctionCallExprSyntax) {
            guard let nameExpr = argument("name", in: call), let name = literal(nameExpr) else { return }
            var dependencies: [DependencyEntry] = []
            if let array = argument("dependencies", in: call)?.as(ArrayExprSyntax.self) {
                for element in array.elements {
                    if let key = dependencyKey(element.expression) {
                        dependencies.append(DependencyEntry(key: key, location: file.location(of: element.expression)))
                    }
                }
            }
            let pathExpr = argument("path", in: call)
            targets.append(
                TargetEntry(
                    name: name,
                    location: file.location(of: nameExpr),
                    path: pathExpr.flatMap(literal),
                    pathLocation: pathExpr.map { file.location(of: $0) },
                    dependencies: dependencies
                )
            )
        }

        private func dependencyKey(_ expression: ExprSyntax) -> DependencyKey? {
            if let text = literal(expression) { return .byName(text) }
            guard let call = expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self)
            else { return nil }
            switch member.declName.baseName.text {
            case "product":
                guard let name = stringArgument("name", in: call) else { return nil }
                return .product(name: name, package: stringArgument("package", in: call))
            case "target":
                return stringArgument("name", in: call).map { .target($0) }
            case "byName":
                return stringArgument("name", in: call).map { .byName($0) }
            default:
                return nil
            }
        }

        private func argument(_ label: String, in call: FunctionCallExprSyntax) -> ExprSyntax? {
            call.arguments.first { $0.label?.text == label }?.expression
        }

        private func stringArgument(_ label: String, in call: FunctionCallExprSyntax) -> String? {
            argument(label, in: call).flatMap(literal)
        }

        /// The value of a plain string literal; nil for anything computed or interpolated.
        private func literal(_ expression: ExprSyntax) -> String? {
            guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
            var text = ""
            for segment in literal.segments {
                guard let plain = segment.as(StringSegmentSyntax.self) else { return nil }
                text += plain.content.text
            }
            return text
        }
    }
}

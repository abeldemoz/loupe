import LoupeArchitecture
import SwiftSyntax

/// Interface targets hold protocols and data-only models. These rules check the syntax of every
/// declaration in them, plus one rule (`public-dto`) that applies to every non-test target.
struct InterfacePurityRules: Rule {
    static let referenceType = RuleInfo(
        id: "interface-reference-type", family: "Interface purity",
        title: "No classes or actors in interfaces",
        rule: "Interface targets contain protocols, structs and enums, never classes or actors.",
        why: "A class carries identity and behavior, which are implementation details. Interfaces hold plain value models and protocols so implementations on both sides can change freely.",
        howToFix: "Make it a struct or enum with stored properties, or a protocol if consumers only need its behavior. Move the class itself into an implementation target."
    )
    static let function = RuleInfo(
        id: "interface-function", family: "Interface purity",
        title: "No methods in interfaces",
        rule: "Concrete types in interface targets are data-only: no `func` and no `subscript`. Protocol requirements are fine.",
        why: "\"Move that logic to the consumer\": behavior is an implementation detail. If the interface owns it, every change recompiles everything that depends on the interface, and every consumer is stuck with one answer.",
        howToFix: "Move the function to the consumer that uses it, as a function or an extension in the implementation target. If several consumers share it, put it in that layer's shared implementation."
    )
    static let computedProperty = RuleInfo(
        id: "interface-computed-property", family: "Interface purity",
        title: "No computed properties in interfaces",
        rule: "Concrete types in interface targets have only plain stored properties: no computed, `lazy` or observed (`willSet`/`didSet`) properties.",
        why: "A computed property is a method in disguise: logic that every consumer then depends on.",
        howToFix: "Store the value and compute it where the model is built, or move the computation to the consumer."
    )
    static let staticMember = RuleInfo(
        id: "interface-static-member", family: "Interface purity",
        title: "No static or global members in interfaces",
        rule: "Interface targets declare no `static`/`class` members and no global variables, constants or functions.",
        why: "A preset such as `static let empty` is a decision about what a default value means. That belongs to the consumers that need it, not to the contract everyone shares.",
        howToFix: "Move the member to the consumer that uses it. If several consumers need the same value, define it in the implementation layer they share."
    )
    static let propertyDefault = RuleInfo(
        id: "interface-property-default", family: "Interface purity",
        title: "No initial values on stored properties",
        rule: "Stored properties in interface targets have no initial value (`= …`).",
        why: "A default hides a decision inside the interface. When the init assigns every property, each construction site makes its own choices explicit.",
        howToFix: "Remove the initial value, add the property to the init, and pass the value at each construction site."
    )
    static let initCount = RuleInfo(
        id: "interface-init-count", family: "Interface purity",
        title: "One init per struct",
        rule: "A public struct in an interface target declares exactly one init in its body (per `#if` configuration); an enum declares none; an extension declares none.",
        why: "A public struct needs an explicit init to be built from another module, and a second init is a second way to build the model: logic that belongs to consumers.",
        howToFix: "Keep one memberwise init in the struct's body that only assigns each parameter to its property. Move any other way of building the value to the consumer."
    )
    static let initNotTrivial = RuleInfo(
        id: "interface-init-not-trivial", family: "Interface purity",
        title: "Inits only assign",
        rule: "The init of an interface struct only assigns each parameter to a stored property (`self.x = x`), assigns every stored property, and is neither failable, throwing nor async.",
        why: "Anything beyond assignment (clamping, formatting, validation, a hidden default) is logic. Model construction must be a plain copy of data so every consumer sees the same value.",
        howToFix: "Reduce the init to `self.x = x` for every property, and move the extra work to the code that builds the model."
    )
    static let initDefaultArgument = RuleInfo(
        id: "interface-init-default-argument", family: "Interface purity",
        title: "No default arguments in inits",
        rule: "Init parameters in interface targets have no default values.",
        why: "A default argument is a default value by another route: a decision made for every caller.",
        howToFix: "Remove the default and pass the value explicitly at each call site."
    )
    static let protocolExtension = RuleInfo(
        id: "interface-protocol-extension", family: "Interface purity",
        title: "No default implementations in interfaces",
        rule: "Interface targets contain no protocol extensions with members.",
        why: "A default implementation is behavior that every conformer silently inherits. It belongs to the implementation layer, where the conformers are.",
        howToFix: "Move the members into the implementations that need them, or into a helper in the implementation layer, and make each conformer state its behavior."
    )
    static let publicDTO = RuleInfo(
        id: "public-dto", family: "Interface purity",
        title: "DTOs are never public",
        rule: "Types named `*DTO` are not `public`.",
        why: "DTOs are implementation details of the services that decode them. A public DTO leaks API vocabulary to every consumer and makes the API impossible to swap.",
        howToFix: "Remove `public` and expose the domain model that the service maps from the DTO."
    )

    var infos: [RuleInfo] {
        [Self.referenceType, Self.function, Self.computedProperty, Self.staticMember, Self.propertyDefault,
         Self.initCount, Self.initNotTrivial, Self.initDefaultArgument, Self.protocolExtension, Self.publicDTO]
    }

    func check(_ workspace: Workspace) -> [Violation] {
        var violations: [Violation] = []
        for target in workspace.targets {
            guard let kind = target.kind, !kind.isTest else { continue }
            let protocols = kind.isPureInterface ? Self.protocolNames(in: target) : []
            for file in target.sourceFiles {
                if kind.isPureInterface {
                    violations += Self.violations(in: file, targetName: target.name, protocolNames: protocols)
                }
                violations += Self.publicDTOs(in: file, targetName: target.name)
            }
        }
        return violations
    }

    /// The purity violations in one file of an interface target. `protocolNames` are the protocols
    /// declared anywhere in the target, which tells a protocol extension from any other extension.
    static func violations(in file: SourceFile, targetName: String, protocolNames: Set<String> = []) -> [Violation] {
        var checker = PurityChecker(file: file, targetName: targetName, protocolNames: protocolNames)
        checker.checkItems(file.tree.statements, in: .file)
        return checker.violations
    }

    private static func protocolNames(in target: WorkspaceTarget) -> Set<String> {
        final class Collector: SyntaxVisitor {
            var names: Set<String> = []
            init() { super.init(viewMode: .sourceAccurate) }
            override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
                names.insert(node.name.text)
                return .visitChildren
            }
        }
        let collector = Collector()
        for file in target.sourceFiles { collector.walk(file.tree) }
        return collector.names
    }

    // MARK: public-dto

    static func publicDTOs(in file: SourceFile, targetName: String) -> [Violation] {
        final class Finder: SyntaxVisitor {
            let file: SourceFile
            let targetName: String
            var violations: [Violation] = []
            /// Whether each enclosing type is public; a nested `public` in an internal type isn't visible outside.
            var enclosingIsPublic: [Bool] = []

            init(file: SourceFile, targetName: String) {
                self.file = file
                self.targetName = targetName
                super.init(viewMode: .sourceAccurate)
            }

            func enter(name: TokenSyntax, modifiers: DeclModifierListSyntax) {
                let isPublic = modifiers.contains { $0.name.text == "public" || $0.name.text == "open" }
                if isPublic, name.text.hasSuffix("DTO"), enclosingIsPublic.allSatisfy({ $0 }) {
                    violations.append(
                        Violation(
                            ruleID: InterfacePurityRules.publicDTO.id, location: file.location(of: name),
                            summary: "\(quoted(name.text)) is a public DTO in \(quoted(targetName))",
                            fix: "Remove `public` from \(name.text) (internal is enough for the service that decodes it) and expose the domain model it is mapped to."
                        )
                    )
                }
                enclosingIsPublic.append(isPublic)
            }

            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(name: node.name, modifiers: node.modifiers); return .visitChildren }
            override func visitPost(_ node: StructDeclSyntax) { enclosingIsPublic.removeLast() }
            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(name: node.name, modifiers: node.modifiers); return .visitChildren }
            override func visitPost(_ node: EnumDeclSyntax) { enclosingIsPublic.removeLast() }
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(name: node.name, modifiers: node.modifiers); return .visitChildren }
            override func visitPost(_ node: ClassDeclSyntax) { enclosingIsPublic.removeLast() }
            override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(name: node.name, modifiers: node.modifiers); return .visitChildren }
            override func visitPost(_ node: ActorDeclSyntax) { enclosingIsPublic.removeLast() }
            override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enter(name: node.name, modifiers: node.modifiers); return .visitChildren }
            override func visitPost(_ node: ProtocolDeclSyntax) { enclosingIsPublic.removeLast() }
            override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { enter(name: node.name, modifiers: node.modifiers); enclosingIsPublic.removeLast(); return .skipChildren }
        }
        guard file.tree.description.contains("DTO") else { return [] }
        let finder = Finder(file: file, targetName: targetName)
        finder.walk(file.tree)
        return finder.violations
    }
}

// MARK: - The purity checker

enum Context {
    case file
    case structType(String)
    case enumType(String)
    case extensionOf(String)
    case protocolType
}

struct PurityChecker {
    let file: SourceFile
    let targetName: String
    let protocolNames: Set<String>
    var violations: [Violation] = []
    private var reported = Set<String>()

    init(file: SourceFile, targetName: String, protocolNames: Set<String>) {
        self.file = file
        self.targetName = targetName
        self.protocolNames = protocolNames
    }

    mutating func report(_ rule: RuleInfo, at node: some SyntaxProtocol, summary: String, why: String? = nil, fix: String) {
        let location = file.location(of: node)
        guard reported.insert("\(rule.id):\(location.line):\(location.column):\(summary)").inserted else { return }
        violations.append(Violation(ruleID: rule.id, location: location, summary: summary, why: why, fix: fix))
    }

    // MARK: Walking

    mutating func checkItems(_ items: CodeBlockItemListSyntax, in context: Context) {
        for item in items {
            switch item.item {
            case .decl(let decl): checkDecl(decl, in: context)
            default: break
            }
        }
    }

    mutating func checkMembers(_ members: MemberBlockItemListSyntax, in context: Context) {
        for member in members { checkDecl(member.decl, in: context) }
    }

    mutating func checkDecl(_ decl: DeclSyntax, in context: Context) {
        if case .protocolType = context { return }
        if let node = decl.as(StructDeclSyntax.self) {
            checkStruct(node)
        } else if let node = decl.as(EnumDeclSyntax.self) {
            checkMembers(node.memberBlock.members, in: .enumType(node.name.text))
        } else if let node = decl.as(ClassDeclSyntax.self) {
            reportReferenceType(node.name, keyword: "class")
        } else if let node = decl.as(ActorDeclSyntax.self) {
            reportReferenceType(node.name, keyword: "actor")
        } else if let node = decl.as(ExtensionDeclSyntax.self) {
            checkExtension(node)
        } else if let node = decl.as(FunctionDeclSyntax.self) {
            checkFunction(node, in: context)
        } else if let node = decl.as(SubscriptDeclSyntax.self) {
            checkSubscript(node, in: context)
        } else if let node = decl.as(VariableDeclSyntax.self) {
            checkVariable(node, in: context)
        } else if let node = decl.as(InitializerDeclSyntax.self) {
            checkStrayInit(node, in: context)
        } else if let node = decl.as(IfConfigDeclSyntax.self) {
            for clause in node.clauses {
                switch clause.elements {
                case .statements(let items): checkItems(items, in: context)
                case .decls(let members): checkMembers(members, in: context)
                default: break
                }
            }
        }
    }

    private func owner(of context: Context) -> String {
        switch context {
        case .structType(let name), .enumType(let name), .extensionOf(let name): name
        case .file, .protocolType: targetName
        }
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
    }

    private func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" || $0.name.text == "open" }
    }

    // MARK: Declarations

    private mutating func reportReferenceType(_ name: TokenSyntax, keyword: String) {
        report(
            InterfacePurityRules.referenceType, at: name,
            summary: "\(quoted(name.text)) is a \(keyword) in the interface target \(quoted(targetName))",
            fix: "Make \(name.text) a struct (or enum) with stored properties, or a protocol if consumers only need its behavior, and move the \(keyword) into an implementation target."
        )
    }

    private mutating func checkFunction(_ node: FunctionDeclSyntax, in context: Context) {
        let owner = owner(of: context)
        if isStatic(node.modifiers) {
            report(
                InterfacePurityRules.staticMember, at: node.name,
                summary: "Static function \(quoted(node.name.text + "()")) in \(quoted(owner))",
                fix: "Move \(node.name.text)() to the consumer that calls it. Interface targets hold data, not factories or helpers."
            )
        } else if case .file = context {
            report(
                InterfacePurityRules.staticMember, at: node.name,
                summary: "Global function \(quoted(node.name.text + "()")) in the interface target \(quoted(targetName))",
                fix: "Move \(node.name.text)() to the consumer that calls it."
            )
        } else {
            report(
                InterfacePurityRules.function, at: node.name,
                summary: "\(quoted(owner)) declares the method \(quoted(node.name.text + "()"))",
                fix: "Move \(node.name.text)() to the consumer that calls it, as a function or an extension of \(owner) in the implementation target that uses it."
            )
        }
    }

    private mutating func checkSubscript(_ node: SubscriptDeclSyntax, in context: Context) {
        let owner = owner(of: context)
        if isStatic(node.modifiers) {
            report(
                InterfacePurityRules.staticMember, at: node.subscriptKeyword,
                summary: "Static subscript in \(quoted(owner))",
                fix: "Move the subscript to the consumer that uses it."
            )
        } else {
            report(
                InterfacePurityRules.function, at: node.subscriptKeyword,
                summary: "\(quoted(owner)) declares a subscript",
                fix: "Move the subscript to the consumer that uses it, as an extension of \(owner) in the implementation target."
            )
        }
    }

    private mutating func checkVariable(_ node: VariableDeclSyntax, in context: Context) {
        let owner = owner(of: context)
        let isGlobal: Bool = if case .file = context { true } else { false }
        for binding in node.bindings {
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                ?? binding.pattern.trimmedDescription
            if isStatic(node.modifiers) || isGlobal {
                let what = isGlobal ? "Global \(node.bindingSpecifier.text)" : "Static \(node.bindingSpecifier.text)"
                report(
                    InterfacePurityRules.staticMember, at: binding.pattern,
                    summary: "\(what) \(quoted(name)) in \(quoted(owner))",
                    fix: "Move \(name) to the consumer that needs it. A preset or constant is that consumer's decision, not part of the shared contract."
                )
            } else if node.modifiers.contains(where: { $0.name.text == "lazy" }) {
                report(
                    InterfacePurityRules.computedProperty, at: binding.pattern,
                    summary: "\(quoted(owner)).\(name) is a `lazy` property",
                    fix: "Make \(name) a plain stored property that the init assigns, and compute its value where the model is built."
                )
            } else if let accessors = binding.accessorBlock {
                let observed = accessorNames(accessors).allSatisfy { $0 == "willSet" || $0 == "didSet" } && !accessorNames(accessors).isEmpty
                report(
                    InterfacePurityRules.computedProperty, at: binding.pattern,
                    summary: observed
                        ? "\(quoted(owner)).\(name) has a `willSet`/`didSet` observer"
                        : "\(quoted(owner)).\(name) is a computed property",
                    fix: observed
                        ? "Remove the observer and make \(name) a plain stored property. Observation is the consumer's job."
                        : "Store \(name) and compute it where the model is built, or move the computation to the consumer."
                )
            } else if binding.initializer != nil {
                report(
                    InterfacePurityRules.propertyDefault, at: binding.pattern,
                    summary: "\(quoted(owner)).\(name) has an initial value",
                    fix: "Remove `= …` from \(name), add it to the init of \(owner), and pass the value at each construction site."
                )
            }
        }
    }

    private func accessorNames(_ block: AccessorBlockSyntax) -> [String] {
        switch block.accessors {
        case .accessors(let list): list.map { $0.accessorSpecifier.text }
        case .getter: ["get"]
        }
    }

    private mutating func checkStrayInit(_ node: InitializerDeclSyntax, in context: Context) {
        switch context {
        case .enumType(let name):
            report(
                InterfacePurityRules.initCount, at: node.initKeyword,
                summary: "Enum \(quoted(name)) declares an init",
                fix: "Remove the init from \(name). Enums in interfaces have only their cases; build values from a case."
            )
        case .extensionOf(let name):
            report(
                InterfacePurityRules.initCount, at: node.initKeyword,
                summary: "An init in an extension of \(quoted(name))",
                fix: "Remove it. The only init of a struct is the single memberwise init in its body; other ways to build the value belong to the consumer."
            )
        default:
            break
        }
    }

    // MARK: Extensions

    private mutating func checkExtension(_ node: ExtensionDeclSyntax) {
        let name = node.extendedType.trimmedDescription
        let members = node.memberBlock.members
        if protocolNames.contains(name) {
            let behaviors = members.compactMap { member -> String? in
                let decl = member.decl
                if let function = decl.as(FunctionDeclSyntax.self) { return function.name.text + "()" }
                if let variable = decl.as(VariableDeclSyntax.self) {
                    return variable.bindings.first?.pattern.trimmedDescription
                }
                if decl.is(SubscriptDeclSyntax.self) { return "subscript" }
                if decl.is(InitializerDeclSyntax.self) { return "init" }
                return nil
            }
            if !behaviors.isEmpty {
                report(
                    InterfacePurityRules.protocolExtension, at: node.extendedType,
                    summary: "Extension of the protocol \(quoted(name)) provides default implementations: \(behaviors.joined(separator: ", "))",
                    fix: "Move \(behaviors.joined(separator: ", ")) into the implementations that need them (or a helper in the implementation layer) and make each conformer of \(name) state its own behavior."
                )
            }
            return
        }
        checkMembers(members, in: .extensionOf(name))
    }

    // MARK: Structs and their inits

    private mutating func checkStruct(_ node: StructDeclSyntax) {
        let name = node.name.text
        checkMembers(node.memberBlock.members, in: .structType(name))

        let isPublicStruct = isPublic(node.modifiers)
        for configuration in Self.configurations(of: node.memberBlock.members) {
            let inits = configuration.compactMap { $0.as(InitializerDeclSyntax.self) }
            if inits.isEmpty, isPublicStruct {
                report(
                    InterfacePurityRules.initCount, at: node.name,
                    summary: "Public struct \(quoted(name)) declares no init",
                    fix: "Add one memberwise init to \(name): `public init(…) { self.x = x … }`. Without it other modules can't build \(name), because the synthesized init is internal."
                )
            }
            for extra in inits.dropFirst() {
                report(
                    InterfacePurityRules.initCount, at: extra.initKeyword,
                    summary: "Struct \(quoted(name)) declares more than one init",
                    fix: "Keep a single memberwise init in \(name) and remove this one. Other ways to build the value belong to the consumer."
                )
            }
            if let initializer = inits.first {
                checkInit(initializer, of: name, among: configuration)
            }
        }
    }

    private mutating func checkInit(_ node: InitializerDeclSyntax, of structName: String, among members: [DeclSyntax]) {
        // Stored properties that the init must assign: no accessors and no initial value (those are
        // reported by their own rules).
        var stored: [String] = []
        for member in members {
            guard let variable = member.as(VariableDeclSyntax.self), !isStatic(variable.modifiers),
                  !variable.modifiers.contains(where: { $0.name.text == "lazy" }) else { continue }
            for binding in variable.bindings where binding.accessorBlock == nil && binding.initializer == nil {
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) { stored.append(identifier.identifier.text) }
            }
        }

        let parameters = node.signature.parameterClause.parameters
        for parameter in parameters {
            if parameter.defaultValue != nil {
                let name = (parameter.secondName ?? parameter.firstName).text
                report(
                    InterfacePurityRules.initDefaultArgument, at: parameter,
                    summary: "Parameter \(quoted(name)) of the init of \(quoted(structName)) has a default value",
                    fix: "Remove `\(parameter.defaultValue?.trimmedDescription ?? "= …")` from \(name) and pass it explicitly at each call site."
                )
            }
        }
        if node.optionalMark != nil {
            report(
                InterfacePurityRules.initNotTrivial, at: node.initKeyword,
                summary: "The init of \(quoted(structName)) is failable",
                fix: "Make it non-failable. Validation belongs to the code that builds the model; \(structName) only holds the data."
            )
        }
        if node.signature.effectSpecifiers?.asyncSpecifier != nil || node.signature.effectSpecifiers?.throwsClause != nil {
            report(
                InterfacePurityRules.initNotTrivial, at: node.initKeyword,
                summary: "The init of \(quoted(structName)) is \(node.signature.effectSpecifiers?.asyncSpecifier != nil ? "async" : "throwing")",
                fix: "Make it a plain synchronous, non-throwing init that only assigns its parameters."
            )
        }

        let parameterNames = parameters.map { ($0.secondName ?? $0.firstName).text }.filter { $0 != "_" }
        var assigned: [String] = []
        var assignedFrom: [String] = []
        var onlyPlainAssignments = true
        for statement in node.body?.statements ?? [] {
            if let (property, value) = Self.assignment(in: statement), parameterNames.contains(value) {
                assigned.append(property)
                assignedFrom.append(value)
            } else {
                    onlyPlainAssignments = false
                report(
                    InterfacePurityRules.initNotTrivial, at: statement,
                    summary: "The init of \(quoted(structName)) does more than assign: `\(statement.trimmedDescription.prefix(60))`",
                    fix: "Replace it with `self.property = parameter`, and move the logic to the code that builds \(structName)."
                )
            }
        }
        // A statement that does more than assign has been reported; "never assigned" would be the same cause twice.
        for property in stored where onlyPlainAssignments && !assigned.contains(property) {
            report(
                InterfacePurityRules.initNotTrivial, at: node.initKeyword,
                summary: "The init of \(quoted(structName)) never assigns the stored property \(quoted(property))",
                fix: "Add a \(property) parameter and `self.\(property) = \(property)`. An unassigned optional `var` silently defaults to nil, which is a hidden default."
            )
        }
        for name in parameterNames where onlyPlainAssignments && !assignedFrom.contains(name) {
            report(
                InterfacePurityRules.initNotTrivial, at: node.initKeyword,
                summary: "The init of \(quoted(structName)) takes the parameter \(quoted(name)) but never assigns it to a property",
                fix: "Assign it (`self.\(name) = \(name)`) or remove the parameter."
            )
        }
    }

    /// `self.x = y` or `x = y`, as (property, value) when `y` is a plain identifier.
    private static func assignment(in statement: CodeBlockItemSyntax) -> (String, String)? {
        guard case .expr(let expression) = statement.item,
              let sequence = expression.as(SequenceExprSyntax.self), sequence.elements.count == 3,
              sequence.elements[sequence.elements.index(after: sequence.elements.startIndex)].is(AssignmentExprSyntax.self),
              let value = sequence.elements.last?.as(DeclReferenceExprSyntax.self)
        else { return nil }
        let target = sequence.elements.first!
        if let member = target.as(MemberAccessExprSyntax.self),
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        {
            return (member.declName.baseName.text, value.baseName.text)
        }
        if let reference = target.as(DeclReferenceExprSyntax.self) {
            return (reference.baseName.text, value.baseName.text)
        }
        return nil
    }

    /// Every configuration a member list can take, flattened to declarations.
    ///
    /// A struct is judged in each configuration separately, because `#if DEBUG` / `#else` can legitimately
    /// give it a different init in each. Blocks that share a condition move together: a `#if DEBUG`
    /// property and a `#if DEBUG` init are either both present or both absent, so mixed combinations
    /// that can never be compiled are not considered.
    static func configurations(of members: MemberBlockItemListSyntax) -> [[DeclSyntax]] {
        var conditions: [String] = []
        collectConditions(in: members, into: &conditions)
        // Past this many distinct conditions, treat every branch as present at once rather than
        // enumerate 2^n configurations.
        guard conditions.count <= 6 else { return [flatten(members, active: Set(conditions))] }
        var result: [[DeclSyntax]] = []
        var seen = Set<[Int]>()
        for mask in 0..<(1 << conditions.count) {
            let active = Set(conditions.indices.filter { mask & (1 << $0) != 0 }.map { conditions[$0] })
            let flat = flatten(members, active: active)
            if seen.insert(flat.map { $0.position.utf8Offset }).inserted { result.append(flat) }
        }
        return result
    }

    private static func collectConditions(in members: MemberBlockItemListSyntax, into conditions: inout [String]) {
        for member in members {
            guard let ifConfig = member.decl.as(IfConfigDeclSyntax.self) else { continue }
            for clause in ifConfig.clauses {
                if let condition = clause.condition?.trimmedDescription, !conditions.contains(condition) {
                    conditions.append(condition)
                }
                if case .decls(let inner)? = clause.elements { collectConditions(in: inner, into: &conditions) }
            }
        }
    }

    /// The declarations present when exactly the conditions in `active` hold. In an `#if` / `#elseif` /
    /// `#else` chain the first clause whose condition holds is the one that compiles.
    private static func flatten(_ members: MemberBlockItemListSyntax, active: Set<String>) -> [DeclSyntax] {
        var result: [DeclSyntax] = []
        for member in members {
            guard let ifConfig = member.decl.as(IfConfigDeclSyntax.self) else {
                result.append(member.decl)
                continue
            }
            let chosen = ifConfig.clauses.first { clause in
                guard let condition = clause.condition?.trimmedDescription else { return true }
                return active.contains(condition)
            }
            if case .decls(let inner)? = chosen?.elements { result += flatten(inner, active: active) }
        }
        return result
    }
}

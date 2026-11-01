import Testing
@testable import LoupeCore

@Suite struct InterfacePurityTests {
    func check(_ source: String, protocols: Set<String> = []) -> [Violation] {
        InterfacePurityRules.violations(
            in: SourceFile(path: "/app/Movies.swift", source: source), targetName: "Movies", protocolNames: protocols
        )
    }

    func rules(_ source: String, protocols: Set<String> = []) -> [String] {
        check(source, protocols: protocols).map(\.ruleID)
    }

    // MARK: What interfaces may contain

    @Test func dataOnlyModelsAreClean() {
        let source = """
        public struct Movie: Equatable, Sendable {
            public enum Kind: String, Sendable { case feature, short }
            public typealias ID = Int
            public let id: ID
            public let title: String
            public var posterPath: String?
            public let kind: Kind
            public init(id: ID, title: String, posterPath: String?, kind: Kind) {
                self.id = id
                self.title = title
                self.posterPath = posterPath
                self.kind = kind
            }
        }
        public enum Sort { case title, year(descending: Bool) }
        extension Movie: Identifiable {}
        public typealias MovieList = [Movie]
        """
        #expect(check(source).isEmpty)
    }

    @Test func protocolRequirementsAreAllowed() {
        let source = """
        public protocol MovieService: Sendable {
            associatedtype Failure: Error
            var count: Int { get }
            var name: String { get set }
            func movies() async throws -> [Int]
            static func make() -> Self
            subscript(index: Int) -> Int { get }
            init()
        }
        """
        #expect(check(source).isEmpty)
    }

    @Test func nonPublicStructsNeedNoInit() {
        #expect(rules("struct Internal { let id: Int }").isEmpty)
    }

    @Test func parameterNamesMayDifferFromPropertyNames() {
        let source = """
        public struct Movie {
            public let id: Int
            public init(identifier: Int) { self.id = identifier }
        }
        """
        #expect(check(source).isEmpty)
    }

    // MARK: Reference types, functions, members

    @Test func classesAndActorsAreReported() {
        let found = check("""
        public final class Store {}
        public actor Cache {}
        """)
        #expect(found.map(\.ruleID) == ["interface-reference-type", "interface-reference-type"])
        #expect(found[0].summary == "'Store' is a class in the interface target 'Movies'")
        #expect(found[0].location.line == 1)
        #expect(found[0].location.column == 20)
    }

    @Test func methodsAreReportedButNotProtocolRequirements() {
        let found = check("""
        public struct Movie {
            public let id: Int
            public init(id: Int) { self.id = id }
            public func isLong() -> Bool { true }
            public subscript(i: Int) -> Int { i }
        }
        """)
        #expect(found.map(\.ruleID) == ["interface-function", "interface-function"])
        #expect(found[0].summary == "'Movie' declares the method 'isLong()'")
    }

    @Test func staticMembersAndGlobalsAreReported() {
        let found = check("""
        public struct Selection {
            public let id: Int
            public init(id: Int) { self.id = id }
            public static let empty = Selection(id: 0)
            public static func make() -> Selection { empty }
            public class var shared: Int { 1 }
        }
        public let defaultTimeout = 5
        public func helper() {}
        """)
        #expect(Set(found.map(\.ruleID)) == ["interface-static-member"])
        #expect(found.count == 5)
        #expect(found[0].summary == "Static let 'empty' in 'Selection'")
        #expect(found.last?.summary == "Global function 'helper()' in the interface target 'Movies'")
    }

    @Test func computedLazyAndObservedPropertiesAreReported() {
        let found = check("""
        public struct Movie {
            public let id: Int
            public var title: String { "x" }
            public lazy var cached = 1
            public var count: Int = 0 { didSet {} }
            public init(id: Int) { self.id = id }
        }
        """)
        #expect(found.map(\.ruleID).filter { $0 == "interface-computed-property" }.count == 3)
        #expect(found.contains { $0.summary == "'Movie'.title is a computed property" })
        #expect(found.contains { $0.summary == "'Movie'.cached is a `lazy` property" })
        #expect(found.contains { $0.summary == "'Movie'.count has a `willSet`/`didSet` observer" })
    }

    @Test func storedPropertyDefaultsAreReported() {
        let found = check("""
        public struct Movie {
            public let id: Int = 0
            public let tags: [String]
            public init(tags: [String]) { self.tags = tags }
        }
        """)
        #expect(found.map(\.ruleID) == ["interface-property-default"])
        #expect(found[0].summary == "'Movie'.id has an initial value")
    }

    // MARK: Inits

    @Test func publicStructNeedsAnInit() {
        let found = check("public struct Movie { public let id: Int }")
        #expect(found.map(\.ruleID) == ["interface-init-count"])
        #expect(found[0].summary == "Public struct 'Movie' declares no init")
    }

    @Test func secondInitIsReported() {
        let found = check("""
        public struct Movie {
            public let id: Int
            public init(id: Int) { self.id = id }
            public init() { self.id = 0 }
        }
        """)
        #expect(found.contains { $0.ruleID == "interface-init-count" && $0.summary == "Struct 'Movie' declares more than one init" })
        #expect(found.filter { $0.ruleID == "interface-init-count" }.count == 1)
    }

    @Test func enumAndExtensionInitsAreReported() {
        let found = check("""
        public enum Kind { case a
            init?(raw: String) { self = .a }
        }
        public struct Movie { public let id: Int; public init(id: Int) { self.id = id } }
        extension Movie { init(other: Int) { self.init(id: other) } }
        """)
        #expect(found.map(\.ruleID) == ["interface-init-count", "interface-init-count"])
        #expect(found[0].summary == "Enum 'Kind' declares an init")
        #expect(found[1].summary == "An init in an extension of 'Movie'")
    }

    @Test func initsMustOnlyAssign() {
        let found = check("""
        public struct Movie {
            public let id: Int
            public let title: String
            public init(id: Int, title: String) throws {
                self.id = max(id, 0)
                self.title = title.trimmingCharacters(in: .whitespaces)
            }
        }
        """)
        #expect(Set(found.map(\.ruleID)) == ["interface-init-not-trivial"])
        // One message per cause: the throwing init, and two statements that do more than assign.
        #expect(found.count == 3)
        #expect(found.contains { $0.summary == "The init of 'Movie' is throwing" })
    }

    @Test func failableAsyncAndUnassignedAreSeparateCauses() {
        let found = check("""
        public struct Movie {
            public let id: Int
            public var note: String?
            public init?(id: Int, extra: Int) async { self.id = id }
        }
        """)
        let summaries = Set(found.map(\.summary))
        #expect(summaries.contains("The init of 'Movie' is failable"))
        #expect(summaries.contains("The init of 'Movie' is async"))
        #expect(summaries.contains("The init of 'Movie' never assigns the stored property 'note'"))
        #expect(summaries.contains("The init of 'Movie' takes the parameter 'extra' but never assigns it to a property"))
    }

    @Test func defaultArgumentsAreReported() {
        let found = check("""
        public struct Size {
            public let width: Double
            public let identifier: String?
            public init(width: Double, identifier: String? = nil) {
                self.width = width
                self.identifier = identifier
            }
        }
        """)
        #expect(found.map(\.ruleID) == ["interface-init-default-argument"])
        #expect(found[0].summary == "Parameter 'identifier' of the init of 'Size' has a default value")
        #expect(found[0].fix?.contains("= nil") == true)
    }

    // MARK: #if configurations

    @Test func debugAndReleaseInitsAreJudgedPerConfiguration() {
        // The shape of Credits' SettingsSceneModel: the property and the init share a condition, so a
        // configuration with the DEBUG property but the release init can never be compiled.
        let source = """
        public struct SettingsSceneModel {
            public let generalItems: [Int]
        #if DEBUG
            public let developerItems: [Int]
        #endif
        #if DEBUG
            public init(generalItems: [Int], developerItems: [Int]) {
                self.generalItems = generalItems
                self.developerItems = developerItems
            }
        #else
            public init(generalItems: [Int]) {
                self.generalItems = generalItems
            }
        #endif
        }
        """
        #expect(check(source).isEmpty)
    }

    @Test func aConfigurationWithoutAnInitIsReported() {
        let source = """
        public struct Model {
            public let id: Int
        #if DEBUG
            public init(id: Int) { self.id = id }
        #endif
        }
        """
        #expect(rules(source) == ["interface-init-count"])
    }

    @Test func aConfigurationWithTwoInitsIsReported() {
        let source = """
        public struct Model {
            public let id: Int
            public init(id: Int) { self.id = id }
        #if DEBUG
            public init() { self.id = 0 }
        #endif
        }
        """
        #expect(rules(source).contains("interface-init-count"))
    }

    // MARK: Protocol extensions

    @Test func protocolExtensionsWithMembersAreReported() {
        let source = """
        public protocol SceneDelegate: AnyObject { func viewDidLoad() }
        public extension SceneDelegate {
            func viewDidLoad() {}
            func viewWillAppear() {}
        }
        """
        let found = check(source, protocols: ["SceneDelegate"])
        #expect(found.map(\.ruleID) == ["interface-protocol-extension"])
        #expect(found[0].summary == "Extension of the protocol 'SceneDelegate' provides default implementations: viewDidLoad(), viewWillAppear()")
    }

    @Test func emptyProtocolExtensionsAreFine() {
        #expect(check("extension SceneDelegate: Sendable {}", protocols: ["SceneDelegate"]).isEmpty)
    }

    @Test func extensionsOfOtherTypesFollowTheMemberRules() {
        let found = check("extension Movie { func isLong() -> Bool { true } }")
        #expect(found.map(\.ruleID) == ["interface-function"])
    }

    // MARK: DTOs

    @Test func publicDTOsAreReported() {
        let source = """
        public struct MovieDTO: Decodable { let id: Int }
        struct HiddenDTO {}
        public struct Outer { struct NestedDTO {} }
        struct Internal { public struct DeepDTO {} }
        public typealias ShowDTO = Int
        """
        let found = InterfacePurityRules.publicDTOs(in: SourceFile(path: "/app/DTO.swift", source: source), targetName: "Movies")
        #expect(found.map(\.summary) == [
            "'MovieDTO' is a public DTO in 'Movies'",
            "'ShowDTO' is a public DTO in 'Movies'",
        ])
    }

    // MARK: Messages

    @Test func everyViolationHasAFixAndALocation() {
        let source = """
        public final class Store {}
        public struct Movie {
            public let id: Int = 1
            public var title: String { "" }
            public func f() {}
            public static let x = 1
            public init(id: Int = 0) throws { self.id = id }
        }
        """
        for violation in check(source) {
            #expect(RuleCatalog.info(for: violation.ruleID) != nil, "\(violation.ruleID) is not in the catalog")
            #expect(violation.fix?.isEmpty == false)
            #expect(violation.location.line >= 1 && violation.location.column >= 1)
        }
    }
}

import Testing
@testable import LoupeArchitecture

/// The dependency matrix, edge by edge. Changing the architecture means changing this table.
@Suite struct DependencyPolicyTests {
    // Kinds used throughout, named like the apps' own targets.
    static let utilities = TargetRef(name: "Utilities", kind: .utilities)
    static let testSupport = TargetRef(name: "TestSupport", kind: .testSupport)
    static let coreInterface = TargetRef(name: "CoreInterface", kind: .interface(.coreInterface))
    static let coreDoubles = TargetRef(name: "CoreTestDoubles", kind: .interfaceTestDoubles(.coreInterface))
    static let crossInterface = TargetRef(name: "CrossInterface", kind: .interface(.crossInterface))
    static let crossDoubles = TargetRef(name: "CrossTestDoubles", kind: .interfaceTestDoubles(.crossInterface))
    static let sceneInterface = TargetRef(name: "SceneInterface", kind: .interface(.presentationInterface))
    static let sceneDoubles = TargetRef(name: "SceneTestDoubles", kind: .interfaceTestDoubles(.presentationInterface))
    static let presentation = TargetRef(name: "Presentation", kind: .presentation)
    static let routingDoubles = TargetRef(name: "RoutingTestDoubles", kind: .routingTestDoubles)
    static let presentationTests = TargetRef(name: "PresentationTests", kind: .test(.presentation))
    static let shared = TargetRef(name: "Shared", kind: .coreFeature("Shared", .interface))
    static let sharedImplementations = TargetRef(name: "SharedImplementations", kind: .coreFeature("Shared", .implementations))
    static let products = TargetRef(name: "Products", kind: .coreFeature("Products", .interface))
    static let productsImpl = TargetRef(name: "ProductsImplementations", kind: .coreFeature("Products", .implementations))
    static let productsDoubles = TargetRef(name: "ProductsTestDoubles", kind: .coreFeature("Products", .testDoubles))
    static let productsTests = TargetRef(name: "ProductsTests", kind: .coreFeature("Products", .tests))
    static let networking = TargetRef(name: "Networking", kind: .coreFeature("Networking", .interface))
    static let networkingImpl = TargetRef(name: "NetworkingImplementations", kind: .coreFeature("Networking", .implementations))
    static let networkingDoubles = TargetRef(name: "NetworkingTestDoubles", kind: .coreFeature("Networking", .testDoubles))
    static let useCasesImpl = TargetRef(name: "UseCasesImplementations", kind: .coreFeature("UseCases", .implementations))

    struct Edge: CustomTestStringConvertible, Sendable {
        var from: TargetRef
        var to: TargetRef
        var allowed: Bool
        var implementationDependencies: [TargetRef] = []
        var category: DependencyCategory? = nil
        var testDescription: String { "\(from.name) -> \(to.name) is \(allowed ? "allowed" : "forbidden")" }
    }

    static let edges: [Edge] = [
        // Utilities depends on nothing; TestSupport and interfaces only on Utilities.
        Edge(from: utilities, to: coreInterface, allowed: false, category: .interface),
        Edge(from: testSupport, to: utilities, allowed: true),
        Edge(from: testSupport, to: coreInterface, allowed: false, category: .interface),
        Edge(from: coreInterface, to: utilities, allowed: true),
        Edge(from: coreInterface, to: crossInterface, allowed: false, category: .interface),
        Edge(from: coreInterface, to: presentation, allowed: false, category: .interface),
        Edge(from: sceneInterface, to: coreInterface, allowed: false, category: .interface),
        Edge(from: crossInterface, to: utilities, allowed: true),

        // Interface test doubles: their own interface and Utilities.
        Edge(from: coreDoubles, to: coreInterface, allowed: true),
        Edge(from: coreDoubles, to: utilities, allowed: true),
        Edge(from: coreDoubles, to: crossInterface, allowed: false, category: .testDoubles),
        Edge(from: sceneDoubles, to: sceneInterface, allowed: true),
        Edge(from: sceneDoubles, to: coreInterface, allowed: false, category: .testDoubles),

        // Presentation: interfaces and Utilities; never Core, never test doubles, never TestSupport.
        Edge(from: presentation, to: sceneInterface, allowed: true),
        Edge(from: presentation, to: coreInterface, allowed: true),
        Edge(from: presentation, to: crossInterface, allowed: true),
        Edge(from: presentation, to: utilities, allowed: true),
        Edge(from: presentation, to: productsImpl, allowed: false, category: .implementation),
        Edge(from: presentation, to: coreDoubles, allowed: false, category: .implementation),
        Edge(from: presentation, to: testSupport, allowed: false, category: .testSupport),
        Edge(from: routingDoubles, to: presentation, allowed: true),
        Edge(from: routingDoubles, to: sceneInterface, allowed: true),
        Edge(from: routingDoubles, to: coreInterface, allowed: true),
        Edge(from: routingDoubles, to: crossInterface, allowed: false, category: .testDoubles),
        Edge(from: routingDoubles, to: testSupport, allowed: false, category: .testSupport),

        // Tests outside Core: own package, interfaces and their doubles, Utilities, TestSupport.
        Edge(from: presentationTests, to: presentation, allowed: true),
        Edge(from: presentationTests, to: routingDoubles, allowed: true),
        Edge(from: presentationTests, to: sceneInterface, allowed: true),
        Edge(from: presentationTests, to: sceneDoubles, allowed: true),
        Edge(from: presentationTests, to: coreDoubles, allowed: true),
        Edge(from: presentationTests, to: crossDoubles, allowed: true),
        Edge(from: presentationTests, to: testSupport, allowed: true),
        Edge(from: presentationTests, to: utilities, allowed: true),
        Edge(from: presentationTests, to: productsImpl, allowed: false, category: .test),

        // Core feature interfaces.
        Edge(from: products, to: coreInterface, allowed: true),
        Edge(from: products, to: shared, allowed: true),
        Edge(from: products, to: utilities, allowed: true),
        Edge(from: products, to: networking, allowed: false, category: .interface),
        Edge(from: products, to: crossInterface, allowed: false, category: .interface),
        Edge(from: products, to: sharedImplementations, allowed: false, category: .interface),
        Edge(from: products, to: productsImpl, allowed: false, category: .interface),
        Edge(from: shared, to: coreInterface, allowed: true),
        Edge(from: shared, to: utilities, allowed: true),
        Edge(from: shared, to: shared, allowed: false, category: .interface),
        Edge(from: shared, to: networking, allowed: false, category: .interface),

        // Core feature implementations: any interface target plus SharedImplementations.
        Edge(from: productsImpl, to: products, allowed: true),
        Edge(from: productsImpl, to: networking, allowed: true),
        Edge(from: productsImpl, to: shared, allowed: true),
        Edge(from: productsImpl, to: coreInterface, allowed: true),
        Edge(from: productsImpl, to: crossInterface, allowed: true),
        Edge(from: productsImpl, to: utilities, allowed: true),
        Edge(from: productsImpl, to: sharedImplementations, allowed: true),
        Edge(from: productsImpl, to: networkingImpl, allowed: false, category: .implementation),
        Edge(from: productsImpl, to: networkingDoubles, allowed: false, category: .implementation),
        Edge(from: productsImpl, to: coreDoubles, allowed: false, category: .implementation),
        Edge(from: productsImpl, to: sceneInterface, allowed: false, category: .implementation),
        Edge(from: productsImpl, to: presentation, allowed: false, category: .implementation),
        Edge(from: productsImpl, to: testSupport, allowed: false, category: .testSupport),
        Edge(from: sharedImplementations, to: shared, allowed: true),
        Edge(from: sharedImplementations, to: coreInterface, allowed: true),
        Edge(from: sharedImplementations, to: utilities, allowed: true),
        Edge(from: sharedImplementations, to: crossInterface, allowed: false, category: .implementation),
        Edge(from: sharedImplementations, to: productsImpl, allowed: false, category: .implementation),
        Edge(from: sharedImplementations, to: products, allowed: false, category: .implementation),

        // Core feature test doubles: own interface plus what that interface may depend on.
        Edge(from: productsDoubles, to: products, allowed: true),
        Edge(from: productsDoubles, to: coreInterface, allowed: true),
        Edge(from: productsDoubles, to: shared, allowed: true),
        Edge(from: productsDoubles, to: utilities, allowed: true),
        Edge(from: productsDoubles, to: networking, allowed: false, category: .testDoubles),
        Edge(from: productsDoubles, to: productsImpl, allowed: false, category: .testDoubles),
        Edge(from: productsDoubles, to: sharedImplementations, allowed: false, category: .testDoubles),
        Edge(from: productsDoubles, to: testSupport, allowed: false, category: .testSupport),
        Edge(from: networkingDoubles, to: networking, allowed: true),

        // Core feature tests.
        Edge(from: productsTests, to: productsImpl, allowed: true),
        Edge(from: productsTests, to: productsDoubles, allowed: true),
        Edge(from: productsTests, to: products, allowed: true),
        Edge(from: productsTests, to: networking, allowed: true),
        Edge(from: productsTests, to: coreInterface, allowed: true),
        Edge(from: productsTests, to: testSupport, allowed: true),
        Edge(from: productsTests, to: networkingImpl, allowed: false, category: .test),
        Edge(from: productsTests, to: useCasesImpl, allowed: false, category: .test),
        // SharedImplementations, only when the feature's implementations use it.
        Edge(from: productsTests, to: sharedImplementations, allowed: false, category: .test),
        Edge(from: productsTests, to: sharedImplementations, allowed: true, implementationDependencies: [sharedImplementations]),
        Edge(from: productsTests, to: sharedImplementations, allowed: false, implementationDependencies: [networking], category: .test),
        // Another feature's doubles, and the cross-cutting interfaces' doubles, only when the
        // feature's implementations depend on that interface.
        Edge(from: productsTests, to: networkingDoubles, allowed: false, category: .test),
        Edge(from: productsTests, to: networkingDoubles, allowed: true, implementationDependencies: [networking]),
        Edge(from: productsTests, to: coreDoubles, allowed: false, category: .test),
        Edge(from: productsTests, to: coreDoubles, allowed: true, implementationDependencies: [coreInterface]),
        Edge(from: productsTests, to: crossDoubles, allowed: false, category: .test),
        Edge(from: productsTests, to: crossDoubles, allowed: true, implementationDependencies: [crossInterface]),
        Edge(from: productsTests, to: sceneDoubles, allowed: false, category: .test, ),
    ]

    @Test(arguments: edges)
    func edge(_ edge: Edge) {
        let denial = DependencyPolicy.evaluate(
            from: edge.from, to: edge.to, implementationDependencies: edge.implementationDependencies
        )
        if edge.allowed {
            #expect(denial == nil, "\(edge.from.name) -> \(edge.to.name): \(denial?.reason ?? "")")
        } else {
            #expect(denial != nil)
            if let category = edge.category { #expect(denial?.category == category) }
        }
    }

    @Test func testSupportIsForTestTargetsOnly() {
        for from in [Self.productsImpl, Self.productsDoubles, Self.coreDoubles, Self.presentation, Self.coreInterface] {
            let denial = DependencyPolicy.evaluate(from: from, to: Self.testSupport)
            #expect(denial?.category == .testSupport, "\(from.name) must not link TestSupport")
        }
        for from in [Self.productsTests, Self.presentationTests] {
            #expect(DependencyPolicy.evaluate(from: from, to: Self.testSupport) == nil)
        }
    }

    @Test func everyDeniedEdgeExplainsItself() {
        for edge in Self.edges where !edge.allowed {
            let denial = DependencyPolicy.evaluate(from: edge.from, to: edge.to)
            #expect(!(denial?.reason.isEmpty ?? true))
        }
    }

    @Test func packageMatrix() {
        #expect(PackagePolicy.allowedDependencies(of: .utilities).isEmpty)
        for role in [Role.coreInterface, .crossInterface, .presentationInterface] {
            #expect(PackagePolicy.allowedDependencies(of: role) == [.utilities])
        }
        #expect(PackagePolicy.allowedDependencies(of: .core) == [.coreInterface, .crossInterface, .utilities])
        #expect(PackagePolicy.allowedDependencies(of: .presentation)
            == [.presentationInterface, .coreInterface, .crossInterface, .utilities])
        // Nothing may depend on an implementation package.
        for role in Role.allCases {
            #expect(!PackagePolicy.allowedDependencies(of: role).contains(.core))
            #expect(!PackagePolicy.allowedDependencies(of: role).contains(.presentation))
        }
    }
}

@Suite struct CoreNamingTests {
    @Test(arguments: [
        ("Products", "Products", CoreRole.interface),
        ("ProductsImplementations", "Products", .implementations),
        ("ProductsTestDoubles", "Products", .testDoubles),
        ("ProductsTests", "Products", .tests),
        ("Shared", "Shared", .interface),
        ("SharedImplementations", "Shared", .implementations),
        ("SharedTests", "Shared", .tests),
    ])
    func split(name: String, feature: String, role: CoreRole) {
        let result = CoreNaming.split(name)
        #expect(result.feature == feature)
        #expect(result.role == role)
    }

    @Test(arguments: [
        ("ProductsImpl", "ProductsImplementations"),
        ("ProductsImplementation", "ProductsImplementations"),
        ("ProductsMocks", "ProductsTestDoubles"),
        ("ProductsTestDouble", "ProductsTestDoubles"),
        ("ProductsTest", "ProductsTests"),
        ("ProductsSpec", "ProductsTests"),
    ])
    func nearMisses(name: String, corrected: String) {
        #expect(CoreNaming.correctedName(for: name)?.corrected == corrected)
    }

    @Test(arguments: ["Products", "ProductsImplementations", "ProductsTestDoubles", "ProductsTests", "Test", "Impl"])
    func correctNamesAreLeftAlone(name: String) {
        #expect(CoreNaming.correctedName(for: name) == nil)
    }

    @Test func pathsAreNormalized() {
        #expect(CoreNaming.normalizedPath("Products/Products/") == "Products/Products")
        #expect(CoreNaming.normalizedPath("./Products//Products") == "Products/Products")
        #expect(CoreNaming.expectedPath(feature: "Products", targetName: "ProductsTests") == "Products/ProductsTests")
    }
}

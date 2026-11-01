import Foundation
import Testing
@testable import LoupeCore

/// The exact text a developer or agent sees for the main rules. See `Golden.swift`.
@Suite struct GoldenMessageTests {
    struct Case: Sendable {
        var name: String
        var mutate: @Sendable (FixtureApp) throws -> Void
    }

    static let cases: [Case] = [
        Case(name: "implementation-dependency") { app in
            try app.addDependency("\"ProductsImplementations\"", toTarget: "UseCasesImplementations", in: "Core/Package.swift")
        },
        Case(name: "undeclared-import") { app in
            try app.prepend("import Networking", to: "Core/UseCases/UseCasesImplementations/ProductUseCase.swift")
        },
        Case(name: "non-linux-import") { app in
            try app.prepend("import UIKit", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        },
        Case(name: "interface-computed-property") { app in
            try app.replace("    public let title: String\n", with: "    public let title: String\n    public var shout: String { title.uppercased() }\n", in: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        },
        Case(name: "interface-function-and-static-member") { app in
            try app.append("\nextension ProductSceneModel {\n    public func isLong() -> Bool { title.count > 20 }\n    public static let empty = ProductSceneModel(title: \"\")\n}\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        },
        Case(name: "interface-init") { app in
            try app.write("SceneInterface/Sources/SceneInterface/ProductSceneModel.swift", """
            public struct ProductSceneModel: Equatable, Sendable {
                public let title: String
                public let subtitle: String?
                public init(title: String, subtitle: String? = nil) throws {
                    self.title = title.trimmingCharacters(in: .whitespaces)
                }
            }
            """)
        },
        Case(name: "core-target-path") { app in
            try app.replace("path: \"Products/ProductsTests/\"", with: "path: \"Products/ProductTests/\"", in: "Core/Package.swift")
        },
        Case(name: "test-support-in-non-test-target") { app in
            try app.addDependency(".product(name: \"TestSupport\", package: \"Utilities\")", toTarget: "RoutingTestDoubles", in: "Presentation/Package.swift")
        },
        Case(name: "third-party-dependency") { app in
            try app.addPackageDependency(".package(url: \"https://github.com/apple/swift-collections.git\", from: \"1.0.0\")", in: "Presentation/Package.swift")
            try app.addDependency(".product(name: \"Collections\", package: \"swift-collections\")", toTarget: "Presentation", in: "Presentation/Package.swift")
        },
        Case(name: "forbidden-package-dependency") { app in
            try app.addPackageDependency(".package(path: \"../Core\")", in: "Presentation/Package.swift")
            try app.addDependency(".product(name: \"CoreFeatureImplementations\", package: \"Core\")", toTarget: "Presentation", in: "Presentation/Package.swift")
        },
        Case(name: "allows") { app in
            try app.append("\n// loupe:allow interface-static-member\npublic let noReason = 1\n// loupe:allow interface-fucntion -- typo\n// loupe:allow interface-function -- stale\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        },
    ]

    @Test(arguments: cases)
    func messages(_ testCase: Case) async throws {
        let app = try FixtureApp()
        try testCase.mutate(app)
        let report = try await app.run()
        let text = Reporter(format: .text, relativeTo: app.root.path).render(report)
        try assertGolden(text, named: "\(testCase.name).txt")
    }
}

extension GoldenMessageTests.Case: CustomTestStringConvertible {
    var testDescription: String { name }
}

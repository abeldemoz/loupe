import Foundation
import Testing
@testable import LoupeCore

/// Each test starts from an app with no violations, injects one, and expects exactly one
/// well-located finding for it.
@Suite struct EndToEndTests {
    typealias Finding = FixtureApp.Finding

    func expectClean(_ app: FixtureApp, _ comment: Comment? = nil) async throws {
        let report = try await app.run()
        #expect(app.errors(report) == [], comment)
    }

    @Test func theBaselineAppIsClean() async throws {
        let app = try FixtureApp()
        let report = try await app.run()
        #expect(app.errors(report) == [])
        #expect(report.stats.packages == 6)
        #expect(report.stats.files == 19)
        #expect(report.allowed == 0)
    }

    // MARK: Injected violations

    @Test func uikitInPresentation() async throws {
        let app = try FixtureApp()
        try app.prepend("import UIKit", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        let found = app.errors(try await app.run())
        #expect(found == [Finding(rule: "non-linux-import", file: "Presentation/Sources/Presentation/ProductPresenter.swift", line: 1, column: 8)], "got \(found)")
    }

    @Test func guardedUIKitIsFine() async throws {
        let app = try FixtureApp()
        try app.prepend("#if canImport(UIKit)\nimport UIKit\n#endif", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        try await expectClean(app)
    }

    @Test func implementationDependingOnAnotherImplementation() async throws {
        let app = try FixtureApp()
        try app.addDependency("\"ProductsImplementations\"", toTarget: "UseCasesImplementations", in: "Core/Package.swift")
        let position = try app.locate("\"ProductsImplementations\",", in: "Core/Package.swift", after: "name: \"UseCasesImplementations\"")
        let report = try await app.run()
        #expect(app.errors(report) == [Finding(rule: "implementation-dependency", file: "Core/Package.swift", line: position.line, column: position.column)], "got \(app.errors(report))")

        // The message names the real targets and says exactly what to depend on instead.
        let violation = try #require(report.errors.first)
        #expect(violation.summary == "'UseCasesImplementations' depends on 'ProductsImplementations'")
        #expect(violation.fix?.contains("replace \"ProductsImplementations\" with 'Products'") == true)
        #expect(violation.why?.contains("never on each other's implementations") == true)
    }

    @Test func computedPropertyOnASceneModel() async throws {
        let app = try FixtureApp()
        try app.replace(
            "    public let title: String\n",
            with: "    public let title: String\n    public var shout: String { title.uppercased() }\n",
            in: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift"
        )
        let position = try app.locate("shout", in: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        let found = app.errors(try await app.run())
        #expect(found == [Finding(rule: "interface-computed-property", file: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift", line: position.line, column: position.column)], "got \(found)")
    }

    @Test func testSupportInANonTestTarget() async throws {
        let app = try FixtureApp()
        try app.addDependency(".product(name: \"TestSupport\", package: \"Utilities\")", toTarget: "RoutingTestDoubles", in: "Presentation/Package.swift")
        let position = try app.locate(".product(name: \"TestSupport\"", in: "Presentation/Package.swift", after: "name: \"RoutingTestDoubles\"")
        let found = app.errors(try await app.run())
        #expect(found == [Finding(rule: "test-support-in-non-test-target", file: "Presentation/Package.swift", line: position.line, column: position.column)], "got \(found)")
    }

    @Test func aCoreTargetPathTypo() async throws {
        let app = try FixtureApp()
        try app.replace("path: \"Products/ProductsTests/\"", with: "path: \"Products/ProductTests/\"", in: "Core/Package.swift")
        let position = try app.locate("\"Products/ProductTests/\"", in: "Core/Package.swift")
        let report = try await app.run()
        #expect(app.errors(report) == [Finding(rule: "core-target-path", file: "Core/Package.swift", line: position.line, column: position.column)])
        #expect(report.errors.first?.summary == "Core target 'ProductsTests' is at 'Products/ProductTests', but its feature and role put it at 'Products/ProductsTests'")
    }

    @Test func aMisnamedCoreTarget() async throws {
        let app = try FixtureApp()
        try app.replace("name: \"UseCasesTests\"", with: "name: \"UseCasesTest\"", in: "Core/Package.swift")
        let position = try app.locate("\"UseCasesTest\"", in: "Core/Package.swift")
        let found = app.errors(try await app.run())
        #expect(found == [Finding(rule: "core-target-name", file: "Core/Package.swift", line: position.line, column: position.column)], "got \(found)")
    }

    @Test func anUndeclaredImport() async throws {
        let app = try FixtureApp()
        try app.prepend("import Networking", to: "Core/UseCases/UseCasesImplementations/ProductUseCase.swift")
        let report = try await app.run()
        #expect(app.errors(report) == [Finding(rule: "undeclared-import", file: "Core/UseCases/UseCasesImplementations/ProductUseCase.swift", line: 1, column: 8)])
        let manifestLine = try app.locate("name: \"UseCasesImplementations\"", in: "Core/Package.swift").line
        #expect(report.errors.first?.fix?.contains("Add \"Networking\" to the dependencies of 'UseCasesImplementations' in Core/Package.swift:\(manifestLine)") == true)
    }

    @Test func anUndeclaredImportFromAnotherPackageNamesTheProduct() async throws {
        let app = try FixtureApp()
        try app.prepend("import CrossInterface", to: "Core/UseCases/UseCasesImplementations/ProductUseCase.swift")
        let fix = try #require(try await app.run().errors.first?.fix)
        #expect(fix.contains(".product(name: \"CrossInterface\", package: \"CrossInterface\")"))
    }

    @Test func aPublicDTO() async throws {
        let app = try FixtureApp()
        try app.append("\npublic struct ProductDTO: Decodable {\n    let id: Int\n}\n", to: "Core/Products/ProductsImplementations/DefaultProductService.swift")
        let position = try app.locate("ProductDTO", in: "Core/Products/ProductsImplementations/DefaultProductService.swift")
        let found = app.errors(try await app.run())
        #expect(found == [Finding(rule: "public-dto", file: "Core/Products/ProductsImplementations/DefaultProductService.swift", line: position.line, column: position.column)], "got \(found)")
    }

    @Test func aThirdPartyPackage() async throws {
        let app = try FixtureApp()
        try app.addPackageDependency(".package(url: \"https://github.com/apple/swift-collections.git\", from: \"1.0.0\")", in: "Presentation/Package.swift")
        try app.addDependency(".product(name: \"Collections\", package: \"swift-collections\")", toTarget: "Presentation", in: "Presentation/Package.swift")
        let position = try app.locate(".package(url:", in: "Presentation/Package.swift")
        let report = try await app.run()
        #expect(app.errors(report) == [Finding(rule: "third-party-dependency", file: "Presentation/Package.swift", line: position.line, column: position.column)])
        #expect(report.errors.first?.fix?.contains("from: Presentation") == true)
    }

    @Test func presentationDependingOnTheCorePackage() async throws {
        let app = try FixtureApp()
        try app.addPackageDependency(".package(path: \"../Core\")", in: "Presentation/Package.swift")
        try app.addDependency(".product(name: \"CoreFeatureImplementations\", package: \"Core\")", toTarget: "Presentation", in: "Presentation/Package.swift")
        let position = try app.locate(".package(path: \"../Core\")", in: "Presentation/Package.swift")
        let report = try await app.run()
        // One message at the `.package` line, not one per product edge.
        #expect(app.errors(report) == [Finding(rule: "forbidden-package-dependency", file: "Presentation/Package.swift", line: position.line, column: position.column)])
        #expect(report.errors.first?.summary == "'Presentation' (presentation package) depends on 'Core' (core package)")
    }

    @Test func aTestDependingOnAnotherFeaturesImplementation() async throws {
        let app = try FixtureApp()
        try app.addDependency("\"ProductsImplementations\"", toTarget: "UseCasesTests", in: "Core/Package.swift")
        let found = app.errors(try await app.run())
        #expect(found.map(\.rule) == ["test-target-dependency"])
    }

    @Test func sharedUsedByOneFeature() async throws {
        let app = try FixtureApp()
        try app.addTargets("""
                .target(
                    name: "Shared",
                    dependencies: [
                        .product(name: "CoreInterface", package: "CoreInterface"),
                    ],
                    path: "Shared/Shared/"
                ),
        """, in: "Core/Package.swift")
        try app.addDependency("\"Shared\"", toTarget: "Products", in: "Core/Package.swift")
        try app.write("Core/Shared/Shared/Money.swift", "public struct Money: Sendable {\n    public let cents: Int\n    public init(cents: Int) { self.cents = cents }\n}\n")
        let position = try app.locate("\"Shared\"", in: "Core/Package.swift", after: "targets: [")
        let report = try await app.run()
        #expect(app.errors(report) == [Finding(rule: "shared-single-consumer", file: "Core/Package.swift", line: position.line, column: position.column)])
        #expect(report.errors.first?.summary == "'Shared' is used by only 'Products'; it needs at least 2 feature interface targets")
    }

    @Test func anUnknownTargetInAMappedPackage() async throws {
        let app = try FixtureApp()
        try app.addTargets("        .target(name: \"CoreHelpers\"),", in: "CoreInterface/Package.swift")
        let found = app.errors(try await app.run())
        #expect(found.map(\.rule) == ["unmapped-target"])
    }

    // MARK: Allows

    @Test func anAllowWithAReasonExcusesTheViolation() async throws {
        let app = try FixtureApp()
        try app.append("\n// loupe:allow interface-static-member -- shared preset, tracked in PRISM-1\npublic let defaultTitle = \"\"\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        let report = try await app.run()
        #expect(app.errors(report) == [])
        #expect(report.allowed == 1)
    }

    @Test func anAllowWithoutAReason() async throws {
        let app = try FixtureApp()
        try app.append("\n// loupe:allow interface-static-member\npublic let defaultTitle = \"\"\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        let found = app.errors(try await app.run())
        #expect(Set(found.map(\.rule)) == ["allow-missing-reason", "interface-static-member"])
    }

    @Test func aStaleAllow() async throws {
        let app = try FixtureApp()
        try app.append("\n// loupe:allow interface-function -- no longer needed\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        let found = app.errors(try await app.run())
        #expect(found.map(\.rule) == ["allow-unused"])
    }

    @Test func newAllowsAreSurfacedForReview() async throws {
        let app = try FixtureApp()
        try app.git("init", "-q", "-b", "main")
        try app.git("add", "-A")
        try app.git("commit", "-q", "-m", "baseline")
        try app.append("\n// loupe:allow interface-static-member -- shared preset, tracked in PRISM-1\npublic let defaultTitle = \"\"\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")

        let report = try await app.run(base: "HEAD")
        #expect(report.errors.isEmpty)
        #expect(report.notes.count == 1)
        #expect(report.notes.first?.summary == "This branch adds `loupe:allow interface-static-member`: shared preset, tracked in PRISM-1")
        #expect(report.hasErrors == false)

        // Without --base the same allow is quiet.
        #expect(try await app.run().notes.isEmpty)
    }

    @Test func allowsThatWereAlreadyThereAreNotNew() async throws {
        let app = try FixtureApp()
        try app.append("\n// loupe:allow interface-static-member -- shared preset\npublic let defaultTitle = \"\"\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        try app.git("init", "-q", "-b", "main")
        try app.git("add", "-A")
        try app.git("commit", "-q", "-m", "baseline with an allow")
        #expect(try await app.run(base: "HEAD").notes.isEmpty)
    }

    // MARK: Output

    @Test func reportsAreIdenticalAcrossRuns() async throws {
        let app = try FixtureApp()
        try app.prepend("import UIKit", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        try app.prepend("import Networking", to: "Core/UseCases/UseCasesImplementations/ProductUseCase.swift")
        try app.append("\npublic let x = 1\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        let reporter = Reporter(format: .text, relativeTo: app.root.path)
        let first = reporter.render(try await app.run())
        let second = reporter.render(try await app.run())
        #expect(first == second)
        let errors = first.components(separatedBy: "error: [")
        #expect(errors.count == 4, "three violations, in one report")
    }

    @Test func everyReportedRuleIsInTheCatalog() async throws {
        let app = try FixtureApp()
        try app.prepend("import UIKit", to: "Presentation/Sources/Presentation/ProductPresenter.swift")
        try app.append("\npublic final class Store {}\n", to: "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift")
        for violation in try await app.run().findings {
            #expect(RuleCatalog.info(for: violation.ruleID) != nil)
        }
    }

    // MARK: Runs that cannot happen

    @Test func aMissingConfigIsARunError() async throws {
        let app = try FixtureApp()
        try FileManager.default.removeItem(at: app.url("loupe.json"))
        await #expect(throws: LoupeError.self) { try await app.run() }
    }

    @Test func aMissingPackageDirectoryIsARunError() async throws {
        let app = try FixtureApp()
        try FileManager.default.removeItem(at: app.url("Presentation"))
        do {
            _ = try await app.run()
            Issue.record("expected a run error")
        } catch let error as LoupeError {
            #expect(error.message.contains("packages.presentation.path is \"Presentation\", but there is no such directory"))
        }
    }

    @Test func aManifestThatWontDumpIsARunErrorWithTheCommandToReproduceIt() async throws {
        let app = try FixtureApp()
        try app.write("Utilities/Package.swift", "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \n")
        do {
            _ = try await app.run()
            Issue.record("expected a run error")
        } catch let error as LoupeError {
            #expect(error.message.contains("Reproduce with: swift package dump-package --package-path"))
            #expect(error.message.contains("packages.utilities"))
        }
    }

    @Test func aConfiguredTargetThatDoesNotExistIsARunError() async throws {
        let app = try FixtureApp()
        try app.replace("\"testDoubles\": \"SceneTestDoubles\"", with: "\"testDoubles\": \"SceneDoubles\"", in: "loupe.json")
        do {
            _ = try await app.run()
            Issue.record("expected a run error")
        } catch let error as LoupeError {
            #expect(error.message.contains("packages.presentationInterface.testDoubles is \"SceneDoubles\""))
        }
    }

    @Test func aBaseRefThatDoesNotExistExplainsHowToFetchIt() async throws {
        let app = try FixtureApp()
        try app.git("init", "-q", "-b", "main")
        try app.git("add", "-A")
        try app.git("commit", "-q", "-m", "baseline")
        do {
            _ = try await app.run(base: "origin/develop")
            Issue.record("expected a run error")
        } catch let error as LoupeError {
            #expect(error.message.contains("--base origin/develop"))
            #expect(error.message.contains("fetch-depth: 0"))
        }
    }
}

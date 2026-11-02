import Foundation
import Testing
import LoupeArchitecture
@testable import LoupeCore

@Suite struct ConfigTests {
    func decode(_ json: String) throws -> LoupeConfig {
        try ConfigLoader.decode(Data(json.utf8), fileURL: URL(fileURLWithPath: "/app/.loupe.json"))
    }

    func problems(_ json: String) -> [String] {
        do {
            _ = try decode(json)
            return []
        } catch let error as LoupeError {
            return error.message.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        } catch {
            return ["\(error)"]
        }
    }

    @Test func decodesAFullConfig() throws {
        let config = try decode("""
        {
          "$schema": "https://example.com/loupe.schema.json",
          "version": 1,
          "packages": {
            "utilities": { "path": "Utilities", "testSupport": "TestSupport" },
            "presentationInterface": { "path": "SceneInterface", "testDoubles": "SceneTestDoubles" },
            "presentation": { "path": "Presentation", "routingTestDoubles": "RoutingTestDoubles" },
            "core": { "path": "Core" }
          },
          "exclude": [{ "glob": "Core/**/OpenAPITypes.swift", "reason": "generated from openapi.yaml" }]
        }
        """)
        #expect(config.packages[.utilities]?.testSupport == "TestSupport")
        #expect(config.packages[.presentationInterface]?.testDoubles == "SceneTestDoubles")
        #expect(config.packages[.presentation]?.routingTestDoubles == "RoutingTestDoubles")
        #expect(config.packages[.core]?.path == "Core")
        #expect(config.exclude == [.init(glob: "Core/**/OpenAPITypes.swift", reason: "generated from openapi.yaml")])
    }

    @Test func typosAreErrorsWithSuggestions() {
        let found = problems("""
        { "version": 1, "packages": { "core": { "path": "Core" }, "utilities": { "path": "U", "testSuport": "TS" } } }
        """)
        #expect(found == ["- packages.utilities.testSuport: unknown key. Did you mean 'testSupport'? It takes: path, target, testSupport."])
    }

    @Test func unknownRolesListTheValidOnes() {
        let found = problems(#"{ "version": 1, "packages": { "corre": { "path": "C" } } }"#)
        #expect(found.count == 1)
        #expect(found[0].hasPrefix("- packages.corre: unknown role. Did you mean 'core'?"))
    }

    @Test func keysForAnotherRoleAreExplained() {
        let found = problems(#"{ "version": 1, "packages": { "core": { "path": "C", "testDoubles": "X" } } }"#)
        #expect(found == ["- packages.core.testDoubles: not used by the core role. It takes: path."])
    }

    @Test func excludesNeedAReason() {
        let found = problems("""
        { "version": 1, "packages": { "core": { "path": "C" } }, "exclude": [{ "glob": "A/**" }] }
        """)
        #expect(found.count == 1)
        #expect(found[0].hasPrefix("- exclude[0].reason: required."))
    }

    @Test func everyProblemIsReportedAtOnce() {
        let found = problems("""
        { "versoin": 1, "packages": { "core": {} }, "exclude": [{ "reason": "x" }] }
        """)
        #expect(found.count == 4)
    }

    @Test func versionIsRequiredAndChecked() {
        #expect(problems(#"{ "packages": { "core": { "path": "C" } } }"#).first?.hasPrefix("- version: required.") == true)
        #expect(problems(#"{ "version": 2, "packages": { "core": { "path": "C" } } }"#).first?.hasPrefix("- version: 2 isn't supported") == true)
    }

    @Test func notJSONIsReported() {
        #expect(throws: LoupeError.self) { try decode("{ nope") }
    }

    @Test func missingFileExplainsWhereLoupeLooked() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try ConfigLoader.load(directory: directory)
            Issue.record("expected an error")
        } catch let error as LoupeError {
            #expect(error.message.contains("No .loupe.json found in \(directory.path)"))
            #expect(error.message.contains("\"coreInterface\""))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func theVisibleFileNameOfV010SaysHowToMigrate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("loupe.json"))
        do {
            _ = try ConfigLoader.load(directory: directory)
            Issue.record("expected an error")
        } catch let error as LoupeError {
            #expect(error.message.contains("No .loupe.json found in \(directory.path), but there is a loupe.json"))
            #expect(error.message.contains("git mv loupe.json .loupe.json"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite struct RuleCatalogTests {
    @Test func idsAreUniqueAndKebabCase() {
        let ids = RuleCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.allSatisfy { $0.isLowercase || $0 == "-" }, "\(id)")
        }
    }

    @Test func everyRuleExplainsItself() {
        for info in RuleCatalog.all {
            #expect(!info.title.isEmpty && !info.rule.isEmpty && !info.why.isEmpty && !info.howToFix.isEmpty, "\(info.id)")
        }
    }

    @Test func theV1CatalogIsComplete() {
        let expected: Set = [
            "third-party-dependency", "forbidden-package-dependency", "interface-dependency", "implementation-dependency",
            "test-doubles-dependency", "test-target-dependency", "test-support-in-non-test-target", "shared-single-consumer",
            "core-target-name", "core-target-path", "undeclared-import", "non-linux-import",
            "interface-reference-type", "interface-function", "interface-computed-property", "interface-static-member",
            "interface-property-default", "interface-init-count", "interface-init-not-trivial",
            "interface-init-default-argument", "interface-protocol-extension", "public-dto",
            "allow-unknown-rule", "allow-missing-reason", "allow-unused",
        ]
        #expect(expected.isSubset(of: Set(RuleCatalog.all.map(\.id))))
    }

    @Test func onlyAllowRulesAreNotAllowable() {
        for info in RuleCatalog.all {
            #expect(info.allowable == !info.id.hasPrefix("allow-"), "\(info.id)")
        }
    }

    @Test func suggestionsFindNearMisses() {
        #expect(RuleCatalog.suggestions(for: "interface-fucntion").contains("interface-function"))
        #expect(RuleCatalog.suggestions(for: "zzzzzzzz").isEmpty)
    }
}

@Suite struct ImportStatementTests {
    func imports(_ source: String) -> [(String, Set<String>)] {
        ImportStatement.collect(in: SourceFile(path: "/a.swift", source: source)).map { ($0.module, $0.guardedModules) }
    }

    @Test func plainImportsAreUnguarded() {
        let found = imports("import Foundation\n@testable import Core\nimport struct Swift.Int\nimport Foundation.NSURL")
        #expect(found.map(\.0) == ["Foundation", "Core", "Swift", "Foundation"])
        #expect(found.allSatisfy { $0.1.isEmpty })
    }

    @Test func canImportGuardsTheNamedModule() {
        let found = imports("""
        #if canImport(UIKit)
        import UIKit
        #elseif canImport(AppKit)
        import AppKit
        #endif
        """)
        #expect(found[0] == ("UIKit", ["UIKit"]))
        #expect(found[1] == ("AppKit", ["AppKit"]))
    }

    @Test func conjunctionsGuardEveryOperand() {
        let found = imports("#if canImport(UIKit) && canImport(Combine)\nimport UIKit\nimport Combine\n#endif")
        #expect(found.allSatisfy { $0.1 == ["UIKit", "Combine"] })
    }

    @Test func disjunctionsAndNegationsGuardNothing() {
        #expect(imports("#if canImport(UIKit) || canImport(AppKit)\nimport UIKit\n#endif")[0].1.isEmpty)
        #expect(imports("#if !canImport(UIKit)\nimport UIKit\n#endif")[0].1.isEmpty)
        #expect(imports("#if os(iOS)\nimport UIKit\n#endif")[0].1.isEmpty)
    }

    @Test func aGuardOnlyCoversItsOwnModule() {
        let found = imports("#if canImport(UIKit)\nimport SwiftUI\n#endif")
        #expect(found[0] == ("SwiftUI", ["UIKit"]))
    }
}

/// `loupe.schema.json` is published for editors; it must describe exactly what the decoder accepts.
@Suite struct SchemaTests {
    func schema() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("loupe.schema.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func keys(_ object: [String: Any]?) -> Set<String> { Set((object?["properties"] as? [String: Any])?.keys.map { $0 } ?? []) }

    @Test func topLevelKeysMatchTheDecoder() throws {
        #expect(keys(try schema()) == Set(ConfigLoader.topLevelKeys))
    }

    @Test func rolesMatchTheArchitecture() throws {
        let packages = (try schema()["properties"] as? [String: Any])?["packages"] as? [String: Any]
        #expect(keys(packages) == Set(Role.allCases.map(\.rawValue)))
    }

    @Test func packageKeysMatchTheDecoderPerRole() throws {
        let root = try schema()
        let definitions = try #require(root["$defs"] as? [String: Any])
        let packages = try #require((root["properties"] as? [String: Any])?["packages"] as? [String: Any])
        let roles = try #require(packages["properties"] as? [String: Any])
        for role in Role.allCases {
            let reference = try #require((roles[role.rawValue] as? [String: Any])?["$ref"] as? String)
            let definition = try #require(definitions[String(reference.dropFirst("#/$defs/".count))] as? [String: Any])
            let expected = Set(["path"] + (role == .core ? [] : ["target"]) + ConfigLoader.extraKeys(for: role))
            #expect(keys(definition) == expected, "\(role.rawValue)")
        }
    }

    @Test func excludeKeysMatchTheDecoder() throws {
        let exclude = (try schema()["properties"] as? [String: Any])?["exclude"] as? [String: Any]
        #expect(keys(exclude?["items"] as? [String: Any]) == Set(ConfigLoader.excludeKeys))
    }
}

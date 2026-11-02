import Foundation
@testable import LoupeCore

/// A small app in the architecture's shape, written to a temp directory so tests can inject one
/// violation at a time and run the real checker over real `swift package dump-package` output.
final class FixtureApp {
    let root: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory.canonical
        for (path, content) in Self.baseline { try write(path, content) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func write(_ path: String, _ content: String) throws {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }

    /// Replaces the one occurrence of `old` in a file, failing loudly if it isn't there exactly once.
    func replace(_ old: String, with new: String, in path: String) throws {
        let text = try read(path)
        let parts = text.components(separatedBy: old)
        guard parts.count == 2 else { throw FixtureError("expected exactly one occurrence of \(old.debugDescription) in \(path), found \(parts.count - 1)") }
        try write(path, parts.joined(separator: new))
    }

    func prepend(_ line: String, to path: String) throws { try write(path, line + "\n" + read(path)) }

    func append(_ text: String, to path: String) throws { try write(path, read(path) + text) }


    // MARK: Structural edits to a Package.swift, independent of how it is formatted

    /// Adds `dependency` to the `dependencies:` of the target named `target`.
    func addDependency(_ dependency: String, toTarget target: String, in path: String) throws {
        var lines = try read(path).components(separatedBy: "\n")
        let targetsStart = lines.firstIndex(where: { $0.hasPrefix("    targets: [") }) ?? 0
        guard let nameIndex = lines[targetsStart...].firstIndex(where: { $0.contains("name: \"\(target)\"") }) else {
            throw FixtureError("no target \(target) in \(path)")
        }
        guard let index = lines[nameIndex...].firstIndex(where: { $0.contains("dependencies: [") }) else {
            throw FixtureError("target \(target) has no dependencies: in \(path)")
        }
        if lines[index].trimmingCharacters(in: .whitespaces).hasSuffix("[") {
            let indent = String(lines[index].prefix { $0 == " " }) + "    "
            lines.insert("\(indent)\(dependency),", at: index + 1)
        } else if let close = lines[index].lastIndex(of: "]") {
            lines[index].insert(contentsOf: ", \(dependency)", at: close)
        }
        try write(path, lines.joined(separator: "\n"))
    }

    /// Adds a `.package(...)` entry to the manifest's top-level `dependencies:`.
    func addPackageDependency(_ entry: String, in path: String) throws {
        var lines = try read(path).components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("    dependencies: [") }) else {
            throw FixtureError("no top-level dependencies: in \(path)")
        }
        lines.insert("        \(entry),", at: index + 1)
        try write(path, lines.joined(separator: "\n"))
    }

    /// Adds target declarations at the start of `targets: [`.
    func addTargets(_ declarations: String, in path: String) throws {
        var lines = try read(path).components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("    targets: [") }) else {
            throw FixtureError("no targets: in \(path)")
        }
        lines.insert(declarations, at: index + 1)
        try write(path, lines.joined(separator: "\n"))
    }

    /// The 1-based line and column of the first `needle` at or after the first line containing `marker`.
    func locate(_ needle: String, in path: String, after marker: String? = nil) throws -> (line: Int, column: Int) {
        let lines = try read(path).components(separatedBy: "\n")
        var start = 0
        if let marker {
            guard let index = lines.firstIndex(where: { $0.contains(marker) }) else {
                throw LocateError(needle: marker, path: path)
            }
            start = index
        }
        for index in start..<lines.count {
            if let range = lines[index].range(of: needle) {
                return (index + 1, lines[index].distance(from: lines[index].startIndex, to: range.lowerBound) + 1)
            }
        }
        throw LocateError(needle: needle, path: path)
    }

    struct LocateError: Error { var needle: String; var path: String }
    struct FixtureError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    func run(base: String? = nil) async throws -> CheckReport {
        try await Checker.run(CheckOptions(directory: root, base: base))
    }

    /// `(rule, path relative to the app, line, column)` for each error, in report order.
    func errors(_ report: CheckReport) -> [Finding] {
        report.errors.map {
            Finding(rule: $0.ruleID, file: String($0.location.path.dropFirst(root.path.count + 1)), line: $0.location.line, column: $0.location.column)
        }
    }

    struct Finding: Equatable, CustomStringConvertible {
        var rule: String
        var file: String
        var line: Int
        var column: Int
        var description: String { "[\(rule)] \(file):\(line):\(column)" }
    }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Loupe Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError("git \(arguments.joined(separator: " ")) failed") }
    }

    // MARK: The baseline app: no violations

    static let baseline: [String: String] = [
        ".loupe.json": #"""
        {
          "version": 1,
          "packages": {
            "utilities": { "path": "Utilities", "testSupport": "TestSupport" },
            "coreInterface": { "path": "CoreInterface", "testDoubles": "CoreTestDoubles" },
            "crossInterface": { "path": "CrossInterface", "testDoubles": "CrossTestDoubles" },
            "presentationInterface": { "path": "SceneInterface", "testDoubles": "SceneTestDoubles" },
            "core": { "path": "Core" },
            "presentation": { "path": "Presentation", "routingTestDoubles": "RoutingTestDoubles" }
          }
        }
        """#,

        // MARK: Utilities
        "Utilities/Package.swift": #"""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Utilities",
            products: [
                .library(name: "Utilities", targets: ["Utilities"]),
                .library(name: "TestSupport", targets: ["TestSupport"]),
            ],
            targets: [
                .target(name: "Utilities"),
                .target(name: "TestSupport"),
            ]
        )
        """#,
        "Utilities/Sources/Utilities/Utilities.swift": "public enum Utilities {\n    public static func clamp(_ value: Int) -> Int { max(0, value) }\n}\n",
        "Utilities/Sources/TestSupport/TestSupport.swift": "public enum TestSupport {}\n",

        // MARK: Interface packages
        "CoreInterface/Package.swift": interfacePackage("CoreInterface", doubles: "CoreTestDoubles"),
        "CoreInterface/Sources/CoreInterface/Item.swift": #"""
        public struct Item: Equatable, Sendable {
            public let id: Int
            public init(id: Int) {
                self.id = id
            }
        }
        """#,
        "CoreInterface/Sources/CoreTestDoubles/ItemStub.swift": "import CoreInterface\n\npublic struct ItemStub: Sendable {\n    public let item: Item\n    public init(item: Item) { self.item = item }\n}\n",

        "CrossInterface/Package.swift": interfacePackage("CrossInterface", doubles: "CrossTestDoubles"),
        "CrossInterface/Sources/CrossInterface/Logging.swift": "public protocol Logging: Sendable {\n    func log(_ message: String)\n}\n",
        "CrossInterface/Sources/CrossTestDoubles/LoggingSpy.swift": "import CrossInterface\n\npublic final class LoggingSpy: Logging, @unchecked Sendable {\n    public init() {}\n    public func log(_ message: String) {}\n}\n",

        "SceneInterface/Package.swift": interfacePackage("SceneInterface", doubles: "SceneTestDoubles"),
        "SceneInterface/Sources/SceneInterface/ProductSceneModel.swift": #"""
        public struct ProductSceneModel: Equatable, Sendable {
            public let title: String
            public init(title: String) {
                self.title = title
            }
        }
        """#,
        "SceneInterface/Sources/SceneTestDoubles/SceneStub.swift": "import SceneInterface\n\npublic struct SceneStub: Sendable {\n    public init() {}\n}\n",

        // MARK: Core
        "Core/Package.swift": #"""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Core",
            products: [
                .library(name: "CoreFeatureInterfaces", targets: ["Networking", "Products"]),
                .library(name: "CoreFeatureImplementations", targets: ["ProductsImplementations", "UseCasesImplementations"]),
            ],
            dependencies: [
                .package(path: "../CoreInterface"),
                .package(path: "../CrossInterface"),
            ],
            targets: [
                // MARK: Networking
                .target(
                    name: "Networking",
                    path: "Networking/Networking/"
                ),
                .target(
                    name: "NetworkingTestDoubles",
                    dependencies: ["Networking"],
                    path: "Networking/NetworkingTestDoubles/"
                ),

                // MARK: Products
                .target(
                    name: "Products",
                    dependencies: [
                        .product(name: "CoreInterface", package: "CoreInterface"),
                    ],
                    path: "Products/Products/"
                ),
                .target(
                    name: "ProductsImplementations",
                    dependencies: [
                        "Products",
                        "Networking",
                        .product(name: "CoreInterface", package: "CoreInterface"),
                        .product(name: "CrossInterface", package: "CrossInterface"),
                    ],
                    path: "Products/ProductsImplementations/"
                ),
                .target(
                    name: "ProductsTestDoubles",
                    dependencies: [
                        "Products",
                        .product(name: "CoreInterface", package: "CoreInterface"),
                    ],
                    path: "Products/ProductsTestDoubles/"
                ),
                .testTarget(
                    name: "ProductsTests",
                    dependencies: [
                        "ProductsImplementations",
                        "Products",
                        "Networking",
                        "NetworkingTestDoubles",
                        .product(name: "CoreInterface", package: "CoreInterface"),
                        .product(name: "CoreTestDoubles", package: "CoreInterface"),
                    ],
                    path: "Products/ProductsTests/"
                ),

                // MARK: UseCases
                .target(
                    name: "UseCasesImplementations",
                    dependencies: [
                        "Products",
                        .product(name: "CoreInterface", package: "CoreInterface"),
                    ],
                    path: "UseCases/UseCasesImplementations/"
                ),
                .testTarget(
                    name: "UseCasesTests",
                    dependencies: [
                        "UseCasesImplementations",
                        "ProductsTestDoubles",
                        .product(name: "CoreInterface", package: "CoreInterface"),
                    ],
                    path: "UseCases/UseCasesTests/"
                ),
            ]
        )
        """#,
        "Core/Networking/Networking/HTTPClient.swift": "import Foundation\n\npublic protocol HTTPClient: Sendable {\n    func get(path: String) async throws -> Data\n}\n",
        "Core/Networking/NetworkingTestDoubles/HTTPClientSpy.swift": "import Foundation\nimport Networking\n\npublic final class HTTPClientSpy: HTTPClient, @unchecked Sendable {\n    public init() {}\n    public func get(path: String) async throws -> Data { Data() }\n}\n",
        "Core/Products/Products/ProductService.swift": "import CoreInterface\n\npublic protocol ProductService: Sendable {\n    func product(id: Int) async throws -> Item\n}\n",
        "Core/Products/ProductsImplementations/DefaultProductService.swift": #"""
        import CoreInterface
        import CrossInterface
        import Networking
        import Products

        public struct DefaultProductService: ProductService {
            private let client: any HTTPClient
            private let logger: any Logging

            public init(client: any HTTPClient, logger: any Logging) {
                self.client = client
                self.logger = logger
            }

            public func product(id: Int) async throws -> Item {
                logger.log("loading \(id)")
                _ = try await client.get(path: "/products/\(id)")
                return Item(id: id)
            }
        }
        """#,
        "Core/Products/ProductsTestDoubles/ProductServiceStub.swift": "import CoreInterface\nimport Products\n\npublic struct ProductServiceStub: ProductService {\n    public init() {}\n    public func product(id: Int) async throws -> Item { Item(id: id) }\n}\n",
        "Core/Products/ProductsTests/DefaultProductServiceTests.swift": "import CoreInterface\nimport Networking\nimport NetworkingTestDoubles\nimport Products\nimport ProductsImplementations\nimport Testing\n\n@Suite struct DefaultProductServiceTests {\n    @Test func loads() {}\n}\n",
        "Core/UseCases/UseCasesImplementations/ProductUseCase.swift": "import CoreInterface\nimport Products\n\npublic struct ProductUseCase {\n    let service: any ProductService\n    public init(service: any ProductService) { self.service = service }\n}\n",
        "Core/UseCases/UseCasesTests/ProductUseCaseTests.swift": "import ProductsTestDoubles\nimport Testing\nimport UseCasesImplementations\n\n@Suite struct ProductUseCaseTests {\n    @Test func works() {}\n}\n",

        // MARK: Presentation
        "Presentation/Package.swift": #"""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Presentation",
            products: [
                .library(name: "Presentation", targets: ["Presentation"]),
                .library(name: "RoutingTestDoubles", targets: ["RoutingTestDoubles"]),
            ],
            dependencies: [
                .package(path: "../SceneInterface"),
                .package(path: "../CoreInterface"),
                .package(path: "../Utilities"),
            ],
            targets: [
                .target(
                    name: "Presentation",
                    dependencies: [
                        .product(name: "SceneInterface", package: "SceneInterface"),
                        .product(name: "CoreInterface", package: "CoreInterface"),
                    ]
                ),
                .target(
                    name: "RoutingTestDoubles",
                    dependencies: ["Presentation"]
                ),
                .testTarget(
                    name: "PresentationTests",
                    dependencies: [
                        "Presentation",
                        "RoutingTestDoubles",
                        .product(name: "SceneInterface", package: "SceneInterface"),
                        .product(name: "CoreInterface", package: "CoreInterface"),
                        .product(name: "SceneTestDoubles", package: "SceneInterface"),
                        .product(name: "CoreTestDoubles", package: "CoreInterface"),
                        .product(name: "TestSupport", package: "Utilities"),
                    ]
                ),
            ]
        )
        """#,
        "Presentation/Sources/Presentation/ProductPresenter.swift": "import CoreInterface\nimport SceneInterface\n\npublic struct ProductPresenter {\n    public init() {}\n    public func scene(for item: Item) -> ProductSceneModel { ProductSceneModel(title: \"\\(item.id)\") }\n}\n",
        "Presentation/Sources/RoutingTestDoubles/RoutingSpy.swift": "import Presentation\n\npublic struct RoutingSpy {\n    public init() {}\n}\n",
        "Presentation/Tests/PresentationTests/ProductPresenterTests.swift": "import CoreInterface\nimport Presentation\nimport RoutingTestDoubles\nimport SceneInterface\nimport TestSupport\nimport Testing\n\n@Suite struct ProductPresenterTests {\n    @Test func presents() {}\n}\n",
    ]

    static func interfacePackage(_ name: String, doubles: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            products: [
                .library(name: "\(name)", targets: ["\(name)"]),
                .library(name: "\(doubles)", targets: ["\(doubles)"]),
            ],
            targets: [
                .target(name: "\(name)"),
                .target(name: "\(doubles)", dependencies: ["\(name)"]),
            ]
        )
        """
    }
}

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Loupe",
    products: [
        .executable(name: "loupe", targets: ["LoupeCLI"]),
        .library(name: "LoupeArchitecture", targets: ["LoupeArchitecture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        // The major version tracks the Swift release: 603 is Swift 6.3. It builds with newer toolchains
        // too, and it is what GitHub's macOS runners (Xcode 26, Swift 6.3) can build.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.1"),
    ],
    targets: [
        // The canonical architecture: roles, target kinds and the dependency policy. No IO and no
        // parsing, so a future app generator can reuse it.
        .target(name: "LoupeArchitecture"),
        .target(
            name: "LoupeCore",
            dependencies: [
                "LoupeArchitecture",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
        ),
        .executableTarget(
            name: "LoupeCLI",
            dependencies: [
                "LoupeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
        ),
        .testTarget(
            name: "LoupeArchitectureTests",
            dependencies: ["LoupeArchitecture"],
        ),
        .testTarget(
            name: "LoupeCoreTests",
            dependencies: [
                "LoupeCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            exclude: ["Goldens"],
        ),
        .testTarget(
            name: "LoupeEndToEndTests",
            // CLITests run the built `loupe` binary, so `swift build` has to come before `swift test`.
            dependencies: ["LoupeCore"],
            exclude: ["Goldens"],
        ),
    ]
)

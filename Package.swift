// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "F1Live",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "F1Live", targets: ["F1Live"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "KeychainSupport"),
        .executableTarget(
            name: "F1Live",
            dependencies: [
                "KeychainSupport",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: ["Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "F1LiveTests",
            dependencies: ["F1Live"],
            // Command Line Tools ships Swift Testing here but does not add
            // its own framework directory to test-target imports.
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags([
                "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
            ])]
        )
    ],
    swiftLanguageModes: [.v5]
)

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
            dependencies: ["F1Live"]
        )
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 6.0
// FireCore — platform-independent logic for FIRE D-Day.
// No third-party dependencies, ever (README §5.1).

import PackageDescription

let package = Package(
    name: "FireCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FireCore",
            targets: ["FireCore"]
        )
    ],
    targets: [
        .target(
            name: "FireCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Read-only live check against the real API (README M1's "print the real balance in the
        // terminal"). Not a product, so nothing the app or widget links ever sees it.
        .executableTarget(
            name: "FireProbe",
            dependencies: ["FireCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FireCoreTests",
            dependencies: ["FireCore"],
            resources: [
                // Real recorded API responses replayed through URLProtocol.
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)

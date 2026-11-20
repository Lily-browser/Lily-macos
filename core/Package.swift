// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lily",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lily", targets: ["Lily"]),
        .library(name: "LilyCore", targets: ["LilyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lily-browser/LilyKit.git", revision: "e00a27ecb28dab4d5567a0b3648d0f425ddfbde9"),
    ],
    targets: [
        .target(
            name: "LilyCore",
            dependencies: [.product(name: "LilyKit", package: "LilyKit")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        ),
        .executableTarget(name: "Lily", dependencies: ["LilyCore"]),
        .testTarget(name: "LilyCoreTests", dependencies: ["LilyCore"]),
    ],
    // Swift 6 mode: complete strict-concurrency checking, data races are compile errors.
    // There are no package dependencies; any added must be pinned (`exact:` or `revision:`),
    // which scripts/security-lint.sh enforces.
    swiftLanguageModes: [.v6]
)

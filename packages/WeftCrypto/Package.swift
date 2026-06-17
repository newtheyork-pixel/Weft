// swift-tools-version:5.9
// WeftCrypto — the native client's E2EE crypto core.
// Dependency-free: CryptoKit + CommonCrypto + Foundation only.
import PackageDescription

let package = Package(
    name: "WeftCrypto",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WeftCrypto", targets: ["WeftCrypto"])
    ],
    targets: [
        .target(
            name: "WeftCrypto",
            path: "Sources/WeftCrypto"
        ),
        .testTarget(
            name: "WeftCryptoTests",
            dependencies: ["WeftCrypto"],
            path: "Tests/WeftCryptoTests"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QingkongCore",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v14)],
    products: [.library(name: "QingkongCore", targets: ["QingkongCore"])],
    targets: [
        .target(name: "QingkongCore"),
        .testTarget(name: "QingkongCoreTests", dependencies: ["QingkongCore"])
    ]
)

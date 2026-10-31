// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BuddyOSBridge",
    platforms: [
        // 配布の対象 OS（macOS 15.6 以降）に合わせる。
        .macOS("15.6")
    ],
    products: [
        .executable(name: "BridgeApp", targets: ["BridgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/EFPrefix/EFQRCode.git", from: "7.0.3"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "BridgeApp",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "EFQRCode", package: "EFQRCode"),
                .product(name: "APNS", package: "APNSwift")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "BridgeAppTests",
            dependencies: ["BridgeApp"],
            path: "Tests"
        )
    ],
    // Keep the existing Swift 5 language mode.
    swiftLanguageModes: [.v5]
)

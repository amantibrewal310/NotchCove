// swift-tools-version: 5.9
import PackageDescription
import Foundation

let currentDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let coreLibDir = URL(fileURLWithPath: currentDir).deletingLastPathComponent().appendingPathComponent("core/target/release").path

let package = Package(
    name: "NotchCove",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotchCove", targets: ["NotchCove"])
    ],
    targets: [
        .target(
            name: "CCoveCore",
            path: "Sources/CCoveCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "NotchCove",
            dependencies: ["CCoveCore"],
            path: "Sources/NotchCove",
            linkerSettings: [
                .unsafeFlags([
                    "\(coreLibDir)/libcove_core.a"
                ])
            ]
        )
    ]
)

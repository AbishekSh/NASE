// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NASE",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NASE", targets: ["NASE"]),
    ],
    targets: [
        .executableTarget(
            name: "NASE",
            path: "Sources/NASE",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "NASETests",
            dependencies: ["NASE"],
            path: "Tests/NASETests"
        ),
    ]
)

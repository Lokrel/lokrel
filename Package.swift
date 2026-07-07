// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lokrel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "lokrel", targets: ["lokrel"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
    ],
    targets: [
        .executableTarget(
            name: "lokrel",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "ZIPFoundation"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

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
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
        ),
        .executableTarget(
            name: "lokrel",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "Sparkle",
                "ZIPFoundation"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TallyKit",
    platforms: [
        .iOS("26.0"),
        .watchOS("26.0")
    ],
    products: [
        .library(name: "TallyKit", targets: ["TallyKit"])
    ],
    targets: [
        .target(
            name: "TallyKit",
            path: "Sources/TallyKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TallyKitTests",
            dependencies: ["TallyKit"],
            path: "Tests/TallyKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)

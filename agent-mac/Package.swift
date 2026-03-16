// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlawbyAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BlawbyAgent", targets: ["BlawbyAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "BlawbyAgent",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/BlawbyAgent",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Contacts"),
                .linkedFramework("EventKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScriptingBridge")
            ]
        ),
        .testTarget(
            name: "BlawbyAgentTests",
            dependencies: ["BlawbyAgent"],
            path: "Tests/BlawbyAgentTests"
        )
    ]
)

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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "BlawbyAgent",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
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
        )
    ]
)

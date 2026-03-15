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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "BlawbyAgent",
            dependencies: [],
            path: "Sources/BlawbyAgent",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("ScriptingBridge")
            ]
        )
    ]
)

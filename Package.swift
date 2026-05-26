// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "spotlight++",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "spotlight++",
            path: "Sources/spotlight++",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)

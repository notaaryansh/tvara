// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "spotlight++",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "spotlight++",
            path: "Sources/spotlight++",
            resources: [
                // CLIP tokenizer assets + MobileCLIP-S2 CoreML models.
                // Bundle.module reaches into here at runtime via
                // url(forResource:withExtension:) and url(forResource:withExtension:subdirectory:).
                .copy("Resources/Models")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)

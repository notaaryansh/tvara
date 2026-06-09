// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tvara",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "tvara",
            path: "Sources/tvara",
            resources: [
                // CLIP tokenizer assets + MobileCLIP-S2 CoreML models.
                // Bundle.module reaches into here at runtime via
                // url(forResource:withExtension:) and url(forResource:withExtension:subdirectory:).
                .copy("Resources/Models")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "tvaraTests",
            dependencies: ["tvara"],
            path: "Tests/tvaraTests"
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tvara",
    platforms: [.macOS(.v14)],
    targets: [
        // SQLite spellfix1 extension, statically linked. Provides indexed
        // edit-distance + phonetic fuzzy matching over a learned
        // vocabulary. Compiled with SQLITE_CORE so the
        // SQLITE_EXTENSION_INIT macros inside spellfix1.c become no-ops
        // and the init symbol can be called as a regular function from
        // our shim. Upstream source: sqlite.org/src/raw/ext/misc/spellfix.c.
        .target(
            name: "CSQLiteSpellfix",
            path: "Sources/CSQLiteSpellfix",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_ENABLE_SPELLFIX"),
            ]
        ),
        .executableTarget(
            name: "tvara",
            dependencies: ["CSQLiteSpellfix"],
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

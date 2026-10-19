// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FeatherDownloader",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DownloadCore", targets: ["DownloadCore"]),
        .library(name: "SubtitleCore", targets: ["SubtitleCore"]),
        .executable(name: "FeatherApp", targets: ["FeatherApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "DownloadCore"),
        .target(name: "SubtitleCore", dependencies: ["DownloadCore"]),
        .executableTarget(name: "FeatherApp", dependencies: [
            "DownloadCore", "SubtitleCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DownloadCoreTests", dependencies: ["DownloadCore"])
    ],
    swiftLanguageVersions: [.v5]
)

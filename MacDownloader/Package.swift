// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FeatherDownloader",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DownloadCore", targets: ["DownloadCore"]),
        .library(name: "SubtitleCore", targets: ["SubtitleCore"]),
        .library(name: "VideoRepairCore", targets: ["VideoRepairCore"]),
        .executable(name: "FeatherApp", targets: ["FeatherApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "DownloadCore"),
        .target(name: "SubtitleCore", dependencies: ["DownloadCore"]),
        .target(name: "VideoRepairCore", dependencies: ["DownloadCore"]),
        .executableTarget(name: "FeatherApp", dependencies: [
            "DownloadCore", "SubtitleCore", "VideoRepairCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DownloadCoreTests", dependencies: ["DownloadCore"]),
        .testTarget(name: "VideoRepairCoreTests", dependencies: ["VideoRepairCore", "DownloadCore"])
    ],
    swiftLanguageVersions: [.v5]
)

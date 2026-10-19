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
    targets: [
        .target(name: "DownloadCore"),
        .target(name: "SubtitleCore", dependencies: ["DownloadCore"]),
        .executableTarget(name: "FeatherApp", dependencies: ["DownloadCore", "SubtitleCore"]),
        .testTarget(name: "DownloadCoreTests", dependencies: ["DownloadCore"])
    ],
    swiftLanguageVersions: [.v5]
)

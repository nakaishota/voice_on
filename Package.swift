// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceOn",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VoiceOn",
            path: "Sources/VoiceOn"
        )
    ]
)

// swift-tools-version:5.9
// Whisper PTT for the Mac, a menu bar app. Build it on the Mac with ./build.sh, or from the
// desktop with `make mac-app MAC=<ssh host>`.
import PackageDescription

let package = Package(
    name: "WhisperPTT",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WhisperPTT", path: "Sources/WhisperPTT"),
    ]
)

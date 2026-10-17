// swift-tools-version: 6.2
import PackageDescription

// Telling voices apart in a recording, for Void Notes Beta only (the stable app links nothing of
// it). A wrapper around FluidAudio's offline diarizer, like Cairn's: the app sees one function
// and never imports FluidAudio. Without FluidAudio's default trait: a prebuilt text normaliser
// for speech synthesis (~8 MB) the diarizer doesn't use.
let package = Package(
    name: "VoidVoices",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VoidVoices", targets: ["VoidVoices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.16.1", traits: []),
    ],
    targets: [
        .target(
            name: "VoidVoices",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

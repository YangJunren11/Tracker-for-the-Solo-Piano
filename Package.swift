// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoloPianoTracker",
    products: [
        .library(name: "SoloPianoTracker", targets: ["SoloPianoTracker"]),
        .executable(name: "piano-tracker", targets: ["piano-tracker"]),
    ],
    targets: [
        .target(name: "SoloPianoTracker", dependencies: ["CTinySoundFont", "CZlib"]),
        // TinySoundFont, which plays the reference piano
        .target(name: "CTinySoundFont"),
        // zlib, for compressed MusicXML (.mxl)
        .systemLibrary(name: "CZlib"),
        // Follows a recording from the command line and writes what it found
        .executableTarget(name: "piano-tracker", dependencies: ["SoloPianoTracker"]),
        // Synthetic scores and performances for the cases recordings do not isolate: a similar
        // passage pages away, a restart, a repeat, the last bars, a tempo far from the score's.
        .testTarget(name: "SoloPianoTrackerTests", dependencies: ["SoloPianoTracker"]),
    ]
)

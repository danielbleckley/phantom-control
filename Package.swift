// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhantomControl",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PhantomCore"),
        // App-agnostic low-latency SDI→H.264→WebCodecs LAN streamer. No Phantom
        // dependencies — drop it into any app that wants to send a camera/SDI feed
        // to an iPad/iPhone browser over the local network.
        .target(name: "LANVideoStream"),
        .executableTarget(name: "phantomctl", dependencies: ["PhantomCore"]),
        .executableTarget(name: "PhantomApp", dependencies: ["PhantomCore", "LANVideoStream"]),
        .executableTarget(name: "PhantomTranscode", dependencies: ["PhantomCore"]),
    ]
)

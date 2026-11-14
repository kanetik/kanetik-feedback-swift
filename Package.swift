// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KanetikFeedback",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "KanetikFeedback", targets: ["KanetikFeedback"]),
    ],
    targets: [
        .target(name: "KanetikFeedback"),
        .testTarget(name: "KanetikFeedbackTests", dependencies: ["KanetikFeedback"]),
    ]
)

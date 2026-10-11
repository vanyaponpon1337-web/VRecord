// swift-tools-version: 5.9
import PackageDescription

// Deterministic camera-independent logic tests run natively on the macOS CI
// runner. The iPhone application itself is built by the Xcode project.
let package = Package(
    name: "VRecordCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VRecordCore", targets: ["VRecordCore"])],
    targets: [
        .target(
            name: "VRecordCore",
            path: "VRecord",
            exclude: ["App", "Camera", "Rendering", "Recording", "Resources",
                      "Core/PermissionsManager.swift", "Tracking/HandTrackingManager.swift"],
            sources: ["Core/GestureStateMachine.swift", "Tracking/HandLandmarks.swift",
                      "Tracking/PinchDetector.swift"]
        ),
        .testTarget(name: "VRecordCoreTests", dependencies: ["VRecordCore"], path: "Tests")
    ],
    swiftLanguageVersions: [.v5]
)

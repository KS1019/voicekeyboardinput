// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceKeyboardPackage",
    // Domain modules stay portable; app and extension targets enforce iOS 26.
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "VoiceKeyboardModels", targets: ["VoiceKeyboardModels"]),
        .library(name: "VoiceKeyboardSharedStorage", targets: ["VoiceKeyboardSharedStorage"]),
        .library(name: "VoiceKeyboardPresentation", targets: ["VoiceKeyboardPresentation"]),
        .library(name: "VoiceKeyboardInterfaces", targets: ["VoiceKeyboardInterfaces"]),
        .library(name: "VoiceKeyboardCommandPipeline", targets: ["VoiceKeyboardCommandPipeline"]),
        .library(name: "VoiceKeyboardCore", targets: ["VoiceKeyboardCore"])
    ],
    targets: [
        .target(
            name: "VoiceKeyboardModels",
            exclude: ["VoiceKeyboardModels.docc"]
        ),
        .target(
            name: "VoiceKeyboardSharedStorage",
            dependencies: ["VoiceKeyboardModels"]
        ),
        .target(
            name: "VoiceKeyboardPresentation",
            dependencies: ["VoiceKeyboardModels"],
            exclude: ["VoiceKeyboardPresentation.docc"]
        ),
        .target(
            name: "VoiceKeyboardCommands",
            dependencies: ["VoiceKeyboardModels"]
        ),
        .target(
            name: "VoiceKeyboardCommandPipeline",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardCommands"
            ]
        ),
        .target(
            name: "VoiceKeyboardInterfaces",
            dependencies: ["VoiceKeyboardModels"],
            exclude: ["VoiceKeyboardInterfaces.docc"]
        ),
        .target(
            name: "VoiceKeyboardCore",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardCommandPipeline",
                "VoiceKeyboardInterfaces"
            ],
            exclude: ["VoiceKeyboardCore.docc"]
        ),
        .testTarget(
            name: "VoiceKeyboardModelsTests",
            dependencies: [
                "VoiceKeyboardModels"
            ]
        ),
        .testTarget(
            name: "VoiceKeyboardSharedStorageTests",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardSharedStorage"
            ]
        ),
        .testTarget(
            name: "VoiceKeyboardPresentationTests",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardPresentation"
            ]
        ),
        .testTarget(
            name: "VoiceKeyboardCommandsTests",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardCommands"
            ]
        ),
        .testTarget(
            name: "VoiceKeyboardCommandPipelineTests",
            dependencies: [
                "VoiceKeyboardCommandPipeline",
                "VoiceKeyboardModels"
            ]
        ),
        .testTarget(
            name: "VoiceKeyboardInterfacesTests",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardInterfaces"
            ]
        ),
        .testTarget(
            name: "VoiceKeyboardCoreTests",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardInterfaces",
                "VoiceKeyboardCore"
            ]
        )
    ]
)

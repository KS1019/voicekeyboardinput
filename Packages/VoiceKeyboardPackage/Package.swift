// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceKeyboardPackage",
    // Domain modules stay portable; app and extension targets enforce iOS 26.
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .visionOS(.v1),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "VoiceKeyboardModels", targets: ["VoiceKeyboardModels"]),
        .library(name: "VoiceKeyboardPresentation", targets: ["VoiceKeyboardPresentation"]),
        .library(name: "VoiceKeyboardInterfaces", targets: ["VoiceKeyboardInterfaces"]),
        .library(name: "VoiceKeyboardCore", targets: ["VoiceKeyboardCore"])
    ],
    targets: [
        .target(
            name: "VoiceKeyboardModels",
            exclude: ["VoiceKeyboardModels.docc"]
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
            name: "VoiceKeyboardInterfaces",
            dependencies: ["VoiceKeyboardModels"],
            exclude: ["VoiceKeyboardInterfaces.docc"]
        ),
        .target(
            name: "VoiceKeyboardCore",
            dependencies: [
                "VoiceKeyboardModels",
                "VoiceKeyboardCommands",
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

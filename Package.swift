// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlowFlowX",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SlowFlowX", targets: ["SlowFlowX"])
    ],
    targets: [
        .executableTarget(
            name: "SlowFlowX",
            path: "Sources/SlowFlowX",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Speech")
            ]
        )
    ]
)

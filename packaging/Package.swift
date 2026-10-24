// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SGPlayer",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15)],
    products: [.library(name: "SGPlayer", targets: ["SGPlayer"]),
               .library(name: "SGPlayerUI", targets: ["SGPlayerUI"])],
    targets: [
        .binaryTarget(name: "SGPlayer", path: "Artifacts/SGPlayer.xcframework"),
        .target(name: "SGPlayerUI", dependencies: ["SGPlayer"],
                resources: [.copy("Resources/Fonts"), .copy("Resources/Licenses")],
                linkerSettings: [
                    .linkedLibrary("c++"), .linkedLibrary("iconv"), .linkedLibrary("z"),
                    .linkedFramework("AVKit"), .linkedFramework("AVFoundation"),
                    .linkedFramework("AudioToolbox"), .linkedFramework("VideoToolbox"),
                    .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
                    .linkedFramework("CoreImage"), .linkedFramework("CoreText"),
                    .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("GLKit"),
                    .linkedFramework("QuartzCore"), .linkedFramework("ImageIO"),
                    .linkedFramework("Security"), .linkedFramework("UniformTypeIdentifiers"),
                    .linkedFramework("Cocoa", .when(platforms: [.macOS])),
                    .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS]))
                ]),
        .testTarget(name: "SGPlayerUITests", dependencies: ["SGPlayerUI"], resources: [.copy("Fixtures")])
    ]
)

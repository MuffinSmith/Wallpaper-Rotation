// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WallpaperRotation",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RotationCore", targets: ["RotationCore"]),
        .library(name: "AppleWallpaper", targets: ["AppleWallpaper"]),
        .executable(name: "WallpaperRotation", targets: ["WallpaperRotation"]),
        .executable(name: "WallpaperDiagnostics", targets: ["WallpaperDiagnostics"])
    ],
    targets: [
        .target(name: "RotationCore"),
        .target(name: "AppleWallpaper", dependencies: ["RotationCore"]),
        .executableTarget(name: "WallpaperRotation", dependencies: ["RotationCore", "AppleWallpaper"]),
        .executableTarget(name: "WallpaperDiagnostics", dependencies: ["RotationCore", "AppleWallpaper"]),
        .testTarget(name: "RotationCoreTests", dependencies: ["RotationCore"]),
        .testTarget(name: "AppleWallpaperTests", dependencies: ["AppleWallpaper", "RotationCore"]),
        .testTarget(name: "WallpaperRotationTests", dependencies: ["WallpaperRotation", "AppleWallpaper"])
    ]
)

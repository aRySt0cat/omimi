// swift-tools-version: 6.2
// OmiKit: デバイス非依存のコアロジック (BLE プロトコル / Opus / Ogg / セグメント管理 / 話者の照合と学習 / AI で整理 / 書き出し)。
// 外部依存なし。macOS 上で `swift test` で検証できるよう CoreBluetooth / UIKit に依存しない。

import PackageDescription

let package = Package(
    name: "OmiKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "OmiKit", targets: ["OmiKit"]),
        .library(name: "OmiTranscription", targets: ["OmiTranscription"]),
        .library(name: "OmiSpeakers", targets: ["OmiSpeakers"]),
        .executable(name: "omikit-cli", targets: ["omikit-cli"]),
    ],
    targets: [
        .target(name: "OmiKit"),
        .target(name: "OmiTranscription", dependencies: ["OmiKit"]),
        // iPhone での話者分離 (Core ML。モデルはアプリが同梱し、URL で渡す)
        .target(name: "OmiSpeakers", dependencies: ["OmiKit"]),
        .executableTarget(name: "omikit-cli", dependencies: ["OmiKit", "OmiTranscription", "OmiSpeakers"]),
        .testTarget(name: "OmiKitTests", dependencies: ["OmiKit", "OmiTranscription", "OmiSpeakers"],
                    resources: [.copy("Fixtures")]),
    ]
)

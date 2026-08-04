#!/usr/bin/env swift
// Resources/AppIcon.icns を生成する。
// Dock には出ないアプリだが、システム設定のアクセシビリティ一覧やログイン項目に出るので用意しておく。
//
// 使い方: make icon

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1_024]
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = repoRoot.appendingPathComponent("build/AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 角丸の下地に、声を表す波形を重ねる。
func draw(size: Int) -> NSBitmapImageRep {
    let scale = CGFloat(size) / 1_024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    let inset = canvas.insetBy(dx: 40 * scale, dy: 40 * scale)
    let squircle = CGPath(
        roundedRect: inset,
        cornerWidth: 224 * scale,
        cornerHeight: 224 * scale,
        transform: nil
    )

    // 下地: インディゴ → 水色
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.36, green: 0.30, blue: 0.96, alpha: 1),
            CGColor(red: 0.24, green: 0.74, blue: 0.88, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: inset.minX, y: inset.maxY),
        end: CGPoint(x: inset.maxX, y: inset.minY),
        options: []
    )
    context.restoreGState()

    // 波形: 中央から対称に伸びるバー
    let heights: [CGFloat] = [0.20, 0.42, 0.68, 0.94, 0.62, 0.34, 0.78, 0.46, 0.22]
    let barWidth = 52 * scale
    let spacing = 34 * scale
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
    var x = canvas.midX - totalWidth / 2
    context.setFillColor(CGColor(gray: 1, alpha: 0.95))

    for ratio in heights {
        let height = 460 * scale * ratio
        let bar = CGRect(x: x, y: canvas.midY - height / 2, width: barWidth, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        context.fillPath()
        x += barWidth + spacing
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in sizes {
    for (suffix, pixels) in [("", size), ("@2x", size * 2)] {
        guard pixels <= 1_024 else { continue }
        let rep = draw(size: pixels)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let name = "icon_\(size)x\(size)\(suffix).png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let output = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil が失敗しました\n".data(using: .utf8)!)
    exit(1)
}
print("generated \(output.path)")

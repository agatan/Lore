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

/// Loreのmark「L.」。Menu barのglyphと同じ形を、無地の下地に白と一色の点だけで描く。
/// 光彩やgradientは足さない。縦の線は時間の流れ、足の先の点は録音中の印。
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    // macOSのicon gridに合わせ、824 ptの本体を中央に置く。
    let body = canvas.insetBy(dx: 100 * s, dy: 100 * s)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // 下地: わずかにvioletを含む墨色の無地。暗いDockでも縁が分かるよう、ごく薄い線だけ引く。
    c.addPath(squircle)
    c.setFillColor(rgb(0.09, 0.09, 0.12))
    c.fillPath()
    c.addPath(squircle)
    c.setStrokeColor(rgb(1, 1, 1, 0.08))
    c.setLineWidth(4 * s)
    c.strokePath()

    // 「L」: 白い一本の線。Menu barのglyph（2.6 / 18 pt）と同じ太さの比率。
    let stroke = 78 * s
    let stemX = 364 * s, top = 724 * s, baseY = 330 * s, footEnd = 532 * s
    let l = CGMutablePath()
    l.move(to: CGPoint(x: stemX, y: top))
    l.addLine(to: CGPoint(x: stemX, y: baseY))
    l.addLine(to: CGPoint(x: footEnd, y: baseY))
    c.addPath(l)
    c.setStrokeColor(rgb(1, 1, 1))
    c.setLineWidth(stroke)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.strokePath()

    // 「.」: 録音中のroseを一色で。
    let r = 50 * s
    let center = CGPoint(x: 652 * s, y: baseY)
    c.setFillColor(rgb(0.93, 0.33, 0.47))
    c.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))

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

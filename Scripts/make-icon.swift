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

/// Loreのmark「L.」。縦の線は時間の流れ（timelineの縦線）、足の先の丸は録音中の印。
/// 線の上の二つの穴は、その日に残した記録を表す。下地は夜のインクの色で、markだけを光らせる。
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    let inset = canvas.insetBy(dx: 100 * s, dy: 100 * s)   // macOS grid: 824 body
    let squircle = CGPath(roundedRect: inset, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // drop shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0, 0, 0, 0.35))
    c.addPath(squircle); c.setFillColor(rgb(0.08, 0.07, 0.14)); c.fillPath()
    c.restoreGState()

    // ink background
    c.saveGState(); c.addPath(squircle); c.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0.17, 0.15, 0.32), rgb(0.07, 0.06, 0.13)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: inset.minX, y: inset.maxY), end: CGPoint(x: inset.maxX, y: inset.minY), options: [])
    // soft glow behind the rail
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0.45, 0.40, 1.0, 0.45), rgb(0.45, 0.40, 1.0, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 430 * s, y: 520 * s), startRadius: 0, endCenter: CGPoint(x: 430 * s, y: 520 * s), endRadius: 420 * s, options: [])
    // top sheen
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sheen, start: CGPoint(x: 0, y: inset.maxY), end: CGPoint(x: 0, y: inset.midY), options: [])
    c.restoreGState()

    // "L": the timeline rail. Stem = time, foot ends at the live (recording) node.
    let railX = 356 * s, top = 744 * s, baseY = 318 * s, right = 612 * s
    let w = 76 * s
    let rail = CGMutablePath()
    rail.move(to: CGPoint(x: railX, y: top))
    rail.addLine(to: CGPoint(x: railX, y: baseY))
    rail.addLine(to: CGPoint(x: right, y: baseY))
    let railShape = rail.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -4 * s), blur: 40 * s, color: rgb(0.48, 0.42, 1.0, 0.7))
    c.addPath(railShape); c.setFillColor(rgb(0.6, 0.6, 1)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(railShape); c.clip()
    let railGrad = CGGradient(colorsSpace: space, colors: [rgb(0.74, 0.68, 1.0), rgb(0.47, 0.50, 1.0), rgb(0.32, 0.82, 0.97)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(railGrad, start: CGPoint(x: railX, y: top), end: CGPoint(x: right, y: baseY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    // nodes on the stem: punched rings
    for y in [606.0, 466.0] {
        let yy = CGFloat(y) * s, r = 22 * s
        c.setFillColor(rgb(0.11, 0.10, 0.21)); c.fillEllipse(in: CGRect(x: railX - r, y: yy - r, width: 2*r, height: 2*r))
    }
    // live node at the end of the foot
    let rr = 66 * s, cx = right + 40 * s, cy = baseY
    c.setFillColor(rgb(0.10, 0.09, 0.19)); c.fillEllipse(in: CGRect(x: cx - rr - 16*s, y: cy - rr - 16*s, width: 2*(rr+16*s), height: 2*(rr+16*s)))
    c.saveGState()
    c.setShadow(offset: .zero, blur: 40 * s, color: rgb(1.0, 0.35, 0.5, 0.75))
    c.setFillColor(rgb(0.97, 0.38, 0.50)); c.fillEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: 2*rr, height: 2*rr))
    c.restoreGState()
    let rose = CGGradient(colorsSpace: space, colors: [rgb(1.0, 0.56, 0.64), rgb(0.93, 0.29, 0.45)] as CFArray, locations: [0, 1])!
    c.saveGState(); c.addEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: 2*rr, height: 2*rr)); c.clip()
    c.drawLinearGradient(rose, start: CGPoint(x: cx, y: cy + rr), end: CGPoint(x: cx, y: cy - rr), options: [])
    c.restoreGState()

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

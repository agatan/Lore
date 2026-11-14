// LP用の収録を仕上げる。
// 使い方: patch-recording <in.mp4> <out.mp4> <重ねる画像.png> <x> <y> <w> <h> <出力幅> [poster秒]
// 単独windowを収録するとsystemが信号機の位置へ収録中の印を描くため、同じwindowの静止画から
// その領域 (x, y, w, h: 左上原点のpixel) を全frameへ重ね、出力幅へ縮小する。幅0なら縮小だけ行う。
// poster秒を渡すと、その時点のframeを <out>.png として書く（動画を再生しない環境の静止画）。
import AVFoundation
import AppKit
import QuartzCore
let a = CommandLine.arguments
let input = URL(fileURLWithPath: a[1]), output = URL(fileURLWithPath: a[2])
let src = NSImage(contentsOfFile: a[3])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let r = CGRect(x: Double(a[4])!, y: Double(a[5])!, width: Double(a[6])!, height: Double(a[7])!)
let outWidth = Double(a[8])!
let patch = r.isEmpty ? nil : src.cropping(to: r)
let sem = DispatchSemaphore(value: 0)
Task {
  do {
    let asset = AVURLAsset(url: input)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let size = try await track.load(.naturalSize)
    let duration = try await asset.load(.duration)
    let s = outWidth / size.width
    let render = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    let comp = AVMutableVideoComposition()
    comp.renderSize = render
    comp.frameDuration = CMTime(value: 1, timescale: 60)
    let inst = AVMutableVideoCompositionInstruction()
    inst.timeRange = CMTimeRange(start: .zero, duration: duration)
    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    li.setTransform(CGAffineTransform(scaleX: s, y: s), at: .zero)
    inst.layerInstructions = [li]
    comp.instructions = [inst]
    let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: render)
    let video = CALayer(); video.frame = parent.frame
    let overlay = CALayer()
    overlay.contents = patch
    // Core Animation tool uses bottom-left origin.
    overlay.frame = CGRect(x: r.minX * s, y: (size.height - r.maxY) * s, width: r.width * s, height: r.height * s)
    parent.addSublayer(video)
    if patch != nil { parent.addSublayer(overlay) }
    comp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    try? FileManager.default.removeItem(at: output)
    let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
    ex.videoComposition = comp
    try await ex.export(to: output, as: .mp4)
    if a.count > 9, let seconds = Double(a[9]) {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      let (frame, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
      let poster = output.deletingPathExtension().appendingPathExtension("png")
      guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try data.write(to: poster)
    }
    print("wrote \(output.lastPathComponent) \(Int(render.width))x\(Int(render.height))")
  } catch {
    FileHandle.standardError.write(Data("収録の仕上げに失敗: \(error)\n".utf8))
    exit(1)
  }
  sem.signal()
}
sem.wait()

// Codificador del video de presentación con AVFoundation (sin instalar nada: ni ffmpeg ni Homebrew).
//   swiftc -O docs/pitch/video/encode.swift -o /tmp/sard_encode
//   /tmp/sard_encode frames  CARPETA_PNG  FPS  salida.mp4          # una secuencia 00000.png, 00001.png… → H.264 sin audio
//   /tmp/sard_encode mux     video.mp4  audio.m4a  salida.mp4      # une el video con el audio (AAC) sin recodificar el video
//   /tmp/sard_encode extract entrada.mov FPS CARPETA_PNG [desde] [hasta]   # fotogramas de una grabación (para el simulador)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadImage(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("no se pudo leer \(url.path)") }
    return img
}

func runSync(_ block: @escaping (@escaping () -> Void) -> Void) {
    let sem = DispatchSemaphore(value: 0)
    block { sem.signal() }
    sem.wait()
}

func encodeFrames(dir: String, fps: Int32, out: String) {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".png") }.sorted() ?? []
    if files.isEmpty { fail("no hay PNG en \(dir)") }
    let first = loadImage(URL(fileURLWithPath: dir + "/" + files[0]))
    let width = first.width, height = first.height
    try? FileManager.default.removeItem(atPath: out)
    guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4) else { fail("no se pudo crear \(out)") }
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { fail("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    let space = CGColorSpaceCreateDeviceRGB()
    for (i, name) in files.enumerated() {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        let img = loadImage(URL(fileURLWithPath: dir + "/" + name))
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pb = buffer else { fail("sin búfer de píxeles") }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if !adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: fps)) { fail("append \(i): \(String(describing: writer.error))") }
    }
    input.markAsFinished()
    runSync { done in writer.finishWriting { done() } }
    if writer.status != .completed { fail("no terminó: \(String(describing: writer.error))") }
    print("video: \(files.count) fotogramas a \(fps) fps → \(out)")
}

func mux(video: String, audio: String, out: String) {
    try? FileManager.default.removeItem(atPath: out)
    let comp = AVMutableComposition()
    let v = AVURLAsset(url: URL(fileURLWithPath: video)), a = AVURLAsset(url: URL(fileURLWithPath: audio))
    guard let vt = v.tracks(withMediaType: .video).first, let at = a.tracks(withMediaType: .audio).first,
          let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { fail("faltan pistas") }
    let dur = v.duration
    try? cv.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
    try? ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(a.duration, dur)), of: at, at: .zero)
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { fail("sin exportador") }
    ex.outputURL = URL(fileURLWithPath: out)
    ex.outputFileType = .mp4
    ex.shouldOptimizeForNetworkUse = true
    runSync { done in ex.exportAsynchronously { done() } }
    if ex.status != .completed { fail("exportación: \(String(describing: ex.error))") }
    print("mux → \(out) (\(String(format: "%.2f", CMTimeGetSeconds(dur))) s)")
}

func extract(movie: String, fps: Int32, dir: String, from: Double, to: Double?) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let asset = AVURLAsset(url: URL(fileURLWithPath: movie))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    gen.appliesPreferredTrackTransform = true
    let total = CMTimeGetSeconds(asset.duration)
    let end = min(to ?? total, total)
    var t = from, i = 0
    while t < end {
        if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
            let url = URL(fileURLWithPath: String(format: "%@/%05d.png", dir, i))
            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
        }
        i += 1
        t = from + Double(i) / Double(fps)
    }
    print("extraídos \(i) fotogramas de \(movie) (\(String(format: "%.1f", total)) s) → \(dir)")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "frames" where args.count == 5: encodeFrames(dir: args[2], fps: Int32(args[3])!, out: args[4])
case "mux" where args.count == 5: mux(video: args[2], audio: args[3], out: args[4])
case "extract" where args.count >= 5: extract(movie: args[2], fps: Int32(args[3])!, dir: args[4], from: args.count > 5 ? Double(args[5])! : 0, to: args.count > 6 ? Double(args[6])! : nil)
default: fail("uso: encode frames DIR FPS OUT | mux VIDEO AUDIO OUT | extract MOV FPS DIR [desde] [hasta]")
}

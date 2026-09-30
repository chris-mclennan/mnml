// winrec — record ONE window (by CGWindowID) to a .mov, window pixels only.
//
//   winrec --window ID --out FILE.mov [--fps 30] [--bitrate 60000000]
//
// ScreenCaptureKit with a desktop-independent-window filter: what is
// recorded is that window's own backing store, so another window
// sliding over it, the desktop, the menu bar or the pointer never reach
// the file. Frames arrive when the window changes (an idle window sends
// none); each one keeps the presentation time the window server gave
// it, so a frame's time in the file is the time it was on screen.
//
// Stops on SIGINT / SIGTERM or when stdin closes, finishes the file,
// and prints one JSON line to stdout: frames written, first/last
// presentation time, the pixel size. Exit 0 ok, 2 usage, 3 the window
// is not shareable (gone, or no Screen Recording grant), 4 writer error.
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func die(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write(("winrec: " + msg + "\n").data(using: .utf8)!)
    exit(code)
}

var windowID: CGWindowID = 0
var outPath = ""
var fps = 30
var bitrate = 60_000_000
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--window": windowID = CGWindowID(args.next().flatMap { UInt32($0) } ?? 0)
    case "--out": outPath = args.next() ?? ""
    case "--fps": fps = args.next().flatMap { Int($0) } ?? 30
    case "--bitrate": bitrate = args.next().flatMap { Int($0) } ?? bitrate
    default: die(2, "unknown argument \(a)")
    }
}
if windowID == 0 || outPath.isEmpty { die(2, "usage: winrec --window ID --out FILE.mov [--fps N] [--bitrate BPS]") }

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var frames = 0
    var firstPTS = CMTime.invalid
    var lastPTS = CMTime.invalid
    let queue = DispatchQueue(label: "winrec.frames")
    var failed: String?

    init(url: URL, width: Int, height: Int, bitrate: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, CMSampleBufferGetImageBuffer(sb) != nil else { return }
        // Only complete frames carry pixels; idle/blank ones are skipped.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started {
            guard writer.startWriting() else { failed = "startWriting: \(writer.error?.localizedDescription ?? "?")"; return }
            writer.startSession(atSourceTime: pts)
            started = true
            firstPTS = pts
        }
        if input.isReadyForMoreMediaData {
            if input.append(sb) { frames += 1; lastPTS = pts }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failed = "stream stopped: \(error.localizedDescription)"
    }
}

// ScreenCaptureKit needs a window-server connection (CGS) first.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let sema = DispatchSemaphore(value: 0)
var content: SCShareableContent?
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, err in
    content = c
    if c == nil { FileHandle.standardError.write("winrec: \(err?.localizedDescription ?? "no shareable content")\n".data(using: .utf8)!) }
    sema.signal()
}
sema.wait()
guard let win = content?.windows.first(where: { $0.windowID == windowID }) else {
    die(3, "window \(windowID) is not shareable (gone, or no Screen Recording grant)")
}
let filter = SCContentFilter(desktopIndependentWindow: win)
let scale = Double(filter.pointPixelScale)
let pw = Int((Double(win.frame.width) * scale).rounded())
let ph = Int((Double(win.frame.height) * scale).rounded())
let cfg = SCStreamConfiguration()
cfg.width = pw
cfg.height = ph
cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
cfg.showsCursor = false
cfg.capturesAudio = false
cfg.ignoreShadowsSingleWindow = true
cfg.pixelFormat = kCVPixelFormatType_32BGRA
cfg.queueDepth = 8
cfg.scalesToFit = false

let rec: Recorder
do {
    rec = try Recorder(url: URL(fileURLWithPath: outPath), width: pw, height: ph, bitrate: bitrate, fps: fps)
} catch { die(4, "writer: \(error.localizedDescription)") }
let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
do { try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.queue) } catch { die(4, "addStreamOutput: \(error)") }

var startErr: Error?
stream.startCapture { e in startErr = e; sema.signal() }
sema.wait()
if let e = startErr { die(3, "startCapture: \(e.localizedDescription)") }
FileHandle.standardError.write("winrec: recording window \(windowID) at \(pw)x\(ph)\n".data(using: .utf8)!)

// Stop on a signal or when stdin closes.
let stop = DispatchSemaphore(value: 0)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()); s1.setEventHandler { stop.signal() }; s1.resume()
let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global()); s2.setEventHandler { stop.signal() }; s2.resume()
DispatchQueue.global().async {
    while let _ = readLine(strippingNewline: true) {}
    stop.signal()
}
stop.wait()

stream.stopCapture { _ in sema.signal() }
sema.wait()
rec.queue.sync {}
if !rec.started { die(4, "no frames were captured") }
rec.input.markAsFinished()
// Extend the file to the moment we stopped: an idle window sends no
// frames, and the last one should stay on screen until the end.
rec.writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
rec.writer.finishWriting { sema.signal() }
sema.wait()
if rec.writer.status != .completed { die(4, "finishWriting: \(rec.writer.error?.localizedDescription ?? "status \(rec.writer.status.rawValue)")") }
let first = rec.firstPTS.seconds, last = rec.lastPTS.seconds
print("{\"frames\":\(rec.frames),\"first_pts\":\(first),\"last_pts\":\(last),\"width\":\(pw),\"height\":\(ph)\(rec.failed.map { ",\"warning\":\"\($0)\"" } ?? "")}")

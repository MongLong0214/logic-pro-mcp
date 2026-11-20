// LogicCapture: record one app window (video, native Retina pixels, up to 60 fps) plus that app's audio.
//
// Why a window and not the display: the window filter excludes the desktop, the Dock, the menu bar and
// every notification banner by construction, so the footage is clean even if the host Mac is not.
// The audio is the app's own output taken digitally (no microphone, no loopback driver).
//
// Needs the Screen Recording permission of whatever launched it. Run it from the same terminal that
// holds that permission (the project drives it through `tmux -L logic-aqua send-keys -t gate:0`).
//
//   LogicCapture --bundle com.apple.logic10 --out take.mov [--fps 60] [--max-seconds 120] [--list]
//
// Stop with SIGINT/SIGTERM or by creating the file `<out>.stop`. On start it prints one JSON line
// with the wall-clock epoch of the first video frame, so the MCP driver log can be aligned to it.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    var started = false
    var firstVideoPTS = CMTime.invalid
    var firstEpoch = 0.0
    var videoFrames = 0
    var droppedFrames = 0
    var audioBuffers = 0
    let queue = DispatchQueue(label: "capture.samples")

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // ProRes 422 LT: intra-frame, so a busy 4K60 stream (a scrolling playhead) cannot stall a long-GOP HEVC
        // encoder the way it did in testing (video froze while audio kept going). Big on disk, light on the CPU.
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422LT,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // Only frames flagged "complete" carry pixels; idle/blank status frames are skipped.
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if !started {
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                started = true
                firstVideoPTS = pts
                let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
                firstEpoch = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMTimeSubtract(nowHost, pts))
                let line = "{\"event\":\"started\",\"first_frame_epoch\":\(firstEpoch)}"
                print(line); fflush(stdout)
            }
            if video.isReadyForMoreMediaData { video.append(sb); videoFrames += 1 } else { droppedFrames += 1 }
        case .audio:
            guard started, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), firstVideoPTS) >= 0 else { return }
            if audio.isReadyForMoreMediaData { audio.append(sb); audioBuffers += 1 }
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("stream stopped: \(error)\n".utf8))
    }

    func finish() async {
        guard started else { return }
        video.markAsFinished(); audio.markAsFinished()
        await writer.finishWriting()
        print("{\"event\":\"finished\",\"video_frames\":\(videoFrames),\"dropped_frames\":\(droppedFrames),\"audio_buffers\":\(audioBuffers),\"status\":\(writer.status.rawValue)}")
        fflush(stdout)
    }
}

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

@main
struct Main {
    static func main() async {
        do {
            // Match on bundle id: Logic's display name contains a no-break space, so comparing names fails.
            let bundle = arg("--bundle") ?? "com.apple.logic10"
            let owner = bundle
            let fps = Int(arg("--fps") ?? "60") ?? 60
            let maxSeconds = Double(arg("--max-seconds") ?? "180") ?? 180
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows
                .filter { $0.owningApplication?.bundleIdentifier == bundle && $0.frame.width > 800 && $0.windowLayer == 0 }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            if CommandLine.arguments.contains("--list") {
                for w in windows { print("\(w.windowID)\t\(w.frame)\t\(w.title ?? "")") }
                print("\(windows.count) matching window(s) for \(owner) of \(content.windows.count)")
                fflush(stdout)
                return
            }
            guard let out = arg("--out") else { print("usage: LogicCapture --owner NAME --out FILE"); exit(2) }
            guard let win = windows.first else { print("no on-screen window for \(owner)"); exit(3) }
            // Pixels = points x the scale of the display the window is on (2 on this Retina panel).
            let scale = Int(NSScreen.screens.first(where: { $0.frame.intersects(win.frame) })?.backingScaleFactor ?? 2)
            let width = Int(win.frame.width) * scale, height = Int(win.frame.height) * scale
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            cfg.width = width; cfg.height = height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.queueDepth = 8
            let rec = try Recorder(url: URL(fileURLWithPath: out), width: width, height: height, fps: fps)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
            try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.queue)
            try stream.addStreamOutput(rec, type: .audio, sampleHandlerQueue: rec.queue)
            print("{\"event\":\"window\",\"id\":\(win.windowID),\"pixels\":[\(width),\(height)],\"fps\":\(fps)}"); fflush(stdout)
            try await stream.startCapture()
            var stop = false
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let sigs = [SIGINT, SIGTERM].map { s -> DispatchSourceSignal in
                let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
                src.setEventHandler { stop = true }; src.resume(); return src
            }
            _ = sigs
            let t0 = Date()
            while !stop && Date().timeIntervalSince(t0) < maxSeconds
                    && !FileManager.default.fileExists(atPath: out + ".stop") {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await stream.stopCapture()
            await rec.finish()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

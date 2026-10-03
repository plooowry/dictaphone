import AVFoundation
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable {
    case mic, system, both
}

/// Records everything the Mac is playing (Teams, Zoom, Meet, a browser…) to a 16 kHz mono WAV.
/// Capture happens before the audio reaches the output device, so headphones don't matter.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "dictaphone.system-audio")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// Wall-clock time of the first audio buffer, used to line this track up with the microphone track.
    private(set) var firstBufferAt: Date?

    func start(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Dictaphone", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true      // don't record our own read-back voice
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2               // we only want audio; keep video negligible
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync { file = nil }   // closes and finalizes the WAV
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { log("system audio stopped: \(error)") }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let input = Self.pcm(from: sb) else { return }
        if firstBufferAt == nil { firstBufferAt = Date() }
        if converter == nil { converter = AVAudioConverter(from: input.format, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16000 / input.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if err == nil, out.frameLength > 0 { try? file?.write(from: out) }
    }

    private static func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var d = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &d) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let rc = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return rc == noErr ? buf : nil
    }
}

import AVFoundation
import Observation

/// A voice message being recorded: 48 kHz mono PCM to a file, with live levels for the bar.
@MainActor
@Observable
final class VoiceRecorder {
    struct Recording {
        let url: URL
        /// Seconds.
        let duration: Double
        /// 0 to 1, ten a second.
        let levels: [Double]
    }

    enum Start {
        case started, denied, failed
    }

    /// Instagram's limit for a voice message.
    static let maxDuration: TimeInterval = 60

    /// The recording bar is up.
    private(set) var isActive = false
    /// Still listening (false once the limit is reached).
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Double] = []
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var ticker: Task<Void, Never>?

    func start() async -> Start {
        guard !isActive else { return .started }
        let url = URL.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).caf")
        #if DEBUG
        if Self.usesTestTone {
            begin(url: url, recorder: nil)
            return .started
        }
        #endif
        guard await AVAudioApplication.requestRecordPermission() else { return .denied }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maxDuration) else {
                restoreSession()
                return .failed
            }
            begin(url: url, recorder: recorder)
            return .started
        } catch {
            restoreSession()
            return .failed
        }
    }

    /// Stops and hands back the recording; nil when it's too short to be a message.
    func finish() -> Recording? {
        guard isActive, let url else { return nil }
        let duration = elapsed
        recorder?.stop()
        #if DEBUG
        if recorder == nil { try? Self.writeTestTone(seconds: max(duration, 1), to: url) }
        #endif
        let recording = Recording(url: url, duration: duration, levels: levels)
        reset()
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return recording
    }

    func cancel() {
        guard isActive else { return }
        recorder?.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    private func begin(url: URL, recorder: AVAudioRecorder?) {
        self.url = url
        self.recorder = recorder
        elapsed = 0
        levels = []
        isActive = true
        isRecording = true
        let started = Date.now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                self.tick(since: started)
            }
        }
    }

    private func tick(since started: Date) {
        elapsed = min(Date.now.timeIntervalSince(started), Self.maxDuration)
        if let recorder {
            recorder.updateMeters()
            // The same -60 to -10 dB range the website's recorder measures.
            let decibels = Double(recorder.averagePower(forChannel: 0))
            levels.append(min(max((decibels + 60) / 50, 0), 1))
            if !recorder.isRecording { isRecording = false }
        } else {
            levels.append(0.4 + 0.3 * sin(elapsed * 5))
            if elapsed >= Self.maxDuration { isRecording = false }
        }
    }

    private func reset() {
        ticker?.cancel()
        ticker = nil
        recorder = nil
        url = nil
        isActive = false
        isRecording = false
        restoreSession()
    }

    /// Back to playing sound even on silent, as the app does otherwise.
    private func restoreSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    #if DEBUG
    /// -testVoiceClip YES: a tone instead of the microphone, to test voice messages without
    /// recording anyone.
    static var usesTestTone: Bool { UserDefaults.standard.bool(forKey: "testVoiceClip") }

    private static func writeTestTone(seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            let time = Double(index) / 48_000
            let envelope = min(1, time * 8, (seconds - time) * 8)
            samples[index] = Float(0.25 * envelope * sin(2 * .pi * 440 * time) * (0.6 + 0.4 * sin(2 * .pi * 2 * time)))
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }
    #endif
}

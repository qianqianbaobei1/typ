import Foundation

/// Transcribes speech in pieces while the user is still talking: whenever there is a pause,
/// the audio up to that pause is sent to Whisper in the background, so on release only the
/// last piece is left to recognize.
@MainActor
final class StreamingTranscriber {
    private let recorder: AudioRecorder
    private let transcribe: (_ wav: Data, _ prompt: String) async throws -> String
    private let basePrompt: String

    private var timer: Timer?
    private var segmentStart = 0
    private var noiseFloor: Float = 1
    private var chain: Task<String, Error>?
    private(set) var segments = 0

    private let rate = Int(AudioRecorder.sampleRate)
    private let frame = Int(AudioRecorder.sampleRate) / 10    // 100 ms frames
    private let minSegment = Int(AudioRecorder.sampleRate) * 3  // don't cut pieces shorter than 3 s
    private let maxSegment = Int(AudioRecorder.sampleRate) * 12 // without a pause, force a cut after 12 s
    private let pauseFrames = 4                                // 0.4 s of quiet counts as a pause

    init(recorder: AudioRecorder, basePrompt: String,
         transcribe: @escaping (_ wav: Data, _ prompt: String) async throws -> String) {
        self.recorder = recorder
        self.basePrompt = basePrompt
        self.transcribe = transcribe
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        chain?.cancel()
        chain = nil
    }

    private func frameRMS(_ s: [Float], _ i: Int) -> Float {
        AudioRecorder.rms(Array(s[(i * frame)..<min(s.count, (i + 1) * frame)]))
    }

    private func tick() {
        let total = recorder.count
        guard total - segmentStart >= minSegment else { return }
        let tailFrames = pauseFrames + 1
        let tail = recorder.slice(from: total - tailFrames * frame, to: total)
        guard tail.count == tailFrames * frame else { return }
        let levels = (0..<tailFrames).map { frameRMS(tail, $0) }
        noiseFloor = min(noiseFloor, levels.min() ?? 1)
        let quiet = max(0.006, noiseFloor * 3)
        var cut: Int
        if levels.suffix(pauseFrames).allSatisfy({ $0 < quiet }) {
            // Cut in the middle of the pause.
            cut = total - (pauseFrames * frame) / 2
        } else if total - segmentStart >= maxSegment {
            // No pause for a long time: cut at the quietest 100 ms of the last 1.5 s.
            let window = recorder.slice(from: total - 15 * frame, to: total)
            guard window.count == 15 * frame else { return }
            let quietest = (0..<15).min { frameRMS(window, $0) < frameRMS(window, $1) } ?? 14
            cut = total - 15 * frame + quietest * frame + frame / 2
        } else {
            return
        }
        enqueue(recorder.slice(from: segmentStart, to: cut), minSamples: rate / 2)
        segmentStart = cut
    }

    private func enqueue(_ piece: [Float], minSamples: Int) {
        guard piece.count > minSamples, AudioRecorder.rms(piece) > 0.002 else { return }
        segments += 1
        let previous = chain
        let prompt = basePrompt
        let transcribe = self.transcribe
        let wav = AudioRecorder.wav(piece)
        chain = Task {
            let before = try await previous?.value ?? ""
            // Give Whisper the end of what was said so far, for continuity.
            let context = String(before.suffix(120))
            let text = try await transcribe(wav, [prompt, context].filter { !$0.isEmpty }.joined(separator: " "))
            return Self.join(before, text)
        }
    }

    /// Recognizes what's left and returns the full transcript.
    func finish(all samples: [Float]) async throws -> String {
        timer?.invalidate()
        timer = nil
        if segmentStart < samples.count { enqueue(Array(samples[segmentStart...]), minSamples: rate / 5) }
        return try await chain?.value ?? ""
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        let cjk: (Character) -> Bool = { c in c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) } }
        return cjk(last) || cjk(first) ? a + b : a + " " + b
    }
}

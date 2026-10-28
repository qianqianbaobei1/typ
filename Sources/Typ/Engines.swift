import Foundation

enum SpeechEngineKind: String, CaseIterable, Identifiable, Sendable {
    case sensevoice, whisper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sensevoice: return "极速：SenseVoice（中文更快）"
        case .whisper: return "精准：Whisper（英文术语更好）"
        }
    }
    var port: Int { self == .whisper ? 18731 : 18732 }
}

/// Runs a local speech-recognition server (model stays loaded in memory) and sends it audio:
/// SenseVoice via sherpa-onnx, or whisper.cpp.
@MainActor
final class WhisperEngine: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, ready
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "未启动"
            case .starting: return "加载模型中…"
            case .ready: return "就绪"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var kind: SpeechEngineKind = .whisper
    private var process: Process?

    static var senseVoiceDir: URL { Paths.support.appendingPathComponent("sensevoice", isDirectory: true) }
    static var senseVoicePython: String { senseVoiceDir.appendingPathComponent("venv/bin/python").path }
    static var senseVoiceModel: String { senseVoiceDir.appendingPathComponent("model").path }
    static var senseVoiceInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: senseVoicePython)
            && FileManager.default.fileExists(atPath: senseVoiceModel + "/tokens.txt")
    }
    static var senseVoiceScript: String? { Bundle.main.path(forResource: "sensevoice_server", ofType: "py") }

    static let binaryCandidates = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
    static var binaryPath: String? { binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    func start(kind requested: SpeechEngineKind, modelPath: String) {
        stop()
        killOrphans()
        let kind: SpeechEngineKind = requested == .sensevoice && Self.senseVoiceInstalled && Self.senseVoiceScript != nil ? .sensevoice : .whisper
        self.kind = kind
        if requested == .sensevoice && kind == .whisper { Log.write("SenseVoice not installed, falling back to Whisper") }
        if kind == .sensevoice {
            launch(Self.senseVoicePython, ["-I", Self.senseVoiceScript!, Self.senseVoiceModel, "\(kind.port)"])
            return
        }
        guard let bin = Self.binaryPath else {
            status = .failed("未找到 whisper-server，请先运行：brew install whisper-cpp")
            return
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            status = .failed("未找到语音模型：\(modelPath)")
            return
        }
        let threads = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        launch(bin, ["-m", modelPath, "--host", "127.0.0.1", "--port", "\(kind.port)", "-t", "\(threads)", "-l", "auto", "-nt"])
    }

    private func launch(_ executable: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        FileManager.default.createFile(atPath: Paths.whisperLog.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: Paths.whisperLog) {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.status = .failed("语音引擎已退出（代码 \(proc.terminationStatus)），详见 whisper.log")
            }
        }
        do {
            try p.run()
        } catch {
            status = .failed("语音引擎启动失败：\(error.localizedDescription)")
            return
        }
        process = p
        status = .starting
        Task { await waitUntilReady(p) }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        if p.isRunning { p.terminate() }
        status = .stopped
    }

    private func killOrphans() {
        for pattern in ["whisper-server.*--port \(SpeechEngineKind.whisper.port)", "sensevoice_server.py"] {
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k.arguments = ["-f", pattern]
            try? k.run()
            k.waitUntilExit()
        }
    }

    private func waitUntilReady(_ p: Process) async {
        let url = URL(string: "http://127.0.0.1:\(kind.port)/")!
        for _ in 0..<240 {
            guard process === p else { return }
            if let (_, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse) != nil {
                if process === p { status = .ready }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if process === p { status = .failed("语音引擎启动超时") }
    }

    nonisolated static func transcribe(kind: SpeechEngineKind, wav: Data, language: String, prompt: String) async throws -> String {
        if kind == .sensevoice { return try await senseVoice(wav: wav, language: language) }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(kind.port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        let boundary = "TypBoundary\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("temperature", "0.0")
        field("language", language)
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw TypError.message("语音识别失败：\(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TypError.message("语音识别返回格式错误")
        }
        if let err = obj["error"] as? String { throw TypError.message("语音识别失败：\(err)") }
        return Self.clean(obj["text"] as? String ?? "")
    }

    nonisolated static func senseVoice(wav: Data, language: String) async throws -> String {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(SpeechEngineKind.sensevoice.port)/asr")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.setValue(language, forHTTPHeaderField: "X-Language")
        req.httpBody = wav
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = obj?["text"] as? String else {
            throw TypError.message("语音识别失败：\(obj?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "")")
        }
        return clean(text)
    }

    /// Strips Whisper's non-speech annotations and known silence hallucinations.
    nonisolated static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*(music|音乐|掌声|applause|silence)[^)]*\)"#,
                                          with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let hallucinations = ["请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", "字幕由Amara.org社区提供", "谢谢观看", "Thank you for watching.", "Thanks for watching!"]
        if hallucinations.contains(where: { t == $0 }) { return "" }
        return t
    }
}

/// OpenAI-compatible chat completions client (DeepSeek by default).
struct LLMClient: Sendable {
    let baseURL: String
    let apiKey: String
    let model: String

    func chat(system: String, user: String, examples: [(String, String)] = [], json: Bool = false,
              temperature: Double = 0.2) async throws -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw TypError.message("API 地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "stream": false,
            "messages": [["role": "system", "content": system]]
                + examples.flatMap { [["role": "user", "content": $0.0], ["role": "assistant", "content": $0.1]] }
                + [["role": "user", "content": user]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let usage = obj?["usage"] as? [String: Any] {
            let p = usage["prompt_tokens"] as? Int ?? 0
            let h = usage["prompt_cache_hit_tokens"] as? Int ?? 0
            let c = usage["completion_tokens"] as? Int ?? 0
            Log.write("LLM usage: prompt \(p) (cache hit \(h)), completion \(c), \(elapsed)s")
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw TypError.message(code == 401 ? "API Key 无效" : code == 402 ? "DeepSeek 余额不足" : "AI 请求失败（\(code)）：\(msg.prefix(120))")
        }
        guard let choices = obj?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TypError.message("AI 返回格式错误")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Like `chat`, but guards against the provider's occasional multi-second queueing:
    /// if no answer arrives within `hedgeAfter`, an identical second request is raced against the first,
    /// and the whole call gives up after `deadline`.
    func fastChat(system: String, user: String, examples: [(String, String)] = [], json: Bool = false,
                  temperature: Double = 0.2, hedgeAfter: Double = 2.5, deadline: Double) async throws -> String {
        let client = self
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await client.chat(system: system, user: user, examples: examples, json: json, temperature: temperature) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(hedgeAfter * 1e9))
                Log.write("LLM slow (>\(hedgeAfter)s), sending a hedge request")
                return try await client.chat(system: system, user: user, examples: examples, json: json, temperature: temperature)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1e9))
                return nil // deadline marker
            }
            var lastError: Error = TypError.message("AI 请求失败")
            var pending = 3
            while pending > 0 {
                pending -= 1
                do {
                    guard let result = try await group.next() else { break }
                    guard let text = result else {
                        group.cancelAll()
                        throw TypError.message(String(format: "AI 响应超时（%.0f 秒）", deadline))
                    }
                    group.cancelAll()
                    return text
                } catch let e as TypError {
                    if case .message(let m) = e, m.hasPrefix("AI 响应超时") { throw e }
                    lastError = e
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }
}

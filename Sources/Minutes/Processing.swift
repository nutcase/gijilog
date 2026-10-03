import AVFoundation
import Foundation
import Security
import Speech

struct RecordedChunk: Codable {
    var filename: String
    var offset: Double
    var source: String
}
struct RecordingManifest: Codable {
    var version = 1
    var chunks: [RecordedChunk] = []
    var trackStarts: [String: Double] = [:]
}
struct RecordedInput {
    var url: URL
    var offset: Double
    var source: String
}
enum KeyStore {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.minutes.openai",
        kSecAttrAccount as String: "api-key",
    ]
    static func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError.message("Keychain削除エラー: \(status)")
            }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q.merge(attributes) { _, new in new }
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppError.message("Keychain保存エラー: \(added)") }
        } else if status != errSecSuccess {
            throw AppError.message("Keychain更新エラー: \(status)")
        }
    }
}
final class LocalRecognition {
    private var task: SFSpeechRecognitionTask?
    func transcribe(_ url: URL) async throws -> [Segment] {
        let permission = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard permission == .authorized else { throw AppError.message("音声認識を許可してください。") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
            recognizer.supportsOnDeviceRecognition
        else { throw AppError.message("日本語の端末内音声認識が利用できません。クラウド処理へ自動送信はしません。") }
        return try await withCheckedThrowingContinuation { c in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            var finished = false
            let lock = NSLock()
            let timeout = DispatchWorkItem { [weak self] in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                self?.task?.cancel()
                c.resume(throwing: AppError.message("端末内音声認識がタイムアウトしました。音声は保存されています。"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
            task = recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                if let result, result.isFinal {
                    finished = true
                    lock.unlock()
                    timeout.cancel()
                    c.resume(
                        returning: result.bestTranscription.segments.map {
                            Segment(time: $0.timestamp, source: "", text: $0.substring)
                        })
                } else if let error {
                    finished = true
                    lock.unlock()
                    timeout.cancel()
                    c.resume(throwing: error)
                } else {
                    lock.unlock()
                }
            }
        }
    }
}
final class LocalOnlySession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
enum Processor {
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? CloudFailure { return error.code == 429 || error.code >= 500 }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(
                error.code)
        }
        return false
    }
    // Short PCM chunks keep recognition requests bounded and uploads below the file limit.
    static func chunks(_ url: URL, directory: URL) throws -> [(URL, Double)] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let count = AVAudioFrameCount(format.sampleRate * 40)
        var result: [(URL, Double)] = []
        while input.framePosition < input.length {
            let offset = Double(input.framePosition) / format.sampleRate
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw AppError.message("音声バッファを確保できません。")
            }
            try input.read(into: buffer, frameCount: count)
            let chunk = directory.appendingPathComponent(UUID().uuidString + ".wav")
            do {
                let output = try AVAudioFile(
                    forWriting: chunk,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    ])
                try output.write(from: buffer)
            }
            result.append((chunk, offset))
        }
        return result
    }
    static func recognizeChunk(_ url: URL, offset: Double, source: String, cloud: Bool, key: String) async throws
        -> [Segment]
    {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var result: [Segment] = []
        for (wav, relative) in try chunks(url, directory: temporary) {
            // Skip silent tracks to avoid hallucinated transcription and unnecessary API calls.
            let file = try AVAudioFile(forReading: wav)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try file.read(into: buffer)
            var peak: Float = 0
            if let values = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(values[channel][frame])) }
                }
            }
            guard peak > 0.002 else { continue }
            if cloud {
                let text = try await cloudTranscribe(wav, key: key)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Segment(time: offset + relative, source: source, text: text))
                }
            } else {
                let recognizer = LocalRecognition()
                let words = try await recognizer.transcribe(wav)
                if !words.isEmpty {
                    result.append(
                        Segment(
                            time: offset + relative + (words.first?.time ?? 0), source: source,
                            text: words.map(\.text).joined()))
                }
            }
        }
        return result
    }
    static func recordingInputs(folder: URL, allowMissing: Bool = false) throws -> [RecordedInput] {
        let manifestURL = folder.appendingPathComponent("recording.json")
        var manifest: RecordingManifest?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest?.version == 1 else { throw AppError.message("未対応の録音時刻データです。") }
        }
        if let manifest, !manifest.chunks.isEmpty {
            return try manifest.chunks.sorted { $0.offset < $1.offset }.map { chunk in
                guard chunk.filename == URL(fileURLWithPath: chunk.filename).lastPathComponent,
                    chunk.offset.isFinite, chunk.offset >= 0,
                    ["Mac音声", "マイク"].contains(chunk.source)
                else { throw AppError.message("録音時刻データが不正です。") }
                let url = folder.appendingPathComponent("chunks").appendingPathComponent(chunk.filename)
                guard allowMissing || FileManager.default.fileExists(atPath: url.path) else {
                    throw AppError.message("録音チャンクが見つかりません。元の録音ファイルは保存されています。")
                }
                return RecordedInput(url: url, offset: chunk.offset, source: chunk.source)
            }
        }
        // Legacy recordings have no common clock metadata. Keep their existing per-track times.
        return [("system.caf", "Mac音声"), ("microphone.caf", "マイク")].compactMap { file, source in
            let url = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return RecordedInput(url: url, offset: manifest?.trackStarts[file] ?? 0, source: source)
        }
    }
    static func hasRecordedAudio(folder: URL) throws -> Bool {
        let raw = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {
            url in
            url.pathExtension == "caf"
                && ["system", "microphone"].contains(where: { base in
                    url.lastPathComponent == base + ".caf" || url.lastPathComponent.hasPrefix(base + "-")
                })
        }
        let urls = raw + (try recordingInputs(folder: folder, allowMissing: true)).map(\.url)
        var failure: Error?
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do { if try AVAudioFile(forReading: url).length > 0 { return true } } catch { failure = error }
        }
        if let failure { throw failure }
        return false
    }
    static func transcribe(folder: URL, cloud: Bool, key: String, progress: @escaping (String) async -> Void)
        async throws -> [Segment]
    {
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.json").path) {
            await progress("旧録音を再処理中（トラック間の開始時刻は不明）")
        }
        var all: [Segment] = []
        for input in try recordingInputs(folder: folder) {
            await progress("\(input.source) \(Int(input.offset))秒〜を文字起こし中")
            // Both live and replay use the same silence gate and recognition path.
            all.append(
                contentsOf: try await recognizeChunk(
                    input.url, offset: input.offset, source: input.source, cloud: cloud, key: key))
        }
        return all.sorted { $0.time < $1.time }
    }
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudFailure(code: code)
        }
        return data
    }
    static func cloudTranscribe(_ url: URL, key: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("model", "gpt-4o-transcribe"), ("language", "ja")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        body.append(try Data(contentsOf: url))
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        struct Result: Decodable { let text: String }
        return try JSONDecoder().decode(Result.self, from: await send(request)).text
    }
    static func summarize(_ segments: [Segment], cloud: Bool, key: String, model: String, localModel: String = "")
        async throws -> String
    {
        var state = MinutesState()
        let settings = SessionSettings(mode: cloud ? "cloud" : "local", model: model, localModel: localModel)
        while !MinutesEngine.batch(segments, state: state).isEmpty {
            state = try await MinutesEngine.update(state, segments: segments, settings: settings, key: key)
        }
        return MinutesEngine.render(state, segments: segments)
    }
}
struct CloudFailure: LocalizedError {
    var code: Int
    var errorDescription: String? { "クラウドAPIエラー (\(code))。APIキー・利用上限・モデル設定を確認してください。" }
}

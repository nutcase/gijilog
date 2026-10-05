import AVFoundation
import Foundation
import Security

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
enum Processor {
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? CloudFailure { return error.code == 429 || error.code >= 500 }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(
                error.code)
        }
        return false
    }
    /// The backoff for a retry, extended to the server's Retry-After (capped at two minutes).
    static func retryDelay(after error: Error, attempt: Int, base: (Int) -> TimeInterval) -> TimeInterval {
        max(base(attempt), min((error as? CloudFailure)?.retryAfter ?? 0, 120))
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
    static func recognizeChunk(
        _ url: URL, offset: Double, source: String, key: String, hints: TranscriptionHints = TranscriptionHints()
    ) async throws -> [Segment] {
        var hints = hints
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var result: [Segment] = []
        for (wav, relative) in try chunks(url, directory: temporary) {
            // Audio without a voice is not sent: the model invents speech for room noise, in any language.
            let file = try AVAudioFile(forReading: wav)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try file.read(into: buffer)
            guard voicedSeconds(buffer) >= minimumVoice else { continue }
            let text = hints.removingEcho(from: try await cloudTranscribe(wav, key: key, prompt: hints.prompt))
            // Japanese is requested, so text without any Japanese is the model inventing speech for noise
            // ("Hallo zusammen.", "grazie mille."), or naming none: a lone "OK" is lost with it.
            if containsJapanese(text) {
                result.append(Segment(time: offset + relative, source: source, text: text))
                hints.preceding = TranscriptionHints.tail(hints.preceding + text)
            }
        }
        return result
    }
    // A chunk is sent only with this many seconds of voice. On a 41-minute meeting this skipped 135 of the
    // microphone track's 136 lines in other languages, and none of the Mac audio track's 202 lines of speech.
    static let minimumVoice = 0.4
    static let voiceLevel: Float = 0.004  // RMS a quiet voice reaches on a built-in microphone.
    /// Seconds that sound like a voice: 50 ms windows louder than a quiet voice and well above the chunk's own
    /// background (its quietest tenth, capped so steady sound cannot hide a voice). Clicks are too short to add up.
    static func voicedSeconds(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let rate = buffer.format.sampleRate
        let window = max(1, Int(rate / 20))
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        var levels: [Float] = []
        var start = 0
        while start + window <= Int(buffer.frameLength) {
            var sum: Float = 0
            for i in start..<(start + window) {
                let value = samples[i * stride]
                sum += value * value
            }
            levels.append((sum / Float(window)).squareRoot())
            start += window
        }
        guard !levels.isEmpty else { return 0 }
        let background = levels.sorted()[levels.count / 10]
        let threshold = max(voiceLevel, min(background * 4, 0.02))
        return Double(levels.filter { $0 > threshold }.count) * Double(window) / rate
    }
    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
                || (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0xFF66...0xFF9F).contains($0.value)
        }
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
                    ["Mac音声", "マイク", AudioImport.source].contains(chunk.source)
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
        let urls =
            raw + (try recordingInputs(folder: folder, allowMissing: true)).map(\.url)
            + [folder.appendingPathComponent(AudioMixdown.filename)]
        var failure: Error?
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do { if try AVAudioFile(forReading: url).length > 0 { return true } } catch { failure = error }
        }
        if let failure { throw failure }
        return false
    }
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw CloudFailure(
                code: http?.statusCode ?? 0, message: serverMessage(data), retryAfter: http.flatMap(retryAfter))
        }
        return data
    }
    // Error bodies say what to fix (model name, quota). Keys echoed back by the API are masked before
    // the message is shown or saved with a failed job.
    static func serverMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = json["error"]
        guard
            let text = ((error as? [String: Any])?["message"] as? String ?? error as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let masked = text.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-*]+"#, with: "sk-***", options: .regularExpression)
        return masked.count > 200 ? String(masked.prefix(200)) + "…" : masked
    }
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init) {
            return max(0, milliseconds / 1000)
        }
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
    static func cloudTranscribe(_ url: URL, key: String, prompt: String? = nil) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        var fields = [("model", "gpt-4o-transcribe"), ("language", "ja")]
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }
        for (name, value) in fields {
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
}
struct CloudFailure: LocalizedError {
    var code: Int
    var message: String?
    var retryAfter: TimeInterval?
    var errorDescription: String? {
        "クラウドAPIエラー (\(code))\(message.map { ": " + $0 } ?? "")。APIキー・利用上限・モデル設定を確認してください。"
    }
}
// What the transcription model is told besides the audio: how this meeting spells its names and terms, and the
// words just before the chunk, so a sentence carries on across chunks. The prompt is not speech, so text that only
// repeats it is removed from the result.
struct TranscriptionHints: Sendable, Equatable {
    var title = ""
    var agenda: [String] = []
    var terms: [String] = []
    var preceding = ""
    static let precedingLength = 200
    init(title: String = "", agenda: [String] = [], terms: [String] = [], preceding: String = "") {
        self.title = title
        self.agenda = agenda
        self.terms = terms
        self.preceding = Self.tail(preceding)
    }
    /// Hints for the chunk of a meeting that starts at `offset`: the title unless it is the automatic one, the
    /// agenda, the user's terms, and the end of the transcript so far.
    init(meeting: Meeting, before offset: Double, vocabulary: String) {
        self.init(
            title: isUntitledMeeting(meeting.title) ? "" : meeting.title, agenda: meeting.agenda.map(\.title),
            terms: Self.terms(vocabulary),
            preceding: meeting.segments.filter { $0.time < offset }.suffix(8).map(\.text).joined())
    }
    /// The terms in the user's vocabulary, one per line or separated by commas.
    static func terms(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.components(separatedBy: CharacterSet(charactersIn: "\n,、，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func tail(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(precedingLength))
    }
    /// Lists items up to a length, so a long vocabulary cannot crowd out the rest of the prompt.
    private static func list(_ items: [String], limit: Int) -> String {
        var result = ""
        for item in items {
            let next = result.isEmpty ? item : result + "、" + item
            if next.count > limit { break }
            result = next
        }
        return result
    }
    var prompt: String {
        var lines = ["日本語の会議の文字起こしです。話したとおりに書き起こしてください。"]
        if !title.isEmpty || !agenda.isEmpty || !terms.isEmpty {
            lines[0] += "固有名詞・製品名・略語は、次の表記に合わせてください。"
        }
        if !title.isEmpty { lines.append("会議名: " + String(title.prefix(100))) }
        if !agenda.isEmpty { lines.append("議題: " + Self.list(agenda, limit: 300)) }
        if !terms.isEmpty { lines.append("用語: " + Self.list(terms, limit: 600)) }
        if !preceding.isEmpty { lines.append("直前の発言: " + preceding) }
        return lines.joined(separator: "\n")
    }
    /// The transcript without text that only repeats the prompt. Given a prompt, the model sometimes returns part of
    /// it for audio with little speech, or repeats the end of the preceding speech before the new words.
    func removingEcho(from text: String) -> String {
        let prompt = self.prompt
        let lines = Set(prompt.components(separatedBy: "\n"))
        var result = text.components(separatedBy: .newlines)
            .filter { !lines.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // The end of the preceding speech repeated before new words.
        let longest = min(preceding.count, result.count - 1)
        if longest >= 8, let overlap = (8...longest).reversed().first(where: { preceding.hasSuffix(result.prefix($0)) })
        {
            result = String(result.dropFirst(overlap)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Nothing but a piece of the prompt. From the preceding speech only a whole sentence counts: stock phrases
        // such as "ありがとうございます。" (11 characters) really are said again, by the next person.
        let names = TranscriptionHints(title: title, agenda: agenda, terms: terms).prompt
        if result.count >= 8 && names.contains(result) || result.count >= 12 && preceding.contains(result) { return "" }
        return result
    }
}
// One file to listen back to: the Mac audio and microphone tracks mixed on the common recording clock.
enum AudioMixdown {
    static let filename = "録音.m4a"
    static func write(folder: URL) async throws {
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        let inputs = try Processor.recordingInputs(folder: folder, allowMissing: true).filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        for input in inputs {
            // A chunk cut short by a forced quit may be unreadable; mix the rest instead of giving up.
            let asset = AVURLAsset(url: input.url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration), duration > .zero
            else { continue }
            guard
                let track = tracks[input.source]
                    ?? composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            tracks[input.source] = track
            // Keep silence before and between chunks; a chunk never moves earlier than the end of the previous one.
            // An empty track cannot take a leading gap, so its first chunk goes in first and the gap is inserted before it.
            let range = CMTimeRange(start: .zero, duration: duration)
            let start = CMTime(seconds: input.offset, preferredTimescale: 48_000)
            if track.segments.isEmpty {
                guard (try? track.insertTimeRange(range, of: source, at: .zero)) != nil else { continue }
                if start > .zero { track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: start)) }
            } else {
                let end = track.timeRange.end
                if start > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: start)) }
                try? track.insertTimeRange(range, of: source, at: max(start, end))
            }
        }
        guard !tracks.isEmpty, composition.duration > .zero else { return }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError.message("録音ファイルを作成できません。")
        }
        let output = folder.appendingPathComponent(filename)
        let temporary = folder.appendingPathComponent(".録音-\(UUID().uuidString).m4a")
        try await session.export(to: temporary, as: .m4a)
        _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    }
}
// Minutes from a recording made elsewhere: any audio or video file is decoded to 16 kHz mono and cut at pauses like
// a live recording, so it goes through the same transcription queue, retries and recovery as a live meeting.
enum AudioImport {
    static let source = "録音ファイル"
    static let sampleRate = 16_000.0
    static func split(_ input: URL, into folder: URL) async throws -> [RecordedChunk] {
        let asset = AVURLAsset(url: input)
        // Every audio track is mixed, so a recording with each side on its own track keeps both voices.
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw AppError.message("このファイルには音声が含まれていません。")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        guard reader.canAdd(output),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw AppError.message("録音ファイルを読み込めませんでした。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError.message("録音ファイルを読み込めませんでした。") }
        let chunksFolder = folder.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunksFolder, withIntermediateDirectories: true)
        let slice = Int(sampleRate / 20)  // 50 ms at a time, so a chunk can end inside a short pause.
        var cutter = ChunkCutter()
        var chunks: [RecordedChunk] = []
        var file: AVAudioFile?
        var total = 0
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var start = 0
            while start < count {
                if file == nil {
                    let name = String(format: "import-%04d.caf", chunks.count + 1)
                    file = try AVAudioFile(
                        forWriting: chunksFolder.appendingPathComponent(name),
                        settings: Recorder.compactSettings(format),
                        commonFormat: .pcmFormatFloat32, interleaved: false)
                    chunks.append(RecordedChunk(filename: name, offset: Double(total) / sampleRate, source: source))
                    cutter.begin()
                }
                let take = min(count - start, slice)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(take)),
                    let channel = buffer.floatChannelData?[0],
                    CMBlockBufferCopyDataBytes(
                        block, atOffset: start * MemoryLayout<Float>.size, dataLength: take * MemoryLayout<Float>.size,
                        destination: channel) == kCMBlockBufferNoErr
                else { throw AppError.message("録音ファイルの音声を取り出せませんでした。") }
                buffer.frameLength = AVAudioFrameCount(take)
                try file?.write(from: buffer)
                start += take
                total += take
                if cutter.add(level: ChunkCutter.level(buffer) ?? 1, seconds: Double(take) / sampleRate) {
                    file = nil  // Closes the chunk.
                }
            }
        }
        file = nil
        guard reader.status == .completed else {
            throw reader.error ?? AppError.message("録音ファイルを最後まで読み込めませんでした。")
        }
        guard !chunks.isEmpty else { throw AppError.message("このファイルには音声が含まれていません。") }
        try JSONEncoder().encode(RecordingManifest(chunks: chunks)).write(
            to: folder.appendingPathComponent("recording.json"), options: .atomic)
        return chunks
    }
}

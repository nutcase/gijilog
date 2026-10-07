import AVFoundation
import Foundation

extension ProcessingTests {
    /// Feeds levels to a cutter in 50 ms steps, as a recording would, and returns where the chunk ends.
    private func cut(_ parts: [(level: Float, seconds: Double)]) -> Double? {
        var cutter = ChunkCutter()
        cutter.begin()
        var time = 0.0
        for part in parts {
            for _ in 0..<Int((part.seconds / 0.05).rounded()) {
                time += 0.05
                if cutter.add(level: part.level, seconds: 0.05) { return time }
            }
        }
        return nil
    }
    func testChunkCutterEndsAtPauses() throws {
        let quietRoom = cut([(0.001, 1), (0.1, 11), (0.001, 1)])
        try Self.check(
            quietRoom.map { (12.25...12.4).contains($0) } == true,
            "a chunk ends 0.3 s into the first pause after 10 s: \(String(describing: quietRoom))")
        let early = cut([(0.001, 1), (0.1, 4), (0.001, 0.5), (0.1, 30)])
        try Self.check(
            early.map { abs($0 - ChunkCutter.maximum) < 0.06 } == true,
            "a pause before 10 s does not end the chunk, and talk without pauses ends at the limit")
        let noisyRoom = cut([(0.01, 1), (0.08, 11), (0.012, 1)])
        try Self.check(
            noisyRoom.map { (12.25...12.4).contains($0) } == true,
            "a pause is found over the background noise of the room: \(String(describing: noisyRoom))")
        let softVoice = cut([(0.001, 1), (0.01, 30)])
        try Self.check(
            softVoice.map { abs($0 - ChunkCutter.maximum) < 0.06 } == true,
            "a soft voice in a quiet room is speech, not a pause")
    }
    func testOnlyVoiceIsSent() throws {
        let format = try Self.require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1), "gate format")
        // Ten seconds of a quiet room, with a quiet voice (or a steady loud sound) for the given seconds.
        func voiced(_ seconds: Double, amplitude: Float) throws -> Double {
            let buffer = try Self.require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000), "gate buffer")
            buffer.frameLength = 160_000
            let samples = try Self.require(buffer.floatChannelData, "gate samples")[0]
            for frame in 0..<160_000 {
                let voice = Double(frame) / 16000 < seconds ? amplitude * sin(Float(frame) * 0.17) : 0
                samples[frame] = voice + 0.0003 * sin(Float(frame) * 2.3)
            }
            return Processor.voicedSeconds(buffer)
        }
        let room = try voiced(0, amplitude: 0)
        let voice = try voiced(1, amplitude: 0.012)
        let steady = try voiced(10, amplitude: 0.25)
        try Self.check(room == 0, "room noise is not a voice: \(room)")
        try Self.check(
            abs(voice - 1) < 0.1 && voice >= Processor.minimumVoice, "a second of quiet voice is sent: \(voice)")
        try Self.check(steady > 9.9, "a voice that never pauses is still a voice: \(steady)")
        try Self.check(
            !Processor.containsJapanese("Hallo zusammen.") && !Processor.containsJapanese("OK")
                && Processor.containsJapanese("グラフAPIで。") && Processor.containsJapanese("ｿｳﾃﾞｽﾈ")
                && Processor.containsJapanese("了解"),
            "text without Japanese is told apart from Japanese with English words in it")
    }
    func testTranscriptionHints() throws {
        var meeting = Meeting(title: "週次定例")
        meeting.agenda = MeetingAgenda.parse("リリース範囲\n問い合わせ対応")
        meeting.segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "A案にしましょう。"),
            Segment(id: "b", time: 30, source: "Mac音声", text: "では次に。"),
        ]
        let hints = TranscriptionHints(meeting: meeting, before: 30, vocabulary: "ギジログ\nOpenAI、MCP, ギジログ\n\n")
        try Self.check(
            hints.terms == ["ギジログ", "OpenAI", "MCP"] && hints.preceding == "A案にしましょう。",
            "terms are split and deduplicated, and only speech before the chunk is context")
        let prompt = hints.prompt
        try Self.check(
            prompt.contains("会議名: 週次定例") && prompt.contains("議題: リリース範囲、問い合わせ対応")
                && !prompt.contains("ギジログ") && prompt.contains("直前の発言: A案にしましょう。")
                && hints.keywords == ["ギジログ", "OpenAI", "MCP"],
            "the prompt carries the meeting's own names and the speech just before, the terms are keywords:\n\(prompt)")
        let read = TranscriptionHints(
            terms: ["AIQ（アイキュー）", "Moribus(モリバス)", "<b>太字</b>", "（注）", String(repeating: "長", count: 41)])
        try Self.check(
            read.keywords == ["AIQ", "Moribus", "b太字/b", "（注）"]
                && read.prompt.contains("読み方: AIQ（アイキュー）、Moribus(モリバス)") && read.prompt.contains("固有名詞"),
            "a term's reading goes in the prompt, and a keyword has no angle brackets and is no sentence: \(read.keywords)"
        )
        try Self.check(
            TranscriptionHints(terms: (1...150).map { "語\($0)" }).keywords.count == TranscriptionHints.keywordCount,
            "a long list keeps its first terms")
        var untitled = Meeting(title: "会議 2026/10/05 13:00")
        untitled.segments = [Segment(id: "a", time: 0, source: "マイク", text: String(repeating: "あ", count: 500))]
        let plain = TranscriptionHints(meeting: untitled, before: 60, vocabulary: "")
        try Self.check(
            !plain.prompt.contains("会議名") && !plain.prompt.contains("固有名詞")
                && plain.preceding.count == TranscriptionHints.precedingLength,
            "an automatic title is no hint, and the preceding speech is bounded")
        try Self.check(
            hints.removingEcho(from: "会議名: 週次定例").isEmpty
                && hints.removingEcho(from: "ギジログ、OpenAI、MCP").isEmpty,
            "text that only repeats the prompt is dropped")
        try Self.check(
            hints.removingEcho(from: "A案にしましょう。B案も検討します") == "B案も検討します",
            "the end of the preceding speech repeated at the start is removed")
        try Self.check(
            hints.removingEcho(from: "ギジログのMCPを使います") == "ギジログのMCPを使います"
                && hints.removingEcho(from: "はい") == "はい",
            "real speech, even with the vocabulary's words or very short, is kept")
        // Both seen at the end of a real meeting's re-transcription: a quiet stretch came back as a sentence from a
        // minute before, and a second person's thanks repeated the first's.
        let earlier = TranscriptionHints(preceding: "人生にはいろいろな謎がある。まさかの魔球フォーク。ありがとうございます。")
        try Self.check(
            earlier.removingEcho(from: "人生にはいろいろな謎がある。").isEmpty
                && earlier.removingEcho(from: "ありがとうございます。") == "ありがとうございます。",
            "a sentence echoed from the preceding speech is dropped, a stock phrase said again is kept")
    }
    func testTranscriptionRequestCarriesHints() async throws {
        let (folder, url) = try fixture(seconds: 1, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.check(URLProtocol.registerClass(MockCloudProtocol.self), "register mock transport")
        defer { URLProtocol.unregisterClass(MockCloudProtocol.self) }
        MockCloudProtocol.reset()
        let hints = TranscriptionHints(terms: ["ギジログ"], preceding: "前の発言です。")
        let segments = try await Processor.recognizeChunk(url, offset: 0, source: "マイク", key: "TEST", hints: hints)
        let body = MockCloudProtocol.lastBody
        func field(_ name: String, _ value: String) -> Bool {
            body.contains("name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        try Self.check(
            segments.map(\.text) == ["確認します"] && field("model", "gpt-transcribe") && field("languages[]", "ja")
                && !body.contains("name=\"language\"") && field("keywords[]", "ギジログ")
                && body.contains("name=\"prompt\"") && body.contains("直前の発言: 前の発言です。"),
            "the transcription request asks gpt-transcribe for Japanese, with the terms as keywords:\n\(body)")
    }
}

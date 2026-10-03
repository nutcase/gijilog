import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "gijilog.audio")
    private var stream: SCStream?
    private var acceptingSamples = false
    private var isStopping = false
    private var manifest = RecordingManifest()
    private let stopCaptureOperation: (SCStream?) async throws -> Void
    init(
        stopCapture: @escaping (SCStream?) async throws -> Void = { stream in
            if let stream { try await stream.stopCapture() }
        }
    ) {
        stopCaptureOperation = stopCapture
        super.init()
    }
    private var folder: URL?
    private var chunkFiles: [SCStreamOutputType: AVAudioFile] = [:]
    private var chunkURLs: [SCStreamOutputType: URL] = [:]
    private var chunkStarts: [SCStreamOutputType: Double] = [:]
    private var chunkFrames: [SCStreamOutputType: Int64] = [:]
    private var origin: Double?
    private var expectedNextTime: [SCStreamOutputType: Double] = [:]
    var onChunk: (@Sendable (URL, Double, String) async -> Void)?
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var watchdog: DispatchSourceTimer?
    private var lastMicrophoneInput = Date()
    private var notifiedMissingInput = false
    private var lastMeterUpdate: [SCStreamOutputType: Date] = [:]
    private var cancelledStart = false
    var onError: ((String) -> Void)?
    var onLevel: ((String, Float) -> Void)?  // Track name ("Mac音声" or "マイク") and peak level.
    func start(folder: URL, microphone: String?) async throws {
        queue.sync { cancelledStart = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppError.message("マイクの使用を許可してください。") }
        try checkStarting()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try checkStarting()
        guard let display = content.displays.first else { throw AppError.message("録音対象のディスプレイがありません。") }
        try prepareFiles(in: folder)
        do {
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphone
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            let capture = SCStream(
                filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                configuration: config, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            try queue.sync {
                guard !cancelledStart else { throw CancellationError() }
                stream = capture
            }
            try await capture.startCapture()
            try checkStarting()
            queue.sync {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 15, repeating: 5)
                timer.setEventHandler { [weak self] in self?.checkInputOnQueue(now: Date()) }
                watchdog = timer
                timer.resume()
            }
        } catch {
            try? await stop()
            throw error
        }
    }
    func prepareFiles(in folder: URL) throws {
        try queue.sync {
            guard !cancelledStart else { throw CancellationError() }
            guard !isStopping, !acceptingSamples, stream == nil, chunkFiles.isEmpty else {
                throw AppError.message("前の録音の停止処理が完了していません。")
            }
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
            let manifest = RecordingManifest()
            try JSONEncoder().encode(manifest).write(
                to: folder.appendingPathComponent("recording.json"), options: .atomic)
            self.folder = folder
            self.origin = nil
            self.manifest = manifest
            self.lastMicrophoneInput = Date()
            self.notifiedMissingInput = false
            self.chunkStarts.removeAll()
            self.chunkFrames.removeAll()
            self.chunkURLs.removeAll()
            self.expectedNextTime.removeAll()
            acceptingSamples = true
        }
    }
    func cancelPendingStart() { queue.sync { cancelledStart = true } }
    private func checkStarting() throws {
        try queue.sync { if cancelledStart { throw CancellationError() } }
    }
    func stop() async throws {
        let capture: SCStream? = try queue.sync {
            guard !isStopping else { throw AppError.message("録音の停止処理中です。") }
            isStopping = true
            acceptingSamples = false
            watchdog?.cancel()
            watchdog = nil
            let capture = stream
            stream = nil
            return capture
        }
        var stopError: Error?
        do { try await stopCaptureOperation(capture) } catch { stopError = error }
        // Always close writers and deliver the tail, including when stopCapture fails.
        let pending: [Task<Void, Never>] = await withCheckedContinuation { continuation in
            queue.async {
                for type in Array(self.chunkFiles.keys) { self.finishChunk(type) }
                self.chunkFiles.removeAll()
                self.chunkURLs.removeAll()
                self.chunkStarts.removeAll()
                self.chunkFrames.removeAll()
                self.folder = nil
                self.origin = nil
                self.manifest = RecordingManifest()
                self.expectedNextTime.removeAll()
                let pending = Array(self.deliveries.values)
                self.deliveries.removeAll()
                continuation.resume(returning: pending)
            }
        }
        for task in pending { await task.value }
        queue.sync { isStopping = false }
        if let stopError { throw stopError }
    }
    private func finishChunk(_ type: SCStreamOutputType) {
        guard let url = chunkURLs[type], let offset = chunkStarts[type] else { return }
        chunkFiles.removeValue(forKey: type)  // Close the file before handing it to recognition.
        chunkURLs.removeValue(forKey: type)
        chunkStarts.removeValue(forKey: type)
        chunkFrames.removeValue(forKey: type)
        if let callback = onChunk {
            let source = type == .audio ? "Mac音声" : "マイク"
            let id = UUID()
            deliveries[id] = Task { [weak self] in
                await callback(url, offset, source)
                self?.queue.async { [weak self] in self?.deliveries.removeValue(forKey: id) }
            }
        }
    }
    // 16-bit PCM halves the float capture format, and CAF stays readable after a forced quit.
    static func compactSettings(_ format: AVAudioFormat) -> [String: Any] {
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        return settings
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream, self.acceptingSamples else { return }
            self.onError?(error.localizedDescription)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // ScreenCaptureKit delivers this callback on the serial sampleHandlerQueue.
        guard self.stream === stream else { return }
        consumeOnQueue(sample, of: type)
    }
    func consume(_ sample: CMSampleBuffer, of type: SCStreamOutputType) {
        queue.sync { consumeOnQueue(sample, of: type) }
    }
    func checkInput(now: Date) { queue.sync { checkInputOnQueue(now: now) } }
    private func checkInputOnQueue(now: Date) {
        guard acceptingSamples, !notifiedMissingInput, now.timeIntervalSince(lastMicrophoneInput) > 15 else { return }
        notifiedMissingInput = true
        onError?("マイク音声の入力が途絶えました。保存済み音声を保持して録音を停止します。マイクと権限を確認してください。")
    }
    private func consumeOnQueue(_ sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard acceptingSamples, sample.isValid, let folder, let description = CMSampleBufferGetFormatDescription(sample)
        else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        var block: CMBlockBuffer?
        var size = 0
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
        else { return }
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        let list = pointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
                == noErr,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list), buffer.frameLength > 0
        else { return }
        do {
            if type == .microphone {
                lastMicrophoneInput = Date()
                notifiedMissingInput = false
            }
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard timestamp.isFinite else { throw AppError.message("録音音声の時刻が不正です。") }
            if let expected = expectedNextTime[type], abs(timestamp - expected) > 0.1 {
                finishChunk(type)  // Preserve capture gaps instead of compressing the timeline.
            }
            expectedNextTime[type] = timestamp + Double(buffer.frameLength) / format.sampleRate
            if let file = chunkFiles[type], !file.processingFormat.isEqual(format) {
                finishChunk(type)  // A device switched format: the next chunk takes the new one.
            }
            if origin == nil { origin = timestamp }
            // The chunks are the recording: there is no separate full-length copy of each track.
            if chunkFiles[type] == nil {
                let url = folder.appendingPathComponent("chunks").appendingPathComponent(UUID().uuidString + ".caf")
                chunkFiles[type] = try AVAudioFile(
                    forWriting: url, settings: Self.compactSettings(format), commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved)
                let offset = max(0, timestamp - (origin ?? timestamp))
                chunkURLs[type] = url
                chunkStarts[type] = offset
                chunkFrames[type] = 0
                let source = type == .audio ? "Mac音声" : "マイク"
                let track = type == .audio ? "system.caf" : "microphone.caf"
                if manifest.trackStarts[track] == nil { manifest.trackStarts[track] = offset }
                manifest.chunks.append(RecordedChunk(filename: url.lastPathComponent, offset: offset, source: source))
                try JSONEncoder().encode(manifest).write(
                    to: folder.appendingPathComponent("recording.json"), options: .atomic)
            }
            try chunkFiles[type]?.write(from: buffer)
            chunkFrames[type, default: 0] += Int64(buffer.frameLength)
            if Double(chunkFrames[type, default: 0]) / format.sampleRate >= 12 { finishChunk(type) }
            if let samples = buffer.floatChannelData?[0],
                Date().timeIntervalSince(lastMeterUpdate[type] ?? .distantPast) >= 0.1
            {
                lastMeterUpdate[type] = Date()
                var peak: Float = 0
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
                onLevel?(type == .audio ? "Mac音声" : "マイク", peak)
            }
        } catch { onError?(error.localizedDescription) }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

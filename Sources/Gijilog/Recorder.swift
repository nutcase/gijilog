import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// Records the Mac's audio output and the microphone as two tracks on one clock, cut into ~12-second chunks.
// Mac audio comes from a Core Audio process tap, which needs only the "System Audio Recording Only" permission
// (not screen recording); the microphone comes from AVCaptureSession. Both are converted to 16 kHz mono.
final class Recorder: NSObject, @unchecked Sendable {
    enum Track: Hashable { case audio, microphone }
    private let queue = DispatchQueue(label: "gijilog.audio")
    private var capture: CaptureSession?
    private var acceptingSamples = false
    private var isStopping = false
    private var manifest = RecordingManifest()
    private let stopCaptureOperation: (CaptureSession?) async throws -> Void
    init(stopCapture: @escaping (CaptureSession?) async throws -> Void = { $0?.stop() }) {
        stopCaptureOperation = stopCapture
        super.init()
    }
    private var folder: URL?
    private var chunkFiles: [Track: AVAudioFile] = [:]
    private var chunkURLs: [Track: URL] = [:]
    private var chunkStarts: [Track: Double] = [:]
    private var chunkFrames: [Track: Int64] = [:]
    private var origin: Double?
    private var expectedNextTime: [Track: Double] = [:]
    var onChunk: (@Sendable (URL, Double, String) async -> Void)?
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var watchdog: DispatchSourceTimer?
    private var lastMicrophoneInput = Date()
    private var notifiedMissingInput = false
    private var lastMeterUpdate: [Track: Date] = [:]
    private var cancelledStart = false
    var onError: ((String) -> Void)?
    var onLevel: ((String, Float) -> Void)?  // Track name ("Mac音声" or "マイク") and peak level.
    func start(folder: URL, microphone: String?) async throws {
        queue.sync { cancelledStart = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppError.message("マイクの使用を許可してください。") }
        try checkStarting()
        try prepareFiles(in: folder)
        do {
            let capture = CaptureSession()
            try queue.sync {
                guard !cancelledStart else { throw CancellationError() }
                self.capture = capture
            }
            try capture.start(
                microphone: microphone, queue: queue,
                system: { [weak self, weak capture] buffer, time in
                    guard let self else { return }
                    let handoff = Handoff(buffer: buffer)
                    self.queue.async {
                        guard let capture, self.capture === capture else { return }
                        self.appendOnQueue(handoff.buffer, at: time, to: .audio)
                    }
                },
                microphone: { [weak self, weak capture] sample, time in
                    // Delivered on the recorder's queue.
                    guard let self, let capture, self.capture === capture else { return }
                    self.consumeOnQueue(sample, of: .microphone, at: time)
                },
                failed: { [weak self, weak capture] message in
                    guard let self else { return }
                    self.queue.async {
                        guard let capture, self.capture === capture, self.acceptingSamples else { return }
                        self.onError?(message)
                    }
                })
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
            guard !isStopping, !acceptingSamples, capture == nil, chunkFiles.isEmpty else {
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
        let capture: CaptureSession? = try queue.sync {
            guard !isStopping else { throw AppError.message("録音の停止処理中です。") }
            isStopping = true
            acceptingSamples = false
            watchdog?.cancel()
            watchdog = nil
            let capture = self.capture
            self.capture = nil
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
    private func finishChunk(_ type: Track) {
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
    func consume(_ sample: CMSampleBuffer, of type: Track) {
        queue.sync { consumeOnQueue(sample, of: type) }
    }
    func checkInput(now: Date) { queue.sync { checkInputOnQueue(now: now) } }
    private func checkInputOnQueue(now: Date) {
        guard acceptingSamples, !notifiedMissingInput, now.timeIntervalSince(lastMicrophoneInput) > 15 else { return }
        notifiedMissingInput = true
        onError?("マイク音声の入力が途絶えました。保存済み音声を保持して録音を停止します。マイクと権限を確認してください。")
    }
    private func consumeOnQueue(_ sample: CMSampleBuffer, of type: Track, at time: Double? = nil) {
        guard acceptingSamples, sample.isValid, let description = CMSampleBufferGetFormatDescription(sample)
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
            let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list)
        else { return }
        appendOnQueue(buffer, at: time ?? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), to: type)
    }
    // Times are host-clock seconds for both tracks, so they share one timeline.
    private func appendOnQueue(_ buffer: AVAudioPCMBuffer, at timestamp: Double, to type: Track) {
        guard acceptingSamples, let folder, buffer.frameLength > 0 else { return }
        let format = buffer.format
        do {
            if type == .microphone {
                lastMicrophoneInput = Date()
                notifiedMissingInput = false
            }
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
// A converted buffer the tap allocated for this call and never touches again, moving to the recorder's queue.
private struct Handoff: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
// One recording's capture: the Mac audio tap and the microphone, started and stopped together.
final class CaptureSession: @unchecked Sendable {
    private let tap = SystemAudioTap()
    private var microphone: MicrophoneCapture?
    func start(
        microphone id: String?, queue: DispatchQueue, system: @escaping (AVAudioPCMBuffer, Double) -> Void,
        microphone deliver: @escaping (CMSampleBuffer, Double) -> Void, failed: @escaping (String) -> Void
    ) throws {
        let microphone = try MicrophoneCapture(deviceID: id, queue: queue, deliver: deliver, failed: failed)
        self.microphone = microphone
        try tap.start(deliver: system)
        microphone.start()
    }
    func stop() {
        microphone?.stop()
        tap.stop()
    }
}
// 16 kHz mono is all transcription needs, and keeps the working audio small.
private let captureFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

// What every other app plays, through a Core Audio process tap on a private aggregate device. Needs only the
// "System Audio Recording Only" permission (NSAudioCaptureUsageDescription); this app's own output is excluded.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "gijilog.tap", qos: .userInitiated)
    private static let permissionHint =
        "システム設定の「プライバシーとセキュリティ」→「画面とシステムオーディオの録音」の「システムオーディオ録音のみ」でギジログを許可してください。"
    func start(deliver: @escaping (AVAudioPCMBuffer, Double) -> Void) throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "ギジログ"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "Macの音声を取り込めませんでした。")
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream), "Macの音声の形式を読めませんでした。")
        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ギジログ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Macの音声の取り込みを準備できませんでした。")
        // The tap reports 48 kHz, but the aggregate device delivers at its main device's rate (44.1 kHz on
        // MacBook speakers, for example). Converting from the wrong rate made 12 seconds of audio cover 13.
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &rate) == noErr, rate > 0 {
            stream.mSampleRate = rate
        }
        guard let tapFormat = AVAudioFormat(streamDescription: &stream), let captureFormat,
            let converter = AVAudioConverter(from: tapFormat, to: captureFormat)
        else { throw AppError.message("Macの音声を16kHzに変換できません。") }
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
                // The input is only valid during this call: convert it into a buffer of our own right away.
                guard
                    let source = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                    source.frameLength > 0,
                    let converted = AVAudioPCMBuffer(
                        pcmFormat: captureFormat,
                        frameCapacity: AVAudioFrameCount(
                            (Double(source.frameLength) * captureFormat.sampleRate / tapFormat.sampleRate).rounded(.up))
                            + 64)
                else { return }
                var supplied = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied {
                        status.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    status.pointee = .haveData
                    return source
                }
                guard error == nil, converted.frameLength > 0 else { return }
                let time = inputTime.pointee
                let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : AudioGetCurrentHostTime()
                deliver(converted, Double(AudioConvertHostTimeToNanos(host)) / 1_000_000_000)
            }, "Macの音声の取り込みを準備できませんでした。")
        try Self.check(AudioDeviceStart(aggregateID, procID), "Macの音声の取り込みを開始できませんでした。")
    }
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    private static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw AppError.message("\(message)（\(status)）\(permissionHint)") }
    }
    private static func ownProcess() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
    // The aggregate device runs on the clock of the output the user is listening to.
    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            "音声の出力先が見つかりません。")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "音声の出力先が見つかりません。")
        guard let uid = uid?.takeRetainedValue() as String? else { throw AppError.message("音声の出力先が見つかりません。") }
        return uid
    }
}
// The microphone chosen in Settings (or the system default), delivered as 16 kHz mono on the recorder's queue.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let deliver: (CMSampleBuffer, Double) -> Void
    private var observer: NSObjectProtocol?
    init(
        deviceID: String?, queue: DispatchQueue, deliver: @escaping (CMSampleBuffer, Double) -> Void,
        failed: @escaping (String) -> Void
    ) throws {
        self.deliver = deliver
        super.init()
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio)
        else { throw AppError.message("録音に使うマイクが見つかりません。") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AppError.message("マイク（\(device.localizedName)）から録音できません。")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            failed("マイクの録音が止まりました。" + (error?.localizedDescription ?? ""))
        }
    }
    func start() { session.startRunning() }
    func stop() {
        session.stopRunning()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    // Timestamps move to the host clock, the clock the Mac audio tap reports, so both tracks line up.
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        var time = CMSampleBufferGetPresentationTimeStamp(sample)
        if let clock = session.synchronizationClock {
            time = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
        }
        deliver(sample, CMTimeGetSeconds(time))
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

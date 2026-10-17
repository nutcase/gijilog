import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

// Recording: starting, continuing and stopping a meeting's capture.
extension Store {
    /// Records the selected prepared meeting, or a new one. `newMeeting` always starts a new one.
    func start(newMeeting forcesNew: Bool = false) async {
        guard canStartRecording() else { return }
        busy = true
        pendingCaptureError = nil
        defer { busy = false }
        // A prepared meeting that is selected is the one recorded, with its title, tags and agenda.
        let planned = forcesNew ? nil : selectedMeeting(where: { $0.capture == .planned })
        let id: UUID
        if let planned {
            id = planned.id
            claim(id)  // A meeting prepared on another Mac is recorded here, and its unfinished work is this Mac's.
            change(id) { meeting in
                meeting.capture = .recording
                meeting.date = Date()
                meeting.settings = settings
                meeting.finalReviewPending = true
                meeting.status = "録音中"
            }
        } else {
            let meeting = newMeeting(capture: .recording)
            id = meeting.id
            meetings.insert(meeting, at: 0)
        }
        await record(id) { meeting in
            if let planned {
                // Still prepared: the agenda waits for the next try.
                meeting.capture = .planned
                meeting.date = planned.date
                meeting.settings = nil
                meeting.finalReviewPending = nil
                meeting.status = "準備中"
                meeting.agenda = planned.agenda
            } else {
                meeting.capture = .interrupted
                meeting.status = "録音開始失敗"
            }
        }
    }
    /// A finished meeting can take more recording once nothing is processing it.
    func canContinueRecording(_ meeting: Meeting) -> Bool {
        (meeting.capture == .stopped || meeting.capture == .interrupted) && meeting.id != activeID
            && !isProcessing(meeting.id) && !preparingIDs.contains(meeting.id)
    }
    /// Records more of a finished meeting, such as after a break: the new speech follows the earlier recording on
    /// the meeting's clock, the transcript and minutes grow, and stopping makes one 録音.m4a and reviews the whole
    /// meeting again.
    func continueRecording(_ id: UUID) async {
        guard canStartRecording(), let before = meetings.first(where: { $0.id == id }), canContinueRecording(before)
        else { return }
        busy = true
        pendingCaptureError = nil
        defer { busy = false }
        let base: Double
        do { base = try await prepareContinuation(id) } catch {
            self.error = error.localizedDescription
            return
        }
        change(id) { meeting in
            meeting.capture = .recording
            meeting.status = "録音中"
            meeting.settings = settings
            meeting.finalReviewPending = true
            meeting.notes?.reviewedSegmentIDs = nil
            meeting.notes?.finalizedAt = nil
            meeting.captureError = nil
            meeting.clockStart = Date().addingTimeInterval(-base)
        }
        await record(id, continuingAt: base) { meeting in
            meeting.capture = before.capture
            meeting.status = before.status
            meeting.settings = before.settings
            meeting.finalReviewPending = before.finalReviewPending
            meeting.notes?.reviewedSegmentIDs = before.notes?.reviewedSegmentIDs
            meeting.notes?.finalizedAt = before.notes?.finalizedAt
            meeting.clockStart = before.clockStart
        }
    }
    /// Gets a finished meeting ready to record more and returns where the new part starts on its clock. Its earlier
    /// audio has to stay in the working audio, so that 録音.m4a can be made again with both parts: when it was
    /// cleaned up, 録音.m4a is cut into chunks again, marked as transcribed already.
    func prepareContinuation(_ id: UUID) async throws -> Double {
        let folder = folder(id)
        if try await Task.detached(operation: { try Self.workingAudioMissing(folder) }).value {
            let mix = folder.appendingPathComponent(AudioMixdown.filename)
            guard FileManager.default.fileExists(atPath: mix.path) else {
                throw AppError.message("この会議の録音（録音.m4a）が見つからないため、続けて録音できません。")
            }
            let chunks = try await Task.detached {
                WorkingAudio.remove(in: folder)
                return try await AudioImport.split(mix, into: folder)
            }.value
            change(id) { meeting in
                for chunk in chunks {
                    let relative = "chunks/" + chunk.filename
                    meeting.jobs.removeAll { $0.filename == relative }
                    meeting.jobs.append(
                        TranscriptionJob(
                            id: stableID(relative), filename: relative, offset: chunk.offset, source: chunk.source,
                            state: .completed))
                }
            }
        }
        let length = try await Task.detached { try Processor.recordedLength(folder: folder) }.value
        let lastSpeech = meetings.first { $0.id == id }?.segments.map(\.time).max() ?? 0
        return max(length, lastSpeech + 1)
    }
    private func canStartRecording() -> Bool {
        guard ready, !recording, !busy, !shuttingDown else { return false }
        guard hasKey else {
            error = "録音するには、設定でOpenAI APIキーを保存してください。"
            return false
        }
        if !microphone.isEmpty && AVCaptureDevice(uniqueID: microphone) == nil {
            error = "設定で選んだマイクが見つかりません。接続を確認するか、設定でマイクを選び直してください。"
            return false
        }
        return true
    }
    /// Starts capturing into a meeting already marked as recording; on failure, `revert` puts the meeting back.
    private func record(_ id: UUID, continuingAt base: Double? = nil, revert: (inout Meeting) -> Void) async {
        showNewMeeting()
        selected = id
        activeID = id
        captureInputID = microphone.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : microphone
        claim(id)
        do {
            try await checkpoint(id)
            pipeline.resume(id, key: key)
            try await recorder.start(
                folder: folder(id), microphone: microphone.isEmpty ? nil : microphone, continuingAt: base)
            recording = true
            status = "録音中 — Mac音声＋マイク"
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "会議音声を録音中")
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateLiveSummary() }
            }
            summaryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            lastSoundAt = Date()
            change(id) { $0.stoppedForSilence = nil }
            let silence = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.stopIfSilent() }
            }
            silenceTimer = silence
            RunLoop.main.add(silence, forMode: .common)
            if shuttingDown || pendingCaptureError != nil {
                busy = false
                if let message = pendingCaptureError { await interrupt(message) } else { await stop() }
            }
        } catch {
            change(id) { meeting in
                revert(&meeting)
                meeting.captureError = error.localizedDescription
            }
            activeID = nil
            captureInputID = nil
            self.error = error.localizedDescription
            try? await checkpoint(id)
        }
    }
    private func selectedMeeting(where condition: (Meeting) -> Bool) -> Meeting? {
        meetings.first { $0.id == selected && condition($0) }
    }
    /// A meeting titled by the time, in a new folder. Its title is changed by clicking it.
    func newMeeting(capture: CaptureState) -> Meeting {
        var meeting = Meeting(title: "会議 \(Date().formatted(date: .numeric, time: .shortened))")
        meeting.capture = capture
        meeting.workingMac = thisMac
        if capture == .planned {
            meeting.status = "準備中"
        } else {
            meeting.settings = settings
            meeting.finalReviewPending = true
        }
        meeting.folderName =
            MeetingRepository.uniqueFolder(
                in: root, name: meetingFolderName(date: meeting.date, title: "会議")
            ).lastPathComponent
        return meeting
    }
    // The new job is saved by the next coalesced checkpoint; the chunk is also listed in recording.json,
    // so recovery finds it even if the app stops before that write.
    func enqueueChunk(_ url: URL, offset: Double, source: String) {
        guard let id = activeID else { return }
        let relative = "chunks/" + url.lastPathComponent
        change(id) { meeting in
            if !meeting.jobs.contains(where: { $0.filename == relative }) {
                meeting.jobs.append(
                    TranscriptionJob(id: stableID(relative), filename: relative, offset: offset, source: source))
                meeting.jobs.sort { $0.offset < $1.offset }
            }
        }
        pipeline.pump()
    }
    func updateLiveSummary() { if recording, let id = activeID { pipeline.requestSummary(id) } }
    func interrupt(_ message: String) async {
        guard let id = activeID else { return }
        if busy {
            pendingCaptureError = message
            return
        }
        guard recording else { return }
        change(id) { $0.captureError = message }
        error = message
        await stop(interrupted: true)
    }
    func stop(interrupted: Bool = false) async {
        guard recording, !busy, let id = activeID else { return }
        busy = true
        stopping = true
        defer {
            busy = false
            stopping = false
        }
        summaryTimer?.invalidate()
        summaryTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        recording = false
        meter.reset()
        do { try await recorder.stop() } catch {
            change(id) { $0.captureError = error.localizedDescription }
            self.error = error.localizedDescription
        }
        activeID = nil
        captureInputID = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        change(id) {
            $0.capture = interrupted ? .interrupted : .stopped
            $0.status = "録音停止済み・残りを処理中"
            $0.agenda = MeetingAgenda.finish($0.agenda, at: Date().timeIntervalSince($0.recordingOrigin))
        }
        do { try await discoverJobs(id) } catch {
            self.error = error.localizedDescription
            change(id) { $0.captureError = error.localizedDescription }
        }
        do { try await checkpoint(id) } catch { self.error = error.localizedDescription }
        mixDown([id], onlyMissing: false)
        status = "録音を停止しました。残りはバックグラウンドで処理します。次の録音を開始できます。"
        pipeline.requestSummary(id, force: true)
        pipeline.pump()
    }
}

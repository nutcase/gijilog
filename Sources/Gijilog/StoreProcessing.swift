import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

// Processing: transcription, minutes, imported recordings, working audio, completion and deletion.
extension Store {
    func process(_ meetingID: UUID? = nil, rebuild: Bool = false) async {
        guard ready, !shuttingDown, let id = meetingID ?? selected, !busy, id != activeID, !isProcessing(id),
            meetings.first(where: { $0.id == id })?.capture != .planned
        else { return }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        guard hasKey else {
            error = "処理するには、設定でOpenAI APIキーを保存してください。"
            return
        }
        do {
            // A failed final review only needs text, even if working audio has already been removed.
            if !rebuild, let meeting = meetings.first(where: { $0.id == id }),
                meeting.finalReviewPending == true, !meeting.segments.isEmpty,
                meeting.jobs.allSatisfy({ $0.state == .completed })
            {
                claim(id)
                try await checkpoint(id)
                pipeline.resume(id, key: key)
                pipeline.requestSummary(id, force: true)
                return
            }
            let folder = folder(id)
            // Without its working audio, a meeting is transcribed again from 録音.m4a (both tracks mixed).
            let fromMix = try await Task.detached { try Self.workingAudioMissing(folder) }.value
            var rebuild = rebuild || fromMix
            if let old = meetings.first(where: { $0.id == id }), rebuild || old.settings == nil {
                try await repository.backup(old)
                if old.settings == nil { rebuild = true }
            }
            if fromMix {
                let mix = folder.appendingPathComponent(AudioMixdown.filename)
                guard FileManager.default.fileExists(atPath: mix.path) else {
                    throw AppError.message("作業用の音声も録音.m4a もないため、再処理できません。")
                }
                _ = try await Task.detached {
                    WorkingAudio.remove(in: folder)
                    return try await AudioImport.split(mix, into: folder)
                }.value
                change(id) { $0.jobs = [] }
            }
            try await discoverJobs(id)
            change(id) { meeting in
                meeting.finalReviewPending = true
                if rebuild || meeting.settings == nil {
                    meeting.settings = settings
                    // Items edited by hand, and those deleted, carry over, an edited item still to check marked by
                    // its own ID; the AI writes the rest again from a new transcript.
                    meeting.notes = MinutesState.keptForReprocessing(meeting.notes)
                    meeting.revisedBeforeMinutes = nil
                    meeting.segments = []
                    meeting.minutes = ""
                    for i in meeting.jobs.indices { meeting.jobs[i].state = .pending }
                }
                for i in meeting.jobs.indices where rebuild || meeting.jobs[i].state != .completed {
                    meeting.jobs[i].state = .pending
                    meeting.jobs[i].attempts = 0
                    meeting.jobs[i].retryAfter = nil
                    meeting.jobs[i].lastError = nil
                }
                meeting.status = "録音済み・未処理を再開中"
            }
            claim(id)
            try await checkpoint(id)
            pipeline.resume(id, key: key)
            pipeline.requestSummary(id, force: true)
        } catch { self.error = error.localizedDescription }
    }
    /// Revisit the saved transcript without uploading or transcribing the audio again.
    func refineMinutes(_ id: UUID) async {
        guard ready, !shuttingDown, !busy, id != activeID, !isProcessing(id),
            let meeting = meetings.first(where: { $0.id == id }), !meeting.segments.isEmpty
        else { return }
        guard hasKey else {
            error = "議事録を仕上げるには、設定でOpenAI APIキーを保存してください。"
            return
        }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        change(id) {
            $0.finalReviewPending = true
            $0.notes?.reviewedSegmentIDs = nil
            $0.notes?.finalizedAt = nil
            $0.settings = settings
            $0.status = "録音済み・議事録を仕上げ中"
        }
        claim(id)
        do {
            try await checkpoint(id)
            pipeline.resume(id, key: key)
            pipeline.requestSummary(id, force: true)
        } catch { self.error = error.localizedDescription }
    }
    /// True when some audio the meeting was cut into is gone (removed to save space, or deleted by hand).
    nonisolated static func workingAudioMissing(_ folder: URL) throws -> Bool {
        let inputs = try Processor.recordingInputs(folder: folder, allowMissing: true)
        return inputs.isEmpty || inputs.contains { !FileManager.default.fileExists(atPath: $0.url.path) }
    }
    func chooseRecordingFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.prompt = "議事録を作成"
        panel.message = "議事録を作る録音ファイル（音声・動画）を選んでください。"
        guard panel.runModal() == .OK else { return }
        importRecordings(panel.urls)
    }
    /// Queues files to import one after another; files dropped while an import runs wait their turn.
    func importRecordings(_ urls: [URL]) {
        importQueue += urls
        guard importTask == nil else { return }
        importTask = Task {
            while !importQueue.isEmpty { await importRecording(from: importQueue.removeFirst()) }
            importTask = nil
        }
    }
    // Minutes from a recording made elsewhere (Voice Memos, a Zoom recording, any audio or video file).
    // The original file is left untouched; the meeting folder gets the chunks, 録音.m4a and 議事録.md.
    func importRecording(from input: URL) async {
        guard ready, !shuttingDown else { return }
        guard hasKey else {
            error = "議事録を作るには、設定でOpenAI APIキーを保存してください。"
            return
        }
        importing = true
        defer { importing = false }
        status = "「\(input.lastPathComponent)」を読み込んでいます"
        let title = input.deletingPathExtension().lastPathComponent
        let date = (try? input.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let folderName =
            MeetingRepository.uniqueFolder(in: root, name: meetingFolderName(date: date, title: title))
            .lastPathComponent
        let folder = root.appendingPathComponent(folderName)
        let chunks: [RecordedChunk]
        do {
            chunks = try await Task.detached { try await AudioImport.split(input, into: folder) }.value
        } catch {
            try? FileManager.default.removeItem(at: folder)  // Only the folder created for this import.
            self.error = "「\(input.lastPathComponent)」から議事録を作れませんでした。\(error.localizedDescription)"
            status = "準備完了"
            return
        }
        var meeting = Meeting(title: title)
        meeting.workingMac = thisMac
        meeting.date = date
        meeting.folderName = folderName
        meeting.settings = settings
        meeting.finalReviewPending = true
        meeting.capture = .stopped
        meeting.hasAudio = true
        meeting.status = "録音ファイルを文字起こし中"
        meeting.jobs = chunks.map { chunk in
            let relative = "chunks/" + chunk.filename
            return TranscriptionJob(
                id: stableID(relative), filename: relative, offset: chunk.offset, source: chunk.source)
        }
        meetings.insert(meeting, at: meetings.firstIndex { $0.date < date } ?? meetings.count)
        showNewMeeting()
        if !recording { selected = meeting.id }  // Keep the live meeting on screen.
        do { try await checkpoint(meeting.id) } catch { self.error = error.localizedDescription }
        mixDown([meeting.id], onlyMissing: false)
        pipeline.resume(meeting.id, key: key)
        status = "「\(title)」の文字起こしを始めました"
    }
    // Writes 録音.m4a next to the minutes in the background, one meeting at a time.
    // Work on meeting folders runs one step at a time, so working audio is never removed before 録音.m4a exists.
    private func enqueueBackground(_ work: @escaping @MainActor () async -> Void) {
        let previous = backgroundWork
        backgroundWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
    func mixDown(_ ids: [UUID], onlyMissing: Bool) {
        let folders = ids.map(folder).filter {
            !onlyMissing
                || !FileManager.default.fileExists(atPath: $0.appendingPathComponent(AudioMixdown.filename).path)
        }
        guard !folders.isEmpty else { return }
        enqueueBackground {
            await Task.detached(priority: .utility) {
                for folder in folders { try? await AudioMixdown.write(folder: folder) }
            }.value
        }
    }
    func waitForBackgroundWork() async {
        while let work = backgroundWork {
            await work.value
            if backgroundWork == work { return }
        }
    }
    func isComplete(_ meeting: Meeting) -> Bool {
        meeting.capture != .recording && !meeting.segments.isEmpty && meeting.jobs.allSatisfy { $0.state == .completed }
            && MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
            && meeting.finalReviewPending != true && !pipeline.summaryFailed(meeting.id)
    }
    /// Complete meetings whose working audio can go: 録音.m4a exists and nothing is working on them.
    func cleanableMeetings() -> [UUID] {
        meetings.filter { meeting in
            meeting.id != activeID && !isProcessing(meeting.id) && isComplete(meeting)
                && FileManager.default.fileExists(
                    atPath: folder(meeting.id).appendingPathComponent(AudioMixdown.filename).path)
        }.map(\.id)
    }
    /// Deletes the working audio of complete meetings and returns the bytes freed.
    @discardableResult func removeWorkingAudio(of ids: [UUID]) async -> Int64 {
        let ready = Set(cleanableMeetings())
        let claimed = ids.filter(ready.contains)
        guard !claimed.isEmpty else { return 0 }
        preparingIDs.formUnion(claimed)  // Holds off reprocessing and deletion while the files go.
        defer { preparingIDs.subtract(claimed) }
        let folders = claimed.map(folder)
        let freed = await Task.detached { folders.reduce(Int64(0)) { $0 + WorkingAudio.remove(in: $1) } }.value
        refreshStorageUsage()
        return freed
    }
    func refreshStorageUsage() {
        let root = root
        let folders = cleanableMeetings().map(folder)
        Task {
            let (usage, reclaimable) = await Task.detached {
                (StorageUsage.measure(root), folders.reduce(Int64(0)) { $0 + WorkingAudio.size(in: $1) })
            }.value
            storageUsage = usage
            reclaimableBytes = reclaimable
        }
    }
    func confirmWorkingAudioCleanup() {
        let ids = cleanableMeetings()
        guard !ids.isEmpty, reclaimableBytes > 0 else { return }
        let size = bytes(reclaimableBytes)
        let alert = NSAlert()
        alert.messageText = "作業用の音声を削除しますか？"
        alert.informativeText =
            "完了した会議 \(ids.count)件の作業用の音声（\(size)）を削除します。聞き返し用の録音.m4a と議事録は残ります。"
            + "全文を再処理するときは録音.m4a から文字起こしし直すため、Mac音声とマイクは区別されなくなります。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let freed = await removeWorkingAudio(of: ids)
            status = "作業用の音声を \(bytes(freed)) 削除しました"
        }
    }
    /// Retries only the failed transcription chunks, also while the meeting is still being recorded.
    func retryFailedJobs(_ id: UUID) {
        guard hasKey else {
            error = "再試行するには、設定でOpenAI APIキーを保存してください。"
            return
        }
        let folder = folder(id)
        let missing =
            meetings.first { $0.id == id }?.jobs.contains {
                $0.state == .failed
                    && !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.filename).path)
            } ?? false
        if missing && id != activeID {
            Task { await process(id, rebuild: true) }
            return
        }
        change(id) { meeting in
            for i in meeting.jobs.indices where meeting.jobs[i].state == .failed {
                meeting.jobs[i].state = .pending
                meeting.jobs[i].attempts = 0
                meeting.jobs[i].lastError = nil
                meeting.jobs[i].retryAfter = nil
            }
        }
        claim(id)
        pipeline.resume(id, key: key)
    }
    func isProcessing(_ id: UUID) -> Bool { preparingIDs.contains(id) || pipeline.isProcessing(id) }
    /// The minutes are still being written: during the recording, and while its speech or minutes are processed.
    func minutesChanging(_ meeting: Meeting) -> Bool { meeting.capture == .recording || isProcessing(meeting.id) }
    func canDelete(_ id: UUID) -> Bool { ready && id != activeID && !busy && !isProcessing(id) }
    /// Moves the meeting's audio, transcript and minutes to the Trash.
    func delete(_ id: UUID) async {
        guard canDelete(id) else { return }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        do { try await repository.delete(meeting) } catch {
            self.error = "会議を削除できませんでした: " + error.localizedDescription
            return
        }
        pipeline.forget(id)
        dirtyIDs.remove(id)
        revisions[id] = nil
        savedSizes[id] = nil
        meetings.removeAll { $0.id == id }
        pruneTagFilter()
        if selected == id { selected = visibleMeetings.first?.id }
        status = "会議をゴミ箱に移動しました"
        refreshProcessingCounts()
    }
    func refreshProcessingCounts() {
        let pending = meetings.flatMap(\.jobs).filter { $0.state == .pending || $0.state == .running }.count
        if pendingChunks != pending { pendingChunks = pending }
        if recording {
            let text = "録音中（文字起こし待ち \(pending)件）"
            if status != text { status = text }
        }
    }
    func refreshCompletion(_ id: UUID, summaryFailed: Bool) {
        guard let meeting = meetings.first(where: { $0.id == id }), meeting.capture != .recording,
            meeting.capture != .planned, !meeting.jobs.contains(where: { $0.state == .pending || $0.state == .running })
        else { return }
        let result: String
        if meeting.hasAudio == false {
            result = "録音なし"
        } else if meeting.jobs.isEmpty && meeting.segments.isEmpty {
            result = "録音なし"
        } else if meeting.segments.isEmpty {
            result = meeting.jobs.contains { $0.state == .failed } ? "録音済み・文字起こし失敗" : "録音済み・認識結果なし"
        } else if summaryFailed {
            result = "録音済み・議事録作成失敗"
        } else if !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty {
            result = "録音済み・議事録を更新中"
        } else if meeting.finalReviewPending == true {
            result = "録音済み・議事録を仕上げ中"
        } else if meeting.jobs.contains(where: { $0.state == .failed }) || meeting.captureError != nil {
            result = "録音済み・一部処理失敗"
        } else if meeting.capture == .interrupted {
            result = "録音中断・保存済み"
        } else {
            result = "完了"
        }
        guard meeting.status != result else { return }
        change(id) { $0.status = result }
        if result == "完了" && removesWorkingAudio {
            enqueueBackground { [weak self] in await self?.removeWorkingAudio(of: [id]) }
        }
    }
}

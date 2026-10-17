import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

// Launching: loading the meetings and taking up what a quit or a crash left unfinished on this Mac.
extension Store {
    func recover() async {
        defer { ready = true }
        do {
            let (saved, failures) = try await repository.load()
            let restored = await repository.takeRestored()
            if !restored.isEmpty {
                status = "同期で古い版に戻っていた会議を、この Mac の版に戻しました：" + restored.map { "「\($0)」" }.joined()
            }
            meetings = saved
            for meeting in saved {
                revisions[meeting.id] = meeting.revision
                savedCounts[meeting.id] = SaveCounts.of(meeting)
            }
            // Changed both in the save location and in this Mac's copy while the app was not running: this Mac's
            // stays, and the other is kept aside.
            for (other, found) in await repository.takeConflicts() {
                guard let i = meetings.firstIndex(where: { $0.id == other.id }) else { continue }
                let mine = meetings[i]
                if owns(mine) {
                    await keepAside(other, found: found, here: SaveCounts.of(mine), hereRevision: mine.revision)
                } else {
                    // Another Mac's meeting: its version is the one shown, and nothing is written here.
                    meetings[i] = other
                    revisions[other.id] = other.revision
                    savedCounts[other.id] = SaveCounts.of(other)
                    await repository.keepCopy(other)
                }
            }
            await repository.writeMissingDocuments(saved)
            selected = meetings.first?.id
            if !failures.isEmpty { error = "一部の会議を読み込めませんでした。保存場所のデータは保持しています。\n" + failures.joined(separator: "\n") }
            for meeting in saved {
                // Work left unfinished elsewhere (a recording under way on another Mac, or its processing) is that
                // Mac's to finish: taken up here, it would be written over from whatever copy sync had brought.
                // Older files name no Mac, and any Mac may hold an old copy of them, so they are left alone too; the
                // meeting offers to continue on this Mac instead (continueHere).
                guard meeting.workingMac == thisMac else { continue }
                try await takeUpUnfinishedWork(meeting)
            }
            // The first launch that learns misheard words takes in the fixes already made in the meetings, joined with
            // whatever the list has (another Mac may have started it).
            if persistsSettings && vocabularyProblem == nil && !UserDefaults.standard.bool(forKey: "learnedWordsSeeded")
            {
                learnedWords = LearnedWords.merged(learnedWords, LearnedWords.seed(from: meetings))
                UserDefaults.standard.set(true, forKey: "learnedWordsSeeded")
            }
            // Only now are interrupted recordings marked and their audio found, so they get 録音.m4a on this launch.
            mixDown(
                meetings.filter { $0.capture != .recording && $0.hasAudio == true && $0.workingMac == thisMac }.map(
                    \.id),
                onlyMissing: true)
        } catch { self.error = error.localizedDescription }
        if persistsSettings {
            folderWatcher = FolderWatcher(root) { [weak self] in
                Task { @MainActor in
                    await self?.loadAddedMeetings()
                    await self?.reloadChangedMeetings()
                    self?.readVocabularyFile()
                }
            }
        }
    }
    /// Takes up what a quit or a crash left unfinished in a meeting this Mac records or processes: a recording
    /// stopped short is marked interrupted, and its transcription and minutes are resumed.
    func takeUpUnfinishedWork(_ meeting: Meeting) async throws {
        let id = meeting.id
        let interrupted = meeting.capture == .recording
        if interrupted || meeting.jobs.contains(where: { $0.state == .running }) {
            change(id) { m in
                if interrupted {
                    m.capture = .interrupted
                    m.status = "録音中断・未処理を復旧中"
                }
                for i in m.jobs.indices where m.jobs[i].state == .running {
                    m.jobs[i].state = .pending
                    m.jobs[i].retryAfter = nil
                }
            }
        }
        if meeting.settings != nil {
            // Settled meetings are left untouched; only unfinished work, or audio never inspected, is recovered.
            let needsRecovery =
                interrupted || (meeting.notes == nil && meeting.hasAudio == nil)
                || meeting.finalReviewPending == true
                || meeting.jobs.contains { $0.state == .pending || $0.state == .running }
                || !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
            guard needsRecovery else { return }
            do {
                if interrupted || meeting.finalReviewPending != true || meeting.hasAudio == nil
                    || meeting.jobs.contains(where: { $0.state == .pending || $0.state == .running })
                {
                    try await discoverJobs(id)
                }
                if hasKey {
                    try await checkpoint(id)
                    pipeline.resume(id, key: key)
                } else {
                    change(id) { $0.status = "録音済み・APIキー設定後に未処理を再開" }
                    try await checkpoint(id)
                }
            } catch {
                change(id) {
                    $0.status = "録音済み・復旧確認が必要"
                    $0.captureError = error.localizedDescription
                }
                try? await checkpoint(id)
                self.error = error.localizedDescription
            }
        } else if interrupted {
            try await checkpoint(id)
        }
    }
    func discoverJobs(_ id: UUID) async throws {
        let path = folder(id)
        let inputs = try await Task.detached { try Processor.recordingInputs(folder: path, allowMissing: true) }.value
        change(id) { meeting in
            for input in inputs {
                let relative =
                    input.url.deletingLastPathComponent().lastPathComponent == "chunks"
                    ? "chunks/" + input.url.lastPathComponent : input.url.lastPathComponent
                if !meeting.jobs.contains(where: { $0.filename == relative }) {
                    meeting.jobs.append(
                        TranscriptionJob(
                            id: stableID(relative), filename: relative, offset: input.offset, source: input.source))
                }
            }
            meeting.jobs.sort { $0.offset < $1.offset }
        }
        let hasAudio = try await Task.detached { try Processor.hasRecordedAudio(folder: path) }.value
        change(id) { $0.hasAudio = hasAudio }
    }
}

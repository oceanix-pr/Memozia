import Foundation
import Testing

@testable import Memozia

/// 「清理视频」按钮的安全边界。
///
/// 删掉的是用户导入/录制的原件，因此要求它做到四件事，本文件逐条钉住：
///
/// 1. **没有可复用关键帧就坚决不删**。原件一走就再也抽不出帧，
///    顺手删帧或先删视频都会把整条画面链路废掉，所以缓存可用性是删除的前置条件。
/// 2. **只删视频那一个文件**。关键帧、画面要点、音频、转写与分析检查点必须原样留下，
///    因此不允许按后缀扫目录、也不允许递归删除。
/// 3. **删完还能继续用**。`loadOrExtractFrames` 在 `videoURL` 为 nil 时必须命中帧缓存，
///    否则画面页签在清理后就只剩一个看不了的播放器占位。
/// 4. **删完条目类型不能丢**。原视频是磁盘上最后一份「这是视频条目」的物证，删掉后条目
///    仍须按录屏展示（图标与类型文案都不回退成录音），因此清理要把视频源标记写进 meta.json，
///    扫描也要能从画面产物判定视频来源。
struct VideoCleanupTests {

    /// 一个条目文件夹的最小真实形状：音频 + 原始视频 + 画面要点 + frames/ + 检查点目录
    private struct Sandbox {
        let root: URL
        let video: URL
        let audio: URL
        let visual: URL
        let frames: URL
        let checkpoint: URL

        init(videoBytes: Int) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoziaVideoCleanup-\(UUID().uuidString)", isDirectory: true)
            let frames = root.appendingPathComponent(AudioRecording.framesDirectoryName, isDirectory: true)
            let checkpoint = root.appendingPathComponent(
                AudioRecording.visualAnalysisCheckpointDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

            self.root = root
            self.frames = frames
            self.checkpoint = checkpoint
            self.video = root.appendingPathComponent("会议_video.mp4")
            self.audio = root.appendingPathComponent("会议.m4a")
            self.visual = root.appendingPathComponent("visual.md")

            try Data(repeating: 0x5A, count: videoBytes).write(to: video)
            try Data(repeating: 0x01, count: 512).write(to: audio)
            try "## 00:01 幻灯片首页".write(to: visual, atomically: true, encoding: .utf8)
            try Data(repeating: 0x02, count: 256).write(
                to: frames.appendingPathComponent(AudioRecording.frameFileName(index: 1, time: 1.5)))
            try Data("{}".utf8).write(to: checkpoint.appendingPathComponent("manifest.json"))
        }

        /// 帧缓存版本标记：与当前抽帧策略一致才算「可复用」
        func writeCacheVersion(_ version: String) throws {
            try version.write(to: frames.appendingPathComponent(VideoUnderstandingService.framesCacheVersionFileName),
                              atomically: true, encoding: .utf8)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func removeAll() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - 前置条件

    @Test func testReusableCacheRequiresMatchingVersionAndFrames() async throws {
        let sandbox = try Sandbox(videoBytes: 1024)
        defer { sandbox.removeAll() }

        // 只有 jpg、没有版本标记：旧策略产物，必须重抽，不能当作可复用
        #expect(!(await VideoUnderstandingService.hasReusableFrameCache(in: sandbox.frames)))

        // 版本标记不符：同样不可复用
        try sandbox.writeCacheVersion("obsolete-sampling-version")
        #expect(!(await VideoUnderstandingService.hasReusableFrameCache(in: sandbox.frames)))

        // 版本正确且确有帧才算可复用
        try sandbox.writeCacheVersion(VideoUnderstandingService.framesCacheVersion)
        #expect(await VideoUnderstandingService.hasReusableFrameCache(in: sandbox.frames))

        // 目录存在但一帧没有
        let empty = sandbox.root.appendingPathComponent("empty-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try VideoUnderstandingService.framesCacheVersion.write(
            to: empty.appendingPathComponent(VideoUnderstandingService.framesCacheVersionFileName),
            atomically: true, encoding: .utf8)
        #expect(!(await VideoUnderstandingService.hasReusableFrameCache(in: empty)))
    }

    /// 缓存不可用时不仅拒绝删除，还必须一个文件都不少
    @Test func testCleanupRefusesWithoutReusableCacheAndKeepsEverything() async throws {
        let sandbox = try Sandbox(videoBytes: 2048)
        defer { sandbox.removeAll() }

        await #expect(throws: VideoUnderstandingService.VideoUnderstandingError.frameCacheMissing) {
            _ = try await VideoUnderstandingService.cleanupOriginalVideo(
                videoURL: sandbox.video, framesDirectoryURL: sandbox.frames)
        }
        #expect(sandbox.exists(sandbox.video))
        #expect(sandbox.exists(sandbox.audio))
        #expect(sandbox.exists(sandbox.visual))
    }

    // MARK: - 删除范围

    /// 成功路径：只少一个视频文件，其余产物逐条核对
    @Test func testCleanupDeletesOnlyTheVideoFile() async throws {
        let sandbox = try Sandbox(videoBytes: 4096)
        defer { sandbox.removeAll() }
        try sandbox.writeCacheVersion(VideoUnderstandingService.framesCacheVersion)
        let frameURL = sandbox.frames.appendingPathComponent(
            AudioRecording.frameFileName(index: 1, time: 1.5))

        let freed = try await VideoUnderstandingService.cleanupOriginalVideo(
            videoURL: sandbox.video, framesDirectoryURL: sandbox.frames)

        #expect(freed == 4096)
        #expect(!sandbox.exists(sandbox.video))
        #expect(sandbox.exists(sandbox.audio), "音频被误删")
        #expect(sandbox.exists(sandbox.visual), "画面要点被误删")
        #expect(sandbox.exists(frameURL), "关键帧被误删")
        #expect(sandbox.exists(sandbox.checkpoint.appendingPathComponent("manifest.json")), "分析检查点被误删")
        #expect(sandbox.exists(sandbox.frames), "关键帧目录被误删")
    }

    @Test func testCleanupReportsFailureInsteadOfPretendingSuccess() async throws {
        let sandbox = try Sandbox(videoBytes: 1024)
        defer { sandbox.removeAll() }
        try sandbox.writeCacheVersion(VideoUnderstandingService.framesCacheVersion)

        // 原件已被用户在 Finder 里移走：缓存判定通过，但删除必须报错而不是静默
        try FileManager.default.removeItem(at: sandbox.video)
        await #expect(throws: (any Error).self) {
            _ = try await VideoUnderstandingService.cleanupOriginalVideo(
                videoURL: sandbox.video, framesDirectoryURL: sandbox.frames)
        }
        #expect(sandbox.exists(sandbox.frames.appendingPathComponent(
            AudioRecording.frameFileName(index: 1, time: 1.5))), "删除失败时也不该动关键帧")
    }

    // MARK: - 清理后的可用性

    /// 原件已清理但缓存可用：仍要能拿到帧，画面分析不至于失效
    @Test func testCachedFramesStillLoadWithoutOriginalVideo() async throws {
        let sandbox = try Sandbox(videoBytes: 1024)
        defer { sandbox.removeAll() }
        try sandbox.writeCacheVersion(VideoUnderstandingService.framesCacheVersion)

        let frames = try await VideoUnderstandingService.loadOrExtractFrames(
            videoURL: nil, framesDirectoryURL: sandbox.frames)
        #expect(frames.count == 1)
        #expect(frames.first?.time == 1.5)
    }

    /// 缓存命中时即使原件还在也不重抽（不浪费时间，也不覆盖用户核对过的帧）
    @Test func testCacheHitDoesNotReextractFromExistingVideo() async throws {
        let sandbox = try Sandbox(videoBytes: 1024)
        defer { sandbox.removeAll() }
        try sandbox.writeCacheVersion(VideoUnderstandingService.framesCacheVersion)

        let frames = try await VideoUnderstandingService.loadOrExtractFrames(
            videoURL: sandbox.video, framesDirectoryURL: sandbox.frames)
        #expect(frames.count == 1)
        #expect(sandbox.exists(sandbox.video))
    }

    /// 既无原件又无可用缓存：明确报错，不能拿不存在的 URL 去抽帧
    @Test func testMissingVideoWithoutUsableCacheThrows() async throws {
        let sandbox = try Sandbox(videoBytes: 1024)
        defer { sandbox.removeAll() }

        await #expect(throws: VideoUnderstandingService.VideoUnderstandingError.sourceUnavailable) {
            _ = try await VideoUnderstandingService.loadOrExtractFrames(
                videoURL: nil, framesDirectoryURL: sandbox.frames)
        }
    }

    // MARK: - 清理后的条目类型不丢

    /// 删除原视频后，磁盘上仍须留有能判定「这是视频条目」的证据，
    /// 否则数据库重建/换机同步会把录屏当纯录音，列表图标退回波形
    @Test func testVideoSourceEvidenceSurvivesVideoDeletion() async throws {
        let sandbox = try Sandbox(videoBytes: 4096)
        defer { sandbox.removeAll() }
        try sandbox.writeCacheVersion(VideoUnderstandingService.framesCacheVersion)

        let before = try listFiles(sandbox.root)
        #expect(AudioRecording.folderIndicatesVideoSource(folderURL: sandbox.root, files: before))

        _ = try await VideoUnderstandingService.cleanupOriginalVideo(
            videoURL: sandbox.video, framesDirectoryURL: sandbox.frames)

        #expect(!sandbox.exists(sandbox.video), "原视频应已删除")
        let after = try listFiles(sandbox.root)
        #expect(AudioRecording.folderIndicatesVideoSource(folderURL: sandbox.root, files: after),
                "删掉原视频后仍须能从画面产物判定为视频条目")
    }

    /// 纯录音文件夹（只有音频与 meta.json）：不能被判成视频条目，
    /// 否则历史条目修复会把普通录音都改成录屏
    @Test func testAudioOnlyFolderIsNotAVideoEntry() throws {
        let root = try makeFolder(prefix: "MemoziaAudioOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x01, count: 512)
            .write(to: root.appendingPathComponent("20260918120000.m4a"))
        try #"{"title": "会议", "isHidden": false}"#
            .write(to: root.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        #expect(!AudioRecording.folderHasVisualArtifacts(folderURL: root))
        let files = try listFiles(root)
        #expect(!AudioRecording.folderIndicatesVideoSource(folderURL: root, files: files))
    }

    /// 只见画面产物：原视频已被清理、meta.json 也没标记的早期录屏，仍须被认出是视频条目，
    /// 否则历史数据永远修不回来
    @Test func testVisualArtifactsAloneProveVideoSource() throws {
        let root = try makeFolder(prefix: "MemoziaArtifactsOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = root.appendingPathComponent(AudioRecording.framesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try Data(repeating: 0x02, count: 128).write(
            to: frames.appendingPathComponent(AudioRecording.frameFileName(index: 1, time: 1.0)))

        #expect(AudioRecording.folderHasVisualArtifacts(folderURL: root))
        let files = try listFiles(root)
        #expect(AudioRecording.folderIndicatesVideoSource(folderURL: root, files: files))
    }

    /// 清理只把 `videoFileName` 置空，条目类型必须落进 meta.json（文件是权威源）：
    /// 库里那行被重建后靠它把条目恢复成录屏
    @MainActor
    @Test func testCleanupKeepsVideoSourceFlagInMeta() throws {
        let storage = try makeFolder(prefix: "MemoziaVideoType")
        let folderName = "20260918120000"
        try FileManager.default.createDirectory(
            at: storage.appendingPathComponent(folderName, isDirectory: true),
            withIntermediateDirectories: true)
        let previousStorage = UserDefaults.standard.string(forKey: AudioRecording.storageDirectoryKey)
        AudioRecording.setStorageDirectory(storage)
        defer {
            if let previousStorage {
                AudioRecording.setStorageDirectory(URL(fileURLWithPath: previousStorage))
            } else {
                AudioRecording.resetStorageDirectory()
            }
            try? FileManager.default.removeItem(at: storage)
        }

        let recording = AudioRecording(
            fileName: "会议",
            fileExtension: "m4a",
            storedFileName: "\(folderName).m4a",
            folderName: folderName,
            videoFileName: "\(folderName)_video.mp4"
        )
        #expect(recording.mediaKind == .screenRecording)
        recording.saveMetaToFolder()

        // 复现「清理视频」：原视频文件名置空（视频源标记由 saveMetaToFolder 落进 meta.json）
        recording.videoFileName = nil
        recording.saveMetaToFolder()

        #expect(recording.mediaKind == .screenRecording, "清理后仍须按录屏展示，不能退回录音")
        #expect(AudioRecording.loadMetaFromFolder(folderName: folderName).hasVideoSource,
                "清理后 meta.json 必须仍标记视频源")
    }

    /// 两类条目的判据：无视频源 = 录音；有视频源 = 录屏（导入视频与录屏不区分，统一算录屏）
    @Test func testMediaKindUnifiesScreenRecordingAndImportedVideo() throws {
        let audio = AudioRecording(
            fileName: "会议录音",
            fileExtension: "m4a",
            storedFileName: "a.m4a",
            recordingSource: .microphone,
            folderName: "20260918120000"
        )
        #expect(audio.mediaKind == .audio)

        let screen = AudioRecording(
            fileName: "录屏",
            fileExtension: "m4a",
            storedFileName: "b.m4a",
            recordingSource: .mixed,
            folderName: "20260918120001",
            videoFileName: "b_video.mp4"
        )
        #expect(screen.mediaKind == .screenRecording)

        // 导入视频（本机来源为 nil）与录屏同类：不因来源不同分成两种图标与文案
        let imported = AudioRecording(
            fileName: "外部视频",
            fileExtension: "m4a",
            storedFileName: "c.m4a",
            folderName: "20260918120002",
            videoFileName: "c_video.mp4"
        )
        #expect(imported.mediaKind == .screenRecording)
    }

    private func makeFolder(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func listFiles(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
}

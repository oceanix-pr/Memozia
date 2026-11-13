import Testing

@testable import Memozia

/// 一键处理计划（`OneClickPlan`）的纯逻辑回归。
///
/// 钉住四条产品语义：
/// 1. **已完成默认跳过**：不想重跑的步骤（尤其是按次计费的云端调用）不会被重复执行；
/// 2. **只有显式重新转写才覆盖已有转写**：且「有手动编辑」时必须先要求额外确认；
/// 3. **音频文件不存在时不排转写**（避免必然失败的步骤）；
/// 4. **云端数据范围显式**：仅当本次真的会把图片/视频帧送云端时才提示。
struct OneClickPlanTests {

    /// 全部「未完成」的录音输入（各用例在此基础上改一项）
    private func recordingInputs() -> OneClickPlan.Inputs {
        OneClickPlan.Inputs(
            isRecording: true,
            hasVideo: false,
            transcriptCompleted: false,
            transcriptManuallyEdited: false,
            visualCompleted: false,
            summaryCompleted: false,
            todoCompleted: false,
            audioFileExists: true,
            isImageNote: false,
            usesCloudLLM: false,
            forceRetranscribe: false
        )
    }

    private func noteInputs(isImage: Bool) -> OneClickPlan.Inputs {
        OneClickPlan.Inputs(
            isRecording: false,
            hasVideo: false,
            transcriptCompleted: false,
            transcriptManuallyEdited: false,
            visualCompleted: false,
            summaryCompleted: false,
            todoCompleted: false,
            audioFileExists: false,
            isImageNote: isImage,
            usesCloudLLM: false,
            forceRetranscribe: false
        )
    }

    // MARK: - 步骤顺序与跳过

    @Test("录音未转写：按「转写 → 总结 → 拆解待办」执行")
    func recordingWithoutTranscriptRunsAllSteps() {
        let plan = OneClickPlan.make(recordingInputs())
        #expect(plan.runItems.map(\.kind) == [.transcription, .summary, .todoExtraction])
        #expect(plan.skipItems.isEmpty)
        #expect(plan.hasWork)
    }

    @Test("全部已完成：无步骤执行，且不产生待确认项")
    func allCompletedPlanHasNoWork() {
        var inputs = recordingInputs()
        inputs.transcriptCompleted = true
        inputs.summaryCompleted = true
        inputs.todoCompleted = true
        let plan = OneClickPlan.make(inputs)
        #expect(plan.hasWork == false)
        #expect(plan.runItems.isEmpty)
        #expect(plan.skipItems.map(\.skipReason) == [.alreadyCompleted, .alreadyCompleted, .alreadyCompleted])
    }

    @Test("已转写但未显式重做：转写被跳过，其余步骤照常")
    func completedTranscriptIsSkippedByDefault() {
        var inputs = recordingInputs()
        inputs.transcriptCompleted = true
        let plan = OneClickPlan.make(inputs)
        #expect(plan.items.first?.kind == .transcription)
        #expect(plan.items.first?.willRun == false)
        #expect(plan.runItems.map(\.kind) == [.summary, .todoExtraction])
    }

    @Test("显式重新转写：覆盖已有转写（仅在音频文件存在时）")
    func forceRetranscribeOverridesCompletedTranscript() {
        var inputs = recordingInputs()
        inputs.transcriptCompleted = true
        let forced = OneClickPlan.make(inputs.withForceRetranscribe(true))
        #expect(forced.runItems.first?.kind == .transcription)
        #expect(forced.requiresManualEditConfirmation == false)

        // 音频文件已不存在：不排转写（必然失败的步骤不进队列），重做开关也无意义
        var missingAudio = inputs
        missingAudio.audioFileExists = false
        let plan = OneClickPlan.make(missingAudio.withForceRetranscribe(true))
        #expect(plan.items.contains { $0.kind == .transcription } == false)
    }

    @Test("转写存在手动编辑且本次会覆盖：要求额外确认（先备份）")
    func manualEditsRequireExtraConfirmation() {
        var inputs = recordingInputs()
        inputs.transcriptCompleted = true
        inputs.transcriptManuallyEdited = true

        // 不重转：不覆盖，无需额外确认
        #expect(OneClickPlan.make(inputs).requiresManualEditConfirmation == false)
        // 重转：会覆盖手动修改，必须额外确认
        #expect(OneClickPlan.make(inputs.withForceRetranscribe(true)).requiresManualEditConfirmation)
    }

    @Test("视频条目：画面分析未完成才排入，完成后跳过")
    func videoVisualStepFollowsCompletion() {
        var inputs = recordingInputs()
        inputs.hasVideo = true
        let plan = OneClickPlan.make(inputs)
        #expect(plan.runItems.map(\.kind) == [.transcription, .visualAnalysis, .summary, .todoExtraction])

        inputs.visualCompleted = true
        let second = OneClickPlan.make(inputs)
        #expect(second.items.first { $0.kind == .visualAnalysis }?.willRun == false)
    }

    @Test("快捷笔记：只按「总结 → 拆解待办」执行，不出现转写/画面")
    func quickNotePlanHasNoTranscriptionOrVisual() {
        let plan = OneClickPlan.make(noteInputs(isImage: true))
        #expect(plan.items.map(\.kind) == [.summary, .todoExtraction])
        #expect(plan.runItems.map(\.kind) == [.summary, .todoExtraction])
    }

    // MARK: - 云端数据范围

    @Test("云端模型 + 图片笔记 + 需要总结：提示图片数据范围")
    func imageNoteOnCloudReportsImageScope() {
        var inputs = noteInputs(isImage: true)
        inputs.usesCloudLLM = true
        #expect(OneClickPlan.make(inputs).cloudScope == .image)

        // 本地模型不出本机：不给多余提示
        inputs.usesCloudLLM = false
        #expect(OneClickPlan.make(inputs).cloudScope == nil)
    }

    @Test("云端模型 + 录屏且本次分析画面：提示视频帧数据范围")
    func videoOnCloudReportsFrameScope() {
        var inputs = recordingInputs()
        inputs.hasVideo = true
        inputs.usesCloudLLM = true
        #expect(OneClickPlan.make(inputs).cloudScope == .videoFrames)

        // 画面分析已完成（本次不跑）：没有帧送云端，不提示
        var visualDone = inputs
        visualDone.visualCompleted = true
        #expect(OneClickPlan.make(visualDone).cloudScope == nil)

        // 本地模型：不提示
        var local = inputs
        local.usesCloudLLM = false
        #expect(OneClickPlan.make(local).cloudScope == nil)
    }
}

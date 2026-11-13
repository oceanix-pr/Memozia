import SwiftUI

/// 录音列表视图（侧边栏）- 合并显示录音与快捷笔记
struct RecordingListView: View {
    let recordings: [AudioRecording]
    let quickNotes: [QuickNote]
    /// 多选绑定（Set）：macOS List 自动支持 ⌘点击/⇧点击范围选择
    @Binding var selectedListItems: Set<ListItem>
    var onCreateQuickNote: () -> Void = {}
    var onImportMedia: () -> Void = {}
    var onScreenshot: () -> Void = {}
    let onDeleteRecording: (AudioRecording) -> Void
    var onDeleteQuickNote: (QuickNote) -> Void = { _ in }
    let onRecordingTitleChange: (AudioRecording, String) -> Void
    var onQuickNoteTitleChange: (QuickNote, String) -> Void = { _, _ in }
    /// 当前体验模式：列表工具栏只保留普通模式也支持的主链路入口。
    /// 捕获（截图/录屏统一会话）属专业能力，仅专业模式显示。
    var experience: AppExperience = .pro
    var showHiddenRecordings: Bool = false
    var allowsMultipleSelection: Bool = true
    /// P1-5: 编辑标题的条目 ID（替代 NotificationCenter 广播）
    @Binding var editingItemID: String?
    var onRefresh: @MainActor () async -> Void = {}
    var isMeetingRecording: Bool = false
    /// 菜单直接挂在持有 selection 的 List 上，避免外层容器截断列表的选择上下文。
    var contextMenuContent: (Set<ListItem>) -> AnyView = { _ in AnyView(EmptyView()) }
    var onToggleMeetingRecording: () -> Void = {}

    @State private var searchText = ""
    /// P2-7: 防抖后的搜索文本
    @State private var debouncedSearchText = ""
    @State private var searchRequest = UUID()
    @State private var searchHits: [String: FullTextSearch.Hit] = [:]
    @State private var searchUnreadable = 0
    @State private var isSearching = false
    /// 自定义搜索框焦点（⌘F 聚焦、Esc 清空/失焦）
    @FocusState private var searchFieldFocused: Bool
    @State private var isRefreshing = false
    /// 过滤+排序+按月分组结果缓存：仅在输入（搜索/隐藏开关/数据源）变化时重算，
    /// 避免选中切换等无关 body 重算反复执行 O(n log n) 排序
    @State private var filteredGroups: [MonthGroup] = []
    /// 当前处于折叠状态的月份分组 key（yyyy-MM）。默认仅当月（及选中条目所在月份）
    /// 展开，其余月份折叠：首屏只构建当月行视图，提升启动加载性能
    @State private var collapsedMonths: Set<String> = []
    /// 用户手动切换过折叠状态的月份：这些月份的展开/折叠完全由用户操作决定，
    /// 不再被 recompute 的默认规则（当月展开/其余折叠）重置
    @State private var userToggledMonths: Set<String> = []

    /// 待办数量索引：条目文件夹名 → 待办统计（仅收录条数 > 0 的条目）。
    /// 待办存于条目文件夹的加密 todos.json（非 SwiftData），文件为权威源。
    /// 对账按 todos.json 的 mtime 增量进行：未变化的目录直接复用缓存，
    /// 只重新读取发生变化的目录（旧实现每次数据源变化/待办通知都全库解密解析一遍）
    @State private var todoIndex: [String: EntryTodoCount] = [:]
    /// 待办索引重建请求：全量对账，或仅重算某个条目（通知携带文件夹名时）。
    /// 更换 token 即重算，`.task(id:)` 自动取消上一轮以避免并发扫描。
    private enum TodoScanRequest: Equatable {
        case all(UUID)
        case folder(String, UUID)
    }
    @State private var todoScanRequest = TodoScanRequest.all(UUID())

    /// 月份分组（key 为 yyyy-MM，倒序排列）
    private struct MonthGroup: Identifiable {
        let key: String
        /// 分组标题锚点日期（用于本地化月份显示）
        let titleDate: Date
        let items: [ListItem]

        var id: String { key }
    }

    /// 原生 List 的内容身份：记录月份与组内条目的顺序，覆盖新增、删除、替换和重排。
    /// 标题、状态和待办数量不参与，避免普通行更新打断编辑或滚动。
    private var listContentIdentity: [[String]] {
        filteredGroups.map { group in [group.key] + group.items.map(\.id) }
    }

    /// 月份分组 key 格式化器（yyyy-MM，字符串倒序即时间倒序）
    /// 用 autoupdatingCurrent 而非 current：本实例长期存活，捕获 current 会把时区快照冻住，
    /// 用户改系统时区后分组口径会与新条目命名口径不一致
    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return formatter
    }()

    /// P1-3: 单次遍历合并+过滤+排序，再按月分组缓存
    private func recomputeFilteredItems() {
        let search = debouncedSearchText
        var items: [ListItem] = []

        for recording in recordings {
            if !showHiddenRecordings && recording.isHidden { continue }
            if !search.isEmpty && searchHits[recording.folderName] == nil { continue }
            items.append(.recording(recording))
        }

        for note in quickNotes {
            if !showHiddenRecordings && note.isHidden { continue }
            if !search.isEmpty && searchHits[note.folderName] == nil { continue }
            items.append(.quickNote(note))
        }

        items.sort { $0.createdAt > $1.createdAt }

        // 按月分组：items 已按时间倒序，组内顺序直接保持；key 字典序倒序即月份倒序
        var byMonth: [String: [ListItem]] = [:]
        for item in items {
            byMonth[Self.monthKeyFormatter.string(from: item.createdAt), default: []].append(item)
        }
        filteredGroups = byMonth
            .sorted { $0.key > $1.key }
            .map { MonthGroup(key: $0.key, titleDate: $0.value[0].createdAt, items: $0.value) }

        applyDefaultCollapseStates()
    }

    private func searchContents() async {
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchHits = [:]
            searchUnreadable = 0
            debouncedSearchText = ""
            isSearching = false
            recomputeFilteredItems()
            return
        }
        isSearching = true
        let entries = recordings.filter { showHiddenRecordings || !$0.isHidden }.map { recording in
            FullTextSearch.Entry(folder: recording.folderName, title: recording.fileName,
                fields: recording.segments.sorted { $0.startTime < $1.startTime }.map {
                    FullTextSearch.Field(value: $0.text, seconds: $0.startTime)
                } + [recording.summary, recording.visualSummary].compactMap { $0 }.map {
                    FullTextSearch.Field(value: $0, seconds: nil)
                })
        } + quickNotes.filter { showHiddenRecordings || !$0.isHidden }.map { note in
            FullTextSearch.Entry(folder: note.folderName, title: note.title,
                fields: [note.textContent, note.ocrText, note.summaryText].compactMap { $0 }.map {
                    FullTextSearch.Field(value: $0, seconds: nil)
                })
        }
        let work = Task.detached(priority: .userInitiated) { try FullTextSearch.find(query, in: entries) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            searchHits = result.hits
            searchUnreadable = result.unreadable
            debouncedSearchText = query
            isSearching = false
            recomputeFilteredItems()
        } catch is CancellationError { /* A newer search owns the UI state. */ }
        catch { searchUnreadable = 1; isSearching = false }
    }

    /// 增量重建待办索引：主线程只快照条目文件夹名（@Model 不跨 actor 传递），
    /// 后台按 mtime 对账——仅 mtime 变化的目录才读取/解密/解析 todos.json，
    /// 未变化的目录复用上一轮缓存。避免每次数据源变化或待办通知都全库读盘。
    /// 收到带文件夹名的通知时只重算该条目（`reconcileOne`）。
    private func rebuildTodoIndex(for request: TodoScanRequest) async {
        // 只快照文件夹名：URL 解析（`folderURL` 内含月度目录探测的同步 stat）放到后台，
        // 避免主线程为每条目做一次 stat
        let folders: [String]
        switch request {
        case .all:
            folders = recordings.map { $0.folderName } + quickNotes.map { $0.folderName }
        case .folder:
            folders = []
        }
        let previous = todoIndex

        let worker = Task.detached(priority: .utility) { () -> [String: EntryTodoCount] in
            switch request {
            case .all:
                return TodoCountIndex.reconcile(previous: previous, folders: folders)
            case .folder(let folderName, _):
                // 单条目：只对该目录 stat（必要时读一次），其它条目复用缓存
                return TodoCountIndex.reconcileOne(previous: previous, folderName: folderName)
            }
        }
        // task(id:) 被新一轮扫描替换时，把取消显式传给 detached worker；否则旧扫描会继续
        // 全库读盘并与新扫描重叠。
        let index = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled else { return }
        todoIndex = index
    }

    /// 应用默认折叠规则：当月及选中条目所在月份展开，其余月份折叠。
    /// 用户手动切换过（userToggledMonths）的月份保持用户状态；
    /// 折叠状态下不构建组内行视图（见 monthGroupRow），首屏仅加载当月条目
    private func applyDefaultCollapseStates() {
        let currentMonthKey = Self.monthKeyFormatter.string(from: Date())
        // 选中条目所在月份保持展开：导入旧录音等程序化选中不应落在被折叠的分组里
        let selectedMonthKeys = Set(
            selectedListItems.map { Self.monthKeyFormatter.string(from: $0.createdAt) }
        )
        for group in filteredGroups {
            guard !userToggledMonths.contains(group.key) else { continue }
            if group.key == currentMonthKey || selectedMonthKeys.contains(group.key) {
                collapsedMonths.remove(group.key)
            } else {
                collapsedMonths.insert(group.key)
            }
        }
    }

    /// 分组是否展开：搜索中强制展开全部分组（否则匹配结果可能被折叠隐藏），
    /// 搜索清空后各分组恢复用户操作/默认规则的折叠状态
    private func isMonthExpanded(_ key: String) -> Bool {
        !debouncedSearchText.isEmpty || !collapsedMonths.contains(key)
    }

    /// 月份分组的展开绑定（折叠状态存于 collapsedMonths，默认仅当月展开）
    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { isMonthExpanded(key) },
            set: { expanded in
                // 手动切换过的月份不再跟随默认规则，保持用户意图
                userToggledMonths.insert(key)
                if expanded {
                    collapsedMonths.remove(key)
                } else {
                    collapsedMonths.insert(key)
                }
            }
        )
    }

    /// 是否有可见条目（用于空状态判断，不创建中间数组）
    private var hasVisibleItems: Bool {
        if !showHiddenRecordings {
            return recordings.contains { !$0.isHidden }
                || quickNotes.contains { !$0.isHidden }
        }
        return !recordings.isEmpty || !quickNotes.isEmpty
    }

    /// 普通模式仍复用 Set 选中结构，但把 ⌘/⇧ 点击收敛为最后一个新选项。
    private var effectiveSelection: Binding<Set<ListItem>> {
        Binding(
            get: { selectedListItems },
            set: { newSelection in
                guard !allowsMultipleSelection, newSelection.count > 1 else {
                    selectedListItems = newSelection
                    return
                }
                let newlySelected = newSelection.subtracting(selectedListItems).first
                if let item = newlySelected ?? newSelection.first {
                    selectedListItems = [item]
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            // 合并列表（按月分组，分组可折叠）
            // List 内容提取为 listContent、分组行提取为 monthGroupRow：
            // body 内闭包嵌套过深会导致类型检查超时
            List(selection: effectiveSelection) {
                listContent
            }
            // macOS 的 List 在 DisclosureGroup 内增删/替换条目时，旧行内容可能残留并叠在
            // 新行上。按实际分组与有序条目 ID 重建 List，而非只在搜索/隐藏开关变化时重建。
            // 搜索、选中和月份折叠状态均在 List 外持有，不受重建影响。
            .id(listContentIdentity)
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: ListItem.self) { items in
                contextMenuContent(items)
            }
        }
        .navigationTitle("Memozia · 闻墨集")
        // P2-7: 搜索防抖，300ms 内连续输入只触发一次过滤
        .task(id: searchRequest) { await searchContents() }
        .onChange(of: searchText) { searchRequest = UUID() }
        .onChange(of: recordings.map(\.transcriptModifiedAt)) { searchRequest = UUID() }
        .onChange(of: recordings.map(\.summary)) { searchRequest = UUID() }
        .onChange(of: recordings.map(\.visualSummary)) { searchRequest = UUID() }
        .onChange(of: recordings.map(\.fileName)) { searchRequest = UUID() }
        .onChange(of: quickNotes.map(\.textContent)) { searchRequest = UUID() }
        .onChange(of: quickNotes.map(\.ocrText)) { searchRequest = UUID() }
        .onChange(of: quickNotes.map(\.summaryText)) { searchRequest = UUID() }
        .onChange(of: quickNotes.map(\.title)) { searchRequest = UUID() }
        .safeAreaInset(edge: .bottom) {
            if isSearching { ProgressView().controlSize(.small).padding(6) }
            if searchUnreadable > 0 && !searchText.isEmpty {
                Text("部分内容无法读取，搜索结果可能不完整。")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        // 输入变化才重算列表；@Query 刷新带来的数组身份变化同样触发。
        // 注意：@Model 按身份判等，隐藏/取消隐藏等原地修改 isHidden 的操作不会改变
        // recordings/quickNotes 数组的判等结果，必须额外监听 isHidden 集合变化才能触发重算
        .onAppear { recomputeFilteredItems() }
        .onChange(of: debouncedSearchText) { recomputeFilteredItems() }
        .onChange(of: showHiddenRecordings) { recomputeFilteredItems(); searchRequest = UUID() }
        .onChange(of: recordings) {
            recomputeFilteredItems()
            todoScanRequest = .all(UUID())
            searchRequest = UUID()
        }
        .onChange(of: quickNotes) {
            recomputeFilteredItems()
            todoScanRequest = .all(UUID())
            searchRequest = UUID()
        }
        .onChange(of: recordings.map(\.isHidden)) { recomputeFilteredItems(); searchRequest = UUID() }
        .onChange(of: quickNotes.map(\.isHidden)) { recomputeFilteredItems(); searchRequest = UUID() }
        // 待办索引：启动与数据源变化时重建（后台增量对账，不阻塞列表）
        .task(id: todoScanRequest) { await rebuildTodoIndex(for: todoScanRequest) }
        // 待办写入/删除/清除后重建（todos.json 变更通知；发布方可能在后台线程）。
        // 通知带 folderName 时只重算该条目（省掉全库 stat）；不带则退回全量对账
        .onReceive(
            NotificationCenter.default.publisher(for: .todoDocumentDidChange)
                .receive(on: DispatchQueue.main)
        ) { note in
            if !searchText.isEmpty { searchRequest = UUID() }
            if let folder = note.userInfo?[TodoDocument.folderNameUserInfoKey] as? String,
               !folder.isEmpty {
                todoScanRequest = .folder(folder, UUID())
            } else {
                todoScanRequest = .all(UUID())
            }
        }
        #if os(macOS)
        .frame(minWidth: 240)
        #endif
        .toolbar {
            sidebarToolbarItems
        }
    }

    // MARK: - 搜索框

    /// 自定义搜索框（方案 B）：钉在列表顶部，替代系统 `.searchable`。
    ///
    /// 外观走 macOS 26+ 的 Liquid Glass（`glassEffect`），旧系统回退为半透明填充，
    /// 详见 `searchFieldSurface`。原 `.searchable` 在 macOS 会并入窗口工具栏
    /// （与右上角按钮同区），现改为侧栏顶部独立搜索条；过滤/防抖/重建等既有逻辑
    /// 保持不变（见 body 中 `.task(id: searchText)` 与 `.id(listContentIdentity)`）。
    @ViewBuilder
    private var searchField: some View {
        searchFieldSurface
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            // Esc：有输入先清空，已空则退出焦点（对齐系统搜索框行为）
            #if os(macOS)
            .onExitCommand {
                if searchText.isEmpty {
                    searchFieldFocused = false
                } else {
                    clearSearch()
                }
            }
            #endif
            // ⌘F 聚焦搜索框（替代 .searchable 自带的 ⌘F 入口）
            .background(
                Button("") { searchFieldFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
    }

    /// 搜索框外观：
    /// - macOS 26+（macOS 27 同款设计语言）用 Liquid Glass 悬浮玻璃面，
    ///   `.interactive()` 让玻璃随指针/按压反馈；内边距在 `glassEffect` 之前给出，
    ///   玻璃形态才会贴合内容尺寸。
    /// - 旧系统回退为 `.quaternary` 半透明填充 + 圆角，保证外观不塌陷。
    @ViewBuilder
    private var searchFieldSurface: some View {
        let content = searchFieldContent
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        } else {
            content
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 搜索框内容（放大镜 + 无边框输入 + 清除按钮），与 TranscriptView 搜索框一致
    @ViewBuilder
    private var searchFieldContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("搜索标题、原文、总结或待办", text: $searchText)
                .accessibilityIdentifier("library.fullTextSearch")
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($searchFieldFocused)
                .onSubmit { searchFieldFocused = false }

            if !searchText.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                // 纯图标按钮：VoiceOver 只会读到 SF Symbol 名，需显式语义标签
                .accessibilityLabel(Text("清除搜索"))
            }
        }
    }

    /// 清空搜索并立即刷新（绕过 300ms 防抖，避免清除后仍短暂显示旧过滤结果）
    private func clearSearch() {
        searchText = ""
        debouncedSearchText = ""
        recomputeFilteredItems()
    }

    /// List 内容：空状态或月份分组列表
    @ViewBuilder
    private var listContent: some View {
        if filteredGroups.isEmpty {
            if !hasVisibleItems {
                ContentUnavailableView(
                    "暂无条目",
                    systemImage: "tray",
                    description: Text("点击工具栏「笔记」新建快捷笔记，或点击「导入」添加音频和视频")
                )
                .listRowSeparator(.hidden)
            } else {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            }
        } else {
            // 月份分组不可手动添加：仅由条目数据驱动，新增条目自动带出对应月份分组
            ForEach(filteredGroups) { group in
                monthGroupRow(group)
            }
        }
    }

    /// 单个月份分组（可折叠）：折叠状态下不构建组内行视图，展开时才加载
    private func monthGroupRow(_ group: MonthGroup) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(for: group.key)) {
            if isMonthExpanded(group.key) {
                ForEach(group.items) { item in
                    deletableRenamableRow(item)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(group.titleDate, format: .dateTime.year().month(.wide))
                    .fontWeight(.semibold)
                Spacer()
                Text(group.items.count, format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 列表项行视图

    /// 列表行（选中态 + tag + 双向滑动操作）。
    /// 单独提取为方法：避免 body 内 ForEach → 条件 → 修饰符链嵌套过深导致类型检查超时
    private func deletableRenamableRow(_ item: ListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            listItemRow(item, isSelected: selectedListItems.contains(item))
            if !debouncedSearchText.isEmpty, let hit = searchHits[item.folderName] {
                Text(verbatim: hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let seconds = hit.seconds, case .recording(let recording) = item {
                    Button {
                        selectedListItems = [item]
                        SourceNavigation.shared.request = .init(recordingID: recording.id, seconds: seconds)
                    } label: {
                        Label("定位原文", systemImage: "play.circle")
                    }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
            .tag(item)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteItem(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                Button {
                    editingItemID = item.id
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                .tint(.blue)
            }
    }

    @ViewBuilder
    private func listItemRow(_ item: ListItem, isSelected: Bool) -> some View {
        switch item {
        case .recording(let recording):
            RecordingRowView(
                recording: recording,
                isSelected: isSelected,
                isEditing: editingItemID == item.id,
                todoItemCount: todoIndex[recording.folderName]?.totalCount ?? 0,
                onTitleChange: onRecordingTitleChange,
                onStartEditing: { editingItemID = item.id },
                onEditingFinished: { editingItemID = nil }
            )
        case .quickNote(let note):
            QuickNoteRowView(
                note: note,
                isSelected: isSelected,
                isEditing: editingItemID == item.id,
                todoItemCount: todoIndex[note.folderName]?.totalCount ?? 0,
                onTitleChange: onQuickNoteTitleChange,
                onStartEditing: { editingItemID = item.id },
                onEditingFinished: { editingItemID = nil }
            )
        }
    }

    // MARK: - 删除

    private func deleteItem(_ item: ListItem) {
        switch item {
        case .recording(let recording):
            onDeleteRecording(recording)
        case .quickNote(let note):
            onDeleteQuickNote(note)
        }
    }

    // MARK: - 侧边栏工具栏项

    @ToolbarContentBuilder
    private var sidebarToolbarItems: some ToolbarContent {
        #if os(macOS)
        // 会议录音按钮
        ToolbarItem(placement: .primaryAction) {
            Button {
                onToggleMeetingRecording()
            } label: {
                Label(isMeetingRecording ? "停止" : "录音",
                      systemImage: isMeetingRecording ? "stop.circle.fill" : "record.circle")
            }
            .controlSize(.large)
            .tint(isMeetingRecording ? .red : nil)
            .help(isMeetingRecording ? "停止录音" : "开始会议录音")
        }

        // 统一「捕获」纯按钮（下拉菜单已取消，目标选择与静/动出口全部收敛到截图悬浮工具栏）：
        // 点按进默认模式会话 → 拖拽=区域 / 悬停单击=窗口 / 空格=全屏，
        // 选定后悬浮工具栏一个地方分流出口：保存/复制/钉住/OCR/文件 或「录制」录为视频；
        // 录屏一步直达（录全屏）与声源/质量快切保留在菜单栏「捕获屏幕」。
        // 仅专业模式显示：普通模式仍可用 ⌃⌘S 与菜单栏「区域截图」完成基础区域截图，
        // 但不暴露这扇通往窗口/全屏/录屏的专业入口。
        if experience == .pro {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onScreenshot()
                } label: {
                    Label("捕获", systemImage: "camera.viewfinder")
                }
                .controlSize(.large)
                .help("捕获屏幕：拖拽选区域、单击选窗口、空格全屏；悬浮工具栏可保存截图或录制为视频（全局热键 ⌃⌘S）")
            }
        }
        #endif

        // 媒体导入独立于快捷笔记，让视频理解的起点可直接发现
        ToolbarItem(placement: .primaryAction) {
            Button {
                onImportMedia()
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .help("导入音频或视频（m4a / mp3 / wav / mp4 / mov / m4v）")
        }

        // 新建快捷笔记按钮
        ToolbarItem(placement: .primaryAction) {
            Button {
                onCreateQuickNote()
            } label: {
                Label("笔记", systemImage: "text.pad.header.badge.plus")
            }
            .controlSize(.large)
            .help("新建快捷笔记")
        }

        // 刷新按钮：同步（含崩溃恢复）期间真实转圈，替代原先 0.6s 假禁用
        ToolbarItem(placement: .primaryAction) {
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await onRefresh()
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Label(isRefreshing ? "同步中…" : "刷新",
                          systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
            }
            .controlSize(.large)
            .help(isRefreshing ? "正在同步磁盘与数据库" : "重新加载列表")
            .disabled(isRefreshing)
        }
    }
}

// MARK: - 待办数量索引

/// 单个条目的待办统计（Sendable，可跨后台任务传递）。
///
/// 列表「已拆待办」状态派生自本结构：条目文件夹名（entryID）→ 统计。
/// `sourceModificationDate` 记录 todos.json 的修改时间，下一次对账时据此跳过
/// 未变化的目录（旧实现每次都把全库 todos.json 解密 + 解析一遍）。
struct EntryTodoCount: Sendable, Equatable {
    /// 条目文件夹名（与 `ListItem.folderName` 同源）
    let entryID: String
    /// 未完成待办数（尚未写入提醒事项）
    let openCount: Int
    /// 已完成待办数（已写入提醒事项）
    let completedCount: Int
    /// todos.json 的修改时间；nil 表示读取不到 mtime
    let sourceModificationDate: Date?

    /// 待办总数（列表徽标判据：> 0 即显示「已拆待办」）
    var totalCount: Int { openCount + completedCount }
}

/// 待办数量索引的纯函数集合：把对账决策从文件系统 I/O 中解耦，便于离线单测。
/// 全部为 nonisolated 静态方法，可在后台任务中调用。
enum TodoCountIndex {

    /// 由待办文档构建统计；空文档返回 nil（等同未拆待办，不入索引）
    static func make(entryID: String, items: [TodoItem], modificationDate: Date?) -> EntryTodoCount? {
        guard !items.isEmpty else { return nil }
        let completed = items.filter { $0.status == .exported }.count
        return EntryTodoCount(
            entryID: entryID,
            openCount: items.count - completed,
            completedCount: completed,
            sourceModificationDate: modificationDate
        )
    }

    /// 是否需要重新读取该目录的待办文件（按 mtime 判定）：
    /// - 两侧都没有修改时间（无文件且无缓存）：无需处理
    /// - 只有一侧有：文件新增或被删除，需要重算
    /// - 两侧都有：mtime 变化才需要
    static func needsRefresh(cached: EntryTodoCount, modificationDate: Date?) -> Bool {
        switch (cached.sourceModificationDate, modificationDate) {
        case (nil, nil):                    return false
        case let (cachedDate?, fileDate?):  return cachedDate != fileDate
        default:                            return true
        }
    }

    /// 增量对账：复用未变化目录的缓存，仅重新读取 mtime 变化的目录，
    /// 并剔除已不在列表中的条目。全程不触碰 SwiftData / MainActor。
    static func reconcile(
        previous: [String: EntryTodoCount],
        folders: [String]
    ) -> [String: EntryTodoCount] {
        var result: [String: EntryTodoCount] = [:]
        result.reserveCapacity(previous.count)
        var seen = Set<String>()
        seen.reserveCapacity(folders.count)
        for folderName in folders where !folderName.isEmpty {
            // 去重：同一文件夹名可能同时出现在录音与笔记数据源里
            guard seen.insert(folderName).inserted else { continue }
            if Task.isCancelled { break }
            let folderURL = AudioRecording.resolveFolderURL(forFolderName: folderName)
            let fileURL = folderURL.appendingPathComponent(TodoDocument.fileName)
            let modificationDate = (try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            if let cached = previous[folderName],
               !needsRefresh(cached: cached, modificationDate: modificationDate) {
                result[folderName] = cached
                continue
            }
            guard let document = TodoDocument.load(from: folderURL),
                  let entry = make(
                    entryID: folderName,
                    items: document.items,
                    modificationDate: modificationDate
                  ) else {
                continue
            }
            result[folderName] = entry
        }
        return result
    }

    /// 只重算单个条目的统计（待办变更通知带 folderName 时用）：
    /// 复用其余条目的缓存，只对该目录做一次 `stat`（必要时再读一次 `todos.json`），
    /// 省掉全库逐个 `stat`。该目录的 `todos.json` 已不存在时删除其索引项。
    static func reconcileOne(
        previous: [String: EntryTodoCount],
        folderName: String
    ) -> [String: EntryTodoCount] {
        guard !folderName.isEmpty else { return previous }
        var result = previous
        let folderURL = AudioRecording.resolveFolderURL(forFolderName: folderName)
        let fileURL = folderURL.appendingPathComponent(TodoDocument.fileName)
        let modificationDate = (try? fileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ))?.contentModificationDate
        if let document = TodoDocument.load(from: folderURL),
           let entry = make(
            entryID: folderName,
            items: document.items,
            modificationDate: modificationDate
           ) {
            result[folderName] = entry
        } else {
            result.removeValue(forKey: folderName)
        }
        return result
    }
}

// MARK: - 条目类型配色

extension AudioRecording.MediaKind {
    /// 列表图标配色：录音红、录屏蓝（与同列表的图片笔记金、文字笔记浅紫错开，提升区分度）。
    /// 仅表达展示层的颜色，类型判据仍集中在 `AudioRecording.mediaKind`
    var tintColor: Color {
        switch self {
        case .audio:           return .red
        case .screenRecording: return .blue
        }
    }
}

/// 图片笔记行首图标配色：金黄（略浅，浅色底上对比更足）
private let imageNoteTintColor = Color(red: 0.80, green: 0.62, blue: 0.14)

/// 文字笔记行首图标配色：浅紫
private let textNoteTintColor = Color(red: 0.66, green: 0.51, blue: 0.88)

// MARK: - 录音行视图
struct RecordingRowView: View {
    let recording: AudioRecording
    /// 当前行是否选中（选中态行底色为系统强调色，图标/标签需提亮保证可读）
    let isSelected: Bool
    /// P1-5: 由父视图驱动编辑状态，替代 NotificationCenter 订阅
    let isEditing: Bool
    /// 已拆出的待办条数（0 = 未拆待办；来自列表级内存索引，文件为权威源）
    let todoItemCount: Int
    let onTitleChange: (AudioRecording, String) -> Void
    let onStartEditing: () -> Void
    let onEditingFinished: () -> Void

    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                // 录音类条目按类型着色、形状区分（不随转写状态变化）：
                // 红色波形 = 纯录音，蓝色显示器 = 录屏（含导入视频）
                //（类型判据集中在 AudioRecording.mediaKind：清理原视频后类型仍成立）
                Image(systemName: recording.mediaKind.iconName)
                    .foregroundStyle(recording.mediaKind.tintColor.adaptedForSelection(isSelected))
                    .opacity(recording.isHidden ? 0.5 : 1.0)
                    .font(.subheadline)
                    .accessibilityHidden(true)

                if isEditing {
                    TextField("标题", text: $titleDraft, onCommit: commitTitle)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .focused($titleFieldFocused)
                        .onAppear {
                            titleDraft = recording.fileName
                            titleFieldFocused = true
                        }
                } else {
                    Text(recording.fileName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            onStartEditing()
                        }
                    Image(systemName: "pencil")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .opacity(0.6)
                    if recording.isHidden {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 6) {
                statusLabel

                Label(recording.formattedDuration, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(recording.isHidden ? .secondary : .primary)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("双击查看详情，双击标题可编辑")
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != recording.fileName {
            onTitleChange(recording, trimmed)
        }
        onEditingFinished()
    }

    private var accessibilityLabel: String {
        let typeText = recording.mediaKind == .audio
            ? String(localized: "录音")
            : String(localized: "录屏")
        // 视觉上已转写/未总结为默认态不占位，朗读仍保留完整状态语义
        let statusText: String
        switch recording.transcriptionStatus {
        case .pending:    statusText = String(localized: "未转写")
        case .processing: statusText = String(localized: "转写中")
        case .completed:  statusText = todoItemCount > 0
            ? String(localized: "已拆待办") + " \(todoItemCount)"
            : (hasSummary ? String(localized: "已总结") : String(localized: "已转写"))
        case .failed:     statusText = String(localized: "转写失败")
        }
        let dateString = DateFormatters.listRowTimestamp.string(from: recording.createdAt)
        // 整句走本地化键：否则非中文界面的 VoiceOver 会把整行读成中文拼接串
        return String(
            format: String(localized: "%@ %@，时长 %@，状态 %@，创建于 %@"),
            typeText, recording.fileName, recording.formattedDuration, statusText, dateString
        )
    }

    /// 是否已生成总结（解密后非空视为已总结，兼容明文回退）
    private var hasSummary: Bool {
        !recording.decryptedSummary.isEmpty
    }

    /// 整合后的单一状态标签（每行最多一个，四类条目统一「价值深度链」）：
    /// 失败 > 转写中 > 已拆待办 > 已总结 > 已转写（默认态不显示）> 未转写。
    /// 「已拆待办」是价值管线的终点（内容 → 转写 → 总结 → 待办），
    /// 为完成态过程标记而非待处理存量；撤销终点（删待办）后回退「已总结」。
    /// 已拆待办/已总结均隐含已转写；未总结与已转写是常态，不占位
    @ViewBuilder
    private var statusLabel: some View {
        switch recording.transcriptionStatus {
        case .failed:
            statusCapsule("失败", color: .red, isSelected: isSelected)
        case .processing:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                Text("转写中")
                    .font(.caption2)
            }
            .foregroundStyle(Color.blue.adaptedForSelection(isSelected))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.blue.opacity(isSelected ? 0.4 : 0.1))
            .clipShape(Capsule())
        case .completed:
            // 录音的待办仅能在总结之后生成，故有待办必已总结
            if todoItemCount > 0 {
                statusCapsule("已拆待办", color: .green, isSelected: isSelected)
            } else if hasSummary {
                statusCapsule("已总结", color: .green, isSelected: isSelected)
            }
        case .pending:
            statusCapsule("未转写", color: .secondary, isSelected: isSelected)
        }
    }
}

// MARK: - 快捷笔记行视图
struct QuickNoteRowView: View {
    let note: QuickNote
    /// 当前行是否选中（选中态行底色为系统强调色，图标/标签需提亮保证可读）
    let isSelected: Bool
    /// P1-5: 由父视图驱动编辑状态
    let isEditing: Bool
    /// 已拆出的待办条数（0 = 未拆待办；来自列表级内存索引，文件为权威源）
    let todoItemCount: Int
    let onTitleChange: (QuickNote, String) -> Void
    let onStartEditing: () -> Void
    let onEditingFinished: () -> Void

    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: note.isImageNote ? "photo.fill" : "text.bubble.fill")
                    .foregroundStyle(
                        (note.isImageNote ? imageNoteTintColor : textNoteTintColor)
                            .adaptedForSelection(isSelected)
                    )
                    .opacity(note.isHidden ? 0.5 : 1.0)
                    .font(.subheadline)
                    .accessibilityHidden(true)

                if isEditing {
                    TextField("标题", text: $titleDraft, onCommit: commitTitle)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .focused($titleFieldFocused)
                        .onAppear {
                            titleDraft = note.title
                            titleFieldFocused = true
                        }
                } else {
                    Text(note.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            onStartEditing()
                        }
                    Image(systemName: "pencil")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .opacity(0.6)
                    if note.isHidden {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 6) {
                // 整合后的单一状态：类型已由行首图标表达（金 = 图片 / 浅紫 = 文字）。
                // 笔记的待办与总结相互独立（待办直接拆自文字内容/图片 OCR，
                // 不依赖总结），故按价值深度取最深者：已拆待办 > 已总结；
                // 两者皆无时为默认态不占位。是否已总结的丢失信息由朗读补全
                if todoItemCount > 0 {
                    statusCapsule("已拆待办", color: .green, isSelected: isSelected)
                } else if hasSummary {
                    statusCapsule("已总结", color: .green, isSelected: isSelected)
                }

                // 文字预览（取前 20 字符）
                if !note.decryptedTextContent.isEmpty {
                    Text(note.decryptedTextContent.prefix(20))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text(note.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(note.isHidden ? .secondary : .primary)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("双击查看详情，双击标题可编辑")
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != note.title {
            onTitleChange(note, trimmed)
        }
        onEditingFinished()
    }

    private var accessibilityLabel: String {
        // 整句走本地化键：否则非中文界面的 VoiceOver 会把整行读成中文拼接串
        // （与 RecordingRowView.accessibilityLabel 保持同一口径）
        let typeText = note.isImageNote
            ? String(localized: "图片笔记")
            : String(localized: "文字笔记")
        // 待办与总结相互独立，朗读同时给出两个维度（视觉上仅显示价值更深者）
        let summaryText = hasSummary ? String(localized: "已总结") : String(localized: "未总结")
        let statusText = todoItemCount > 0
            ? String(format: String(localized: "已拆待办 %lld 条，%@"), todoItemCount, summaryText)
            : summaryText
        let dateString = DateFormatters.listRowTimestamp.string(from: note.createdAt)
        return String(
            format: String(localized: "%@ %@，%@，创建于 %@"),
            typeText, note.title, statusText, dateString
        )
    }

    /// 是否已生成总结（解密后非空视为已总结，兼容明文回退）
    private var hasSummary: Bool {
        !note.decryptedSummaryText.isEmpty
    }
}

// MARK: - 列表行统一状态胶囊

/// 四类条目（录音/录屏/图片/文字）共用的状态胶囊样式；
/// 状态整合后每行最多显示一个（价值深度链规则见 RecordingRowView.statusLabel 注释）
private func statusCapsule(_ text: LocalizedStringKey, color: Color, isSelected: Bool) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(color.adaptedForSelection(isSelected))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(isSelected ? 0.4 : 0.1))
        .clipShape(Capsule())
}

// MARK: - 选中态颜色适配

extension Color {
    /// 选中态颜色适配：不硬编码白色，而是交给系统默认前景色（.primary），
    /// 由系统随选中行实际背景（聚焦强调色/失焦灰/半透明玻璃选区）自适应，
    /// 与整行标题文字的 .primary 保持一致，避免白色在浅灰/玻璃选区上不可见
    func adaptedForSelection(_ isSelected: Bool) -> Color {
        guard isSelected else { return self }
        return .primary
    }
}

// MARK: - 新建快捷笔记 Sheet
struct CreateQuickNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var textContent = ""
    var onCreate: (String) -> Void
    var onCreateFromImage: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Text("新建快捷笔记")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            // 文字输入区
            VStack(alignment: .leading, spacing: 6) {
                Label("粘贴通知文字或会议纪要", systemImage: "text.alignleft")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $textContent)
                    .font(.body)
                    .frame(minHeight: 160)
                    .padding(4)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Spacer()
                    Text("\(textContent.count) 字")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // 分隔线
            HStack {
                Rectangle().fill(.tertiary).frame(height: 1)
                Text("或")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Rectangle().fill(.tertiary).frame(height: 1)
            }

            // 从剪贴板创建图片笔记
            Button {
                onCreateFromImage()
            } label: {
                Label("从剪贴板粘贴图片", systemImage: "photo.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer()

            // 创建按钮
            Button {
                onCreate(textContent)
            } label: {
                Text("创建笔记并拆解待办")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
    }
}

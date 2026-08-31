import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

private enum ChatSidebarMode: String, CaseIterable, Identifiable {
    case chats
    case tasks

    var id: Self { self }
}

private struct ChatTaskDraft: Identifiable {
    let id = UUID()
    var chatID: AppChat.ID?
    var chatTitle: String
    var status: AppChatTaskStatus
    var hasDueDate: Bool
    var dueAt: Date
}

struct ChatSidebarView: View {
    @Bindable var model: AppModel
    @AppStorage(AppAppearance.storageKey)
    private var appearanceRawValue = AppAppearance.system.rawValue

    @State private var hoveredChatID: AppChat.ID?
    @State private var chatBeingRenamed: AppChat?
    @State private var renameText = ""
    @State private var chatPendingDeletion: AppChat?
    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var sidebarMode = ChatSidebarMode.chats
    @State private var taskBeingEdited: ChatTaskDraft?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryControls
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            if sidebarMode == .tasks, !model.taskChats.isEmpty {
                scheduledSummary
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if isSearchVisible || !searchText.isEmpty {
                chatSearch
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            chatList
        }
        .animation(.smooth(duration: 0.18), value: isSearchVisible)
        .alert(
            "Rename chat",
            isPresented: renameAlertPresented,
            presenting: chatBeingRenamed
        ) { chat in
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                model.renameChat(id: chat.id, title: renameText)
            }
            .disabled(renameText.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty)
        } message: { _ in
            Text("Choose a name that identifies this chat's context.")
        }
        .alert(
            "Delete chat?",
            isPresented: deletionAlertPresented,
            presenting: chatPendingDeletion
        ) { chat in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteChat(id: chat.id)
            }
        } message: { chat in
            Text("“\(chat.title)” and its saved document context will be removed.")
        }
        .sheet(item: $taskBeingEdited) { draft in
            ChatTaskEditorSheet(draft: draft) { title, status, dueAt in
                if let chatID = draft.chatID {
                    model.renameChat(id: chatID, title: title)
                    model.setChatTask(
                        id: chatID,
                        status: status,
                        dueAt: dueAt)
                } else {
                    model.createTaskChat(
                        title: title,
                        status: status,
                        dueAt: dueAt)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title3)
                    .foregroundStyle(TurboFieldfareMacTheme.accentColor)
                Text("TurboFieldfare")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .gesture(WindowDragGesture())

            appearanceMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 38)
        .padding(.bottom, 12)
    }

    private var primaryControls: some View {
        HStack(spacing: 8) {
            sidebarModePicker
            searchButton
            newItemButton
        }
    }

    private var searchButton: some View {
        Button(action: toggleSearch) {
            Label("Search", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 30, height: 28)
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSearchVisible
                         ? TurboFieldfareMacTheme.accentColor
                         : Color.secondary)
        .background(
            isSearchVisible
                ? TurboFieldfareMacTheme.accentColor.opacity(0.12)
                : Color.clear,
            in: .rect(cornerRadius: 7))
        .keyboardShortcut("f", modifiers: .command)
        .help("Search (⌘F)")
        .accessibilityValue(isSearchVisible ? "Shown" : "Hidden")
    }

    private var newItemButton: some View {
        Button {
            if sidebarMode == .chats {
                model.createChat()
            } else {
                createTask()
            }
        } label: {
            Label(
                sidebarMode == .chats ? "New chat" : "New task",
                systemImage: sidebarMode == .chats
                    ? "square.and.pencil"
                    : "calendar.badge.plus")
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .foregroundStyle(TurboFieldfareMacTheme.accentColor)
                .frame(width: 32, height: 28)
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(
            TurboFieldfareMacTheme.accentColor.opacity(0.14),
            in: .rect(cornerRadius: 7))
        .disabled(!model.canNavigateChats)
        .help(sidebarMode == .chats
              ? "New chat (⌘N)"
              : "New task")
        .accessibilityLabel(
            sidebarMode == .chats ? "New chat" : "New task")
    }

    private var scheduledSummary: some View {
        HStack(spacing: 6) {
            Label("\(openTaskCount) open", systemImage: "circle.dashed")
            if overdueTaskCount > 0 {
                Text("·")
                Text("\(overdueTaskCount) overdue")
                    .foregroundStyle(.red)
            }
            if todayTaskCount > 0 {
                Text("·")
                Text("\(todayTaskCount) today")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private var chatSearch: some View {
        TextField(
            sidebarMode == .chats ? "Search chats" : "Search tasks",
            text: $searchText)
        .textFieldStyle(.roundedBorder)
        .focused($searchFocused)
        .onExitCommand(perform: dismissSearch)
        .accessibilityLabel(
            sidebarMode == .chats ? "Search chats" : "Search tasks")
    }

    private var sidebarModePicker: some View {
        Picker("View", selection: $sidebarMode) {
            Label("Chats", systemImage: "bubble.left.and.bubble.right")
                .tag(ChatSidebarMode.chats)
            Label("Tasks", systemImage: "checklist")
                .tag(ChatSidebarMode.tasks)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("View")
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if sidebarMode == .chats {
                    if !pinnedChats.isEmpty {
                        chatSection("Pinned", chats: pinnedChats)
                    }
                    if !regularChats.isEmpty {
                        if pinnedChats.isEmpty {
                            ForEach(regularChats) { chat in
                                chatRow(chat)
                            }
                        } else {
                            chatSection("Recent", chats: regularChats)
                        }
                    }
                } else {
                    taskSections
                }
                if filteredChats.isEmpty {
                    emptyListContent
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var taskSections: some View {
        ForEach(AppChatTaskBucket.allCases, id: \.self) { bucket in
            let chats = taskChats(in: bucket)
            if !chats.isEmpty {
                chatSection(bucket.label, chats: chats)
            }
        }
    }

    private var emptyListContent: some View {
        let hasQuery = !searchText.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        let title = hasQuery
            ? (sidebarMode == .chats ? "No Matching Chats" : "No Matching Tasks")
            : "No Tasks Yet"
        let icon = hasQuery ? "magnifyingglass" : "checklist"
        let description = hasQuery
            ? "Try a different title or message."
            : "Choose New task to create a scheduled workspace."
        return ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text(description))
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    @ViewBuilder
    private func chatSection(_ title: String, chats: [AppChat]) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 3)

        ForEach(chats) { chat in
            chatRow(chat)
        }
    }

    private func chatRow(_ chat: AppChat) -> some View {
        let isSelected = chat.id == model.selectedChatID
        let isGenerating = model.isChatRunning(id: chat.id)
        let showsActions = hoveredChatID == chat.id || isSelected

        return HStack(spacing: 4) {
            if sidebarMode == .tasks, let status = chat.taskStatus {
                Button {
                    toggleTaskCompletion(chat)
                } label: {
                    Image(systemName: status == .done
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(.body)
                        .foregroundStyle(taskTint(for: chat))
                        .frame(width: 24, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .help(status == .done ? "Reopen task" : "Mark task done")
                .accessibilityLabel(
                    status == .done ? "Reopen task" : "Mark task done")
            }
            Button {
                model.selectChat(id: chat.id)
            } label: {
                HStack(spacing: 8) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.mini)
                            .help("Generating in this chat")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(chat.title)
                                .font(.callout.weight(
                                    isSelected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if chat.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Pinned chat")
                            }
                            if chat.branchedFromChatID != nil {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help(branchSourceHelp(for: chat))
                            }
                            if chat.contextSummary?.isEmpty == false {
                                Image(systemName: "brain")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help(
                                        "Older turns are kept in compressed memory")
                            }
                        }
                        if let status = chat.taskStatus {
                            HStack(spacing: 4) {
                                if sidebarMode == .chats {
                                    Image(systemName: status.systemImage)
                                }
                                Text(status.label)
                                if let dueAt = chat.taskDueAt {
                                    Text("·")
                                    Text(taskDueLabel(dueAt))
                                }
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(taskTint(for: chat))
                            .lineLimit(1)
                        }
                        if !chat.preview.isEmpty {
                            Text(chat.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, sidebarMode == .chats ? 9 : 0)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!model.canNavigateChats && !isSelected)

            Menu {
                taskMenuItems(for: chat)
                Divider()
                Button(
                    chat.isPinned ? "Unpin" : "Pin to Top",
                    systemImage: chat.isPinned ? "pin.slash" : "pin"
                ) {
                    model.toggleChatPinned(id: chat.id)
                }
                Divider()
                Button("Branch chat", systemImage: "arrow.triangle.branch") {
                    model.branchChat(from: chat.id)
                }
                .disabled(!model.canEditChat(id: chat.id))
                if chat.branchedFromChatID != nil {
                    Button("Go to source chat", systemImage: "arrow.uturn.backward") {
                        model.selectBranchSource(of: chat.id)
                    }
                    .disabled(model.branchSourceChat(for: chat.id) == nil)
                }
                Button("Rename", systemImage: "pencil") {
                    renameText = chat.title
                    chatBeingRenamed = chat
                }
                .disabled(!model.canEditChat(id: chat.id))
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    chatPendingDeletion = chat
                }
                .disabled(!model.canEditChat(id: chat.id))
            } label: {
                Label("Chat actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(showsActions ? 1 : 0)
            .accessibilityHidden(!showsActions)
            .padding(.trailing, 5)
        }
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: .rect(cornerRadius: 9))
        .padding(.leading, chat.branchedFromChatID == nil ? 0 : 12)
        .contentShape(.rect(cornerRadius: 9))
        .onHover { isHovering in
            hoveredChatID = isHovering ? chat.id : nil
        }
        .contextMenu {
            taskMenuItems(for: chat)
            Divider()
            Button(chat.isPinned ? "Unpin" : "Pin to Top") {
                model.toggleChatPinned(id: chat.id)
            }
            Divider()
            Button("Branch chat") {
                model.branchChat(from: chat.id)
            }
            .disabled(!model.canEditChat(id: chat.id))
            if chat.branchedFromChatID != nil {
                Button("Go to source chat") {
                    model.selectBranchSource(of: chat.id)
                }
                .disabled(!model.canEditChat(id: chat.id)
                          || model.branchSourceChat(for: chat.id) == nil)
            }
            Button("Rename") {
                renameText = chat.title
                chatBeingRenamed = chat
            }
            .disabled(!model.canEditChat(id: chat.id))
            Button("Delete", role: .destructive) {
                chatPendingDeletion = chat
            }
            .disabled(!model.canEditChat(id: chat.id))
        }
    }

    @ViewBuilder
    private func taskMenuItems(for chat: AppChat) -> some View {
        Button(
            chat.isTask ? "Edit Task…" : "Add to Tasks…",
            systemImage: chat.isTask ? "slider.horizontal.3" : "checklist"
        ) {
            editTask(chat)
        }
        if let status = chat.taskStatus {
            Button(
                status == .done ? "Reopen Task" : "Mark Task Done",
                systemImage: status == .done
                    ? "arrow.uturn.backward.circle"
                    : "checkmark.circle"
            ) {
                toggleTaskCompletion(chat)
            }
            Button("Remove from Tasks", systemImage: "checklist.unchecked") {
                model.clearChatTask(id: chat.id)
            }
        }
    }

    private var appearanceMenu: some View {
        let appearance = AppAppearance.resolve(appearanceRawValue)
        return Menu {
            Picker("Appearance", selection: $appearanceRawValue) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.label, systemImage: option.systemImage)
                        .tag(option.rawValue)
                }
            }
        } label: {
            Label("Appearance", systemImage: appearance.systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: \(appearance.label)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(appearance.label)
    }

    private var sortedChats: [AppChat] {
        sidebarMode == .chats ? model.sidebarChats : model.taskChats
    }

    private var filteredChats: [AppChat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedChats }
        return sortedChats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(query)
                || chat.preview.localizedCaseInsensitiveContains(query)
                || chat.messages.contains {
                    $0.content.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var pinnedChats: [AppChat] {
        filteredChats.filter(\.isPinned)
    }

    private var regularChats: [AppChat] {
        filteredChats.filter { !$0.isPinned }
    }

    private func taskChats(in bucket: AppChatTaskBucket) -> [AppChat] {
        filteredChats.filter { $0.taskBucket() == bucket }
    }

    private var openTaskCount: Int {
        model.taskChats.filter { $0.taskStatus != .done }.count
    }

    private var overdueTaskCount: Int {
        model.taskChats.filter { $0.taskBucket() == .overdue }.count
    }

    private var todayTaskCount: Int {
        model.taskChats.filter { $0.taskBucket() == .today }.count
    }

    private func toggleSearch() {
        if isSearchVisible || !searchText.isEmpty {
            dismissSearch()
            return
        }
        isSearchVisible = true
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    private func dismissSearch() {
        searchFocused = false
        searchText = ""
        isSearchVisible = false
    }

    private func createTask() {
        taskBeingEdited = ChatTaskDraft(
            chatID: nil,
            chatTitle: "",
            status: .planned,
            hasDueDate: true,
            dueAt: suggestedTaskDueDate(daysFromToday: 1))
    }

    private func editTask(_ chat: AppChat) {
        taskBeingEdited = ChatTaskDraft(
            chatID: chat.id,
            chatTitle: chat.title,
            status: chat.taskStatus ?? .planned,
            hasDueDate: chat.taskDueAt != nil,
            dueAt: chat.taskDueAt
                ?? suggestedTaskDueDate(daysFromToday: 1))
    }

    private func toggleTaskCompletion(_ chat: AppChat) {
        guard let status = chat.taskStatus else { return }
        model.setChatTask(
            id: chat.id,
            status: status == .done ? .planned : .done,
            dueAt: chat.taskDueAt)
    }

    private func taskDueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today, \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow, \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(
            .dateTime.month(.abbreviated).day().hour().minute())
    }

    private func taskTint(for chat: AppChat) -> Color {
        switch chat.taskBucket() {
        case .overdue:
            return .red
        case .today:
            return .orange
        case .completed:
            return .green
        default:
            return .secondary
        }
    }

    private func branchSourceHelp(for chat: AppChat) -> String {
        guard let source = model.branchSourceChat(for: chat.id) else {
            return "The source chat is no longer available"
        }
        guard let message = model.branchSourceMessage(for: chat.id) else {
            return "Branched from \(source.title)"
        }
        let oneLine = message.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Branched from \(source.title) at: \(String(oneLine.prefix(80)))"
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { chatBeingRenamed != nil },
            set: { if !$0 { chatBeingRenamed = nil } })
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { chatPendingDeletion != nil },
            set: { if !$0 { chatPendingDeletion = nil } })
    }
}

private struct ChatTaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let isNewTask: Bool
    let onSave: (String, AppChatTaskStatus, Date?) -> Void

    @State private var chatTitle: String
    @State private var status: AppChatTaskStatus
    @State private var hasDueDate: Bool
    @State private var dueAt: Date
    @FocusState private var isNameFocused: Bool

    init(
        draft: ChatTaskDraft,
        onSave: @escaping (String, AppChatTaskStatus, Date?) -> Void
    ) {
        self.isNewTask = draft.chatID == nil
        self.onSave = onSave
        _chatTitle = State(initialValue: draft.chatTitle)
        _status = State(initialValue: draft.status)
        _hasDueDate = State(initialValue: draft.hasDueDate)
        _dueAt = State(initialValue: draft.dueAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isNewTask ? "New Task" : "Task Details")
                    .font(.title2.weight(.semibold))
                Text(isNewTask
                     ? "Create a focused workspace for this task."
                     : "Update its name, status, or due date.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("What needs to be done?", text: $chatTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Status", selection: $status) {
                    ForEach(AppChatTaskStatus.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Set due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: $dueAt,
                        displayedComponents: [.date, .hourAndMinute])
                    HStack(spacing: 8) {
                        quickDueButton("Today", daysFromToday: 0)
                        quickDueButton("Tomorrow", daysFromToday: 1)
                        quickDueButton("Next Week", daysFromToday: 7)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(chatTitle, status, hasDueDate ? dueAt : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chatTitle.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            isNameFocused = true
        }
    }

    private func quickDueButton(
        _ label: String,
        daysFromToday: Int
    ) -> some View {
        Button(label) {
            hasDueDate = true
            dueAt = suggestedTaskDueDate(daysFromToday: daysFromToday)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private func suggestedTaskDueDate(
    daysFromToday: Int,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Date {
    let startOfToday = calendar.startOfDay(for: now)
    let targetDay = calendar.date(
        byAdding: .day,
        value: daysFromToday,
        to: startOfToday) ?? now
    let preferred = calendar.date(
        bySettingHour: 17,
        minute: 0,
        second: 0,
        of: targetDay) ?? targetDay
    if daysFromToday == 0, preferred <= now {
        return now.addingTimeInterval(3_600)
    }
    return preferred
}

private extension AppChatTaskStatus {
    var label: String {
        switch self {
        case .planned: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .planned: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }
}

private extension AppChatTaskBucket {
    var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .noDueDate: return "No Due Date"
        case .completed: return "Completed"
        }
    }
}

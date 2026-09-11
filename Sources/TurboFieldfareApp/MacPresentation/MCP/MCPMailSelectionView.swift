import SwiftUI
import TurboFieldfareAppCore

public struct MCPMailSelectionView: View {
    let manager: AppMCPManager
    let request: AppMCPMailReviewRequest
    let confirm: (AppMCPMailSelection) -> Void
    let cancel: () -> Void
    @State private var contacts: AppMCPMailContacts
    @State private var selectedSenders: Set<String>
    @State private var excludedMessages = Set<String>()
    @State private var senderSearch = ""
    @State private var subjectSearch = ""
    @State private var editingContacts = false

    public init(manager: AppMCPManager, request: AppMCPMailReviewRequest,
                confirm: @escaping (AppMCPMailSelection) -> Void, cancel: @escaping () -> Void) {
        self.manager = manager; self.request = request; self.confirm = confirm; self.cancel = cancel
        _contacts = State(initialValue: request.contacts)
        _selectedSenders = State(initialValue: request.suggestedSenders)
        _subjectSearch = State(initialValue: request.suggestedSubject)
    }

    private var senderCounts: [String: Int] {
        Dictionary(grouping: request.preview.headers, by: \.sender).mapValues(\.count)
    }
    private var allContacts: [AppMCPMailContact] {
        var result = contacts.contacts
        if request.preview.headers.contains(where: { $0.sender.isEmpty }) {
            result.append(.init(email: "", name: "Неизвестный отправитель"))
        }
        return result
    }
    private var visibleContacts: [AppMCPMailContact] {
        let counts = senderCounts
        return allContacts.filter { senderSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(senderSearch) || $0.email.localizedCaseInsensitiveContains(senderSearch) }
            .sorted { (counts[$0.email, default: 0], $0.name) > (counts[$1.email, default: 0], $1.name) }
    }
    private var matching: [AppMCPMailHeader] {
        request.preview.matching(senders: selectedSenders, subject: subjectSearch)
    }
    private var selectedIDs: Set<String> { Set(matching.map(\.id)).subtracting(excludedMessages) }

    public var body: some View {
        let counts = senderCounts
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Какие письма анализировать?").font(.title2.weight(.semibold))
                    Text("\(request.profileName) · \(request.preview.folder) · \(request.preview.headers.count) писем в списке")
                        .foregroundStyle(.secondary)
                    Text(request.preview.bounds).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Контакты и группы…") { editingContacts = true }
            }
            Text("Пока загружены только заголовки. Модель получит текст отмеченных писем после подтверждения.")
                .font(.callout).foregroundStyle(.secondary)
            if !request.prompt.isEmpty {
                Text(request.prompt).font(.callout).lineLimit(2).help(request.prompt)
            }
            if !request.suggestedSenders.isEmpty {
                Label("Отправители предложены по именам, адресам и группам в запросе. Проверь выбор.", systemImage: "text.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !request.preview.complete {
                Label("Показана часть периода: достигнут предел 10 000 заголовков. Полнота анализа не гарантируется.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Отправители").font(.headline)
                    TextField("Найти контакт", text: $senderSearch).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Все, кроме исключённых") {
                            selectedSenders = Set(allContacts.map(\.email)).subtracting(contacts.excludedEmails)
                        }
                        Button("Снять выбор") { selectedSenders = [] }
                    }.controlSize(.small)
                    if !contacts.groups.isEmpty {
                        Menu("Выбрать группу") {
                            ForEach(contacts.groups) { group in
                                Menu(group.name) {
                                    Button("Только эта группа") { selectedSenders = group.emails.subtracting(contacts.excludedEmails) }
                                    Button("Добавить к выбору") { selectedSenders.formUnion(group.emails.subtracting(contacts.excludedEmails)) }
                                }
                            }
                        }
                    }
                    List(visibleContacts) { contact in
                        Toggle(isOn: Binding(get: { selectedSenders.contains(contact.email) }, set: { enabled in
                            if enabled { selectedSenders.insert(contact.email) } else { selectedSenders.remove(contact.email) }
                        })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.name).lineLimit(1)
                                    Text(contact.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if contacts.excludedEmails.contains(contact.email) {
                                        Text("Исключён по умолчанию").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text("\(counts[contact.email, default: 0])").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }.listStyle(.inset)
                }.frame(width: 355)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Письма · выбрано \(selectedIDs.count) из \(matching.count)").font(.headline)
                    TextField("Тема содержит…", text: $subjectSearch).textFieldStyle(.roundedBorder)
                    if matching.isEmpty {
                        ContentUnavailableView("Нет писем в выборке", systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(selectedSenders.isEmpty ? "Отметь отправителей или выбери группу." : "Для выбранных контактов и темы писем в этом списке нет."))
                    } else {
                        List(matching) { header in
                            Toggle(isOn: Binding(get: { !excludedMessages.contains(header.id) }, set: { enabled in
                                if enabled { excludedMessages.remove(header.id) } else { excludedMessages.insert(header.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(header.subject).lineLimit(2)
                                    Text("\(header.senderName.isEmpty ? header.sender : header.senderName) · \(header.date)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.toggleStyle(.checkbox)
                        }.listStyle(.inset)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Отмена", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(selectedSenders.count) отправителей · \(selectedIDs.count) писем").foregroundStyle(.secondary)
                Button(selectedIDs.isEmpty ? "Продолжить с пустой выборкой" : "Анализировать выбранные (\(selectedIDs.count))") {
                    confirm(.init(messageIDs: selectedIDs, senders: selectedSenders, subject: subjectSearch))
                }.buttonStyle(.borderedProminent)
                    .disabled(selectedSenders.isEmpty && !request.preview.headers.isEmpty)
            }
        }.padding(24).frame(width: 1020, height: 730)
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $editingContacts) {
                MCPMailContactsView(manager: manager, profileID: request.preview.profileID, contacts: contacts) { updated in
                    contacts = updated
                    selectedSenders.subtract(updated.excludedEmails)
                }
            }
    }
}

struct MCPMailContactsView: View {
    @Environment(\.dismiss) private var dismiss
    let manager: AppMCPManager
    let profileID: UUID
    let saved: (AppMCPMailContacts) -> Void
    @State var contacts: AppMCPMailContacts
    @State private var members = Set<String>()
    @State private var groupID: UUID?
    @State private var groupName = ""
    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var search = ""
    @State private var error: String?

    init(manager: AppMCPManager, profileID: UUID, contacts: AppMCPMailContacts, saved: @escaping (AppMCPMailContacts) -> Void = { _ in }) {
        self.manager = manager; self.profileID = profileID; self.saved = saved
        _contacts = State(initialValue: contacts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Контакты и группы").font(.title2.weight(.semibold))
            Text("Контакты собираются из заголовков писем. Группы и исключения сохраняются на этом Mac для выбранного ящика.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Поиск контакта", text: $search).textFieldStyle(.roundedBorder)
                    List {
                        ForEach(contacts.contacts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.email.localizedCaseInsensitiveContains(search) }) { contact in
                            HStack {
                                Toggle(isOn: Binding(get: { members.contains(contact.email) }, set: { enabled in
                                    if enabled { members.insert(contact.email) } else { members.remove(contact.email) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(contact.name).lineLimit(1)
                                        Text(contact.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.toggleStyle(.checkbox)
                                Spacer()
                                Toggle("Исключать", isOn: Binding(get: { contacts.excludedEmails.contains(contact.email) }, set: { enabled in
                                    if enabled { contacts.excludedEmails.insert(contact.email) } else { contacts.excludedEmails.remove(contact.email) }
                                })).toggleStyle(.checkbox).font(.caption)
                            }
                        }
                    }.listStyle(.inset)
                    HStack {
                        TextField("Имя / псевдоним", text: $contactName)
                        TextField("Email", text: $contactEmail)
                        Button("Добавить / обновить") { addContact() }
                    }.textFieldStyle(.roundedBorder)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Группы").font(.headline)
                    List(contacts.groups) { group in
                        HStack {
                            Button(group.name) { groupID = group.id; groupName = group.name; members = group.emails }
                                .buttonStyle(.plain)
                            Spacer()
                            Text("\(group.emails.count)").foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.listStyle(.inset)
                    Button("Новая группа") { groupID = nil; groupName = ""; members = [] }
                    TextField("Название группы", text: $groupName).textFieldStyle(.roundedBorder)
                    Text("Отметь контакты слева: \(members.count)").font(.caption).foregroundStyle(.secondary)
                    Button("Применить состав группы") { _ = saveGroup() }
                        .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.isEmpty)
                    if let groupID {
                        Button("Удалить группу", role: .destructive) {
                            contacts.groups.removeAll { $0.id == groupID }; self.groupID = nil; groupName = ""; members = []
                        }
                    }
                }.frame(width: 240)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Отмена") { dismiss() }
                Spacer()
                Button("Сохранить") {
                    if !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !saveGroup() { return }
                    do { try manager.saveMailContacts(contacts, for: profileID); saved(contacts); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 940, height: 620).background(Color(nsColor: .windowBackgroundColor))
    }

    private func addContact() {
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !email.contains(where: \.isWhitespace), !name.isEmpty else {
            error = "Введи имя и email контакта."; return
        }
        contacts.contacts.removeAll { $0.email == email }
        contacts.contacts.append(.init(email: email, name: name))
        contactName = ""; contactEmail = ""; error = nil
    }
    private func saveGroup() -> Bool {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !members.isEmpty else { error = "Введи название группы и отметь контакты."; return false }
        guard !contacts.groups.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            error = "Группа с таким названием уже есть."; return false
        }
        let group = AppMCPMailGroup(id: groupID ?? UUID(), name: name, emails: members)
        contacts.groups.removeAll { $0.id == group.id }; contacts.groups.append(group); groupID = group.id; error = nil
        return true
    }
}

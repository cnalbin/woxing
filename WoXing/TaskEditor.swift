import SwiftUI

@MainActor
struct TaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TodoStore
    @State private var item: Todo
    @State private var subtasks: [Subtask]
    @State private var reminderDate: Date?
    @State private var validation: String?
    @FocusState private var titleFocused: Bool
    private let original: Todo

    init(store: TodoStore, item: Todo) {
        self.store = store
        original = item
        _item = State(initialValue: item)
        _subtasks = State(initialValue: item.subtasks ?? [])
        _reminderDate = State(initialValue: item.reminder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("任务名称", text: $item.title, axis: .vertical)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1...4)
                        .focused($titleFocused)
                }
                Section {
                    Picker(selection: $item.listID) {
                        Text("收件箱").tag(UUID?.none)
                        ForEach(store.lists) { list in Text(list.name).tag(Optional(list.id)) }
                    } label: {
                        Label("清单", systemImage: "tray")
                    }

                    Toggle(isOn: hasDueDate) { Label("截止日期", systemImage: "calendar") }
                    if item.dueDate != nil {
                        DatePicker("截止日期", selection: dueDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                    }

                    Toggle(isOn: hasReminder) { Label("提醒", systemImage: "bell") }
                    if reminderDate != nil {
                        DatePicker("提醒时间", selection: reminder, displayedComponents: [.date, .hourAndMinute])
                    }

                    Picker(selection: Binding(get: { item.priority ?? .none }, set: { item.priority = $0 })) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    } label: {
                        Label("优先级", systemImage: "flag")
                    }

                    Picker(selection: Binding(get: { item.repeatRule ?? .none }, set: { item.repeatRule = $0 })) {
                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    } label: {
                        Label("重复", systemImage: "repeat")
                    }
                    .disabled(item.dueDate == nil || item.isDone)
                } footer: {
                    if item.isDone {
                        Text("重复安排可在下一次待办中编辑。")
                    } else if item.dueDate == nil {
                        Text("设置截止日期后即可安排重复。")
                    } else if (item.repeatRule ?? .none) != .none {
                        Text("完成后按规则创建下一次待办。")
                    }
                }

                Section("子任务") {
                    ForEach($subtasks) { $subtask in
                        HStack {
                            Button { subtask.isDone.toggle() } label: {
                                Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                    .frame(minWidth: 36, minHeight: 36)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(subtask.isDone ? "标为未完成" : "完成子任务")
                            TextField("子任务名称", text: $subtask.title)
                        }
                    }
                    .onDelete { subtasks.remove(atOffsets: $0) }
                    Button { subtasks.append(Subtask()) } label: {
                        Label("添加子任务", systemImage: "plus")
                    }
                }

                Section("备注") {
                    TextField("添加备注", text: Binding(get: { item.notes ?? "" }, set: { item.notes = $0 }), axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle(original.title.isEmpty ? "新建任务" : "任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Wo行", isPresented: Binding(
                get: { validation != nil || store.message != nil },
                set: { if !$0 { validation = nil; store.message = nil } }
            )) {
                Button("知道了", role: .cancel) { validation = nil; store.message = nil }
            } message: {
                Text(validation ?? store.message ?? "")
            }
            .onAppear {
                if original.title.isEmpty { titleFocused = true }
            }
        }
        .tint(Palette.jade)
    }

    private var hasDueDate: Binding<Bool> {
        Binding(get: { item.dueDate != nil }, set: { enabled in
            item.dueDate = enabled ? Calendar.current.startOfDay(for: .now) : nil
            if !enabled { item.repeatRule = RepeatRule.none }
        })
    }

    private var dueDate: Binding<Date> {
        Binding(get: { item.dueDate ?? .now }, set: { item.dueDate = Calendar.current.startOfDay(for: $0) })
    }

    private var hasReminder: Binding<Bool> {
        Binding(get: { reminderDate != nil }, set: { enabled in
            guard enabled else { reminderDate = nil; return }
            let inOneHour = Date.now.addingTimeInterval(3600)
            if let due = item.dueDate, due > inOneHour {
                reminderDate = Calendar.current.date(byAdding: .hour, value: 9, to: due) ?? due
            } else {
                reminderDate = inOneHour
            }
        })
    }

    private var reminder: Binding<Date> {
        Binding(get: { reminderDate ?? .now }, set: { reminderDate = $0 })
    }

    private func save() {
        var updated = item
        updated.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.subtasks = subtasks.compactMap { subtask in
            var cleaned = subtask
            cleaned.title = cleaned.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.title.isEmpty ? nil : cleaned
        }
        updated.reminder = reminderDate.flatMap { date in
            Calendar.current.dateInterval(of: .minute, for: date)?.start
        }
        if let reminder = updated.reminder, reminder != original.reminder, reminder <= .now {
            validation = "提醒时间需要晚于现在。"
            return
        }
        guard store.save(updated) else { return }
        let shouldRequest = !updated.isDone && (updated.reminder.map { $0 > .now } ?? false)
        dismiss()
        if shouldRequest {
            Task { await store.requestReminderPermission() }
        }
    }
}

@MainActor
struct ListEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TodoStore
    @State private var name: String
    @FocusState private var focused: Bool
    private let list: TodoList?

    init(store: TodoStore, list: TodoList?) {
        self.store = store
        self.list = list
        _name = State(initialValue: list?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("清单名称", text: $name).focused($focused).onSubmit(save)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle(list == nil ? "新建清单" : "重命名清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Wo行", isPresented: Binding(
                get: { store.message != nil }, set: { if !$0 { store.message = nil } }
            )) {
                Button("知道了", role: .cancel) { store.message = nil }
            } message: {
                Text(store.message ?? "")
            }
            .onAppear { focused = true }
        }
        .tint(Palette.jade)
    }

    private func save() {
        if store.saveList(id: list?.id, name: name) { dismiss() }
    }
}

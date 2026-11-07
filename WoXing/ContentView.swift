import SwiftUI
import UIKit

enum Palette {
    static let jade = adaptive(light: 0x176B52, dark: 0x8AD9B0)
    static let ink = adaptive(light: 0x172A23, dark: 0xE8F3EC)
    static let muted = adaptive(light: 0x57665D, dark: 0xA9BDB0)
    static let canvas = adaptive(light: 0xF7F8F3, dark: 0x141C18)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x202C25)
    static let mint = adaptive(light: 0xE2F2DF, dark: 0x273E31)
    static let overdue = adaptive(light: 0xFAEDE7, dark: 0x432C28)
    static let flag = adaptive(light: 0xAE4332, dark: 0xFFA294)
    static let gold = adaptive(light: 0x835D0A, dark: 0xF3CD74)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = TodoStore()
    @State private var editor: Todo?
    @State private var selectedDay = Date.now
    @State private var showCompleted = false
    @State private var showingSearch = false
    @State private var searchedTask: Todo?
    @State private var listEditor: ListDraft?
    @State private var pendingDeletion: TodoList?
    @State private var today = Calendar.current.startOfDay(for: .now)

    private struct ListDraft: Identifiable {
        var id = UUID()
        var list: TodoList?
    }

    var body: some View {
        TabView {
            NavigationStack { todayPage }
                .tabItem { Label("今天", systemImage: "sun.max") }
            NavigationStack { schedulePage }
                .tabItem { Label("日程", systemImage: "calendar") }
            NavigationStack { listsPage }
                .tabItem { Label("清单", systemImage: "checklist") }
        }
        .tint(Palette.jade)
        .sheet(item: $editor) { item in
            TaskEditor(store: store, item: item)
        }
        .sheet(item: $listEditor) { draft in
            ListEditor(store: store, list: draft.list)
        }
        .sheet(isPresented: $showingSearch, onDismiss: openSearchResult) {
            searchPage
        }
        .alert("Wo行", isPresented: Binding(
            get: { store.message != nil && editor == nil && listEditor == nil },
            set: { if !$0 { store.message = nil } }
        )) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active {
                today = Calendar.current.startOfDay(for: .now)
                store.refreshReminders()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = Calendar.current.startOfDay(for: .now)
            store.refreshReminders()
        }
    }

    private var todayPage: some View {
        let calendar = Calendar.current
        let scheduled = store.items.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: today) } ?? false }
        let completed = scheduled.filter(\.isDone)
        let remaining = ordered(scheduled.filter { !$0.isDone })
        let late = ordered(store.items.filter { item in
            !item.isDone && (item.dueDate.map { $0 < today } ?? false)
        })

        return List {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wo行").font(.headline).foregroundStyle(Palette.jade)
                Text("今天").font(.largeTitle.bold()).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(dayLabel(today)).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 7)
            .pageRow()
            progress(completed: completed.count, total: scheduled.count).pageRow()
            if !late.isEmpty {
                sectionTitle("已逾期")
                ForEach(late) { taskRow($0, overdue: true) }
            }
            sectionTitle("今日待办")
            if remaining.isEmpty {
                emptyRow("今天的待办已清空", icon: "checkmark.circle")
            } else {
                ForEach(remaining) { taskRow($0) }
            }
            if !completed.isEmpty {
                Button {
                    withAnimation { showCompleted.toggle() }
                } label: {
                    Label("已完成 \(completed.count) 项", systemImage: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Palette.mint, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .pageRow()
                if showCompleted { ForEach(completed) { taskRow($0) } }
            }
            let inboxCount = store.items.filter { !$0.isDone && $0.dueDate == nil }.count
            if inboxCount > 0 {
                NavigationLink {
                    taskList("未安排", scope: .unscheduled)
                } label: {
                    Label("未安排 \(inboxCount) 项", systemImage: "tray")
                        .foregroundStyle(Palette.jade)
                }
                .pageRow()
            }
        }
        .taskPage()
        .navigationTitle("Wo行")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { searchButton }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { editor = Todo(dueDate: today) } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(Palette.canvas)
                    .background(Palette.jade, in: Circle())
                    .shadow(color: Palette.jade.opacity(0.25), radius: 8, y: 4)
            }
            .accessibilityLabel("添加任务")
            .padding(18)
        }
    }

    private var schedulePage: some View {
        let calendar = Calendar.current
        let tasks = ordered(store.items.filter {
            $0.dueDate.map { calendar.isDate($0, inSameDayAs: selectedDay) } ?? false
        })
        return List {
            MonthCalendar(selected: $selectedDay, marked: Set(store.items.compactMap {
                $0.isDone ? nil : $0.dueDate.map { calendar.startOfDay(for: $0) }
            }))
            .pageRow()
            sectionTitle(dayLabel(selectedDay))
            if tasks.isEmpty {
                emptyRow("这一天没有安排", icon: "calendar")
            } else {
                ForEach(tasks) { taskRow($0) }
            }
        }
        .taskPage()
        .navigationTitle("日程")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                searchButton
                addButton(Todo(dueDate: selectedDay))
            }
        }
    }

    private var listsPage: some View {
        List {
            sectionTitle("快速入口")
            listLink("全部任务", icon: "tray.full", scope: .all)
            listLink("收件箱", icon: "tray", scope: .list(nil))
            listLink("已完成", icon: "checkmark.circle", scope: .completed)
            sectionTitle("我的清单")
            ForEach(store.lists) { list in
                listLink(list.name, icon: "list.bullet", scope: .list(list.id))
                    .swipeActions(allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { pendingDeletion = list }
                        Button("重命名") { listEditor = ListDraft(list: list) }
                            .tint(Palette.jade)
                    }
            }
            Button { listEditor = ListDraft() } label: {
                Label("新建清单", systemImage: "plus").foregroundStyle(Palette.jade)
            }
            .pageRow()
        }
        .taskPage()
        .navigationTitle("清单")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                searchButton
                addButton(Todo())
            }
        }
        .confirmationDialog("删除清单", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { list in
            Button("删除「\(list.name)」", role: .destructive) { store.deleteList(list.id) }
        } message: { _ in
            Text("清单里的任务会移回收件箱。")
        }
    }

    private enum Scope {
        case all, unscheduled, completed, list(UUID?)

        func contains(_ item: Todo) -> Bool {
            switch self {
            case .all: return true
            case .unscheduled: return item.dueDate == nil && !item.isDone
            case .completed: return item.isDone
            case .list(let id): return item.listID == id
            }
        }
    }

    private func listLink(_ title: String, icon: String, scope: Scope) -> some View {
        NavigationLink {
            taskList(title, scope: scope)
        } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(Palette.ink)
                Spacer()
                Text(store.items.filter { scope.contains($0) && (icon == "checkmark.circle" || !$0.isDone) }.count,
                     format: .number)
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 6)
        }
        .pageRow()
    }

    private func taskList(_ title: String, scope: Scope) -> some View {
        let tasks = ordered(store.items.filter { scope.contains($0) })
        let listID: UUID?
        if case .list(let id) = scope { listID = id } else { listID = nil }
        return List {
            if tasks.isEmpty { emptyRow("这里还没有任务", icon: "tray") }
            ForEach(tasks) { taskRow($0) }
        }
        .taskPage()
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { addButton(Todo(listID: listID)) }
        }
    }

    private var searchPage: some View {
        SearchPage(tasks: store.items) { task in
            taskRow(task, edit: {
                searchedTask = task
                showingSearch = false
            })
        }
    }

    private func openSearchResult() {
        if let searchedTask {
            editor = searchedTask
            self.searchedTask = nil
        }
    }

    private var searchButton: some View {
        Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
            .accessibilityLabel("搜索任务")
    }

    private func addButton(_ task: Todo) -> some View {
        Button { editor = task } label: { Image(systemName: "plus") }
            .accessibilityLabel("添加任务")
    }

    private func taskRow(_ item: Todo, overdue: Bool = false, edit: (() -> Void)? = nil) -> some View {
        let list = store.lists.first { $0.id == item.listID }
        return HStack(spacing: 2) {
            Button { store.toggle(item.id) } label: {
                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? Palette.jade : Palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(item.isDone ? "将\(item.title)标为未完成" : "完成\(item.title)")

            Button {
                if let edit { edit() } else { editor = item }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? Palette.muted : Palette.ink)
                    HStack(spacing: 7) {
                        if let list {
                            Text(list.name)
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(Palette.jade)
                                .background(Palette.mint, in: Capsule())
                        }
                        if let date = item.dueDate {
                            Text(date, format: .dateTime.month().day().locale(chineseLocale))
                        }
                        if let reminder = item.reminder {
                            Label(reminder.formatted(.dateTime.hour().minute()), systemImage: "bell")
                        }
                        if let subtasks = item.subtasks, !subtasks.isEmpty {
                            Label("\(subtasks.filter(\.isDone).count)/\(subtasks.count)", systemImage: "checklist")
                        }
                    }
                    .font(.caption).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .accessibilityHint("编辑任务")

            if (item.repeatRule ?? .none) != .none {
                Image(systemName: "repeat").accessibilityLabel("重复任务")
                    .foregroundStyle(Palette.muted)
            }
            if let priority = item.priority, priority != .none {
                Image(systemName: "flag.fill")
                    .foregroundStyle(priority == .high ? Palette.flag : Palette.gold)
                    .accessibilityLabel("优先级\(priority.rawValue)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.trailing, 12)
        .background(overdue ? Palette.overdue : Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .swipeActions(allowsFullSwipe: false) {
            Button(role: .destructive) { store.delete(item.id) } label: { Label("删除", systemImage: "trash") }
        }
        .pageRow()
    }

    private func ordered(_ tasks: [Todo]) -> [Todo] {
        tasks.sorted { first, second in
            if first.isDone != second.isDone { return !first.isDone }
            let a = (first.priority ?? .none).rank
            let b = (second.priority ?? .none).rank
            if a != b { return a > b }
            let firstDue = first.dueDate ?? .distantFuture
            let secondDue = second.dueDate ?? .distantFuture
            if firstDue != secondDue { return firstDue < secondDue }
            return first.createdAt > second.createdAt
        }
    }

    private func progress(completed: Int, total: Int) -> some View {
        let value = total > 0 ? Double(completed) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("今日进度").font(.subheadline.weight(.semibold))
            HStack {
                Text("\(completed) / \(total)").font(.title2.bold().monospacedDigit())
                Text("已完成").font(.subheadline).foregroundStyle(Palette.muted)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.jade)
            }
            ProgressView(value: value).tint(Palette.jade)
                .accessibilityLabel("今日完成比例")
        }
        .foregroundStyle(Palette.ink)
        .padding(16)
        .background(Palette.mint, in: RoundedRectangle(cornerRadius: 18))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.bold())
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 12)
            .pageRow()
    }

    private func emptyRow(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .pageRow()
    }
}

let chineseLocale = Locale(identifier: "zh_CN")

func dayLabel(_ date: Date) -> String {
    let day = date.formatted(.dateTime.month().day().locale(chineseLocale))
    let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(chineseLocale))
    return "\(day) · \(weekday)"
}

extension View {
    func pageRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    func taskPage() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .contentMargins(.bottom, 76, for: .scrollContent)
    }
}

private struct SearchPage<Row: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let tasks: [Todo]
    @ViewBuilder let row: (Todo) -> Row

    var body: some View {
        NavigationStack {
            List {
                let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = tasks.filter { item in
                    keyword.isEmpty || item.title.localizedStandardContains(keyword)
                        || (item.notes?.localizedStandardContains(keyword) ?? false)
                        || (item.subtasks?.contains { $0.title.localizedStandardContains(keyword) } ?? false)
                }
                ForEach(matches, content: row)
                if matches.isEmpty {
                    Text("没有找到任务").foregroundStyle(Palette.muted).pageRow()
                }
            }
            .taskPage()
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索任务、子任务或备注")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

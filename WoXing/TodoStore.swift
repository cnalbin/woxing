import Foundation
import Combine
import UserNotifications

enum Priority: String, Codable, CaseIterable {
    case none = "无", low = "低", medium = "中", high = "高"

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum RepeatRule: String, Codable, CaseIterable {
    case none = "不重复", daily = "每天", weekly = "每周", monthly = "每月"

    func nextDate(after day: Date, anchor: Date, calendar: Calendar) -> Date? {
        switch self {
        case .none: return nil
        case .daily: return calendar.date(byAdding: .day, value: 1, to: day)
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: day)
        case .monthly:
            guard let month = calendar.dateInterval(of: .month, for: day),
                  let nextMonth = calendar.dateInterval(of: .month, for: month.end),
                  let days = calendar.range(of: .day, in: .month, for: nextMonth.start)
            else { return nil }
            let dayOfMonth = min(calendar.component(.day, from: anchor), days.count)
            return calendar.date(byAdding: .day, value: dayOfMonth - 1, to: nextMonth.start)
        }
    }
}

struct Subtask: Identifiable, Codable {
    var id = UUID()
    var title = ""
    var isDone = false
}

struct Todo: Identifiable, Codable {
    var id = UUID()
    var title = ""
    var isDone = false
    var createdAt = Date()
    var dueDate: Date?
    var reminder: Date?
    var listID: UUID?
    var priority: Priority?
    var repeatRule: RepeatRule?
    var repeatAnchor: Date?
    var subtasks: [Subtask]?
    var notes: String?
    var nextOccurrenceID: UUID?
}

struct TodoList: Identifiable, Codable {
    var id = UUID()
    var name: String
}

@MainActor
final class TodoStore: ObservableObject {
    private struct Snapshot: Codable {
        var items: [Todo] = []
        var lists: [TodoList] = []
    }

    @Published private var snapshot = Snapshot()
    @Published var message: String?
    private let url: URL
    private var canWrite = true
    private let notificationCenter = UNUserNotificationCenter.current()
    private var reminderRefresh: Task<Void, Never>?
    private var refreshRequested = false

    var items: [Todo] { snapshot.items }
    var lists: [TodoList] { snapshot.lists }

    init() {
        let directory = URL.applicationSupportDirectory
        url = directory.appendingPathComponent("todos.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                if let legacyItems = try? decoder.decode([Todo].self, from: data) {
                    snapshot.items = legacyItems
                } else {
                    snapshot = try decoder.decode(Snapshot.self, from: data)
                }
            }
        } catch {
            canWrite = false
            message = "无法读取本地待办。原文件已保留，请重新打开应用后再试。"
        }
    }

    @discardableResult
    func save(_ item: Todo) -> Bool {
        var next = snapshot
        let previous = next.items.first { $0.id == item.id }
        var updated = item
        if previous?.dueDate != item.dueDate || previous?.repeatRule != item.repeatRule {
            updated.repeatAnchor = item.dueDate
        }
        if let index = next.items.firstIndex(where: { $0.id == item.id }) {
            next.items[index] = updated
        } else {
            next.items.insert(updated, at: 0)
        }
        return commit(next)
    }

    func delete(_ id: UUID) {
        var next = snapshot
        next.items.removeAll { $0.id == id }
        commit(next)
    }

    func toggle(_ id: UUID) {
        var next = snapshot
        guard let index = next.items.firstIndex(where: { $0.id == id }) else { return }
        var item = next.items[index]
        item.isDone.toggle()
        if item.isDone, item.nextOccurrenceID == nil, let upcoming = nextOccurrence(of: item) {
            item.nextOccurrenceID = upcoming.id
            next.items.insert(upcoming, at: index + 1)
        }
        next.items[index] = item
        commit(next)
    }

    @discardableResult
    func saveList(id: UUID?, name: String) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard !lists.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }),
              title != "收件箱" else {
            message = "已有同名清单，请换一个名称。"
            return false
        }

        var next = snapshot
        if let index = next.lists.firstIndex(where: { $0.id == id }) {
            next.lists[index].name = title
        } else {
            next.lists.append(TodoList(name: title))
        }
        return commit(next)
    }

    func deleteList(_ id: UUID) {
        var next = snapshot
        next.lists.removeAll { $0.id == id }
        for index in next.items.indices where next.items[index].listID == id {
            next.items[index].listID = nil
        }
        commit(next)
    }

    func requestReminderPermission() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            if granted {
                refreshReminders()
            } else {
                message = "提醒已保存。请在系统设置中允许 Wo行 发送通知。"
            }
        } catch {
            message = "提醒已保存，但暂时无法申请通知权限。"
        }
    }

    func refreshReminders() {
        guard canWrite else { return }
        refreshRequested = true
        guard reminderRefresh == nil else { return }
        reminderRefresh = Task {
            while refreshRequested {
                refreshRequested = false
                await reconcileReminders()
            }
            reminderRefresh = nil
        }
    }

    @discardableResult
    private func commit(_ next: Snapshot) -> Bool {
        guard canWrite else {
            message = "本地数据尚未成功读取，请重新打开应用后再试。"
            return false
        }
        do {
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            snapshot = next
            refreshReminders()
            return true
        } catch {
            message = "无法保存待办：\(error.localizedDescription)"
            return false
        }
    }

    private func nextOccurrence(of item: Todo) -> Todo? {
        guard let rule = item.repeatRule, let dueDate = item.dueDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let anchor = item.repeatAnchor ?? dueDate
        var date = dueDate
        repeat {
            guard let next = rule.nextDate(after: date, anchor: anchor, calendar: calendar) else { return nil }
            date = next
        } while date <= today

        var upcoming = item
        upcoming.id = UUID()
        upcoming.createdAt = .now
        upcoming.isDone = false
        upcoming.dueDate = date
        upcoming.repeatAnchor = anchor
        upcoming.nextOccurrenceID = nil
        upcoming.subtasks = item.subtasks?.map { Subtask(title: $0.title) }
        if let reminder = item.reminder {
            let distance = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: dueDate), to: calendar.startOfDay(for: reminder)
            ).day ?? 0
            let time = calendar.dateComponents([.hour, .minute], from: reminder)
            if let reminderDay = calendar.date(byAdding: .day, value: distance, to: date),
               let hour = time.hour, let minute = time.minute {
                upcoming.reminder = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: reminderDay)
            }
        }
        return upcoming
    }

    private func reconcileReminders() async {
        let settings = await notificationCenter.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }

        let pending = await notificationCenter.pendingNotificationRequests()
        let upcoming = items.compactMap { item -> (Todo, Date)? in
            guard !item.isDone, let date = item.reminder, date > .now else { return nil }
            return (item, date)
        }.sorted { $0.1 < $1.1 }.prefix(64)
        let prefix = "woxing.todo."
        let ids = Set(upcoming.map { prefix + $0.0.id.uuidString })
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !ids.contains($0) }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: stale)

        for (item, date) in upcoming {
            let id = prefix + item.id.uuidString
            let components = Calendar.current.dateComponents(in: .current, from: date)
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(timeZone: components.timeZone, year: components.year,
                                             month: components.month, day: components.day,
                                             hour: components.hour, minute: components.minute, second: 0),
                repeats: false
            )
            if let existing = pending.first(where: { $0.identifier == id }),
               existing.content.body == item.title,
               (existing.trigger as? UNCalendarNotificationTrigger)?.dateComponents == trigger.dateComponents {
                continue
            }
            do {
                let content = UNMutableNotificationContent()
                content.title = "Wo行 · 待办提醒"
                content.body = item.title
                content.sound = .default
                try await notificationCenter.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                message = "部分提醒未能加入系统通知，请检查设置后重试。"
            }
        }
    }
}

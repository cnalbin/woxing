import Foundation
import Combine
import CryptoKit
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

struct Subtask: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var isDone = false
}

struct Todo: Identifiable, Codable, Equatable {
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

struct TodoList: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
}

struct TodoSnapshot: Codable, Equatable {
    var items: [Todo] = []
    var lists: [TodoList] = []

    func merged(over remote: Self, since base: Self) -> Self {
        let lists = Self.merge(lists, remote: remote.lists, base: base.lists)
        let listIDs = Set(lists.map(\.id))
        let items = Self.merge(items, remote: remote.items, base: base.items).map { item in
            var item = item
            if let id = item.listID, !listIDs.contains(id) { item.listID = nil }
            return item
        }
        return Self(items: items, lists: lists)
    }

    private static func merge<Item: Identifiable & Equatable>(
        _ local: [Item], remote: [Item], base: [Item]
    ) -> [Item] {
        let previous = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Item.ID>()
        return (remote + local).compactMap { item in
            let id = item.id
            guard seen.insert(id).inserted else { return nil }
            return current[id] == previous[id] ? incoming[id] : current[id]
        }
    }
}

@MainActor
final class TodoStore: ObservableObject {
    enum AuthenticationResult {
        case signedIn
        case confirmationRequired
        case failed(String)
    }

    private struct AccountCache: Codable {
        var current = TodoSnapshot()
        var base = TodoSnapshot()
        var importedGuest = false
    }

    @Published private var snapshot = TodoSnapshot()
    @Published var message: String?
    @Published private(set) var session: CloudSession?
    @Published private(set) var syncStatus = "仅存于本机"
    @Published private(set) var syncing = false
    @Published private(set) var authBusy = false
    @Published private(set) var needsLogin = false
    private let directory = URL.applicationSupportDirectory
    private var guest = TodoSnapshot()
    private var guestReadable = true
    private var account = AccountCache()
    private var generation = UUID()
    private var syncRequested = false
    private var canWrite = true
    private let notificationCenter = UNUserNotificationCenter.current()
    private var reminderRefresh: Task<Void, Never>?
    private var refreshRequested = false

    var items: [Todo] { snapshot.items }
    var lists: [TodoList] { snapshot.lists }
    var canImportGuest: Bool {
        session != nil && canWrite && guestReadable && !account.importedGuest
            && (!guest.items.isEmpty || !guest.lists.isEmpty)
    }

    private var guestURL: URL { directory.appendingPathComponent("todos.json") }

    private func cacheURL(_ user: CloudUser) -> URL {
        directory.appendingPathComponent("woxing-account-\(user.id.uuidString).json")
    }

    init() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: guestURL.path) {
                let data = try Data(contentsOf: guestURL)
                let decoder = JSONDecoder()
                if let legacyItems = try? decoder.decode([Todo].self, from: data) {
                    guest.items = legacyItems
                } else {
                    guest = try decoder.decode(TodoSnapshot.self, from: data)
                }
            }
        } catch {
            guestReadable = false
            message = "无法读取本地待办。原文件已保留，请重新打开应用后再试。"
        }
        snapshot = guest
        canWrite = guestReadable
        do {
            if let restored = try SessionVault.load() {
                switchToAccount(restored, resetNotifications: false)
            }
        } catch {
            message = error.localizedDescription
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
    private func commit(_ next: TodoSnapshot) -> Bool {
        guard canWrite else {
            message = "本地数据尚未成功读取，请重新打开应用后再试。"
            return false
        }
        do {
            if let session {
                var updated = account
                updated.current = next
                try persist(updated, user: session.user)
                syncNow()
            } else {
                try JSONEncoder().encode(next).write(to: guestURL, options: .atomic)
                guest = next
                snapshot = next
                refreshReminders()
            }
            return true
        } catch {
            message = "无法保存待办：\(error.localizedDescription)"
            return false
        }
    }

    func authenticate(email: String, password: String, registering: Bool) async -> AuthenticationResult {
        guard !authBusy else { return .failed("正在连接，请稍候。") }
        authBusy = true
        defer { authBusy = false }
        do {
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: CloudSession?
            if registering {
                result = try await CloudAPI.signUp(email: email, password: password)
            } else {
                result = try await CloudAPI.signIn(email: email, password: password)
            }
            guard let result else { return .confirmationRequired }
            try SessionVault.save(result)
            switchToAccount(result)
            syncNow()
            return .signedIn
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func signOut() {
        guard let session else { return }
        do {
            try SessionVault.clear()
            generation = UUID()
            self.session = nil
            needsLogin = false
            account = AccountCache()
            snapshot = guest
            canWrite = guestReadable
            syncStatus = "仅存于本机"
            syncing = false
            syncRequested = false
            clearTaskNotifications()
            Task { await CloudAPI.signOut(session) }
        } catch {
            message = error.localizedDescription
        }
    }

    func importGuest() {
        guard canImportGuest, let session else { return }
        var updated = account
        let itemIDs = Set(updated.current.items.map(\.id))
        let listIDs = Set(updated.current.lists.map(\.id))
        updated.current.lists.append(contentsOf: guest.lists.filter { !listIDs.contains($0.id) })
        updated.current.items.append(contentsOf: guest.items.filter { !itemIDs.contains($0.id) })
        updated.importedGuest = true
        do {
            try persist(updated, user: session.user)
            syncNow()
        } catch {
            message = error.localizedDescription
        }
    }

    func syncNow() {
        guard session != nil, canWrite, !needsLogin else { return }
        syncRequested = true
        guard !syncing else { return }
        syncing = true
        let generation = self.generation
        Task {
            defer { if generation == self.generation { syncing = false } }
            while generation == self.generation, syncRequested {
                syncRequested = false
                await syncOnce(generation)
            }
        }
    }

    private func switchToAccount(_ session: CloudSession, resetNotifications: Bool = true) {
        generation = UUID()
        syncRequested = false
        syncing = false
        needsLogin = false
        self.session = session
        account = AccountCache()
        canWrite = true
        let url = cacheURL(session.user)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                account = try JSONDecoder().decode(AccountCache.self, from: Data(contentsOf: url))
            }
            syncStatus = "等待同步"
        } catch {
            canWrite = false
            syncStatus = "无法读取账号的本地副本"
            message = "无法读取账号的本地副本，原文件已保留。"
        }
        snapshot = account.current
        if resetNotifications { clearTaskNotifications() }
    }

    private func clearTaskNotifications() {
        // This app only uses notifications for tasks.
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
        refreshReminders()
    }

    private func persist(_ cache: AccountCache, user: CloudUser) throws {
        try JSONEncoder().encode(cache).write(to: cacheURL(user), options: .atomic)
        account = cache
        if snapshot != cache.current {
            snapshot = cache.current
            refreshReminders()
        }
    }

    private func syncOnce(_ generation: UUID) async {
        guard var session else { return }
        syncStatus = "正在同步…"
        do {
            if session.expiresAt <= Date.now.timeIntervalSince1970 + 60 {
                do {
                    let renewed = try await CloudAPI.renew(session)
                    guard generation == self.generation, renewed.user.id == session.user.id else { return }
                    try SessionVault.save(renewed)
                    session = renewed
                    self.session = renewed
                } catch let error as CloudError where error.requiresLogin || [400, 401, 403].contains(error.status) {
                    guard generation == self.generation else { return }
                    needsLogin = true
                    syncRequested = false
                    syncStatus = "登录已过期，待办已保存在本机"
                    return
                }
            }

            for _ in 0..<3 {
                let remote = try await CloudAPI.load(session)
                guard generation == self.generation else { return }
                let incoming = remote?.payload ?? TodoSnapshot()
                let local = account.current
                let merged = local.merged(over: incoming, since: account.base)
                if merged != incoming {
                    let saved = try await CloudAPI.save(merged, after: remote?.revision ?? 0, with: session)
                    guard generation == self.generation else { return }
                    if !saved { continue }
                }

                var updated = account
                updated.current = account.current.merged(over: merged, since: local)
                updated.base = merged
                if updated.current != account.current || updated.base != account.base {
                    try persist(updated, user: session.user)
                }
                syncStatus = "已同步 · \(Date.now.formatted(date: .omitted, time: .shortened))"
                return
            }
            syncStatus = "云端有新改动，稍后重试"
        } catch {
            guard generation == self.generation else { return }
            syncStatus = (error as? CloudError)?.localizedDescription ?? "同步暂未完成，待办已保存在本机"
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
        var bytes = Array(SHA256.hash(data: Data(item.id.uuidString.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        upcoming.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                  bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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

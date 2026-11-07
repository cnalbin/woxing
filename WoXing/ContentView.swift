import SwiftUI

struct Todo: Identifiable, Codable {
    var id = UUID()
    var title: String
    var isDone = false
    var createdAt = Date()
}

@MainActor
final class TodoStore: ObservableObject {
    @Published var items: [Todo] = [] {
        didSet { save() }
    }
    @Published var storageError: String?
    private let url: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = directory.appendingPathComponent("todos.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                items = try JSONDecoder().decode([Todo].self, from: Data(contentsOf: url))
            }
        } catch {
            storageError = "无法读取待办数据：\(error.localizedDescription)"
        }
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(Todo(title: trimmed), at: 0)
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {
            storageError = "无法保存待办数据：\(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var store = TodoStore()
    @State private var input = ""
    @State private var filter = Filter.all
    @FocusState private var inputFocused: Bool

    enum Filter: String, CaseIterable {
        case all = "全部", active = "待完成", done = "已完成"
    }

    private var visibleItems: [Todo] {
        store.items.filter { item in
            switch filter {
            case .all: return true
            case .active: return !item.isDone
            case .done: return item.isDone
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("添加一件待办…", text: $input, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($inputFocused)
                        .submitLabel(.done)
                        .onSubmit(addTodo)
                    Button(action: addTodo) {
                        Image(systemName: "plus").fontWeight(.bold)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("添加待办")
                }
                .padding()
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                if visibleItems.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48)).foregroundStyle(.tint)
                        Text(emptyMessage).font(.headline)
                        Text("一步一步，Wo行！").foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(visibleItems) { item in
                            HStack(spacing: 12) {
                                Button {
                                    if let index = store.items.firstIndex(where: { $0.id == item.id }) {
                                        store.items[index].isDone.toggle()
                                    }
                                } label: {
                                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.isDone ? "标记为未完成" : "标记为已完成")
                                Text(item.title)
                                    .strikethrough(item.isDone)
                                    .foregroundStyle(item.isDone ? .secondary : .primary)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { visibleItems[$0].id })
                            store.items.removeAll { ids.contains($0.id) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Wo行")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("待完成 \(store.items.filter { !$0.isDone }.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .alert("数据存储出错", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
                Button("知道了", role: .cancel) { store.storageError = nil }
            } message: { Text(store.storageError ?? "") }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all: return "还没有待办"
        case .active: return "待办已清空"
        case .done: return "还没有完成的待办"
        }
    }

    private func addTodo() {
        store.add(input)
        input = ""
        inputFocused = false
    }
}

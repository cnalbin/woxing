import SwiftUI

@MainActor
struct CloudAccountView: View {
    private enum Field: Hashable { case email, password }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TodoStore
    @State private var email = ""
    @State private var password = ""
    @State private var registering = false
    @State private var feedback: String?
    @State private var showingImport = false
    @State private var showingSignOut = false
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                if let session = store.session {
                    Section("当前账号") {
                        Label(session.user.email ?? "已登录", systemImage: "person.crop.circle")
                        HStack {
                            Label(store.syncStatus, systemImage: "icloud")
                            if store.syncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                        if !store.needsLogin {
                            Button("立即同步") { store.syncNow() }.disabled(store.syncing)
                        }
                    }
                    if store.canImportGuest {
                        Section {
                            Button("导入本机待办") { showingImport = true }
                        } footer: {
                            Text("导入后，这台手机上的未登录待办会复制到当前账号。")
                        }
                    }
                    if store.needsLogin {
                        credentials
                    }
                    Section {
                        Button("退出登录", role: .destructive) { showingSignOut = true }
                            .disabled(store.authBusy)
                    }
                } else {
                    credentials
                    Section {
                        Label("未登录时，待办保存在这台手机上。", systemImage: "iphone")
                    }
                }
                if let message = store.message {
                    Section {
                        Text(message).foregroundStyle(Palette.muted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("账号与同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(store.authBusy)
                }
            }
            .confirmationDialog("导入本机待办到当前账号？", isPresented: $showingImport, titleVisibility: .visible) {
                Button("导入到当前账号") { store.importGuest() }
            } message: {
                Text("导入后，这些待办会同步到登录同一账号的其他设备。")
            }
            .confirmationDialog("退出当前账号？", isPresented: $showingSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    store.signOut()
                    password = ""
                    email = ""
                    feedback = nil
                }
            } message: {
                Text("未同步的改动会保留在此设备，重新登录同一账号后继续同步。")
            }
        }
        .tint(Palette.jade)
        .interactiveDismissDisabled(store.authBusy)
        .onChange(of: store.needsLogin, initial: true) {
            if store.needsLogin {
                email = store.session?.user.email ?? ""
                registering = false
            }
        }
        .onDisappear { store.message = nil }
    }

    private var credentials: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("邮箱").font(.subheadline.weight(.semibold))
                TextField("邮箱", text: $email, prompt: Text("请输入能收邮件的邮箱"))
                    .labelsHidden()
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .disabled(store.authBusy || (store.needsLogin && store.session?.user.email != nil))
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("密码").font(.subheadline.weight(.semibold))
                SecureField("密码", text: $password, prompt: Text(registering ? "请设置密码" : "请输入密码"))
                    .labelsHidden()
                    .textContentType(registering ? .newPassword : .password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .disabled(store.authBusy)
            }
            .padding(.vertical, 4)
            if let feedback {
                Text(feedback).font(.subheadline).foregroundStyle(Palette.ink)
            }
            Button(registering ? "注册" : "登录", action: submit)
                .disabled(store.authBusy)
            if store.authBusy {
                ProgressView().accessibilityLabel("正在连接")
            } else if !store.needsLogin {
                Button(registering ? "已有账号，去登录" : "没有账号，去注册") {
                    registering.toggle()
                    feedback = nil
                    password = ""
                }
                .font(.subheadline)
            }
        } header: {
            Text(store.needsLogin ? "重新登录" : (registering ? "创建账号" : "邮箱登录"))
        } footer: {
            if registering {
                Text("密码至少 6 个字符，注册后需要验证邮箱。")
            }
        }
    }

    private func submit() {
        guard !store.authBusy else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !address.contains(where: \.isWhitespace) else {
            feedback = "请输入有效的邮箱地址。"
            focusedField = .email
            return
        }
        guard !password.isEmpty else {
            feedback = "请先输入密码。"
            focusedField = .password
            return
        }
        guard !registering || password.count >= 6 else {
            feedback = "密码至少需要 6 个字符。"
            focusedField = .password
            return
        }
        focusedField = nil
        feedback = nil
        Task {
            switch await store.authenticate(email: address, password: password, registering: registering) {
            case .signedIn:
                password = ""
            case .confirmationRequired:
                password = ""
                registering = false
                feedback = "请打开邮箱确认注册，然后返回 Wo行 登录。"
            case .failed(let message):
                feedback = message
            }
        }
    }
}

import SwiftUI

@MainActor
struct CloudAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TodoStore
    @State private var email = ""
    @State private var password = ""
    @State private var registering = false
    @State private var feedback: String?
    @State private var showingImport = false
    @State private var showingSignOut = false

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
                if let message = feedback ?? store.message {
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
        Section(store.needsLogin ? "重新登录" : (registering ? "创建账号" : "邮箱登录")) {
            TextField("邮箱", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(store.authBusy || (store.needsLogin && store.session?.user.email != nil))
            SecureField("密码", text: $password)
                .textContentType(registering ? .newPassword : .password)
                .disabled(store.authBusy)
            Button(registering ? "注册" : "登录", action: submit)
                .disabled(store.authBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || password.isEmpty || (registering && password.count < 6))
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
        }
    }

    private func submit() {
        feedback = nil
        Task {
            let isRegistration = registering
            feedback = await store.authenticate(email: email, password: password, registering: isRegistration)
            password = ""
            if isRegistration { registering = false }
        }
    }
}

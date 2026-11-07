# Wo行

原生 SwiftUI 待办应用，支持添加、完成、筛选、左滑删除和本地保存。需要 iOS 17 或更新版本。

## 构建未签名 IPA

在安装了 Xcode 的 Mac 上打开终端，进入本目录，运行：

```sh
bash build-unsigned.sh
```

产物为 `build/WoXing-unsigned.ipa`。使用自己的签名工具、证书和描述文件重签名后安装。可在 Xcode 工程中调整 Bundle Identifier。数据仅保存在设备本地，删除应用会删除数据。

## 使用 GitHub Actions 云构建

1. 将本目录所有文件上传到你的 GitHub 仓库，确保 `.github/workflows/ios.yml` 也已上传。
2. 打开仓库的 **Actions** 页面，选择 **Build unsigned iOS IPA**。推送到 `main` 或 `master` 会自动构建；也可以点击 **Run workflow** 手动运行。
3. 构建成功后，打开该次运行记录，在 **Artifacts** 下载 `WoXing-unsigned`，解压得到 IPA。
4. 用你自己的证书和描述文件重新签名 IPA，再安装到设备。

如果 Actions 被仓库或组织设置禁用，需要先在仓库 Settings → Actions 中启用。未签名的 IPA 无法直接安装。本项目尚未在云端实际构建，首次运行请查看构建日志。

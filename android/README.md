# Android 手机端

原生 Android 应用（Java / Android SDK，Android 8.0 及以上），与 Windows 工具共用 Vultr 账户和 `nodes.json` 格式。无需额外服务器。应用本身不运行代理；代理连接由手机上的 FlClash 等客户端提供。

## 安装和首次接入

1. 用有私有仓库权限的 GitHub 账号，在手机浏览器打开 [最新版](https://github.com/rrrayyyyye/vultr-node-manager/releases/latest)，下载 `vultr-node-manager.apk` 并安装。如系统询问，允许当前浏览器安装这个 APK。
2. 从电脑仓库根目录私下传入 `nodes.json` 和 `vultr-api.key`。不要把它们加入 Git、公开聊天或公开网盘。
3. 打开「Vultr 节点」→「设置」，分别选择这两个文件，点击「保存并连接」。首次仅查询现有实例，不会新建云资源。导入后可删除手机「下载」等公共目录里的副本，电脑保留原件。
4. 在节点详情或主页导出 YAML。在手机 FlClash 中从文件导入，选择规则模式与所需节点，再实际验证代理访问。

余额卡片是全账户的预计剩余：`-account.balance - account.pending_charges`，不会取绝对值或强制归零；失败时保留上次金额和时间并显著标明查询失败。金额可能滞后，以 Vultr 账单为准。「账户」页余额下方可在外部浏览器打开 Vultr 控制台，查看账单、充值及更多设置，应用不会接收浏览器登录凭据。

时长从云端实例创建时间起算，包含关机期间，每秒在本地更新。其他设备开关后请刷新。DNS / TCP 检查只代表基础连通，不能证明完整代理可用。

## 开关和网络

手机和电脑操作的是同一组云服务器。「销毁」会影响所有连接该节点的设备。关闭 App 不会关闭服务器。操作前避免其他设备同时开关同一地区，本地互斥无法锁定另一台设备。

Vultr API 请求使用 HTTPS、绕过系统 HTTP 代理，但 VPN / TUN 仍可能接管。导出配置包含管理 API 和 DNS 的直连规则，请在 FlClash 使用规则模式并保留这些规则；也可在客户端应用分流中排除「Vultr 节点」。Vultr 若启用了 API 来源 IP 白名单，还需允许手机当前直连出口（移动网络出口可能变化）。本应用不修改或重启 FlClash。

销毁回执成功后立即显示「销毁请求已受理，正在确认」。只通过有效完整的实例查询确认已销毁；网络失败保留待确认状态。销毁确认跳过 DNS、端口和账户，最多自动查询三轮（每轮之间 4 秒）；仍未确认时可手动刷新。销毁记录加密保存，App 重启后继续查询。未确定的写请求不会自动重发。实例如果已被另一台设备重新创建，会识别新 ID，不会销毁新实例。

销毁手机当前正在使用的代理节点会中断 GPT 等连接。请先切换其他可用节点再销毁，或接受代理中断后再重建。管理器选择地区不会自动切换 FlClash。

## 更新

设置 →「下载新版 APK」会打开 GitHub Release（私有仓库需要在浏览器登录）。下载同名 APK，直接覆盖安装，保留本机配置。不要先卸载：卸载会移除本机配置与加密密钥，之后需要重新导入。Windows 仍通过仓库目录里的 `git pull --ff-only` 更新。

程序使用固定包名 `org.raye.vultrmanager` 和固定发布签名。后续发布递增 `versionCode` 与 `versionName`。签名密钥保存在主机 `private-settings/android-signing/`（Git 忽略），对应构建凭据保存为 GitHub Actions 加密 Secrets。请将该目录私下备份；泄露签名密钥需要评估换签，丢失签名则无法正常覆盖旧版。

配置及 API 密钥以 Android Keystore AES-GCM 加密保存在应用私有目录。禁用云备份与设备迁移备份；不包含统计或广告 SDK。导出的 YAML 含连接凭据（不含 Vultr API 密钥），由系统文件选择器写入你指定的位置。

## 开发和发布

Java 17，Android SDK 35，Gradle 8.9（wrapper 校验分发包 SHA-256），AGP 8.7.3。在 `android/`：

```powershell
.\gradlew.bat testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest
```

GitHub Actions 在 Android 代码变更时构建、执行模拟 API 单元测试和 Android lint；在隔离 Android 35 模拟器上检查原生界面、导航、Keystore 往返读写，并输出模拟截图。模拟器使用虚构节点且不创建 API 客户端，不访问真实 Vultr 资源。

主分支构建额外生成固定签名的 `vultr-node-manager.apk`。Secrets：`ANDROID_KEYSTORE_BASE64` 和 `ANDROID_STORE_PASSWORD`；alias 为 `vultr-manager`。外部分支 / PR 不使用签名 Secrets。下载通过的 `android-build` artifact，在所有检查通过后将 APK 和校验和附到 GitHub Release。签名材料、SDK 路径、APK 和构建缓存不提交 Git。

1.1.0 新增 IPv6-only 节点支持：覆盖安装后重新导入更新的 nodes.json（原有 API key 无需更换）。导出新 YAML 后更新 FlClash，并开启其全局 IPv6；先保留可用出口再单独测速。手机主界面各节点卡片保持独立，不需要使用地区下拉框。

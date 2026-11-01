# Vultr 多地区节点管理

已加入原生安卓手机端：安装、导入配置和覆盖更新说明见 [android/README.md](android/README.md)，安装包在 [GitHub Releases](https://github.com/rrrayyyyye/vultr-node-manager/releases/latest)。手机和电脑共用同一组云端节点。

Windows 桌面工具，通过 Vultr API 独立创建、查询和销毁东京、洛杉矶等地区的 sing-box 节点。固定 DuckDNS 域名跟随服务器 IP，客户端无需每次重建都修改地址。

## 在另一台 Windows 主机上使用

仓库保存程序和配置模板。实际账号配置留在本机；首次换机需要额外传递两个文件。

1. 在新主机安装 Git，登录有权访问此私有仓库的 GitHub 账号，然后克隆：

   ```powershell
   git clone https://github.com/rrrayyyyye/vultr-node-manager.git
   cd vultr-node-manager
   ```

2. 从已经能用的主机的仓库目录（`setup.ps1` 同级），通过你信任的方式复制 **`nodes.json` 和 `vultr-api.key`**，例如放到新主机的 `D:\vultr-private-settings`。

3. 在仓库目录执行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -SettingsSource "D:\vultr-private-settings"
   ```

4. 双击新生成的桌面「Vultr节点管理」，选择地区并刷新状态。第一次先查询，不必点击「开节点」。同一 Vultr 账号下，两台电脑管理的是同一组服务器；一台电脑销毁节点会影响所有正在使用该节点的设备。

5. 后续在仓库目录执行 `git pull --ff-only` 更新程序。被 Git 忽略的个人配置会保留。若你改过程序，先保存修改再更新。

要求：Windows PowerShell 5.1（系统自带）或可运行 Windows Forms 的 Windows 环境；可直连 Vultr API 和 AliDNS DoH。Vultr API 如设置了来源 IP 限制，需允许每台管理主机直连时的实际出口 IP。

如果浏览器能访问 GitHub，但 `git clone` 提示连接重置，Git 可能没有使用系统代理。例如新主机的 FlClash 确实监听 `127.0.0.1:7890` 时，可用以下命令克隆；端口不同请改为该主机实际端口：

```powershell
git -c http.proxy=http://127.0.0.1:7890 clone https://github.com/rrrayyyyye/vultr-node-manager.git
cd vultr-node-manager
git config --local http.https://github.com/.proxy http://127.0.0.1:7890
```

这是该主机的本地 Git 配置，不会随仓库同步到其他主机。

## 只在另一台设备使用代理

仅使用线路时无需安装管理工具，也无需复制 Vultr API 密钥。点击「导出配置」，把生成的 `客户端配置/vultr-multi-region.yaml` 导入支持 VLESS + REALITY 的客户端，再选择对应地区。该文件含连接凭据，应私下传递。

## 操作

| 按钮 | 行为 |
|---|---|
| 开节点 | 创建当前地区实例；同标签、同地区实例存在时不重复创建 |
| 关节点 | 确认后永久销毁当前地区实例及数据 |
| 刷新状态 | 查看实例状态、域名解析与 TCP 443 可达性 |
| 导出配置 | 生成包含所有地区的客户端 YAML |

关闭管理窗口不会销毁服务器。普通关机也不等于释放云端资源。实例初始化失败后仍可能存在并计费，应刷新状态后再决定排查或销毁。每个地区的实例分别计费，以 Vultr 实际套餐和账单为准。

管理请求（Vultr API 和域名 DoH 查询）绕过 Windows 系统 HTTP 代理，避免所选代理节点销毁后连带失去查询、创建能力。仅在当前请求内调整 .NET 代理及 TLS 设置，不修改系统代理或 FlClash 配置；兼容旧版 PowerShell 的 TLS 设置，同时保留现代系统的 TLS 默认协商。此设置不绕过 VPN/TUN 等系统层路由，使用 TUN 时仍需保证管理域名能走可用线路。

刷新会重新分页查询云端实例，不依赖本机的开关记录。因此另一台电脑销毁后，本机刷新应显示「未创建 / 已销毁」。只有成功取得完整实例列表后才能确认这一状态；API 断网、鉴权失败或响应不完整会显示「查询失败，未确认云端状态」，不能据此判断已停止。若更新后仍有直连错误，请检查实际网络、系统 TLS 支持和 Vultr API 来源 IP 白名单。

使用 FlClash TUN 时，请使用**规则模式**。导出的配置已在代理兜底规则前加入 `api.vultr.com` 和管理 DNS 的 `DIRECT` 规则；全局模式会忽略这些分流规则，使管理 API 再次依赖正在管理的代理节点。已有客户端需要重新导出并更新导入的配置。修改网络模式可能中断正在使用代理的会话，避免为了测试而关闭当前出口。

本机点击「关节点」后，API 接受销毁请求就立即显示「销毁请求已受理，正在确认」，然后自动查询云端结果。确认失败时保留这条已受理记录，每次确认结束后间隔 4 秒再试，最多自动确认 3 轮；确认实例已消失后显示「已销毁」。等待期间暂停计时并禁用重复开关，仍可手动刷新；不会把网络错误伪装成已销毁。确认过程只查询实例列表，跳过端口、DNS、余额检查，账户余额保留上次更新时间，普通刷新再更新余额。另一台电脑若已重新创建同地区的新实例，本机会识别新实例 ID 并结束对旧实例的等待。

状态标记到达时即更新界面，不再等待较慢的账户查询。只读 API 请求遇到短暂的连接错误最多重试一次，每次默认超时 8 秒；账户查询单次超时 6 秒，创建和销毁请求不会自动重发。HTTP 连接关闭后重新建立，减少复用失效连接的影响。

状态为绿色表示基础检查通过，不代表完整代理握手、网站访问或聊天长连接一定正常。管理器选择地区不会自动切换 FlClash 的出口节点。

界面显示「创建时间」（本机时区，含 UTC 偏移）与「已开时长」，按 Vultr 实例的云端创建时间起算，显示天、小时、分、秒并每秒更新。另一台主机创建的实例也能读取；关闭、重开管理窗口不会重置。这里统计实例存续时间，包含实例关机期间，不是操作系统开机时长。销毁后清空，重建后重新起算。秒钟更新不会额外调用 API；另一台主机销毁实例后，仍需点击「刷新状态」确认。查询失败或创建时间无效时显示「—」。

顶部以大字并排显示当前地区的「已开时长」与全账户的「预计剩余（USD）」。点击「刷新状态」会额外只读查询 `/account`，同时列出预存和待结算费用及更新时间。Vultr API 的 `balance` 是带符号的账面值（负值表示预存），因此预计剩余按 `-balance - pending_charges` 计算，所有地区共用；负的预计剩余表示已超出预存，不会取绝对值或归零。金额按 API 返回值估算，可能滞后，以 Vultr 账单为准。账户查询权限不足、断网或金额字段不完整时显示「查询失败」，不影响节点状态显示；不保存账户姓名、邮箱等个人信息。

命令行用法：

```powershell
.\vultr-node.ps1 status -Node tokyo
.\vultr-node.ps1 start -Node los-angeles
.\vultr-node.ps1 status -Node los-angeles
.\vultr-node.ps1 stop -Node los-angeles
.\vultr-node.ps1 status -Node atlanta-v6
.\vultr-node.ps1 export
```

## 新账号 / 新增地区

没有已有配置时，先执行 `setup.ps1 -InitializeOnly` 生成本地模板，再填写 `nodes.json` 与 `vultr-api.key`。模板中的 `YOUR_*` 值必须全部替换。`setup.ps1` 会检查本地配置，不创建云服务器。

每个地区使用独立的实例标签、域名和云端开机脚本 ID。`server/bootstrap.example.sh` 是去除凭据的服务端模板；替换域名、DuckDNS Token、VLESS UUID、REALITY 私钥和 short ID 后，再通过 Vultr 控制台保存为开机脚本。客户端公钥、UUID、short ID 必须与服务端匹配。已有账号换机时无需重新上传开机脚本。

### IPv6-only 节点

模板包含 `atlanta-v6`：亚特兰大 `atl`、`vc2-1c-0.5gb-v6` 套餐、`ipVersion: ipv6`。是否有库存及实际价格以创建时 Vultr 返回为准。新泽西可使用另一份独立节点配置，将地区设为 `ewr`，同时使用不同的 id、标签、域名和开机脚本。现有配置省略 `ipVersion` 时仍按 IPv4 工作，无需为升级改写旧节点。

纯 IPv6 服务端须把开机模板中的 `IP_VERSION="ipv4"` 改为 `IP_VERSION="ipv6"`，并先在 DuckDNS 网页添加独立子域名。启动脚本自动取得云服务器的 IPv6 地址，只更新该域名的 AAAA 记录；不要填入管理电脑的校园网 IPv6。新域名若有默认的 A 记录，应在首次使用前清除，避免其他客户端连接错误地址。DNS Token 只能更新已有域名，不能代替网页注册子域名。

IPv6 模式通过 [nat64.net](https://nat64.net/) 提供的公共 DNS64/NAT64 访问 GitHub 等仅 IPv4 下载站，服务端域名连接优先使用 IPv6；此服务的可用性会影响安装和仅 IPv4 网站的访问，不保证所有网站兼容，尤其是目标直接提供 IPv4 字面地址时。下载的 sing-box 1.14.2 Linux amd64 安装包校验固定 SHA-256，升级版本时必须同步更新校验值。IPv4 模式不启用这项服务。

管理器使用实例的 `v6_main_ip`、AAAA 查询和 IPv6 TCP 检查显示该节点状态；同一地址的缩写和完整写法视为一致。导出会开启客户端与 DNS 的 IPv6 支持，新节点设置 `ip-version: ipv6`，旧节点保留 IPv4 连接。重新打开管理器即可看到新地区，再导出并更新客户端配置；FlClash 的全局 IPv6 开关若覆盖配置，也需允许 IPv6。管理器不会自动更改当前 FlClash 出口。校园网是否能连到这台境外 IPv6 服务器仍需实测，基础检查不等于 ChatGPT 完整访问测试。

`git pull` 只更新程序和模板，不会把新增的私有节点配置同步到另一台电脑。另一台电脑更新程序后，还需私下同步更新后的 `nodes.json`；同一账号原有的 `vultr-api.key` 无需更换。同步前备份并核对目标配置。

本次 IPv6 适配仅覆盖 Windows 管理器；现有安卓版本仍使用 IPv4 状态查询和导出逻辑，暂时不要用安卓端管理或导出此 IPv6 节点。

不要把实际初始化脚本、密钥、连接配置、日志或备份加入提交，即使这是私有仓库。仓库的 `.gitignore` 已排除这些文件。两台主机同时对同一地区进行开关操作仍可能产生竞态，操作前互相确认；本机互斥锁只约束本机。

## 开发与验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check-syntax.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\node-regression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\status-network.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\portable-setup.ps1
```

测试使用模板、模拟 API 与临时目录，不需要真实凭据，不创建或删除真实实例。GitHub Actions 在提交与 PR 时运行这些检查；这属于自动测试，Codex 自动 PR 审查可日后单独启用。

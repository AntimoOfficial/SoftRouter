# AI 部署手册

本手册使用当前已经存在的脚本。统一 inspect/plan/apply CLI、JSON 状态和自动升级属于 roadmap，不能作为已实现功能调用。开始前阅读仓库根目录 AGENTS.md、本文、compatibility.md 和本目录上一级 README.md。

## 1. 发现，不改变网络

确认 AI 具有本机终端能力，用户能进行接线及本地管理员认证。上游认证由用户和 macOS 完成，不读取密码。先检查是否已有本项目、其他网关、互联网共享、VPN 或 PF 管理程序正在运行；已有工作部署不能直接迁移到本实验安装包。

以下命令在目标 Mac 本地读取状态，结果保留在本机，不能整份公开：

```sh
sw_vers
uname -m
/usr/sbin/networksetup -listallhardwareports
/usr/sbin/networksetup -listnetworkserviceorder
/sbin/route -n get default
/usr/sbin/scutil --dns
/usr/sbin/sysctl net.inet.ip.forwarding net.inet6.ip6.forwarding
/usr/bin/pmset -g custom
```

匹配上下游接口与实际网络服务。只有核对硬件、服务 UUID 和 MAC 后才能填写配置。按安装 README 查询网络服务字典，不上传完整系统偏好。检查下游接口不是远程管理通道或当前默认出口。存在多个候选接口时让用户识别实际网卡，不能猜编号。

PF 状态的读取可能需要管理员权限；工具不能读取时明确记为未检查。不得把权限不足当作空规则或 PF 禁用。当前安装器会在修改网络之前进行特权预检，并拒绝已有资源占用。

## 2. 生成本地配置和具体计划

从 gateway.conf.example 生成本地 gateway.conf，按 README 填写全部七项。配置受 Git 排除，不得强制加入。选择不与上游、已有路由及路由器 LAN 冲突的私有 /24 子网。

计划应包含：已核对的接口与网络服务、Mac 下游地址、路由器 WAN 地址、子网掩码、网关、实际可用的 DNS、需要用户进行的接线或设置、拟修改的服务状态和恢复方式。DNS 从实际上游取得并按 dns-and-proxy.md 验证，不能固定公共 DNS 或某所学校的地址。

先运行无特权静态检查：

```sh
/bin/bash softrouter/tests/run.sh
/bin/bash softrouter/install.sh --check
```

这些检查不等于目标环境兼容，也不等于 PF 实际转发通过。将具体计划与必要的本地管理员步骤一起说明，已经明确授权的步骤无需重复询问。

## 3. 准备独立下游接口并安装

使用 Release 的图形安装包时，仍完成本文的环境发现、配置和下游服务准备，再按 [图形安装说明](desktop-installer.md) 导入配置并安装。图形入口调用同一个严格安装器，不替代前置检查。

保持上游 Wi-Fi，USB 网卡接着 Mac，先拔下下游网线，避免路由器 DHCP 抢占 Mac 默认出口。记录下游服务的原始启用状态、IPv4/IPv6 设置及当前路由，用于恢复用户手动准备步骤。

按照安装 README 将选定的闲置下游服务置于禁用、DHCP、自动 IPv6 的预期初始状态。安装器不会自动转换已有用途的接口。原状态不同则先形成具体变更计划，不能盲目执行示例命令。

在仓库根目录安装，配置参数必须替换为实际绝对路径：

```sh
sudo /bin/bash softrouter/install.sh --config /absolute/path/gateway.conf
/Library/SoftRouter/gatewayctl status
```

管理员密码只输入本地系统提示。若 AI 工具不能取得所需权限，交给用户执行该条命令，不索取密码，不通过控制终端界面绕过工具限制。

安装器是 fresh-install only。已有安装、PF 被占用、恢复锁不明或预检失败时停止该安装路径，读取具体错误。不全局清空 PF，不删除锁，不关闭上游来强行继续。

## 4. 路由器

参照 routers/generic.md 或已核对的型号指南配置静态 WAN。将计划中的地址、掩码、网关、DNS 转成明确参数表，保留 LAN 管理路径，核对实际 WAN 端口后接线。

有已授权的浏览器操作能力和管理会话时可以协助填写，否则由用户填写同一张表。新凭据创建、认证和提交遵循工具权限。未支持的型号不能套用小米端口编号或私有接口。

## 5. 端到端验收

分别记录三个结果：服务已建立、上游可用、真实下游可用。RUNNING 只证明第一项。

- Mac 原来的 Wi-Fi 与默认出口仍正确，网关状态为 RUNNING。
- 下游客户端确认连接路由器；手机临时关闭蜂窝，避免成功来自其他出口。
- 对用户实际要访问的公开站点检查 DNS、直连 HTTPS，以及用户启用的代理路径。根页面 200 可能是错误页，核对页面内容或用户浏览器结果。
- 校园场景至少覆盖普通外网与一个校内站点。修改 DNS 后允许旧缓存失效，再复核；不把暂时超时直接归因于转发服务。
- 缺少客户端访问权限时请用户完成这一项，记为待验收，不能宣称全部完成。

停止与重新启动、重启、真实 DHCP 重取、USB 拔插和合盖会影响网络，只在用户授权的可恢复窗口内执行，按 testing.md 记录实测范围。上游暂时离线期间保持网关运行；已有应用连接可能需要重试。

## 6. 收尾与恢复

在本机私有位置记录版本、配置依据、安装前状态、验收结果和未验证项目。提交问题时按 privacy.md 脱敏。

```sh
sudo /Library/SoftRouter/gatewayctl stop
sudo /Library/SoftRouter/gatewayctl start
sudo /Library/SoftRouter/gatewayctl uninstall
```

正常停止仅清理本程序拥有的资源。ATTENTION 表示需要检查，不能假定卸载已恢复一切。当前卸载保留日志和准备阶段禁用的下游服务；恢复手动准备状态时依据之前的记录，网线仍接着路由器时尤其不要盲目重新启用 DHCP。

# SoftRouter

仓库总入口见 [README](../README.md)，AI 部署从 [操作手册](docs/ai-setup.md) 开始。本文命令在 `softrouter/` 目录执行；本目录以外的个人运维资料不属于发布包。

将一台保持唤醒的 Mac 作为 IPv4 网关：通过 Wi-Fi 接入上游网络，再通过独立以太网接口连接下游路由器的 WAN 口。下游设备连接路由器的 LAN 或 Wi-Fi。

本项目处于实验阶段。此前的专用配置曾在 macOS 14.8.5、Apple M1 上完成客户端联网与停止清理验证；本仓库的通用配置版本尚未真实安装验证。它不提供生产级可用性保证，也不能保证避免内核崩溃。准备本仓库不会迁移既有部署。

```mermaid
flowchart LR
    U[上游 Wi-Fi / 802.1X 网络] --> M[Mac / macOS 管理认证]
    M --> P[PF 标准 NAT / 绑定上游接口]
    P --> E[独立 USB 以太网接口]
    E --> W[下游路由器 WAN / 固定 IPv4]
    W --> C[LAN 与 Wi-Fi 客户端]
```

## 行为与范围

- 只转发一个配置好的下游 WAN IPv4 地址，网关与 WAN 地址位于同一 `/24` 子网。
- 使用 PF 标准 NAT、独立规则锚及绑定上游接口的连接状态；不设置 `route-to`、`reply-to`，不改系统默认路由、DNS、代理或 Wi-Fi 配置。
- 保留上游 DHCP 单播 OFFER/ACK 的本地接收路径，包括尚未配置到本机的地址；独立标签阻止该类回复继续转发。普通规则和清理保护规则均保留此约束。
- 上游 SSID、地址和默认路由只用于诊断。暂时断网不会撤销转发或退出进程；网络恢复后，新连接可自然恢复，已有应用连接可能需要重试。
- 出口限制针对接口，不识别 SSID。若同一 Wi-Fi 接口切换到另一个网络，共享会跟随该接口的新上游。默认路由若走其他接口，下游转发不会被放行到那个出口。
- 企业 802.1X 的连接、认证与凭据由 macOS 管理。项目不保存认证凭据；开机启动服务不代表登录前已经完成网络认证。
- 由 launchd 启动并监督，提供状态、停止及卸载入口。Hammerspoon 不是依赖。

## 前置条件

使用独立、闲置的 USB 网卡作为下游接口，确认它不是当前上网、远程管理或其他设备必需的连接。安装前拔下该网卡的网线，保留 USB 网卡接入 Mac。

下游网络服务必须已经使用 DHCP 与自动 IPv6，且处于 Disabled；接口须为 DOWN、无 IPv4 和 IPv6 地址。安装器不会把其他网络配置自动转换成这些状态。PF 必须处于禁用、无引用、无连接状态且没有不兼容规则的空闲状态；系统 IPv4、IPv6 转发均须关闭。互联网共享、VPN 或其他防火墙可能占用这些资源，预检不通过时不会强行接管。

Mac 必须保持开机和唤醒。睡眠、断电、USB 网卡移除以及上游认证失败均可能中断下游联网。

## 确认接口并填写配置

以下命令只读。先匹配硬件端口、接口名称、MAC 地址与网络服务，再查找该服务对应的 UUID：

```sh
/usr/sbin/networksetup -listallhardwareports
/usr/sbin/networksetup -listnetworkserviceorder
/usr/libexec/PlistBuddy -c 'Print :NetworkServices' /Library/Preferences/SystemConfiguration/preferences.plist
```

在最后一项输出中，核对同一 UUID 下的 `UserDefinedName` 与 `Interface:DeviceName`。不要把同名服务或其他网卡的 UUID 填入配置，也不要公开完整查询输出。

```sh
cp gateway.conf.example gateway.conf
```

配置为七条 `KEY=VALUE`，不加引号、不执行 Shell 展开、不写行内注释。将示例中的所有设备值替换为本机已核对的值：

| 配置项 | 含义 |
|---|---|
| `UPSTREAM_INTERFACE` | 上游 Wi-Fi 接口，例如 `en0` |
| `DOWNSTREAM_INTERFACE` | 独立 USB 网卡接口，例如 `en7` |
| `DOWNSTREAM_SERVICE` | 该网卡的网络服务名称 |
| `DOWNSTREAM_SERVICE_UUID` | 该网络服务的实际 UUID |
| `DOWNSTREAM_MAC` | 该网卡的实际单播 MAC 地址 |
| `GATEWAY_ADDRESS` | Mac 下游地址，例如 `192.168.77.1` |
| `CLIENT_ADDRESS` | 下游路由器 WAN 地址，例如 `192.168.77.2` |

接口名称使用 `en` 加数字；服务名称仅支持 ASCII 字母、数字、空格与 `._()/+-`。两个地址须属于同一 `/24` 子网，不能相同，也不能使用网络地址或广播地址。该子网不能与上游网络、其他接口或路由器 LAN 子网冲突。

只有确认选中的是闲置下游网卡之后，才禁用它的网络服务。将下列服务名称替换为已核对的实际名称：

```sh
/usr/sbin/networksetup -getinfo 'USB Ethernet'
/usr/sbin/networksetup -getnetworkserviceenabled 'USB Ethernet'
sudo /usr/sbin/networksetup -setnetworkserviceenabled 'USB Ethernet' off
/sbin/ifconfig en7
```

最后一条命令中的接口名称也须替换为实际值。若 DHCP、自动 IPv6、DOWN 或无地址等前提不满足，先解决该接口的既有用途与配置；不要通过清空 PF 或修改上游网络来绕过预检。

## 安装与使用

在 `softrouter/` 目录执行，配置文件使用实际绝对路径：

```sh
sudo /bin/bash install.sh --config /path/gateway.conf
/Library/SoftRouter/gatewayctl status
```

本版本更名自 Air Gateway。安装器会拒绝已有的 SoftRouter 或 Air Gateway 安装、launchd 作业及遗留运行状态；不自动迁移旧配置，也不接管旧服务。已有部署须先按其原说明停止、核实清理并卸载，再单独计划新安装。旧日志会保留。

安装位置为 `/Library/SoftRouter`，launchd 标签为 `org.softrouter.gateway`。日志保存在 `/Library/Logs/SoftRouter`，本轮私有运行状态位于 `/private/var/run/softrouter`。

确认状态为 `RUNNING` 后，将网线接到下游路由器的 WAN 口。自行将路由器 WAN 设为 `CLIENT_ADDRESS`、掩码 `255.255.255.0`、网关 `GATEWAY_ADDRESS`，DNS 使用该上游可访问的解析器；路由器 LAN 使用不同子网。项目不修改路由器配置。

测试时确认客户端确实连接下游路由器，并关闭测试设备的蜂窝数据、其他热点与 VPN，避免把其他路径的成功当作共享成功。`RUNNING` 表示网关配置已建立，不代表上游已认证或互联网可达。完整验收方法见 [测试说明](docs/testing.md)。

```sh
sudo /Library/SoftRouter/gatewayctl stop
sudo /Library/SoftRouter/gatewayctl start
sudo /Library/SoftRouter/gatewayctl uninstall
```

`stop` 禁用并卸载 launchd 作业，由守护进程清理本轮资源；`start` 重新启用。卸载先停止并确认清理，再移除项目安装文件，保留日志。下游网络服务仍保持 Disabled，不会自动重新开启 DHCP 或恢复安装前用户手动改变的设置。

## 只读诊断

新安装可运行 `/Library/SoftRouter/gatewayctl diagnose --days 3`；源码可运行 `/bin/bash diagnose.sh --days 3`。不需要 sudo，生成私有 Markdown/JSON 报告。图形应用也提供按钮，详见 [巡检 SOP](docs/diagnostics.md)。

## 状态与恢复

| 状态 | 含义 |
|---|---|
| `STARTING` | 正在核对资源与接口 |
| `RUNNING` | 本轮转发配置已建立；上游健康仅观测 |
| `STOPPED` 且 `cleanup_ok=1` | 已确认本轮运行时资源撤销 |
| `ATTENTION` | 所有权不明或清理不完整，需要检查保留的状态 |

同一次系统启动中遗留的私有状态目录会阻止新实例接管。不要删除该目录强行重试，也不要执行全局 PF 清空或关闭命令；目录可能对应仍存活的进程、规则或引用。停止命令若报告状态残留，表示服务已停止自动运行，但不能据此认定资源已完全撤销。恢复边界见 [设计说明](docs/design.md)。

问题报告中只提交脱敏后的状态与相关错误片段，不上传整份配置、系统网络偏好或私有恢复目录，详见 [隐私说明](docs/privacy.md)。

## 许可证

[MIT](LICENSE)，Copyright 2026 SoftRouter contributors。

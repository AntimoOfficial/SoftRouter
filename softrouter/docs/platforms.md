# 三端安装与验证范围

目标拓扑一致：操作系统连接并认证上游 Wi-Fi，电脑的独立有线网口连接路由器 WAN，下游设备连接路由器。

## 选择平台

| 平台 | 后端与入口 | 路由器 WAN |
|---|---|---|
| macOS | [原生应用与 PF 网关](desktop-installer.md) | 按本机生成的静态地址、网关和 DNS 配置 |
| Windows | [ICS 图形助手](../windows/README.md)，解压安装包后运行 `Install.cmd` | 优先 DHCP，具体地址由系统 ICS 分配，读取软件结果 |
| Linux | [NetworkManager 图形助手](../linux/README.md)，`.deb` 或 `install.sh` | DHCP，使用所建共享连接实际提供的子网 |

Windows/Linux 为 `0.1.0-alpha.5` 新增社区测试版本。提供应用、安装和恢复入口，尚无真实网卡、校园认证、重启或下游联网测试记录。离线解析、模拟和包结构验证不是兼容性认证。macOS 的合盖和 DHCP 实测不能推广到其他后端。

三端均不实现校园认证协议、不导入代理订阅，不要求把密码交给 AI。先用系统完成认证，再配置共享。新平台复用系统共享功能，其 DNS、DHCP、IPv6、启动和网络选择行为可能与 PF 实现不同；以平台 README 的限制为准。

## 交给本机 AI

> 请先识别本机操作系统，读取 SoftRouter 的 README、AGENTS.md、platforms.md 和本平台 README。只读确认上游与闲置有线接口，检查已有共享、VPN、虚拟机网络与路由占用。生成具体变更及恢复计划，使用下载包提供的安装入口。配置是数据，不执行配置中的代码。启用共享后从实际下游设备验证，分别记录通过、失败和未测试项目。需要接线或本地管理员认证时说明具体步骤。

## 下载与验收

Release 包含三端软件、公开源码与 `SHA256SUMS`。Windows 包是包含图形应用和双击安装脚本的 ZIP，不是已签名 EXE。Linux `.deb` 只安装应用与桌面入口，没有自动启用共享的维护脚本。缺少依赖时使用发行版包管理器提供的 NetworkManager、Python/Tk 与 PolicyKit。

各端启用共享前保留上游连接，断开闲置下游网口的网线，避免路由器 LAN 的 DHCP 接管电脑默认出口。按平台界面完成配置后接到路由器 WAN；恢复时只撤销本程序持有的共享资源。

社区测试报告见 [模板](https://github.com/AntimoOfficial/SoftRouter/issues/new?template=platform-test.md)。应用安装成功、共享状态建立、真实下游联网成功和关闭共享后恢复是四个独立结果。

# SoftRouter

安装在 Mac 上、用于共享校园网的软路由。

SoftRouter 将保持唤醒的 Mac 作为 IPv4 网关：Mac 通过 Wi-Fi 连接上游，独立以太网接口连接路由器 WAN，下游设备使用路由器的 LAN 或 Wi-Fi。

macOS 负责校园或企业 802.1X 认证，SoftRouter 负责有线转发与常驻管理。上游暂时断线时服务保持运行，上游恢复后客户端可以重新建立连接。

当前为 `0.1.0-alpha.1` 开发预览。通用化版本通过离线检查，但尚未完成真实安装验收；专用部署的成功不能推广为所有 Mac、系统和网卡均受支持。详见 [兼容性与验证范围](softrouter/docs/compatibility.md)。

## 交给 AI 配置

把本仓库地址和下面这段话交给能操作本机终端的 AI：

> 请读取仓库的 README.md、AGENTS.md 和 softrouter/docs/ai-setup.md，帮助我把这台 Mac 配置为 Wi-Fi 上游、有线路由器下游的共享网关。先只读检查环境，形成具体配置与恢复方案，再完成安装和真实下游验收。需要我接线、输入密码或提供权限时说明具体操作。

只有聊天能力的 AI 可以指导命令，不能自行配置电脑。管理员认证、校园认证和接线可能需要用户参与。没有浏览器控制能力或路由器管理会话时，由用户按 AI 生成的 WAN 参数表填写。

- [AI 部署手册](softrouter/docs/ai-setup.md)：判断顺序、现有命令、失败处理。
- [安装与使用](softrouter/README.md)：配置格式、安装、状态、停止和卸载。
- [DNS 与代理](softrouter/docs/dns-and-proxy.md)：处理部分校园网站打不开。
- [排障指南](softrouter/docs/troubleshooting.md)：区分上游、转发、解析和客户端问题。
- [后续实现计划](softrouter/docs/roadmap.md)：明确区分现有能力与尚未实现的接口。

## 仓库分区

```text
.
├── README.md / AGENTS.md        项目与 AI 入口
├── LICENSE / CONTRIBUTING.md   许可证与贡献说明
├── SECURITY.md                安全报告说明
├── PUBLISH_FILES.txt           发布文件白名单
├── .github/                    CI 与问题模板
└── softrouter/                 可发布的程序、文档与测试
```

可以直接将工作区根目录作为 Git 仓库。根目录其他本地文件默认被 `.gitignore` 排除；网络试验、备份、运行证据和个人配置不随仓库上传。历史经验整理到公开文档和合成测试中。

发布前检查白名单及暂存内容，不能只依靠 `.gitignore`：

```sh
/bin/bash softrouter/tests/run.sh
python3 softrouter/tools/check-publication.py --staged
```

校验通过并提交后，可用下列命令从已提交的文件生成源码包，不遍历整个工作区：

```sh
/bin/bash softrouter/tools/package.sh
```

源码包输出到本地忽略的 `dist/`，包含提交编号及 SHA-256 校验文件。所有现有功能以源码和安装说明为准，不需要特定 AI 插件或 Hammerspoon。

许可证：[MIT](LICENSE)。

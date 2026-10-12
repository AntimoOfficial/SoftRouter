# 网络巡检 SOP 与只读诊断

诊断程序是一次有时间范围的证据快照，不是后台监控，也不执行修复。不需要 sudo、Python、Clash 或额外守护服务。只依赖 macOS 自带 Bash 和系统工具。

## 入口

安装新版图形应用后点击「生成诊断报告」，可以不安装或迁移现有网关。选择保存位置；接口、公开测试网址和本机 HTTP 代理均为可选项。默认回看最近三天。旧应用需要换用包含该功能的新安装包，旧网关核心不需要因此升级。

期望 Wi-Fi 字段和 `--expected-ssid` 从 `0.1.0-alpha.4` 开始提供，旧 `0.1.0-alpha.3` 安装包不包含。运行已有入口时先检查 `--help`，不要假定安装新应用会升级已运行的网关。

`0.1.0-alpha.5` 的 macOS 报告新增供电、睡眠策略解释、当前盖状态和下游协商速率，并在应用中展示摘要。`SleepDisabled=1` 表示整机全局禁睡；电池供电时标为需关注，不自动改电源。入口 HTTP 请求成功仅属于主机证据；下游验收始终单列。报告末尾提供空白合盖记录，供人工填写真实条件和结果，详见 [电源与合盖](power-and-lid.md)。这些采集命令仅适用于 macOS，Windows/Linux 使用各自平台入口。

源码目录可直接运行：

```sh
/bin/bash softrouter/diagnose.sh --days 3 --output-dir /private/tmp
```

新安装的网关也提供同一入口：

```sh
/Library/SoftRouter/gatewayctl diagnose --days 3 --output-dir /private/tmp
```

程序创建独立的私有目录，生成 report.md、report.json、evidence.tsv。退出码 0 表示报告已生成，不表示所有检查通过；参数或执行失败返回非零。无接口字段的旧部署需核对后传入 --upstream / --downstream，不能照抄示例网卡编号。

人类可从图形界面生成并阅读 report.md；AI 可调用上述命令，按 report.json 的 facts、events、probes 和可选 history_summary 读取同一份证据。命令行的 --days 支持 1 至 7 天；先检查实际入口的 --help。现有接口是一次性诊断和本地文件，不需要额外运行时 API 或后台服务。

可选网页对照：

```sh
/bin/bash softrouter/diagnose.sh --days 3 --output-dir /private/tmp \
  --url https://example.com/ --proxy http://127.0.0.1:7890
```

用用户真正关心的公开页面替换网址与本机代理端口。最多五个网址；拒绝含用户名密码、查询参数、片段或空白的 URL。没有 --url 时不发送网页测试请求；未传 --proxy 时只测直连。不开启代理、不读取订阅、控制器密钥或浏览器登录会话。程序禁用 curlrc，保留 TLS 证书校验，限制重定向协议、时间与正文大小，不保存正文和 Cookie。

兼容现存部署的只读检查可显式指定 --label 与 --log-dir。仅读取小型 status.txt 和日志文件元信息，不执行旧部署的代码，不自动迁移。没有足够权限的项目保留 unknown。

可选上游 Wi-Fi 比对：

```sh
/bin/bash softrouter/diagnose.sh --days 3 --output-dir /private/tmp \
  --upstream en0 --expected-ssid 'Campus Wi-Fi'
```

先核对实际 Wi-Fi 接口与预期名称，再替换示例。名称按原样比对，不忽略前后空格；图形界面可填写同样的期望 Wi-Fi 字段。匹配记为 observed，错配记为 attention；权限不足、SSID 被隐藏或工具输出无法识别时记为 unknown，不猜测当前网络。报告不保存预期或实际 SSID 原文；名称仍是本地命令参数，敏感环境可用图形入口避免写入终端历史。未提供此选项时不新增 SSID 采集。

比对只回答当前 Wi-Fi 是否与期望一致，不检查自动加入开关，不限制出口，也不重连网络。即使 Wi-Fi 接口、IPv4 转发和进程均正常，连接自身下游仍可能使共享失去真正的上游。

## SOP

1. **界定时间和对象。** 确认目标主机、实际部署、上游和下游接口、预期 Wi-Fi、需要检查的公开站点。不要把当前默认出口必然当成配置期望的出口；已核对预期名称时可显式传入 --expected-ssid。
2. **采集当前状态。** 同时核对 launchd、磁盘状态、系统启动会话、父子进程与转发开关；再检查路由、DNS、DHCP、链路、网卡累计错误和电源。状态文件可能很旧，必须和实时证据交叉验证。
3. **限定历史检索。** 查询认证、漫游和 DHCP 事件，保留时间与事件类别。单条系统命令有限时和输出上限，历史查询最多 20 秒，按时间保留最近 300 条去重事件；摘要统计本次取得的全部去重事件，并标记列表是否截断。超时或权限不足不算零故障，命令完成也不证明系统日志完整覆盖所选时间窗。程序不执行耗时的全库 log stats。
4. **验证实际访问。** 指定站点后比较当前直连与可选本机代理。HTTP 成功只证明入口请求完成；AI 或用户仍需查看正确的页面、标题或必要公开资源。认证根路径的 200 可能是错误页，不自动填密码或提交表单。
5. **独立验收下游。** Air/Mac 自身的请求不能证明路由器客户端能用。需要真实客户端或用户反馈；手机验收须排除蜂窝兜底。没有权限或用户暂停管理时，保留未验证，不擅自建立 SSH。
6. **报告证据和边界。** 区分 observed、attention、unknown、unverified；写清时间窗、当前结果、实际历史事件与缺口。没有持续采样就不计算在线率；漫游至租约恢复耗时不能当作精确断网时长。

发现上游错配时，核对是否误连下游路由器，以及 macOS 中该网络的自动加入状态。修复按 [部署手册](ai-setup.md#2-生成本地配置和具体计划) 关闭下游自动加入、保留目标上游自动加入，保存后重新打开设置验证。巡检程序不会代为修改；仅核验设置和现网不能视为已验证下一次断线后的恢复行为。

## 人工近期汇报

用户要求近期软件或运行总结时，将本机诊断与 GitHub 项目情况合并汇报；针对单个具体联网故障的检查仍按上述 SOP 处理。记录查询时间和两个独立窗口：本机诊断范围与 GitHub 接口实际返回的统计日期。无需定时任务或持续监控。

通过可用的 GitHub 连接器或已有认证的 gh CLI，只读核查 [SoftRouter 仓库](https://github.com/AntimoOfficial/SoftRouter)：

| 维度 | 必须区分的证据 |
|---|---|
| 版本与验证 | 远端默认分支、本地 HEAD、公开源码未提交改动；最新 Release、标签与对应提交；该提交的 CI 结果及验证范围 |
| 访问 | 最近 14 天的 views、uniques、clones、unique cloners；接口实际日期桶、时区和未覆盖日期；有权限时补充来源与热门路径 |
| 社区反馈 | Stars 并辨别仓库所有者或已知维护者本人；Forks、Watchers；全部状态的 Issues、PR、Issue/PR 评审与提交评论；Discussions 启用情况及可读讨论 |
| 下载 | 各平台安装资产与源码资产的累计下载，分开列出；有上次基准时按同一资产 ID 比较变化 |

gh CLI 可分别读取 repos/AntimoOfficial/SoftRouter/traffic/views 与 traffic/clones；它们需要相应仓库权限。Watchers 使用 subscribers_count，不能用与 Stars 同义的 watchers_count。CI 应按准确提交查询 push 运行；只查询 PR 运行的接口不能证明推送 CI 缺失。

权限不足、接口不可用或返回日期落后时写明 unknown 和缺口，不强制登录，不把缺失日期填零。有先前人工汇报时注明基准日期和来源，访客统计按实际窗口并列比较，累计下载核对资产 ID，避免将重传资产当成同一计数。独立访客、clone 来源和下载都不能换算成真实安装用户；不同滚动窗口不能直接相减为增长率。没有 Issues 只说明该公开渠道未收到记录，不能推定没有问题。统计口径见 [GitHub Traffic 文档](https://docs.github.com/en/repositories/viewing-activity-and-data-for-your-repository/viewing-traffic-to-a-repository)。

汇报附本地诊断与 GitHub 证据链接，分别说明当前服务、历史上游事件、真实下游验收、已发布版本和待发布改动。代码与推广判断须沿用实际验证范围，不能把离线检查或单台专用部署推广为通用兼容性。此流程不修改仓库、不自动发帖或发送消息，不上传私有报告、配置或凭据。

## 输出与隐私

report.json 的 schema_version 为 1，包括 facts、events、probes。每条 fact 带 id、state、value；downstream_verified 固定为 false，availability_percent 为 null，明确本程序无法独立证明这两项。

`0.1.0-alpha.6` 已提供可选的 history_summary，保持 schema_version 为 1，以兼容旧报告。event_count 是本次取得的去重事件数，retained_count 是列表保留数，truncated 标明是否省略较早事件；auth_failure_count、wireless_disconnect_count 和 dhcp_no_server_count 分别统计可见的认证失败、无线断链和 DHCP 未获服务器回复记录。last_abnormal_at 为最后一条异常记录的时间，无异常时为 null。计数不是断网次数或断网时长，也不证明整个时间窗没有其他故障。

collection_state 与 coverage 说明检索证据范围；失败或超时留下的记录只算部分结果，跳过查询与没有取得有效证据分别说明。当前 attention_count 仍只统计当前事实中的不一致，不包含已经恢复的历史异常。图形界面单独展示历史摘要；旧报告没有该字段时只能汇总旧列表中的可见事件，不能推定全部取得事件数或完整时间窗。

`0.1.0-alpha.6` 另外采集 guardian.log 与 guardian-error.log 的元信息。旧部署没有这两个文件时标为 unknown，不执行迁移。主日志的有界轮转只作用于采用新源码部署的网关；从源码运行新版诊断不会改变现有日志策略。

状态事实可能包含内网 IP、DNS/本机代理地址、接口、进程号和用户选定的网站。事件只保留时间与固定类别，不保存 SSID、BSSID、EAP 报文或账号标识。临时原始命令输出在退出时删除；报告目录权限为 0700、文件为 0600。无法保证自动脱敏涵盖所有组织信息，公开前仍需人工审阅。不会自动上传报告。

PF 规则需要管理员权限，程序不主动提权，默认标为未检查。程序也不读取任意代理配置、不宣称知道实际代理分流规则。AI 确需补查时按当前授权和对应工具约束进行，只补充与故障直接相关的证据。

诊断不得触发 DHCP 释放、Wi-Fi 重连、网关重启、PF 清空、路由修改或电源修改；修复属于单独的有范围操作。

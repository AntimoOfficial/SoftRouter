# Structured, escaped output from selected facts; never embed raw system logs.
BEGIN {
  FS="\t"; md=out "/report.md"; js=out "/report.json"
  labels["collected_at"]="采集时间"; labels["label"]="目标服务"; labels["window"]="历史范围"
  labels["service"]="网关服务"; labels["launch"]="launchd 状态"; labels["guardian"]="守护进程（PID / PPID / 运行时长 / 启动时间）"
  labels["worker"]="转发进程（PID / PPID / 运行时长 / 启动时间）"; labels["enabled"]="开机启动"; labels["boot_time"]="系统启动时间"
  labels["forwarding"]="IPv4 转发"; labels["route"]="默认出口"; labels["route_binding"]="出口一致性"
  labels["upstream"]="选定/观察到的上游"; labels["upstream_link"]="上游链路"; labels["lease"]="DHCP 租约"
  labels["downstream"]="选定下游"; labels["downstream_link"]="下游链路"; labels["counters"]="下游累计计数"
  labels["dns"]="系统 DNS（所有作用域）"; labels["proxy"]="系统代理设置"; labels["power"]="睡眠设置"; labels["battery"]="供电状态"
  labels["gateway_log"]="网关日志元信息"; labels["error_log"]="错误日志元信息"; labels["pf"]="实时 PF"
  labels["downstream_access"]="真实下游访问"; labels["history"]="历史检索完成情况"
}
function json(s,    i,c,r) {
  r="\""
  for(i=1;i<=length(s);i++) {
    c=substr(s,i,1)
    if(c=="\\") r=r "\\\\"
    else if(c=="\"") r=r "\\\""
    else if(c=="\n") r=r "\\n"
    else if(c=="\r") r=r "\\r"
    else if(c=="\t") r=r "\\t"
    else if(c ~ /[[:cntrl:]]/) r=r " "
    else r=r c
  }
  return r "\""
}
function safe(s) {
  gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s)
  gsub(/\|/,"/",s); gsub(/`/,"'",s); gsub(/[[:cntrl:]]/," ",s)
  return s
}
FILENAME ~ /facts.tsv$/ { n++; keys[n]=$1; states[n]=$2; values[n]=$3; if($2=="attention") attention++; if($2=="unknown" || $2=="unverified") unknown++; next }
FILENAME ~ /events.tsv$/ { e++; times[e]=$1; kinds[e]=$2; next }
FILENAME ~ /probes.tsv$/ {
  p++; urls[p]=$1; modes[p]=$2; codes[p]=$3; http[p]=$4; elapsed[p]=$5
  if($3!="0") outcomes[p]="请求未完成，可能是解析、连接、TLS、超时或内容大小限制；不能只归因于网关"
  else if($4 ~ /^[23][0-9][0-9]$/) outcomes[p]="入口传输成功；页面内容与登录功能未验收"
  else outcomes[p]="收到 HTTP 响应；需区分应用错误、认证限制与网络问题"
  next
}
END {
  print "# SoftRouter 网络诊断报告" > md
  print "\n这是当前状态和留存事件的只读快照，不是持续监控或自动修复。报告生成成功不等于网络健康。" > md
  print "\n## 当前证据\n\n| 检查项 | 证据状态 | 观察结果 |\n|---|---|---|" > md
  for(i=1;i<=n;i++) print "| " safe((keys[i] in labels)?labels[keys[i]]:keys[i]) " | " safe(states[i]) " | " safe(values[i]) " |" > md
  print "\nobserved 表示取得证据；attention 表示发现需核实的不一致；unknown 表示未取得有效证据；unverified 表示未进行该项验收。" > md
  print "\n## 留存事件\n\n事件检索覆盖本机的 Wi-Fi / DHCP 日志，不保证每条均来自选定上游；时间按日志原始时区。漫游到 BOUND 的间隔不等于测得的断网时长。" > md
  if(e) {
    print "\n| 时间 | 事件 |\n|---|---|" > md
    for(i=1;i<=e;i++) print "| " safe(times[i]) " | " safe(kinds[i]) " |" > md
  } else print "\n没有取得匹配事件；可能没有相关记录、日志留存不足、权限不足、被跳过或检索未完成，不能解释为零故障。" > md
  print "\n## 指定网站的当前请求\n" > md
  if(p) {
    print "| URL | 路径 | curl 返回码 | HTTP | 总耗时（秒） | 判断 |\n|---|---|---|---|---|---|" > md
    for(i=1;i<=p;i++) print "| " safe(urls[i]) " | " modes[i] " | " codes[i] " | " http[i] " | " elapsed[i] " | " outcomes[i] " |" > md
  } else print "未指定公开站点，本次没有发送网页测试请求。" > md
  print "\n## 结论边界\n\n- RUNNING、进程存活、上游可达和真实下游可用是不同结论。下游仍需用户或有权限的客户端独立验证。\n- 进程运行时长不等于互联网在线时长；状态文件时间是事件更新时间，不是心跳。\n- 网卡错误计数不是丢包率；协商速率不是测速结果；同一 PID 也不证明期间没有 Wi-Fi 瞬断。\n- 只列出实际事件，不计算没有连续采样支持的可用率，不宣称认证失败根因已消失。\n- 未读取代理订阅、密码、完整系统网络偏好、私有恢复目录或实时 PF 规则；不会自动上传报告。\n- 报告仍可能包含 IP、代理地址、接口、进程号和用户选择的站点，公开前人工脱敏。" > md
  print "{\"schema_version\":1,\"kind\":\"read_only_snapshot\",\"facts\":[" > js
  for(i=1;i<=n;i++) print (i>1?",":"") "{\"id\":" json(keys[i]) ",\"state\":" json(states[i]) ",\"value\":" json(values[i]) "}" > js
  print "],\"events\":[" > js
  for(i=1;i<=e;i++) print (i>1?",":"") "{\"time\":" json(times[i]) ",\"kind\":" json(kinds[i]) "}" > js
  print "],\"probes\":[" > js
  for(i=1;i<=p;i++) print (i>1?",":"") "{\"url\":" json(urls[i]) ",\"path\":" json(modes[i]) ",\"curl_exit\":" json(codes[i]) ",\"http\":" json(http[i]) ",\"seconds\":" json(elapsed[i]) ",\"assessment\":" json(outcomes[i]) "}" > js
  print "],\"downstream_verified\":false,\"availability_percent\":null,\"attention_count\":" (attention+0) ",\"unknown_or_unverified_count\":" (unknown+0) "}" > js
  close(md);close(js)
}

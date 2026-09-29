import AppKit
import CryptoKit
import Darwin

enum SetupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Setup {
    static let bundlePath = "/Applications/SoftRouter.app"
    static let keys: Set<String> = ["UPSTREAM_INTERFACE", "DOWNSTREAM_INTERFACE", "DOWNSTREAM_SERVICE", "DOWNSTREAM_SERVICE_UUID", "DOWNSTREAM_MAC", "GATEWAY_ADDRESS", "CLIENT_ADDRESS"]

    static func parse(_ data: Data) throws -> [String: String] {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10) || $0.value == 127 }) else {
            throw SetupError.message("配置必须为不超过 4096 字节的 UTF-8 文本，使用 LF 换行。")
        }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("#") {
            guard let index = line.firstIndex(of: "=") else { throw SetupError.message("配置每行应为 KEY=VALUE。") }
            let key = String(line[..<index]), value = String(line[line.index(after: index)...])
            guard keys.contains(key), values[key] == nil, !value.isEmpty else { throw SetupError.message("配置存在未知、重复或空字段。") }
            values[key] = value
        }
        guard Set(values.keys) == keys else { throw SetupError.message("配置需要填写示例中的全部七项。") }
        return values
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func run(_ path: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "无法读取命令结果。")
    }

    // Authenticates the displayed snapshot rather than rereading an editable source.
    static func authorizeInstall(_ data: Data) throws -> String {
        guard Bundle.main.bundlePath == bundlePath else {
            throw SetupError.message("请先双击 Release 中的 .pkg 安装，再从应用程序文件夹打开 SoftRouter。")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("softrouter-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("gateway.conf")
        try data.write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let helper = bundlePath + "/Contents/Resources/core/gui-install.sh"
        let command = "/bin/bash " + shellQuote(helper) + " " + shellQuote(config.path) + " " + shellQuote(digest(data))
        let source = "do shell script " + appleQuote(command) + " with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw SetupError.message("无法创建系统授权请求。") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            if error[NSAppleScript.errorNumber] as? Int == -128 { throw SetupError.message("已取消，未完成网关安装。") }
            throw SetupError.message(error[NSAppleScript.errorMessage] as? String ?? "安装未完成，请保留现状并查看部署指南。")
        }
        return result.stringValue ?? "安装步骤已返回，请读取状态并验证下游网页。"
    }
}

struct DiagnosticSnapshot: Decodable {
    struct Fact: Decodable {
        let id: String
        let state: String
        let value: String
    }
    struct Probe: Decodable {
        let curlExit: String?
        let http: String?
        enum CodingKeys: String, CodingKey { case curlExit = "curl_exit", http }
        var transferred: Bool {
            guard curlExit == "0", let http = http, http.count == 3,
                  http.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let status = Int(http) else { return false }
            return (200..<400).contains(status)
        }
    }
    let schemaVersion: Int
    let facts: [Fact]?
    let probes: [Probe]?
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", facts, probes }
    static let maximumBytes = 1_048_576

    static func decode(_ data: Data) throws -> DiagnosticSnapshot {
        guard data.count <= maximumBytes else { throw SetupError.message("诊断摘要超过读取大小限制。") }
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.schemaVersion == 1 else { throw SetupError.message("此报告版本尚不能显示摘要，请查看 Markdown 报告。") }
        return report
    }

    static func directory(from output: String, selectedFolder: URL) throws -> URL {
        let paths = output.components(separatedBy: "\n").filter { $0.hasPrefix("REPORT_DIR=") }
        guard paths.count == 1 else { throw SetupError.message("未取得唯一的报告目录，请查看运行记录。") }
        let path = String(paths[0].dropFirst("REPORT_DIR=".count))
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), directory.deletingLastPathComponent().resolvingSymlinksInPath().path == selectedFolder.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw SetupError.message("报告目录不在所选保存位置，未读取摘要。")
        }
        return directory
    }

    static func load(from directory: URL) throws -> DiagnosticSnapshot {
        // Open the exact new report without following a replaced directory or file symlink.
        let folder = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw SetupError.message("无法打开报告目录。") }
        defer { Darwin.close(folder) }
        let descriptor = openat(folder, "report.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SetupError.message("无法读取诊断摘要，请查看 Markdown 报告。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw SetupError.message("诊断摘要必须是不超过 1 MiB 的普通文件。")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw SetupError.message("诊断摘要超过读取大小限制。") }
        }
        return try decode(data)
    }

    func fact(_ id: String) -> Fact? { facts?.first { $0.id == id } }
    func evidence(_ id: String) -> String {
        guard let fact = fact(id) else { return "未取得证据" }
        let value = fact.value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        switch fact.state {
        case "observed": return value.isEmpty ? "未取得证据" : value
        case "attention": return "需核实：" + (value.isEmpty ? "证据不一致" : value)
        case "unverified": return "尚未验收"
        default: return "未取得证据"
        }
    }
    var serviceTitle: String {
        switch fact("service")?.state {
        case "observed": return "服务已运行 · 诊断快照"
        case "attention": return "服务证据需检查 · 诊断快照"
        default: return "服务状态未确认 · 诊断快照"
        }
    }
    var wifiSummary: String {
        switch fact("upstream_ssid")?.state {
        case "observed": return "期望 Wi-Fi 已匹配"
        case "attention": return "期望 Wi-Fi 不匹配"
        default: return "期望 Wi-Fi 未验证"
        }
    }
    var hostSummary: String {
        guard let probes = probes else { return "未取得请求记录；页面内容未验收" }
        guard !probes.isEmpty else { return "未发送网页请求；页面内容未验收" }
        let completed = probes.filter { $0.transferred }.count
        return "\(completed)/\(probes.count) 次入口传输成功；页面内容未验收"
    }
    var powerSummary: String {
        guard let fact = fact("power_source"), fact.state == "observed" else { return "供电未确认" }
        switch fact.value.components(separatedBy: "；").first {
        case "AC": return "外接电源"
        case "battery": return "电池供电"
        case "UPS": return "UPS 供电"
        default: return "供电未确认"
        }
    }
    var lidSummary: String {
        guard let fact = fact("lid_state"), fact.state == "observed" else { return "合盖状态未确认" }
        switch fact.value.components(separatedBy: "；").first {
        case "open": return "采集时开盖"
        case "closed": return "采集时合盖"
        default: return "合盖状态未确认"
        }
    }
    var evidenceRows: [String] {
        [powerSummary + "；" + lidSummary, evidence("sleep_policy"), hostSummary,
         "未独立验收；" + evidence("downstream_speed")]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let summary = NSTextView()
    let state = NSTextField(wrappingLabelWithString: "")
    let stateTitle = NSTextField(labelWithString: "读取本机状态")
    let configLabel = NSTextField(wrappingLabelWithString: "尚未导入配置")
    let installButton = NSButton(title: "安装网关…", target: nil, action: nil)
    let chooseButton = NSButton(title: "导入配置…", target: nil, action: nil)
    let diagnoseButton = NSButton(title: "生成诊断报告…", target: nil, action: nil)
    let refreshButton = NSButton(title: "刷新状态", target: nil, action: nil)
    let progress = NSProgressIndicator()
    let evidenceLabels = (0..<4).map { _ in NSTextField(wrappingLabelWithString: "生成诊断报告后查看") }
    var configData: Data?
    var isBusy = false

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = color
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func card(_ content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.borderWidth = 1; box.cornerRadius = 14
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        let container = box.contentView!
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return box
    }

    private func configureButton(_ button: NSButton, symbol: String, identifier: String, help: String) {
        button.bezelStyle = .rounded; button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading; button.imageHugsTitle = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier); button.toolTip = help
    }

    private func sectionTitle(_ text: String, symbol: String) -> NSStackView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.contentTintColor = .systemTeal
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        image.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let row = NSStackView(views: [image, label(text, size: 16, weight: .semibold)])
        row.spacing = 8; row.alignment = .centerY
        return row
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 SoftRouter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 SoftRouter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fileItem = NSMenuItem(), fileMenu = NSMenu(title: "文件")
        let diagnosticItem = NSMenuItem(title: "生成诊断报告…", action: #selector(diagnose), keyEquivalent: "d")
        diagnosticItem.target = self; fileMenu.addItem(diagnosticItem)
        let importItem = NSMenuItem(title: "导入配置…", action: #selector(chooseConfig), keyEquivalent: "o")
        importItem.target = self; fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 820, height: 700)
        window.title = "SoftRouter"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView!.setAccessibilityIdentifier("softrouter.main")
        let root = window.contentView!

        let brandImage = NSImageView()
        if let url = Bundle.main.url(forResource: "SoftRouterIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            brandImage.image = image
        } else {
            brandImage.image = NSImage(systemSymbolName: "network", accessibilityDescription: "SoftRouter")
            brandImage.contentTintColor = .systemTeal
        }
        brandImage.imageScaling = .scaleProportionallyUpOrDown
        brandImage.widthAnchor.constraint(equalToConstant: 48).isActive = true
        brandImage.heightAnchor.constraint(equalToConstant: 48).isActive = true
        brandImage.setAccessibilityLabel("SoftRouter 应用图标")
        let brand = vertical([
            label("SoftRouter", size: 28, weight: .semibold),
            label("把 Mac 的网络分享给更多设备", size: 14, color: .secondaryLabelColor)
        ], spacing: 3)
        let header = NSStackView(views: [brandImage, brand]); header.spacing = 16; header.alignment = .centerY
        header.distribution = .fill
        let version = Bundle.main.object(forInfoDictionaryKey: "SoftRouterReleaseVersion") as? String ?? "preview"
        let versionLabel = label("预览版  " + version, size: 11, color: .secondaryLabelColor)
        versionLabel.alignment = .right
        header.addArrangedSubview(versionLabel)
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        brand.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stateTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stateTitle.setAccessibilityIdentifier("gateway.status.title")
        state.font = .systemFont(ofSize: 12); state.textColor = .secondaryLabelColor
        state.setAccessibilityIdentifier("gateway.status.detail")
        let statusText = vertical([stateTitle, state], spacing: 5)
        refreshButton.target = self; refreshButton.action = #selector(refreshStatus)
        configureButton(refreshButton, symbol: "arrow.clockwise", identifier: "gateway.refresh", help: "读取本机服务和转发状态；不会重启网关。")
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let statusRow = NSStackView(views: [statusText, progress, refreshButton])
        statusRow.spacing = 14; statusRow.alignment = .centerY; statusRow.distribution = .fill
        statusText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var evidenceRows: [NSView] = []
        for (index, title) in ["供电 / 合盖", "睡眠策略", "主机网页", "真实下游"].enumerated() {
            let titleLabel = label(title, size: 12, weight: .medium, color: .secondaryLabelColor)
            titleLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true
            let detail = evidenceLabels[index]
            detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byTruncatingTail
            detail.setAccessibilityIdentifier("diagnostics.evidence.\(index)")
            detail.setAccessibilityLabel(title)
            detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.required, for: .vertical)
            let row = NSStackView(views: [titleLabel, detail])
            row.alignment = .firstBaseline; row.spacing = 8
            evidenceRows.append(row)
        }
        evidenceLabels[2].stringValue = "尚未探测；页面内容未验收"
        evidenceLabels[3].stringValue = "未独立验收"
        let statusCard = card(vertical([statusRow, vertical(evidenceRows, spacing: 5)], spacing: 12))

        diagnoseButton.target = self; diagnoseButton.action = #selector(diagnose)
        configureButton(diagnoseButton, symbol: "doc.text.magnifyingglass", identifier: "diagnostics.generate", help: "生成最近三天的本机只读报告，可选择上游 Wi-Fi 和公开站点进行核对。")
        diagnoseButton.bezelColor = .systemTeal
        let diagnosticActions = NSStackView(views: [diagnoseButton]); diagnosticActions.alignment = .centerY
        let diagnosticCard = card(vertical([
            sectionTitle("网络诊断", symbol: "waveform.path.ecg"),
            label("查看供电、合盖、网络与近期事件，核对期望 Wi-Fi。", size: 12, color: .secondaryLabelColor),
            label("只读检查 · 本地报告 · 无需管理员密码", size: 11, weight: .medium, color: .secondaryLabelColor),
            diagnosticActions
        ], spacing: 10))

        chooseButton.target = self; chooseButton.action = #selector(chooseConfig)
        installButton.target = self; installButton.action = #selector(installGateway); installButton.isEnabled = false
        configureButton(chooseButton, symbol: "square.and.arrow.down", identifier: "gateway.import", help: "导入按本机实际接口生成的配置文件，随后查看完整配置。")
        configureButton(installButton, symbol: "network", identifier: "gateway.install", help: "仅首次部署。检查通过后由 macOS 请求管理员授权。")
        configLabel.font = .systemFont(ofSize: 11, weight: .medium); configLabel.textColor = .secondaryLabelColor
        configLabel.setAccessibilityIdentifier("gateway.configuration.summary")
        let setupActions = NSStackView(views: [chooseButton, installButton]); setupActions.spacing = 8
        let deploymentCard = card(vertical([
            sectionTitle("新网关部署", symbol: "point.3.connected.trianglepath.dotted"),
            label("让 AI 准备本机配置，再导入检查。仅支持首次安装，已有网关会保留。", size: 12, color: .secondaryLabelColor),
            configLabel,
            setupActions
        ], spacing: 10))
        let cards = NSStackView(views: [diagnosticCard, deploymentCard])
        cards.distribution = .fillEqually; cards.alignment = .top; cards.spacing = 16
        diagnosticCard.heightAnchor.constraint(equalTo: deploymentCard.heightAnchor).isActive = true

        summary.isEditable = false; summary.isSelectable = true
        summary.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summary.textColor = .labelColor; summary.backgroundColor = .textBackgroundColor
        summary.textContainerInset = NSSize(width: 12, height: 12)
        summary.string = "尚未导入配置或生成报告。\n\n诊断报告会保存在你选择的文件夹。\n部署网关前，请让 AI 阅读部署指南并核对本机接口。"
        summary.setAccessibilityIdentifier("gateway.output")
        summary.setAccessibilityLabel("配置详情与运行记录")
        let scroll = NSScrollView()
        scroll.documentView = summary; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        summary.autoresizingMask = [.width]
        summary.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        let outputTitle = label("配置与运行记录", size: 13, weight: .semibold)
        let output = card(vertical([outputTitle, scroll], spacing: 10))
        output.setContentHuggingPriority(.defaultLow, for: .vertical)

        let guide = NSButton(title: "部署指南", target: self, action: #selector(openGuide))
        configureButton(guide, symbol: "book.closed", identifier: "help.deployment", help: "在浏览器中打开开源仓库的桌面安装指南。")
        guide.setContentHuggingPriority(.required, for: .horizontal)
        let note = label("实验预览 · 安装包尚未签名或公证\n服务运行状态不能替代真实下游联网验收。", size: 11, color: .secondaryLabelColor)
        let footer = NSStackView(views: [note, guide]); footer.spacing = 16; footer.alignment = .centerY
        footer.distribution = .fill
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = vertical([header, statusCard, cards, output, footer], spacing: 12)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        window.initialFirstResponder = diagnoseButton
        diagnoseButton.nextKeyView = chooseButton; chooseButton.nextKeyView = installButton
        installButton.nextKeyView = refreshButton; refreshButton.nextKeyView = summary; summary.nextKeyView = guide
        refreshStatus()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func showError(_ error: Error, title: String = "操作未完成") {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning; alert.addButton(withTitle: "知道了"); alert.runModal()
    }

    private func setBusy(_ value: Bool) {
        isBusy = value
        chooseButton.isEnabled = !value; diagnoseButton.isEnabled = !value; refreshButton.isEnabled = !value
        if value { installButton.isEnabled = false; progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }

    private func showSnapshot(_ report: DiagnosticSnapshot) {
        stateTitle.stringValue = report.serviceTitle
        state.stringValue = report.wifiSummary + "。以下为本次诊断快照；服务状态不能替代页面与下游验收。"
        state.toolTip = report.fact("service")?.value
        for (index, text) in report.evidenceRows.enumerated() {
            evidenceLabels[index].stringValue = text
            evidenceLabels[index].toolTip = text
            evidenceLabels[index].textColor = .labelColor
        }
        evidenceLabels[0].toolTip = report.evidence("power_source") + "；" + report.evidence("lid_state")
        if report.fact("sleep_policy")?.state == "attention" { evidenceLabels[1].textColor = .systemOrange }
    }

    @objc func chooseConfig() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 AI 按本机实际网卡生成的 gateway.conf；不要直接使用示例中的设备信息。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 4097
            guard size <= 4096 else { throw SetupError.message("配置文件不能超过 4096 字节。") }
            let data = try Data(contentsOf: url), values = try Setup.parse(data)
            // Reuse the installed data-only Bash parser for full validation.
            let check = "source \"$1\"; load_config \"$2\""
            let library = Bundle.main.resourceURL!.appendingPathComponent("core/config.sh").path
            let result = try Setup.run("/bin/bash", ["-c", check, "softrouter-config-check", library, url.path])
            guard result.0 == 0 else { throw SetupError.message(result.1) }
            configData = data
            configLabel.stringValue = "已导入：" + url.lastPathComponent
            summary.string = "上游接口：\(values["UPSTREAM_INTERFACE"]!)\n下游服务：\(values["DOWNSTREAM_SERVICE"]!)\n下游接口：\(values["DOWNSTREAM_INTERFACE"]!)\n网卡 MAC：\(values["DOWNSTREAM_MAC"]!)\n服务 UUID：\(values["DOWNSTREAM_SERVICE_UUID"]!)\n\nMac 有线地址：\(values["GATEWAY_ADDRESS"]!)\n路由器 WAN 地址：\(values["CLIENT_ADDRESS"]!)\n掩码：255.255.255.0\n路由器默认网关：\(values["GATEWAY_ADDRESS"]!)\nDNS：使用当前上游实际有效的解析器。"
            refreshStatus()
        } catch { configData = nil; installButton.isEnabled = false; configLabel.stringValue = "配置未导入"; showError(error, title: "配置未导入") }
    }

    @objc func refreshStatus() {
        let controller = "/Library/SoftRouter/gatewayctl"
        if FileManager.default.fileExists(atPath: controller) {
            let result = try? Setup.run(controller, ["status"])
            stateTitle.stringValue = "已检测到 SoftRouter 网关"
            state.stringValue = "已有部署会保留。此处读取服务状态，下游联网尚需实际验证。"
            if let result = result { summary.string = result.1 }
            installButton.isEnabled = false
        } else {
            let forwarding = try? Setup.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"])
            if forwarding?.1.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                stateTitle.stringValue = "已检测到 IPv4 转发"
                state.stringValue = "可能已有其他网关运行，本助手不会覆盖。仍可生成只读诊断报告。"
                installButton.isEnabled = false
            } else {
                stateTitle.stringValue = "尚未检测到本项目网关"
                state.stringValue = "可以先诊断网络，或导入配置开始首次部署。安装前会核对网卡、PF 与网络资源。"
                installButton.isEnabled = configData != nil && !isBusy
            }
        }
    }

    @objc func installGateway() {
        guard !isBusy, let data = configData else { return }
        let alert = NSAlert()
        alert.messageText = "安装并启用 SoftRouter？"
        alert.informativeText = "将按已显示的配置安装常驻服务，并启用有线共享。请确认闲置下游服务已按指南准备、下游网线已拔下。现有网关不会被替换。\n\n下一步由 macOS 请求管理员授权；本应用不接收或保存密码。"
        alert.addButton(withTitle: "继续安装"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setBusy(true)
        stateTitle.stringValue = "正在部署网关"
        state.stringValue = "正在等待系统授权并检查配置，可能需要约一分钟…"
        DispatchQueue.main.async { [self] in
            defer { setBusy(false); refreshStatus() }
            do {
                let output = try Setup.authorizeInstall(data)
                summary.string = output
                let done = NSAlert(); done.messageText = "网关安装步骤已完成"
                done.informativeText = "读取状态确认 RUNNING，再将网线接到路由器 WAN。按配置填写路由器 WAN 和上游 DNS，并从真实下游设备验证网页。"
                done.addButton(withTitle: "知道了"); done.runModal()
            } catch { showError(error, title: "网关安装未完成") }
        }
    }


    @objc func diagnose() {
        guard !isBusy else { return }
        let options = NSAlert()
        options.messageText = "生成网络诊断报告"
        options.informativeText = "回看最近三天，生成 Markdown、JSON 与证据表。只读检查，不需管理员授权，报告仅保存在本机。"
        let upstream = NSTextField(), downstream = NSTextField(), expectedSSID = NSTextField(), urls = NSTextField(), proxy = NSTextField()
        let values = configData.flatMap { try? Setup.parse($0) }
        upstream.stringValue = values?["UPSTREAM_INTERFACE"] ?? ""
        downstream.stringValue = values?["DOWNSTREAM_INTERFACE"] ?? ""
        let fields: [(String, NSTextField, String, String, String)] = [
            ("上游接口", upstream, "留空自动读取，例如 en0", "diagnostics.upstream", "显式指定读取哪个上游接口；不会修改接口。"),
            ("下游接口", downstream, "留空读取状态，未知时不猜测", "diagnostics.downstream", "实际连接下游路由器的有线接口。"),
            ("期望上游 Wi-Fi", expectedSSID, "可选；输入完整网络名称", "diagnostics.expectedSSID", "检查是否接错网络；保留名称中的空格，不自动切网，也不在报告中保存名称。"),
            ("公开网址", urls, "可选；https://example.com/", "diagnostics.urls", "最多五个网址，用空格分隔。不要输入凭据、查询参数、片段或订阅链接。"),
            ("本机 HTTP 代理", proxy, "可选；http://127.0.0.1:7890", "diagnostics.proxy", "仅接受明确指定的本机 HTTP 代理，用于与直连结果对照。")
        ]
        var rows: [NSView] = []
        for (title, field, placeholder, identifier, help) in fields {
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = placeholder
            field.toolTip = help; field.setAccessibilityLabel(title); field.setAccessibilityHelp(help)
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.setAccessibilityIdentifier(identifier)
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
            rows.append(vertical([label(title, size: 12, weight: .medium), field], spacing: 5))
        }
        rows.append(label("留空网址时不发送网页请求。报告不等于联网验收；实际下游与页面内容仍需核实。", size: 11, color: .secondaryLabelColor))
        let form = vertical(rows, spacing: 12)
        form.frame = NSRect(x: 0, y: 0, width: 490, height: 350)
        form.widthAnchor.constraint(equalToConstant: 490).isActive = true
        options.accessoryView = form
        upstream.nextKeyView = downstream; downstream.nextKeyView = expectedSSID
        expectedSSID.nextKeyView = urls; urls.nextKeyView = proxy
        options.window.initialFirstResponder = upstream
        options.addButton(withTitle: "选择保存位置…"); options.addButton(withTitle: "取消")
        guard options.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = "选择报告保存位置"; panel.prompt = "生成报告"; panel.message = "在所选文件夹内创建一个新的私有报告目录，不覆盖已有文件。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let script = Bundle.main.resourceURL!.appendingPathComponent("core/diagnose.sh").path
        var args = [script, "--days", "3", "--output-dir", folder.path]
        for (flag, field) in [("--upstream", upstream), ("--downstream", downstream), ("--proxy", proxy)] {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { args += [flag, value] }
        }
        // SSIDs may contain meaningful leading/trailing spaces; pass one literal argument.
        if !expectedSSID.stringValue.isEmpty { args += ["--expected-ssid", expectedSSID.stringValue] }
        for url in urls.stringValue.split(whereSeparator: { $0.isWhitespace }) { args += ["--url", String(url)] }
        setBusy(true)
        stateTitle.stringValue = "正在生成诊断报告"
        state.stringValue = "正在收集只读证据；历史检索和网页测试均有超时限制…"
        DispatchQueue.global(qos: .utility).async { [self, args] in
            let result = Result { try Setup.run("/bin/bash", args) }
            var snapshot: Result<(URL, DiagnosticSnapshot), Error>?
            if case .success(let output) = result, output.0 == 0 {
                snapshot = Result {
                    let directory = try DiagnosticSnapshot.directory(from: output.1, selectedFolder: folder)
                    return (directory, try DiagnosticSnapshot.load(from: directory))
                }
            }
            let snapshotResult = snapshot
            DispatchQueue.main.async { [self] in
                setBusy(false); refreshStatus()
                switch result {
                case .failure(let error): showError(error, title: "诊断报告未生成")
                case .success(let output):
                    summary.string = output.1
                    if output.0 != 0 { showError(SetupError.message(output.1), title: "诊断报告未生成"); return }
                    switch snapshotResult {
                    case .success(let (directory, report)):
                        showSnapshot(report)
                        NSWorkspace.shared.activateFileViewerSelecting([directory.appendingPathComponent("report.md")])
                    case .failure(let error):
                        state.stringValue = "报告已保存；摘要未读取。真实下游与页面内容仍未验收。"
                        for field in evidenceLabels { field.stringValue = "摘要未读取；详见运行记录"; field.textColor = .secondaryLabelColor; field.toolTip = nil }
                        summary.string += "\n摘要未读取：" + error.localizedDescription
                    case .none: break
                    }
                }
            }
        }
    }

    @objc func openGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/AntimoOfficial/SoftRouter/blob/main/softrouter/docs/desktop-installer.md")!)
    }
}

if CommandLine.arguments.contains("--self-test") {
    var assertions = 0
    func expect(_ condition: @autoclosure () -> Bool) {
        assertions += 1
        if !condition() { fputs("Native self-test failed at assertion \(assertions)\n", stderr); exit(1) }
    }
    let lines = Setup.keys.sorted().map { $0 + "=example" }.joined(separator: "\n")
    expect((try? Setup.parse(Data(lines.utf8)).count) == 7)
    expect((try? Setup.parse(Data((lines + "\nUNKNOWN=value").utf8))) == nil)
    expect((try? Setup.parse(Data((lines + "\nCLIENT_ADDRESS=duplicate").utf8))) == nil)
    expect((try? Setup.parse(Data([0]))) == nil)
    expect((try? Setup.parse(Data(repeating: 65, count: 4097))) == nil)
    expect(Setup.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let value = "a'$(printf injected)\"\\line\nnext"
    let result = try Setup.run("/bin/bash", ["-c", "printf %s " + Setup.shellQuote(value)])
    expect(result.0 == 0 && result.1 == value)
    let literal = "return " + Setup.appleQuote(value)
    var error: NSDictionary?
    let returned = NSAppleScript(source: literal)?.executeAndReturnError(&error).stringValue
    expect(error == nil && returned == value)
    func reportData(_ extra: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = ["schema_version": 1]
        for (key, value) in extra { values[key] = value }
        return try JSONSerialization.data(withJSONObject: values)
    }
    let missing = try DiagnosticSnapshot.decode(reportData())
    expect(missing.serviceTitle.contains("未确认") && missing.evidenceRows[0].contains("未确认"))
    expect(missing.hostSummary.contains("未取得请求记录") && missing.evidenceRows[3].hasPrefix("未独立验收"))
    let successData = try reportData([
        "facts": [["id": "service", "state": "observed", "value": "服务已运行"],
                  ["id": "power_source", "state": "observed", "value": "AC"],
                  ["id": "lid_state", "state": "observed", "value": "closed；瞬时观察"],
                  ["id": "sleep_policy", "state": "attention", "value": "全局禁睡已开启"]],
        "probes": [["curl_exit": "0", "http": "200"], ["curl_exit": "28", "http": "200"],
                   ["curl_exit": "0", "http": "500"], ["curl_exit": "0", "http": "302"]],
        "downstream_verified": true
    ])
    let success = try DiagnosticSnapshot.decode(successData)
    expect(success.serviceTitle == "服务已运行 · 诊断快照")
    expect(success.hostSummary == "2/4 次入口传输成功；页面内容未验收")
    expect(success.evidenceRows[3].hasPrefix("未独立验收"))
    expect(success.evidenceRows[0] == "外接电源；采集时合盖")
    expect(success.evidenceRows[1].hasPrefix("需核实："))
    let attention = try DiagnosticSnapshot.decode(reportData(["facts": [["id": "service", "state": "attention", "value": "不一致"]], "probes": []]))
    expect(attention.serviceTitle.contains("需检查") && attention.hostSummary.contains("未发送网页请求"))
    expect((try? DiagnosticSnapshot.decode(reportData(["schema_version": 2]))) == nil)
    expect((try? DiagnosticSnapshot.decode(Data("invalid".utf8))) == nil)
    expect((try? DiagnosticSnapshot.decode(Data(repeating: 32, count: DiagnosticSnapshot.maximumBytes + 1))) == nil)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("softrouter-summary-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let reportFile = temporary.appendingPathComponent("report.json")
    try successData.write(to: reportFile)
    expect((try? DiagnosticSnapshot.load(from: temporary).hostSummary) == success.hostSummary)
    expect((try? DiagnosticSnapshot.directory(from: "REPORT_DIR=" + temporary.path, selectedFolder: temporary.deletingLastPathComponent()).path) == temporary.standardizedFileURL.path)
    expect((try? DiagnosticSnapshot.directory(from: "REPORT_DIR=/outside/report", selectedFolder: temporary)) == nil)
    try FileManager.default.removeItem(at: reportFile)
    let target = temporary.appendingPathComponent("target.json")
    try successData.write(to: target)
    try FileManager.default.createSymbolicLink(at: reportFile, withDestinationURL: target)
    expect((try? DiagnosticSnapshot.load(from: temporary)) == nil)
    try FileManager.default.removeItem(at: reportFile)
    try FileManager.default.createDirectory(at: reportFile, withIntermediateDirectories: false)
    expect((try? DiagnosticSnapshot.load(from: temporary)) == nil)
    print("Native self-tests: \(assertions) passed. Synthetic report fixtures; no authorization, installation or network mutation.")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

import AppKit
import CryptoKit

enum SetupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Setup {
    static let bundlePath = "/Applications/Air Gateway.app"
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
            throw SetupError.message("请先双击 Release 中的 .pkg 安装，再从应用程序文件夹打开 Air Gateway。")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("air-gateway-ui-" + UUID().uuidString)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let summary = NSTextView()
    let state = NSTextField(wrappingLabelWithString: "")
    let installButton = NSButton(title: "安装网关…", target: nil, action: nil)
    let chooseButton = NSButton(title: "导入配置文件…", target: nil, action: nil)
    var configData: Data?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Air Gateway", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Air Gateway · 安装助手"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "将这台 Mac 变成共享网关")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "先让 AI 按部署指南生成本机配置并准备闲置的下游网卡，再导入文件。安装时请保留 Wi-Fi，拔下下游网线。路由器 WAN 和校园认证仍需单独配置。")
        let version = Bundle.main.object(forInfoDictionaryKey: "AirGatewayReleaseVersion") as? String ?? "preview"
        let preview = NSTextField(wrappingLabelWithString: "实验预览 " + version + " · 未经 Apple Developer ID 签名或公证 · 仅支持首次安装，不迁移已有网关")
        preview.textColor = .secondaryLabelColor
        summary.isEditable = false
        summary.isSelectable = true
        summary.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summary.string = "尚未导入配置。\n\n可以把仓库地址交给 AI，并要求阅读部署指南。此应用不需要保存任何校园网、路由器或管理员密码。"
        let scroll = NSScrollView()
        scroll.documentView = summary; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        summary.autoresizingMask = [.width]
        summary.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        chooseButton.target = self; chooseButton.action = #selector(chooseConfig)
        installButton.target = self; installButton.action = #selector(installGateway); installButton.isEnabled = false
        let refresh = NSButton(title: "读取状态", target: self, action: #selector(refreshStatus))
        let guide = NSButton(title: "部署指南", target: self, action: #selector(openGuide))
        let row = NSStackView(views: [chooseButton, installButton, refresh, guide]); row.spacing = 12
        let stack = NSStackView(views: [heading, intro, preview, scroll, state, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            state.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshStatus()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "尚未完成安装"; alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning; alert.addButton(withTitle: "知道了"); alert.runModal()
    }

    @objc func chooseConfig() {
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
            let result = try Setup.run("/bin/bash", ["-c", check, "air-gateway-config-check", library, url.path])
            guard result.0 == 0 else { throw SetupError.message(result.1) }
            configData = data
            summary.string = "上游接口：\(values["UPSTREAM_INTERFACE"]!)\n下游服务：\(values["DOWNSTREAM_SERVICE"]!)\n下游接口：\(values["DOWNSTREAM_INTERFACE"]!)\n网卡 MAC：\(values["DOWNSTREAM_MAC"]!)\n服务 UUID：\(values["DOWNSTREAM_SERVICE_UUID"]!)\n\nMac 有线地址：\(values["GATEWAY_ADDRESS"]!)\n路由器 WAN 地址：\(values["CLIENT_ADDRESS"]!)\n掩码：255.255.255.0\n路由器默认网关：\(values["GATEWAY_ADDRESS"]!)\nDNS：使用当前上游实际有效的解析器。"
            refreshStatus()
        } catch { configData = nil; installButton.isEnabled = false; showError(error) }
    }

    @objc func refreshStatus() {
        let controller = "/Library/AirGateway/gatewayctl"
        if FileManager.default.fileExists(atPath: controller) {
            let result = try? Setup.run(controller, ["status"])
            state.stringValue = "已存在本项目网关，不重复安装。状态仅证明服务状态，下游联网需另行验证。"
            if let result = result { summary.string = result.1 }
            installButton.isEnabled = false
        } else {
            let forwarding = try? Setup.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"])
            if forwarding?.1.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                state.stringValue = "此 Mac 已开启 IPv4 转发，可能有其他网关正在运行。本助手不会覆盖它。"
                installButton.isEnabled = false
            } else {
                state.stringValue = "尚未安装本项目网关。管理员预检会核对网卡、PF 和现有网络资源。"
                installButton.isEnabled = configData != nil
            }
        }
    }

    @objc func installGateway() {
        guard let data = configData else { return }
        let alert = NSAlert()
        alert.messageText = "安装并启用 Air Gateway？"
        alert.informativeText = "将按已显示的配置安装常驻服务，并启用有线共享。请确认闲置下游服务已按指南准备、下游网线已拔下。现有网关不会被替换。\n\n下一步由 macOS 请求管理员授权；本应用不接收或保存密码。"
        alert.addButton(withTitle: "继续安装"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installButton.isEnabled = false; chooseButton.isEnabled = false
        state.stringValue = "正在等待系统授权并检查配置，可能需要约一分钟…"
        DispatchQueue.main.async { [self] in
            defer { chooseButton.isEnabled = true; refreshStatus() }
            do {
                let output = try Setup.authorizeInstall(data)
                summary.string = output
                let done = NSAlert(); done.messageText = "网关安装步骤已完成"
                done.informativeText = "读取状态确认 RUNNING，再将网线接到路由器 WAN。按配置填写路由器 WAN 和上游 DNS，并从真实下游设备验证网页。"
                done.addButton(withTitle: "知道了"); done.runModal()
            } catch { showError(error) }
        }
    }

    @objc func openGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/AntimoOfficial/air-gateway/blob/main/air-gateway/docs/desktop-installer.md")!)
    }
}

if CommandLine.arguments.contains("--self-test") {
    func expect(_ condition: @autoclosure () -> Bool) { if !condition() { fputs("Installer self-test failed\n", stderr); exit(1) } }
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
    print("Installer self-tests: 8 passed. No authorization, installation or network mutation.")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

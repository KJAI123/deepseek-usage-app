// DeepSeekUsagePanel — macOS 悬浮窗面板：实时显示 DeepSeek API 余额 / 用量
// 数据源：DeepSeek 官方（https://api.deepseek.com/user/balance）或自定义 OpenAI 兼容网关（自动探测 /user/balance、/v1/user/balance）
// 模式：极简（只显示总余额）/ 标准（总余额 + 赠送 + 充值）
// 编译：见 build.sh
import Cocoa
import Security
import WebKit

// MARK: - 钥匙串（API Key 兜底存储，沙箱后以 SharedStore 为主）
enum KeychainStore {
    private static let service = "com.local.deepseek-usage-panel"
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - App Group 共享存储（config.json / balance.json）
// 主应用与小组件均为沙箱进程，通过 App Group 容器共享数据
enum SharedStore {
    static let groupID = "group.com.local.deepseek-usage-panel"
    static let balanceFileName = "balance.json"
    static let configFileName = "config.json"

    private static var dirURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func loadConfig() -> [String: Any] {
        guard let base = dirURL else { return [:] }
        let url = base.appendingPathComponent(configFileName)
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return json
    }

    static func saveConfig(_ dict: [String: Any]) {
        guard let base = dirURL else { return }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            try data.write(to: base.appendingPathComponent(configFileName))
        } catch {
            NSLog("SharedStore saveConfig failed: \(error.localizedDescription)")
        }
    }

    static func get(_ key: String) -> Any? { loadConfig()[key] }
    static func set(_ key: String, _ value: Any) {
        var d = loadConfig()
        d[key] = value
        saveConfig(d)
    }

    /// 写余额缓存（供小组件读取）
    static func writeBalance(_ b: AccountBalance, sign: String) {
        guard let base = dirURL else { return }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "total": b.total,
                "sign": sign,
                "granted": b.granted ?? "0",
                "topped": b.toppedUp ?? "0",
                "available": b.isAvailable,
                "updatedAt": Date().timeIntervalSince1970,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: base.appendingPathComponent(balanceFileName))
        } catch {
            NSLog("SharedStore writeBalance failed: \(error.localizedDescription)")
        }
    }

    /// API Key 读取：优先共享配置，兜底旧钥匙串
    static func apiKey() -> String? {
        if let k = get("apiKey") as? String, !k.isEmpty { return k }
        return KeychainStore.get("apiKey")
    }

    // MARK: - 余额历史（看板数据源）

    /// 追加一条余额记录到 history.json（同一次刷新 5 秒内去重，保留近 90 天 / 最多 1000 条）
    static func appendHistory(total: String) {
        guard let base = dirURL else { return }
        let url = base.appendingPathComponent("history.json")
        var entries: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            entries = arr
        }
        let ts = Date().timeIntervalSince1970
        if let last = entries.last?["ts"] as? Double, ts - last < 5 {
            entries.removeLast()
        }
        entries.append(["ts": ts, "total": total])
        let cutoff = Date().addingTimeInterval(-86400 * 90).timeIntervalSince1970
        entries = entries.filter { ($0["ts"] as? Double ?? 0) > cutoff }
        if entries.count > 1000 { entries = Array(entries.suffix(1000)) }
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            try? data.write(to: url)
        }
    }

    /// 返回 history.json 原始 JSON 字符串（供看板注入）
    static func historyJSON() -> String? {
        guard let base = dirURL else { return nil }
        let url = base.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 通用余额模型（兼容 DeepSeek balance_infos 与 OpenAI 网关 data[] 两种返回）
struct AccountBalance {
    var currency: String = "CNY"
    var total: String = "0"
    var granted: String?
    var toppedUp: String?
    var isAvailable: Bool = true
}

enum BalanceAPIError: LocalizedError {
    case invalidURL, unauthorized, http(Int), network(String), decode(String), empty
    var errorDescription: String? {
        switch self {
        case .invalidURL:   return "无效 URL"
        case .unauthorized: return "Key 无效或已过期"
        case .http(let c):  return "请求失败 HTTP \(c)"
        case .network(let m): return m
        case .decode(let m): return "解析失败：\(m)"
        case .empty:        return "接口无余额数据"
        }
    }
}

struct BalanceAPI {
    private func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return String(describing: n) }
        return "0"
    }

    /// 解析 DeepSeek 官方 / OpenAI 兼容网关两种返回格式
    func parse(_ data: Data) throws -> AccountBalance {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let json = obj as? [String: Any] else { throw BalanceAPIError.decode("非 JSON 对象") }
        var arr: [[String: Any]]?
        if let infos = json["balance_infos"] as? [[String: Any]] { arr = infos }
        else if let list = json["data"] as? [[String: Any]] { arr = list }
        guard let first = arr?.first else { throw BalanceAPIError.empty }
        var b = AccountBalance()
        b.currency = (first["currency"] as? String ?? "CNY").uppercased()
        b.total = str(first["total_balance"])
        b.granted = str(first["granted_balance"])
        b.toppedUp = str(first["topped_up_balance"])
        b.isAvailable = json["is_available"] as? Bool ?? true
        return b
    }

    /// 依次尝试候选路径；401 直接判定 Key 无效，404 才尝试下一个
    func fetchBalance(baseURL: String, key: String, completion: @escaping (Result<AccountBalance, Error>) -> Void) {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let candidates = base.isEmpty
            ? []
            : ["\(base)/user/balance", "\(base)/v1/user/balance"]
        tryFetch(candidates, index: 0, key: key, completion: completion)
    }

    private func tryFetch(_ paths: [String], index: Int, key: String,
                          completion: @escaping (Result<AccountBalance, Error>) -> Void) {
        guard index < paths.count, let url = URL(string: paths[index]) else {
            completion(.failure(BalanceAPIError.invalidURL)); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [self] data, resp, err in
            if let err = err {
                completion(.failure(BalanceAPIError.network(err.localizedDescription))); return
            }
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    completion(.failure(BalanceAPIError.unauthorized)); return
                }
                if http.statusCode == 404 {
                    // 换下一个路径重试
                    tryFetch(paths, index: index + 1, key: key, completion: completion)
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(BalanceAPIError.http(http.statusCode))); return
                }
            }
            guard let data = data else {
                completion(.failure(BalanceAPIError.network("无响应数据"))); return
            }
            do {
                let balance = try parse(data)
                completion(.success(balance))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - 可拖动控件（整窗可拖，按钮仍可点击）
final class DragLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}
final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
final class DragEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - 悬浮面板
final class FloatingPanel: NSPanel {
    private let api = BalanceAPI()
    private var tickTimer: Timer?
    private var secondsLeft: Int = 0
    private var lastUpdated = ""
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // 配置（存 App Group 共享容器）
    private var displayMode: Int {      // 0=极简（只显示总余额） 1=标准（含赠送/充值）
        get { SharedStore.get("displayMode") as? Int ?? 0 }
        set { SharedStore.set("displayMode", newValue) }
    }
    private var sourceType: Int {       // 0=DeepSeek 官方  1=自定义网关
        get { SharedStore.get("sourceType") as? Int ?? 0 }
        set { SharedStore.set("sourceType", newValue) }
    }
    private var baseURL: String {
        get { SharedStore.get("baseURL") as? String ?? "" }
        set { SharedStore.set("baseURL", newValue) }
    }
    private var interval: Int {
        get { SharedStore.get("refreshInterval") as? Int ?? 60 }
        set { SharedStore.set("refreshInterval", newValue) }
    }
    private var isMini: Bool { displayMode == 0 }

    // UI 元素（随模式重建）
    private var statusDot: DragView!
    private var statusLabel: DragLabel!
    private var totalValue: DragLabel!
    private var grantedValue: DragLabel!
    private var toppedValue: DragLabel!
    private var footerLabel: DragLabel!
    private var refreshButton: NSButton!
    private var settingsButton: NSButton!
    private var quitButton: NSButton!

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        let mini = ((SharedStore.get("displayMode") as? Int ?? 0) == 0)
        let w: CGFloat = mini ? 320 : 340
        let h: CGFloat = mini ? 100 : 244
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        buildUI()
        positionPanel()
        startTicker()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 布局构建 / 模式切换
    func applyMode() {
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        let w: CGFloat = isMini ? 320 : 340
        let h: CGFloat = isMini ? 100 : 244
        setContentSize(NSSize(width: w, height: h))
        buildUI()
        positionPanel()
        updateFooter()
        refresh()
    }

    private func buildUI() {
        let content = contentView!

        let effect = DragEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        content.addSubview(effect)

        isMini ? buildMiniLayout(content) : buildFullLayout(content)
    }

    private func buildMiniLayout(_ content: NSView) {
        // 标题 + 状态
        let title = DragLabel(labelWithString: "DeepSeek 用量")
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: 78, width: 110, height: 14)

        statusDot = DragView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.frame = NSRect(x: 260, y: 80, width: 8, height: 8)

        statusLabel = DragLabel(labelWithString: "加载中…")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 274, y: 77, width: 80, height: 14)

        // 总余额大字
        totalValue = DragLabel(labelWithString: "—")
        totalValue.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        totalValue.textColor = .labelColor
        totalValue.frame = NSRect(x: 12, y: 38, width: 296, height: 32)

        // 底部：倒计时 + 按钮
        footerLabel = DragLabel(labelWithString: "等待获取…")
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: 12, y: 18, width: 170, height: 14)

        refreshButton = makeButton("刷新", action: #selector(refresh))
        refreshButton.frame = NSRect(x: 186, y: 4, width: 42, height: 24)
        settingsButton = makeButton("设置", action: #selector(openSettings))
        settingsButton.frame = NSRect(x: 230, y: 4, width: 42, height: 24)
        quitButton = makeButton("隐藏", action: #selector(hidePanel))
        quitButton.frame = NSRect(x: 274, y: 4, width: 42, height: 24)

        for v in [title, statusDot!, statusLabel!, totalValue!, footerLabel!,
                  refreshButton!, settingsButton!, quitButton!] {
            content.addSubview(v)
        }
    }

    private func buildFullLayout(_ content: NSView) {
        let title = DragLabel(labelWithString: "DeepSeek 用量")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 16, y: 212, width: 160, height: 20)

        statusDot = DragView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.frame = NSRect(x: 292, y: 218, width: 8, height: 8)

        statusLabel = DragLabel(labelWithString: "加载中…")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 306, y: 214, width: 90, height: 16)

        let divider = DragView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        divider.frame = NSRect(x: 16, y: 200, width: 308, height: 1)

        let totalLabel = DragLabel(labelWithString: "总余额")
        totalLabel.font = .systemFont(ofSize: 12)
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.frame = NSRect(x: 16, y: 170, width: 80, height: 20)

        totalValue = DragLabel(labelWithString: "—")
        totalValue.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        totalValue.textColor = .labelColor
        totalValue.alignment = .right
        totalValue.frame = NSRect(x: 180, y: 166, width: 144, height: 24)

        let grantedLabel = DragLabel(labelWithString: "赠送余额")
        grantedLabel.font = .systemFont(ofSize: 12)
        grantedLabel.textColor = .secondaryLabelColor
        grantedLabel.frame = NSRect(x: 16, y: 142, width: 80, height: 20)

        grantedValue = DragLabel(labelWithString: "—")
        grantedValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        grantedValue.textColor = .secondaryLabelColor
        grantedValue.alignment = .right
        grantedValue.frame = NSRect(x: 180, y: 138, width: 144, height: 22)

        let toppedLabel = DragLabel(labelWithString: "充值余额")
        toppedLabel.font = .systemFont(ofSize: 12)
        toppedLabel.textColor = .secondaryLabelColor
        toppedLabel.frame = NSRect(x: 16, y: 114, width: 80, height: 20)

        toppedValue = DragLabel(labelWithString: "—")
        toppedValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        toppedValue.textColor = .secondaryLabelColor
        toppedValue.alignment = .right
        toppedValue.frame = NSRect(x: 180, y: 110, width: 144, height: 22)

        footerLabel = DragLabel(labelWithString: "等待获取…")
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: 16, y: 78, width: 300, height: 16)

        refreshButton = makeButton("刷新", action: #selector(refresh))
        refreshButton.frame = NSRect(x: 150, y: 28, width: 56, height: 26)
        settingsButton = makeButton("设置", action: #selector(openSettings))
        settingsButton.frame = NSRect(x: 210, y: 28, width: 56, height: 26)
        quitButton = makeButton("隐藏", action: #selector(hidePanel))
        quitButton.frame = NSRect(x: 270, y: 28, width: 56, height: 26)

        for v in [title, statusDot!, statusLabel!, divider,
                  totalLabel, totalValue!, grantedLabel, grantedValue!,
                  toppedLabel, toppedValue!, footerLabel!,
                  refreshButton!, settingsButton!, quitButton!] {
            content.addSubview(v)
        }
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        b.setButtonType(.momentaryPushIn)
        b.controlSize = .small
        return b
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let f = frame
        setFrameOrigin(NSPoint(x: vf.maxX - f.width - 24, y: vf.maxY - f.height - 24))
    }

    // MARK: - 刷新逻辑
    private func startTicker() {
        tickTimer?.invalidate()
        secondsLeft = interval
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.secondsLeft -= 1
            if self.secondsLeft <= 0 {
                self.secondsLeft = self.interval
                self.refresh()
            }
            self.updateFooter()
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func resolvedBaseURL() -> String? {
        if sourceType == 1 {
            let b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return b.isEmpty ? nil : b
        }
        return "https://api.deepseek.com"
    }

    @objc func refresh() {
        guard let key = SharedStore.apiKey(), !key.isEmpty else {
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = "未设置 Key"
            footerLabel.stringValue = "点「设置」填入 API Key"
            return
        }
        guard let base = resolvedBaseURL() else {
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = "未配置网关"
            footerLabel.stringValue = "点「设置」填写网关地址"
            return
        }
        statusLabel.stringValue = "获取中…"
        api.fetchBalance(baseURL: base, key: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let b):
                    self.apply(b)
                case .failure(let err):
                    self.statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
                    self.statusLabel.stringValue = err.localizedDescription
                    self.updateFooter()
                }
            }
        }
    }

    private func apply(_ b: AccountBalance) {
        let sign = Self.currencySign(b.currency)
        totalValue.stringValue = "\(sign) \(b.total)"
        // 极简模式下赠送/充值控件不存在，用可选链避免崩溃
        if let g = b.granted { grantedValue?.stringValue = "\(sign) \(g)" }
        if let t = b.toppedUp { toppedValue?.stringValue = "\(sign) \(t)" }

        let total = Double(b.total) ?? 0
        totalValue.textColor = total < 5 ? .systemRed : (total < 20 ? .systemOrange : .labelColor)
        grantedValue?.textColor = .secondaryLabelColor
        toppedValue?.textColor = .secondaryLabelColor

        if b.isAvailable {
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "可用"
        } else {
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = "余额不足"
        }
        lastUpdated = Self.timeFormatter.string(from: Date())
        SharedStore.writeBalance(b, sign: sign)
        SharedStore.appendHistory(total: b.total)
        updateFooter()
    }

    private func updateFooter() {
        guard footerLabel != nil else { return }
        var t = "等待获取…"
        if !lastUpdated.isEmpty { t = "更新于 \(lastUpdated)" }
        t += " · \(secondsLeft)s 后刷新"
        footerLabel.stringValue = t
    }

    private static func currencySign(_ code: String) -> String {
        switch code.uppercased() {
        case "CNY", "CN": return "¥"
        case "USD", "US": return "$"
        case "EUR":       return "€"
        default:          return code + " "
        }
    }

    // MARK: - 设置
    @objc func openSettings() {
        let sheet = SettingsWindow(displayMode: displayMode,
                                   sourceType: sourceType,
                                   baseURL: baseURL,
                                   apiKey: SharedStore.apiKey() ?? "",
                                   interval: interval)
        sheet.onSave = { [weak self] in
            guard let self = self else { return }
            self.interval = SharedStore.get("refreshInterval") as? Int ?? 60
            if self.interval <= 0 { self.interval = 60 }
            let newMode = SharedStore.get("displayMode") as? Int ?? 0
            if newMode != self.displayMode {
                self.displayMode = newMode
                self.applyMode()
            } else {
                self.startTicker()
                self.refresh()
            }
        }
        // 独立置顶窗口：不挂 sheet，确保输入框能正常获得焦点、粘贴
        NSApp.activate(ignoringOtherApps: true)
        sheet.focusAPIKeyField()
    }

    /// 隐藏面板（程序仍常驻菜单栏），点菜单栏图标可随时唤出
    @objc func hidePanel() { orderOut(nil) }
}

// MARK: - 设置面板
final class SettingsWindow: NSWindow {
    var onSave: (() -> Void)?
    private let keyField = NSSecureTextField(frame: NSRect(x: 88, y: 280, width: 200, height: 24))
    private let showKey = NSButton(checkboxWithTitle: "显示", target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: NSRect(x: 114, y: 236, width: 170, height: 26), pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: NSRect(x: 114, y: 194, width: 170, height: 26), pullsDown: false)
    private let baseField = NSTextField(frame: NSRect(x: 114, y: 152, width: 240, height: 24))
    private let intervalPopup = NSPopUpButton(frame: NSRect(x: 124, y: 110, width: 120, height: 26), pullsDown: false)
    private let intervals = [15, 30, 60, 120, 300]

    init(displayMode: Int, sourceType: Int, baseURL: String, apiKey: String, interval: Int) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 332),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "DeepSeek 用量面板 · 设置"
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        buildUI(displayMode: displayMode, sourceType: sourceType, baseURL: baseURL,
                apiKey: apiKey, interval: interval)
    }

    private func buildUI(displayMode: Int, sourceType: Int, baseURL: String,
                         apiKey: String, interval: Int) {
        let content = contentView!
        let labelFont = NSFont.systemFont(ofSize: 12)
        let labelColor = NSColor.secondaryLabelColor

        func label(_ text: String, _ frame: NSRect) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = labelFont
            l.textColor = labelColor
            l.frame = frame
            return l
        }

        // API Key
        content.addSubview(label("API Key", NSRect(x: 20, y: 284, width: 64, height: 20)))
        keyField.stringValue = apiKey
        keyField.placeholderString = "sk-…"
        keyField.font = .systemFont(ofSize: 12)
        content.addSubview(keyField)
        showKey.target = self
        showKey.action = #selector(toggleKeyVisible)
        showKey.frame = NSRect(x: 296, y: 282, width: 68, height: 20)
        content.addSubview(showKey)

        // 显示模式
        content.addSubview(label("显示模式", NSRect(x: 20, y: 240, width: 90, height: 20)))
        modePopup.removeAllItems()
        modePopup.addItem(withTitle: "极简 · 只显示总余额")
        modePopup.lastItem?.tag = 0
        modePopup.addItem(withTitle: "标准 · 含赠送/充值明细")
        modePopup.lastItem?.tag = 1
        modePopup.selectItem(withTag: displayMode)
        if modePopup.selectedTag() == -1 { modePopup.selectItem(withTag: 0) }
        content.addSubview(modePopup)

        // 数据源
        content.addSubview(label("数据源", NSRect(x: 20, y: 198, width: 90, height: 20)))
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "DeepSeek 官方 API")
        sourcePopup.lastItem?.tag = 0
        sourcePopup.addItem(withTitle: "自定义网关（中转站）")
        sourcePopup.lastItem?.tag = 1
        sourcePopup.selectItem(withTag: sourceType)
        if sourcePopup.selectedTag() == -1 { sourcePopup.selectItem(withTag: 0) }
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        content.addSubview(sourcePopup)

        // 网关地址
        content.addSubview(label("网关地址", NSRect(x: 20, y: 156, width: 90, height: 20)))
        baseField.stringValue = baseURL
        baseField.placeholderString = "https://your-gateway.com（可选 /v1）"
        baseField.font = .systemFont(ofSize: 12)
        baseField.isEnabled = (sourcePopup.selectedTag() == 1)
        content.addSubview(baseField)

        // 刷新间隔
        content.addSubview(label("自动刷新间隔", NSRect(x: 20, y: 114, width: 100, height: 20)))
        for iv in intervals {
            intervalPopup.addItem(withTitle: "\(iv) 秒")
            intervalPopup.lastItem?.tag = iv
        }
        intervalPopup.selectItem(withTag: interval)
        if intervalPopup.selectedTag() == -1 { intervalPopup.selectItem(withTag: 60) }
        content.addSubview(intervalPopup)

        // 说明
        let hint = NSTextField(labelWithString: "Key 仅保存在本机「钥匙串」。官方接口 api.deepseek.com/user/balance；自定义网关自动探测 /user/balance 与 /v1/user/balance（兼容 new-api / one-api 等 OpenAI 风格网关）。")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping
        hint.frame = NSRect(x: 20, y: 60, width: 340, height: 40)
        content.addSubview(hint)

        // 按钮
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 196, y: 20, width: 82, height: 30)
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 284, y: 20, width: 76, height: 30)
        content.addSubview(saveButton)
    }

    @objc private func toggleKeyVisible() {
        (keyField.cell as? NSSecureTextFieldCell)?.echosBullets = !(showKey.state == .on)
    }

    @objc private func sourceChanged() {
        baseField.isEnabled = (sourcePopup.selectedTag() == 1)
    }

    @objc private func save() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = KeychainStore.set(key, for: "apiKey")   // 兜底写钥匙串
        SharedStore.set("apiKey", key)
        let mode = modePopup.selectedTag()
        let source = sourcePopup.selectedTag()
        var base = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        SharedStore.set("displayMode", mode >= 0 ? mode : 0)
        SharedStore.set("sourceType", source >= 0 ? source : 0)
        SharedStore.set("baseURL", base)
        let tag = intervalPopup.selectedTag()
        SharedStore.set("refreshInterval", tag > 0 ? tag : 60)
        close()
        onSave?()
    }

    @objc private func cancel() { close() }

    /// 独立窗口打开并聚焦 API Key 输入框，保证粘贴/输入可用
    func focusAPIKeyField() {
        makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.makeFirstResponder(self?.keyField)
        }
    }
}

// MARK: - 看板窗口（余额历史曲线，加载 shared/ui 的 Web 看板）
final class DashboardWindow: NSWindow, WKNavigationDelegate {
    private var webView: WKWebView!
    private var loaded = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        title = "DeepSeek 用量看板"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 380)
        appearance = NSAppearance(named: .darkAqua)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        contentView?.addSubview(webView)
        center()
    }

    func loadDashboard() {
        // 优先读应用 Resources/dashboard，找不到则回退到源码目录（开发态）
        var dir = Bundle.main.resourceURL?.appendingPathComponent("dashboard")
        if dir == nil || !FileManager.default.fileExists(atPath: dir!.path) {
            let src = NSString(string: "~/Doubao/chats/2026-10-18/new-chat-2/deepseek-usage-app/shared/ui")
                .expandingTildeInPath
            if FileManager.default.fileExists(atPath: src) { dir = URL(fileURLWithPath: src) }
        }
        guard let d = dir else { return }
        let index = d.appendingPathComponent("dashboard.html")
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        loaded = false
        webView.loadFileURL(index, allowingReadAccessTo: d)
    }

    func refreshData() {
        let entries = SharedStore.historyJSON() ?? "[]"
        let total = SharedStore.get("total") as? String ?? ""
        let sign = SharedStore.get("sign") as? String ?? "¥"
        let js = "window.__DS_DATA__ = { sign: \(Self.jsStr(sign)), current: \(Self.jsStr(total)), entries: \(entries) }; renderDashboard();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshData()
        loaded = true
    }

    static func jsStr(_ s: String) -> String {
        let d = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(d)\""
    }
}

// MARK: - 入口（菜单栏常驻 + 悬浮面板）
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var dashboard: DashboardWindow?
    private let toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "开机自启", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        let p = FloatingPanel()
        panel = p
        p.orderFrontRegardless()
        p.refresh()
        if (SharedStore.apiKey() ?? "").isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak p] in
                p?.openSettings()
            }
        }
    }

    // MARK: 菜单栏
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "yensign.circle",
                                     accessibilityDescription: "DeepSeek 用量")
        let menu = NSMenu()
        menu.delegate = self

        toggleItem.title = "显示面板"
        toggleItem.target = self
        toggleItem.action = #selector(togglePanel)
        menu.addItem(toggleItem)

        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self

        let dashboardItem = menu.addItem(withTitle: "用量看板…", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self

        menu.addItem(.separator())

        launchItem.target = self
        launchItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let visible = panel?.isVisible ?? false
        toggleItem.title = visible ? "隐藏面板" : "显示面板"
        launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func togglePanel() {
        guard let p = panel else { return }
        if p.isVisible { p.orderOut(nil) } else { p.orderFrontRegardless() }
    }

    @objc private func openSettings() {
        panel?.openSettings()
    }

    @objc private func openDashboard() {
        if dashboard == nil {
            let w = DashboardWindow()
            dashboard = w
            w.loadDashboard()
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.refreshData()
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = SMAppService.mainApp.status != .enabled
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enable ? "无法开启开机自启" : "无法关闭开机自启"
            alert.informativeText = "请把应用移到「应用程序」文件夹后重试，或到 系统设置 → 通用 → 登录项 手动调整。\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

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
    /// 共享数据目录：真实 ~/Library/Application Support/DeepSeekUsagePanel
    /// 主应用与小组件通过 temporary-exception entitlement 访问（ad-hoc 签名无 team id，
    /// App Group 不可用，故用此共享目录）
    static func realHome() -> String {
        // 沙盒内 FileManager/NSHomeDirectory 被重定向到容器，须用 passwd 取真实 home
        if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir {
            return String(cString: d)
        }
        return NSHomeDirectory()
    }

    static func dirURL() -> URL {
        URL(fileURLWithPath: realHome())
            .appendingPathComponent("Library/Application Support/DeepSeekUsagePanel")
    }

    static func diagPath() -> String { dirURL().path }

    private static func read(_ name: String) -> [String: Any]? {
        let url = dirURL().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json
    }

    private static func write(_ name: String, _ dict: [String: Any]) {
        let dir = dirURL()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            try data.write(to: dir.appendingPathComponent(name))
        } catch {
            NSLog("SharedStore write \(name) failed: \(error.localizedDescription)")
        }
    }

    static func loadConfig() -> [String: Any] { read("config.json") ?? [:] }

    static func get(_ key: String) -> Any? { loadConfig()[key] }
    static func set(_ key: String, _ value: Any) {
        var d = loadConfig()
        d[key] = value
        write("config.json", d)
    }

    /// 写余额缓存（供小组件读取）
    static func writeBalance(_ b: AccountBalance, sign: String) {
        let payload: [String: Any] = [
            "total": b.total,
            "sign": sign,
            "granted": b.granted ?? "0",
            "topped": b.toppedUp ?? "0",
            "available": b.isAvailable,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        write("balance.json", payload)
    }

    /// 读余额缓存（看板/小组件共用）
    static func readBalance() -> [String: Any]? { read("balance.json") }

    /// API Key 读取：优先共享配置，兜底旧钥匙串
    static func apiKey() -> String? {
        if let k = get("apiKey") as? String, !k.isEmpty { return k }
        return KeychainStore.get("apiKey")
    }

    // MARK: - 余额历史（看板数据源）

    /// 追加一条余额记录到共享历史（同一次刷新 5 秒内去重，保留近 90 天 / 最多 1000 条）
    static func appendHistory(total: String) {
        var entries = historyEntries()
        let ts = Date().timeIntervalSince1970
        if let last = entries.last?["ts"] as? Double, ts - last < 5 {
            entries.removeLast()
        }
        entries.append(["ts": ts, "total": total])
        let cutoff = Date().addingTimeInterval(-86400 * 90).timeIntervalSince1970
        entries = entries.filter { ($0["ts"] as? Double ?? 0) > cutoff }
        if entries.count > 1000 { entries = Array(entries.suffix(1000)) }
        let url = dirURL().appendingPathComponent("history.json")
        do {
            try FileManager.default.createDirectory(at: dirURL(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries)
            try data.write(to: url)
        } catch {
            NSLog("SharedStore appendHistory failed: \(error.localizedDescription)")
        }
    }

    static func historyEntries() -> [[String: Any]] {
        let url = dirURL().appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr
    }

    /// 返回历史 JSON 字符串（供看板注入）
    static func historyJSON() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: historyEntries()) else { return nil }
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

// MARK: - 主题色（Apple 系统色板，参考系统小组件）
extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

enum AccentTheme: Int, CaseIterable {
    case blue, graphite, green, orange, purple, pink, teal, red

    var name: String {
        switch self {
        case .blue:     return "系统蓝"
        case .graphite: return "石墨灰"
        case .green:    return "绿色"
        case .orange:   return "橙色"
        case .purple:   return "紫罗兰"
        case .pink:     return "粉色"
        case .teal:     return "青色"
        case .red:      return "红色"
        }
    }

    var hex: String {
        switch self {
        case .blue:     return "#0A84FF"
        case .graphite: return "#98989D"
        case .green:    return "#30D158"
        case .orange:   return "#FF9F0A"
        case .purple:   return "#BF5AF2"
        case .pink:     return "#FF375F"
        case .teal:     return "#64D2FF"
        case .red:      return "#FF453A"
        }
    }

    var color: NSColor { NSColor(hex: hex) }
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

    // 配置（存共享目录 config.json）
    private var displayMode: Int {      // 0=极简（只显示总余额） 1=标准（含赠送/充值） 2=看板（余额+用量曲线）
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
    private var alwaysOnTop: Bool {
        get { SharedStore.get("alwaysOnTop") as? Bool ?? true }
        set { SharedStore.set("alwaysOnTop", newValue) }
    }
    private var isMini: Bool { displayMode == 0 }
    private var isDashboard: Bool { displayMode == 2 }
    private var opacity: Double {                    // 面板透明度 0.5~1.0
        get { SharedStore.get("opacity") as? Double ?? 1.0 }
        set { SharedStore.set("opacity", newValue) }
    }
    private var accent: Int {                        // 主题色 id（AccentTheme）
        get { SharedStore.get("accent") as? Int ?? 0 }
    }
    private var accentColor: NSColor {
        AccentTheme(rawValue: accent)?.color ?? AccentTheme.blue.color
    }

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
        let mode = SharedStore.get("displayMode") as? Int ?? 0
        let w: CGFloat = mode == 2 ? 340 : (mode == 0 ? 320 : 340)
        let h: CGFloat = mode == 2 ? 280 : (mode == 0 ? 100 : 244)
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        setAlwaysOnTop(alwaysOnTop)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        alphaValue = CGFloat(opacity)
        buildUI()
        positionPanel()
        startTicker()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 布局构建 / 模式切换
    /// 设置是否置顶：true → floating 层（始终在最前）；false → normal 层（会被其他窗口遮挡）。
    /// isFloatingPanel 与 level 必须同步，否则 AppKit 会在窗口显示时用 floating 层级覆盖。
    func setAlwaysOnTop(_ on: Bool) {
        isFloatingPanel = on
        level = on ? .floating : .normal
    }

    func applyMode() {
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        dashboardValues.removeAll()
        chartView = nil
        rangeControl = nil
        let w: CGFloat = isDashboard ? 340 : (isMini ? 320 : 340)
        let h: CGFloat = isDashboard ? 280 : (isMini ? 100 : 244)
        setContentSize(NSSize(width: w, height: h))
        alphaValue = CGFloat(opacity)
        buildUI()
        positionPanel()
        updateFooter()
        refresh()
    }

    private func buildUI() {
        let content = contentView!
        if isDashboard {
            buildDashboardLayout(content)
            return
        }

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

    // MARK: 看板模式（原生小组件风格：卡片 + 迷你曲线，整窗可拖，无拖动条）
    private var dashboardValues: [String: DragLabel] = [:]
    private var chartView: MiniChartView?
    private var rangeControl: NSSegmentedControl?
    private var dashRange: Int {                       // 0=全部 7=近7天 30=近30天
        get { SharedStore.get("dashRange") as? Int ?? 7 }
        set { SharedStore.set("dashRange", newValue) }
    }

    private func buildDashboardLayout(_ content: NSView) {
        // 毛玻璃背景：整窗可拖（与极简/标准一致，小组件交互）
        let effect = DragEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        content.addSubview(effect)

        // 标题 + 时间范围（分段控件）
        let title = DragLabel(labelWithString: "DeepSeek 用量")
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: 260, width: 110, height: 14)
        content.addSubview(title)

        let seg = NSSegmentedControl(labels: ["7天", "30天", "全部"], trackingMode: .selectOne,
                                     target: self, action: #selector(dashRangeChanged))
        seg.selectedSegment = dashRange == 30 ? 1 : (dashRange == 0 ? 2 : 0)
        seg.segmentStyle = .rounded
        if #available(macOS 11.0, *) { seg.selectedSegmentBezelColor = accentColor }
        seg.frame = NSRect(x: 196, y: 256, width: 132, height: 22)
        content.addSubview(seg)
        rangeControl = seg

        // 卡片 3×2（当前余额/今日消耗/累计消耗/累计充值/记录天数/区间最高）
        let specs: [(String, String)] = [
            ("当前余额", "—"), ("今日消耗", "—"), ("累计消耗", "—"),
            ("累计充值", "—"), ("记录天数", "—"), ("区间最高", "—")
        ]
        for (i, spec) in specs.enumerated() {
            let col = i % 3, row = i / 3
            let x = 12 + CGFloat(col) * 108
            let labelY: CGFloat = row == 0 ? 222 : 168
            let valY: CGFloat = row == 0 ? 202 : 148
            let label = DragLabel(labelWithString: spec.0)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: x, y: labelY, width: 100, height: 14)
            content.addSubview(label)
            let val = DragLabel(labelWithString: spec.1)
            val.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            val.textColor = spec.0 == "当前余额" ? accentColor : .labelColor
            val.frame = NSRect(x: x, y: valY, width: 100, height: 18)
            content.addSubview(val)
            dashboardValues[spec.0] = val
        }

        // 迷你余额曲线
        let chart = MiniChartView(frame: NSRect(x: 12, y: 8, width: content.bounds.width - 24, height: 128))
        chart.autoresizingMask = [.width]
        chart.lineColor = accentColor
        content.addSubview(chart)
        chartView = chart
    }

    @objc private func dashRangeChanged() {
        if let s = rangeControl?.selectedSegment {
            dashRange = s == 1 ? 30 : (s == 2 ? 0 : 7)
        }
        updateDashboardUI()
    }

    /// 刷新看板卡片与迷你曲线（幂等，随数据更新调用）
    private func updateDashboardUI() {
        guard isDashboard else { return }
        let entries = SharedStore.historyEntries()
        let balance = SharedStore.readBalance()
        let total = balance?["total"] as? String ?? "—"
        let sign = balance?["sign"] as? String ?? "¥"
        dashboardValues["当前余额"]?.stringValue = "\(sign) \(total)"

        // 今日消耗 / 累计消耗 / 累计充值（余额差推导）
        var todayUsage = 0.0, cumUsage = 0.0, topup = 0.0
        if entries.count >= 2 {
            let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            for i in 1..<entries.count {
                let prev = Double(entries[i - 1]["total"] as? String ?? "0") ?? 0
                let cur = Double(entries[i]["total"] as? String ?? "0") ?? 0
                let diff = prev - cur
                if diff > 0.001 {
                    cumUsage += diff
                    if (entries[i]["ts"] as? Double ?? 0) >= dayStart { todayUsage += diff }
                } else if diff < -0.001 {
                    topup += -diff
                }
            }
        }
        dashboardValues["今日消耗"]?.stringValue = todayUsage > 0.001 ? "\(sign) \(String(format: "%.2f", todayUsage))" : "0.00"
        dashboardValues["累计消耗"]?.stringValue = cumUsage > 0.001 ? "\(sign) \(String(format: "%.2f", cumUsage))" : "0.00"
        dashboardValues["累计充值"]?.stringValue = topup > 0.001 ? "\(sign) \(String(format: "%.2f", topup))" : "0.00"

        let firstTs = entries.first?["ts"] as? Double ?? 0
        let days = firstTs > 0 ? max(1, Int((Date().timeIntervalSince1970 - firstTs) / 86400)) : 0
        dashboardValues["记录天数"]?.stringValue = days > 0 ? "\(days) 天" : "—"
        let maxV = entries.reduce(0.0) { max($0, Double($1["total"] as? String ?? "0") ?? 0) }
        dashboardValues["区间最高"]?.stringValue = maxV > 0 ? "\(sign) \(String(format: "%.2f", maxV))" : "—"

        // 迷你曲线（按范围过滤）
        let cutoff = dashRange > 0 ? Date().timeIntervalSince1970 - Double(dashRange) * 86400 : 0
        let pts: [(ts: TimeInterval, total: Double)] = entries.compactMap { e in
            guard let ts = e["ts"] as? Double, ts >= cutoff else { return nil }
            return (ts: ts, total: Double(e["total"] as? String ?? "0") ?? 0)
        }
        chartView?.setPoints(pts)
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
        totalValue.textColor = accentColor
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
        totalValue.textColor = accentColor
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
        // 看板模式：不触碰原生控件，仅拉数据 + 更新卡片/曲线
        if isDashboard {
            guard let key = SharedStore.apiKey(), !key.isEmpty else { return }
            guard let base = resolvedBaseURL() else { return }
            api.fetchBalance(baseURL: base, key: key) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if case .success(let b) = result {
                        let sign = Self.currencySign(b.currency)
                        SharedStore.writeBalance(b, sign: sign)
                        SharedStore.appendHistory(total: b.total)
                    }
                    self.updateDashboardUI()
                }
            }
            return
        }
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
        totalValue.textColor = total < 5 ? .systemRed : (total < 20 ? .systemOrange : accentColor)
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
                                   interval: interval,
                                   alwaysOnTop: alwaysOnTop,
                                   opacity: SharedStore.get("opacity") as? Double ?? 1.0,
                                   accent: SharedStore.get("accent") as? Int ?? 0)
        sheet.onSave = { [weak self] in
            guard let self = self else { return }
            self.interval = SharedStore.get("refreshInterval") as? Int ?? 60
            if self.interval <= 0 { self.interval = 60 }
            self.setAlwaysOnTop(SharedStore.get("alwaysOnTop") as? Bool ?? true)
            self.alphaValue = CGFloat(SharedStore.get("opacity") as? Double ?? 1.0)
            // save() 已先写 SharedStore 再回调，新旧值已无法区分，故无条件重建
            self.startTicker()
            self.applyMode()
        }
        // 独立置顶窗口：不挂 sheet，确保输入框能正常获得焦点、粘贴
        NSApp.activate(ignoringOtherApps: true)
        sheet.focusAPIKeyField()
    }

    /// 隐藏面板（程序仍常驻菜单栏），点菜单栏图标可随时唤出
    @objc func hidePanel() { orderOut(nil) }
}

// MARK: - 迷你曲线（原生绘制：小组件风格）
final class MiniChartView: NSView {
    var points: [(ts: TimeInterval, total: Double)] = []
    var lineColor: NSColor = .systemTeal

    func setPoints(_ p: [(ts: TimeInterval, total: Double)]) {
        points = p
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            ("暂无数据，等待记录…" as NSString).draw(at: NSPoint(x: 8, y: bounds.height / 2 - 6), withAttributes: attrs)
            return
        }
        let vals = points.map { $0.total }
        let minV = vals.min() ?? 0
        let maxV = vals.max() ?? 1
        let span = max(maxV - minV, 0.0001)
        let w = bounds.width
        let h = bounds.height

        // 底部基线
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 0, y: 0.5))
        base.line(to: NSPoint(x: w, y: 0.5))
        base.lineWidth = 0.5
        base.stroke()

        let mapped: [NSPoint] = points.enumerated().map { i, p in
            let x = CGFloat(i) / CGFloat(points.count - 1) * w
            let y = CGFloat((p.total - minV) / span) * (h - 14) + 7
            return NSPoint(x: x, y: y)
        }

        // 面积填充
        let fill = NSBezierPath()
        fill.move(to: mapped[0])
        for p in mapped.dropFirst() { fill.line(to: p) }
        fill.line(to: NSPoint(x: mapped.last!.x, y: 0))
        fill.line(to: NSPoint(x: mapped.first!.x, y: 0))
        fill.close()
        lineColor.withAlphaComponent(0.16).setFill()
        fill.fill()

        // 折线
        let path = NSBezierPath()
        path.move(to: mapped[0])
        for p in mapped.dropFirst() { path.line(to: p) }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        lineColor.setStroke()
        path.stroke()

        // 末点
        let last = mapped.last!
        let dot = NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
        lineColor.setFill()
        dot.fill()
    }
}

// MARK: - 设置面板
final class SettingsWindow: NSWindow {
    var onSave: (() -> Void)?
    private let keyField = NSSecureTextField(frame: NSRect(x: 88, y: 326, width: 200, height: 24))
    private let showKey = NSButton(checkboxWithTitle: "显示", target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: NSRect(x: 114, y: 282, width: 170, height: 26), pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: NSRect(x: 114, y: 240, width: 170, height: 26), pullsDown: false)
    private let baseField = NSTextField(frame: NSRect(x: 114, y: 198, width: 240, height: 24))
    private let intervalPopup = NSPopUpButton(frame: NSRect(x: 124, y: 156, width: 120, height: 26), pullsDown: false)
    private let topCheck = NSButton(checkboxWithTitle: "窗口始终置顶", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "100%")
    private var accentButtons: [NSButton] = []
    private var currentAccent: Int = 0
    private let intervals = [15, 30, 60, 120, 300]

    init(displayMode: Int, sourceType: Int, baseURL: String, apiKey: String, interval: Int, alwaysOnTop: Bool, opacity: Double, accent: Int) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "DeepSeek 用量面板 · 设置"
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        buildUI(displayMode: displayMode, sourceType: sourceType, baseURL: baseURL,
                apiKey: apiKey, interval: interval, alwaysOnTop: alwaysOnTop,
                opacity: opacity, accent: accent)
    }

    private func buildUI(displayMode: Int, sourceType: Int, baseURL: String,
                         apiKey: String, interval: Int, alwaysOnTop: Bool,
                         opacity: Double, accent: Int) {
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
        content.addSubview(label("API Key", NSRect(x: 20, y: 330, width: 64, height: 20)))
        keyField.stringValue = apiKey
        keyField.placeholderString = "sk-…"
        keyField.font = .systemFont(ofSize: 12)
        content.addSubview(keyField)
        showKey.target = self
        showKey.action = #selector(toggleKeyVisible)
        showKey.frame = NSRect(x: 296, y: 328, width: 68, height: 20)
        content.addSubview(showKey)

        // 显示模式
        content.addSubview(label("显示模式", NSRect(x: 20, y: 286, width: 90, height: 20)))
        modePopup.removeAllItems()
        modePopup.addItem(withTitle: "极简 · 只显示总余额")
        modePopup.lastItem?.tag = 0
        modePopup.addItem(withTitle: "标准 · 含赠送/充值明细")
        modePopup.lastItem?.tag = 1
        modePopup.addItem(withTitle: "看板 · 余额+用量曲线")
        modePopup.lastItem?.tag = 2
        modePopup.selectItem(withTag: displayMode)
        if modePopup.selectedTag() == -1 { modePopup.selectItem(withTag: 0) }
        content.addSubview(modePopup)

        // 数据源
        content.addSubview(label("数据源", NSRect(x: 20, y: 244, width: 90, height: 20)))
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
        content.addSubview(label("网关地址", NSRect(x: 20, y: 202, width: 90, height: 20)))
        baseField.stringValue = baseURL
        baseField.placeholderString = "https://your-gateway.com（可选 /v1）"
        baseField.font = .systemFont(ofSize: 12)
        baseField.isEnabled = (sourcePopup.selectedTag() == 1)
        content.addSubview(baseField)

        // 刷新间隔
        content.addSubview(label("自动刷新间隔", NSRect(x: 20, y: 160, width: 100, height: 20)))
        for iv in intervals {
            intervalPopup.addItem(withTitle: "\(iv) 秒")
            intervalPopup.lastItem?.tag = iv
        }
        intervalPopup.selectItem(withTag: interval)
        if intervalPopup.selectedTag() == -1 { intervalPopup.selectItem(withTag: 60) }
        content.addSubview(intervalPopup)

        // 窗口置顶
        content.addSubview(label("窗口置顶", NSRect(x: 20, y: 128, width: 90, height: 20)))
        topCheck.state = alwaysOnTop ? .on : .off
        topCheck.frame = NSRect(x: 112, y: 126, width: 160, height: 20)
        content.addSubview(topCheck)

        // 面板透明度
        content.addSubview(label("面板透明度", NSRect(x: 20, y: 88, width: 90, height: 20)))
        opacitySlider.doubleValue = max(0.5, min(1.0, opacity))
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.frame = NSRect(x: 112, y: 86, width: 150, height: 20)
        content.addSubview(opacitySlider)
        opacityValue.font = .systemFont(ofSize: 12)
        opacityValue.textColor = .secondaryLabelColor
        opacityValue.frame = NSRect(x: 268, y: 88, width: 52, height: 20)
        opacityValue.stringValue = "\(Int(round(opacity * 100)))%"
        content.addSubview(opacityValue)

        // 主题色（Apple 系统色板）
        content.addSubview(label("主题色", NSRect(x: 20, y: 54, width: 90, height: 20)))
        currentAccent = accent
        for (i, t) in AccentTheme.allCases.enumerated() {
            let x = 112 + CGFloat(i) * 30
            let b = NSButton(title: "", target: self, action: #selector(accentPicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = t.color.cgColor
            b.layer?.cornerRadius = 10
            b.layer?.masksToBounds = true
            b.frame = NSRect(x: x, y: 50, width: 20, height: 20)
            b.toolTip = t.name
            content.addSubview(b)
            accentButtons.append(b)
        }
        updateAccentSelection()

        // 按钮
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 196, y: 12, width: 82, height: 30)
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 284, y: 12, width: 76, height: 30)
        content.addSubview(saveButton)
    }

    @objc private func accentPicked(_ sender: NSButton) {
        currentAccent = sender.tag
        updateAccentSelection()
    }

    private func updateAccentSelection() {
        for (i, b) in accentButtons.enumerated() {
            b.layer?.borderWidth = (i == currentAccent) ? 2.5 : 0
            b.layer?.borderColor = (i == currentAccent) ? NSColor.white.cgColor : NSColor.clear.cgColor
        }
    }

    @objc private func toggleKeyVisible() {
        (keyField.cell as? NSSecureTextFieldCell)?.echosBullets = !(showKey.state == .on)
    }

    @objc private func sourceChanged() {
        baseField.isEnabled = (sourcePopup.selectedTag() == 1)
    }

    @objc private func opacityChanged() {
        opacityValue.stringValue = "\(Int(round(opacitySlider.doubleValue * 100)))%"
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
        SharedStore.set("alwaysOnTop", topCheck.state == .on)
        SharedStore.set("opacity", opacitySlider.doubleValue)
        SharedStore.set("accent", currentAccent)
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
final class DashboardWindow: NSWindow, WKNavigationDelegate, WKScriptMessageHandler {
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
        let controller = WKUserContentController()
        controller.add(self, name: "log")
        config.userContentController = controller
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
        let balance = SharedStore.readBalance()
        let total = balance?["total"] as? String ?? ""
        let sign = balance?["sign"] as? String ?? "¥"
        let accent = AccentTheme(rawValue: SharedStore.get("accent") as? Int ?? 0)?.hex ?? "#0A84FF"
        let js = "window.__DS_DATA__ = { sign: \(Self.jsStr(sign)), current: \(Self.jsStr(total)), entries: \(entries), accent: \(Self.jsStr(accent)) }; console.log('injected', JSON.stringify(window.__DS_DATA__).slice(0, 300)); renderDashboard();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshData()
        loaded = true
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "log" {
            NSLog("DashboardJS: \(String(describing: message.body))")
        }
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
        NSLog("DSAPP diag: dir=\(SharedStore.diagPath()) cfg=\(SharedStore.loadConfig())")
        setupStatusItem()
        let p = FloatingPanel()
        panel = p
        NSLog("DSAPP launch: panel created, alwaysOnTop=\(SharedStore.get("alwaysOnTop") as? Bool ?? true) level=\(p.level.rawValue)")
        p.orderFrontRegardless()
        NSLog("DSAPP launch: ordered front, isVisible=\(p.isVisible)")
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
        // 页面未加载完成时 evaluateJavaScript 会静默失败，延迟补发注入
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.dashboard?.refreshData()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.dashboard?.refreshData()
        }
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

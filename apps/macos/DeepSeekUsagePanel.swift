// DeepSeekUsagePanel — macOS 悬浮窗面板：实时显示 DeepSeek API 余额 / 用量
// 数据源：DeepSeek 官方（https://api.deepseek.com/user/balance）或自定义 OpenAI 兼容网关（自动探测 /user/balance、/v1/user/balance）
// 模式：极简（只显示总余额）/ 标准（总余额 + 赠送 + 充值）
// 编译：见 build.sh
import Cocoa
import Security
import WebKit
import UserNotifications

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

    /// 追加一条余额记录到共享历史（同一次刷新 5 秒内去重，保留近 90 天）
    /// 存储策略：近 48 小时保留全部细粒度采样；更早的数据按自然日折叠为首尾两条，
    /// 从而"记录天数"能真实覆盖数天/数十天，且文件不会无限膨胀。
    static func appendHistory(total: String) {
        var entries = historyEntries()
        let ts = Date().timeIntervalSince1970
        if let last = entries.last?["ts"] as? Double, ts - last < 5 {
            entries.removeLast()
        }
        entries.append(["ts": ts, "total": total])
        let cutoff = Date().addingTimeInterval(-86400 * 90).timeIntervalSince1970
        entries = entries.filter { ($0["ts"] as? Double ?? 0) > cutoff }
        entries = compactHistory(entries)
        if entries.count > 30000 { entries = Array(entries.suffix(30000)) }
        let url = dirURL().appendingPathComponent("history.json")
        do {
            try FileManager.default.createDirectory(at: dirURL(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries)
            try data.write(to: url)
        } catch {
            NSLog("SharedStore appendHistory failed: \(error.localizedDescription)")
        }
    }

    /// 近 48 小时保留全部细粒度；更早按自然日折叠（保留该日首条+末条），时间升序
    static func compactHistory(_ entries: [[String: Any]]) -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        let fineCut = now - 86400 * 2
        var fine: [[String: Any]] = []
        var dayBuckets: [Int: [[String: Any]]] = [:]
        for e in entries {
            let t = e["ts"] as? Double ?? 0
            if t >= fineCut {
                fine.append(e)
            } else {
                let day = Int(floor(t / 86400))
                dayBuckets[day, default: []].append(e)
            }
        }
        var coarse: [[String: Any]] = []
        for day in dayBuckets.keys.sorted() {
            guard let arr = dayBuckets[day], let f = arr.first, let l = arr.last else { continue }
            if arr.count <= 2 { coarse.append(contentsOf: arr) }
            else { coarse.append(f); coarse.append(l) }
        }
        return coarse + fine
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

    /// 清除余额历史（保留当前余额）
    static func clearHistory() {
        let url = dirURL().appendingPathComponent("history.json")
        try? FileManager.default.removeItem(at: url)
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
    private var appearanceMode: Int {                // 0=跟随系统 1=深色 2=浅色
        get { SharedStore.get("appearanceMode") as? Int ?? 0 }
    }
    private var dashCards: [Int] {                   // 看板显示卡片 id 列表
        get { SharedStore.get("dashCards") as? [Int] ?? [0, 1, 2, 3, 4, 5] }
    }
    private var lowBalanceAlert: Bool {
        get { SharedStore.get("lowBalanceAlert") as? Bool ?? false }
    }
    private var lowBalanceThreshold: Double {
        get { SharedStore.get("lowBalanceThreshold") as? Double ?? 10.0 }
    }

    private func applyAppearance() {
        switch appearanceMode {
        case 1: appearance = NSAppearance(named: .darkAqua)
        case 2: appearance = NSAppearance(named: .aqua)
        default: appearance = nil                    // 跟随系统
        }
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
    private var pinButton: NSButton!

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        let mode = SharedStore.get("displayMode") as? Int ?? 0
        let hasChart = SharedStore.get("showChart") as? Bool ?? true
        let h: CGFloat
        switch mode {
        case 0: h = 100
        case 1: h = 244
        default:
            let twoRows = (SharedStore.get("dashCards") as? [Int] ?? [0, 1, 2, 3, 4, 5]).count <= 3
            h = hasChart ? (twoRows ? 232 : 280) : (twoRows ? 150 : 210)
        }
        let w: CGFloat = mode == 2 ? 340 : (mode == 0 ? 320 : 340)
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
        applyAppearance()
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
        SharedStore.set("alwaysOnTop", on)
        updatePinIcon()
    }

    /// 看板卡片行数（≤3 张 1 行，否则 2 行）→ 面板自适应高度
    private func dashboardRows() -> Int { dashCards.count <= 3 ? 1 : 2 }
    private func dashboardHeight() -> CGFloat {
        let twoRows = dashboardRows() == 2
        if showChart { return twoRows ? 280 : 232 }
        return twoRows ? 210 : 150
    }

    /// 置顶小开关（面板右上角）
    @objc private func togglePin() {
        setAlwaysOnTop(!alwaysOnTop)
    }
    private func updatePinIcon() {
        guard pinButton != nil else { return }
        if #available(macOS 11.0, *) {
            pinButton.image = NSImage(systemSymbolName: alwaysOnTop ? "pin.fill" : "pin",
                                      accessibilityDescription: "置顶")
        }
        pinButton.contentTintColor = alwaysOnTop ? accentColor : .secondaryLabelColor
        pinButton.toolTip = alwaysOnTop ? "取消置顶" : "窗口置顶"
    }
    private func makePinButton() -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(togglePin))
        b.isBordered = false
        b.wantsLayer = true
        b.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        return b
    }

    func applyMode() {
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        dashboardValues.removeAll()
        chartView = nil
        rangeControl = nil
        let w: CGFloat = isDashboard ? 340 : (isMini ? 320 : 340)
        let h: CGFloat = isDashboard ? dashboardHeight() : (isMini ? 100 : 244)
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
    private var showChart: Bool {                      // 看板是否显示迷你曲线
        get { SharedStore.get("showChart") as? Bool ?? true }
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

        // 标题 + 时间范围（分段控件）+ 置顶开关——坐标随卡片行数/曲线开关自适应
        let hasChart = showChart
        let twoRows = dashboardRows() == 2
        let titleY: CGFloat = hasChart ? (twoRows ? 260 : 194) : (twoRows ? 160 : 118)
        let segY: CGFloat = hasChart ? (twoRows ? 256 : 190) : (twoRows ? 156 : 114)
        let row1LabelY: CGFloat = hasChart ? (twoRows ? 222 : 168) : (twoRows ? 116 : 72)
        let row1ValY: CGFloat = hasChart ? (twoRows ? 202 : 150) : (twoRows ? 98 : 54)
        let row2LabelY: CGFloat = hasChart ? 168 : 62
        let row2ValY: CGFloat = hasChart ? 148 : 44

        let title = DragLabel(labelWithString: "DeepSeek 用量")
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: titleY, width: 110, height: 14)
        content.addSubview(title)

        let seg = NSSegmentedControl(labels: ["7天", "30天", "全部"], trackingMode: .selectOne,
                                     target: self, action: #selector(dashRangeChanged))
        seg.selectedSegment = dashRange == 30 ? 1 : (dashRange == 0 ? 2 : 0)
        seg.segmentStyle = .rounded
        if #available(macOS 11.0, *) { seg.selectedSegmentBezelColor = accentColor }
        seg.frame = NSRect(x: 196, y: segY, width: 110, height: 22)
        content.addSubview(seg)
        rangeControl = seg

        // 置顶小开关（右上角）
        pinButton = makePinButton()
        pinButton.frame = NSRect(x: 312, y: segY + 2, width: 20, height: 20)
        content.addSubview(pinButton)
        updatePinIcon()

        // 卡片（按用户勾选显示；最多 6 张，3 列）
        let allSpecs: [(Int, String)] = [
            (0, "当前余额"), (1, "今日消耗"), (2, "累计消耗"),
            (3, "累计充值"), (4, "记录天数"), (5, "区间最高")
        ]
        let specs = allSpecs.filter { dashCards.contains($0.0) }
        let cols = min(3, max(1, specs.count))
        let cardW: CGFloat = (content.bounds.width - 24 - CGFloat(cols - 1) * 8) / CGFloat(cols)
        for (i, spec) in specs.enumerated() {
            let col = i % cols, row = i / cols
            let x = 12 + CGFloat(col) * (cardW + 8)
            let labelY: CGFloat = row == 0 ? row1LabelY : row2LabelY
            let valY: CGFloat = row == 0 ? row1ValY : row2ValY
            let label = DragLabel(labelWithString: spec.1)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: x, y: labelY, width: cardW, height: 14)
            content.addSubview(label)
            let val = DragLabel(labelWithString: "—")
            val.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            val.textColor = spec.1 == "当前余额" ? accentColor : .labelColor
            val.frame = NSRect(x: x, y: valY, width: cardW, height: 18)
            content.addSubview(val)
            dashboardValues[spec.1] = val
        }

        // 迷你余额曲线（可隐藏）
        if hasChart {
            let chart = MiniChartView(frame: NSRect(x: 12, y: 8, width: content.bounds.width - 24, height: 128))
            chart.autoresizingMask = [.width]
            chart.lineColor = accentColor
            content.addSubview(chart)
            chartView = chart
        }
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
        // 累计充值：优先取官方充值余额（topped_up_balance，用户实际充值的钱），
        // 记录期内检测到的充值事件作为补充（API 快照已含记录期充值，故取较大值）
        let topped = Double(balance?["topped"] as? String ?? "0") ?? 0
        let cumTopup = max(topup, topped)
        dashboardValues["累计充值"]?.stringValue = cumTopup > 0.001 ? "\(sign) \(String(format: "%.2f", cumTopup))" : "0.00"

        // 记录天数：实际有记录的自然日数（与看板一致）
        let daySet = Set(entries.compactMap { e -> Int? in
            guard let t = e["ts"] as? Double, t > 0 else { return nil }
            return Int(floor(t / 86400))
        })
        let days = daySet.count
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

        // 置顶小开关（右上角）
        pinButton = makePinButton()
        pinButton.frame = NSRect(x: 266, y: 212, width: 20, height: 20)
        content.addSubview(pinButton)
        updatePinIcon()

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
        checkLowBalance(total: total, sign: sign)
        updateFooter()
    }

    /// 低余额提醒（低于阈值发一次系统通知，恢复后重置）
    private func checkLowBalance(total: Double, sign: String) {
        guard lowBalanceAlert else { return }
        if total < lowBalanceThreshold {
            guard !(SharedStore.get("lowNotified") as? Bool ?? false) else { return }
            let center = UNUserNotificationCenter.current()
            // 仅首次提醒时请求授权（避免每次刷新都请求）
            if !(SharedStore.get("notifAuthAsked") as? Bool ?? false) {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                SharedStore.set("notifAuthAsked", true)
            }
            let content = UNMutableNotificationContent()
            content.title = "DeepSeek 余额不足"
            content.body = "当前余额 \(sign) \(String(format: "%.2f", total))，低于提醒阈值 \(sign) \(String(format: "%.2f", lowBalanceThreshold))"
            content.sound = .default
            let req = UNNotificationRequest(identifier: "ds-low-balance", content: content, trigger: nil)
            center.add(req)
            SharedStore.set("lowNotified", true)
        } else {
            SharedStore.set("lowNotified", false)
        }
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
                                   accent: SharedStore.get("accent") as? Int ?? 0,
                                   appearanceMode: SharedStore.get("appearanceMode") as? Int ?? 0,
                                   dashCards: SharedStore.get("dashCards") as? [Int] ?? [0, 1, 2, 3, 4, 5],
                                   dashRange: SharedStore.get("dashRange") as? Int ?? 7,
                                   showChart: SharedStore.get("showChart") as? Bool ?? true,
                                   lowAlert: SharedStore.get("lowBalanceAlert") as? Bool ?? false,
                                   lowThreshold: SharedStore.get("lowBalanceThreshold") as? Double ?? 10.0)
        sheet.onSave = { [weak self] in
            guard let self = self else { return }
            self.interval = SharedStore.get("refreshInterval") as? Int ?? 60
            if self.interval <= 0 { self.interval = 60 }
            self.setAlwaysOnTop(SharedStore.get("alwaysOnTop") as? Bool ?? true)
            self.alphaValue = CGFloat(SharedStore.get("opacity") as? Double ?? 1.0)
            self.applyAppearance()
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

// MARK: - 设置面板（多标签：基础 / 外观 / 看板 / 提醒）
final class SettingsWindow: NSWindow {
    var onSave: (() -> Void)?

    // 基础
    private let keyField = NSSecureTextField(frame: .zero)
    private let showKey = NSButton(checkboxWithTitle: "显示", target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseField = NSTextField(frame: .zero)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let intervals = [15, 30, 60, 120, 300]
    // 外观
    private let topCheck = NSButton(checkboxWithTitle: "窗口始终置顶", target: nil, action: nil)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "100%")
    private var accentButtons: [NSButton] = []
    private var currentAccent: Int = 0
    // 看板
    private let dashCardChecks = ["当前余额", "今日消耗", "累计消耗", "累计充值", "记录天数", "区间最高"].map {
        NSButton(checkboxWithTitle: $0, target: nil, action: nil)
    }
    private let dashRangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chartCheck = NSButton(checkboxWithTitle: "显示曲线图", target: nil, action: nil)
    // 提醒
    private let lowCheck = NSButton(checkboxWithTitle: "余额低于阈值时发送系统通知", target: nil, action: nil)
    private let thresholdField = NSTextField(frame: .zero)
    // 标签栏
    private var tabSeg: NSSegmentedControl!
    private let tabContent = NSView()
    private var tabs: [NSView] = []

    init(displayMode: Int, sourceType: Int, baseURL: String, apiKey: String, interval: Int,
         alwaysOnTop: Bool, opacity: Double, accent: Int, appearanceMode: Int,
         dashCards: [Int], dashRange: Int, showChart: Bool, lowAlert: Bool, lowThreshold: Double) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 454),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "DeepSeek 用量面板 · 设置"
        isReleasedWhenClosed = false
        buildUI(displayMode: displayMode, sourceType: sourceType, baseURL: baseURL,
                apiKey: apiKey, interval: interval, alwaysOnTop: alwaysOnTop,
                opacity: opacity, accent: accent, appearanceMode: appearanceMode,
                dashCards: dashCards, dashRange: dashRange, showChart: showChart,
                lowAlert: lowAlert, lowThreshold: lowThreshold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func label(_ text: String, _ frame: NSRect, _ color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = color
        l.frame = frame
        return l
    }

    private func buildUI(displayMode: Int, sourceType: Int, baseURL: String,
                         apiKey: String, interval: Int, alwaysOnTop: Bool,
                         opacity: Double, accent: Int, appearanceMode: Int,
                         dashCards: [Int], dashRange: Int, showChart: Bool,
                         lowAlert: Bool, lowThreshold: Double) {
        let content = contentView!

        // ---- 标签栏（分段控件，高 30，点击区域大）----
        tabSeg = NSSegmentedControl(labels: ["基础", "外观", "看板", "提醒"],
                                    trackingMode: .selectOne, target: self, action: #selector(tabChanged))
        tabSeg.selectedSegment = 0
        tabSeg.segmentStyle = .rounded
        tabSeg.frame = NSRect(x: 10, y: 398, width: 380, height: 30)
        content.addSubview(tabSeg)

        // 内容容器
        tabContent.frame = NSRect(x: 10, y: 40, width: 380, height: 352)
        content.addSubview(tabContent)

        // 预构建 4 个标签页
        tabs = [
            buildBasicTab(displayMode: displayMode, sourceType: sourceType,
                          baseURL: baseURL, apiKey: apiKey, interval: interval),
            buildAppearanceTab(alwaysOnTop: alwaysOnTop, opacity: opacity,
                               accent: accent, appearanceMode: appearanceMode),
            buildDashboardTab(dashCards: dashCards, dashRange: dashRange, showChart: showChart),
            buildAlertTab(lowAlert: lowAlert, lowThreshold: lowThreshold)
        ]
        switchTab(0)

        // 按钮
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 208, y: 8, width: 82, height: 28)
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 300, y: 8, width: 76, height: 28)
        content.addSubview(saveButton)
    }

    @objc private func tabChanged() {
        switchTab(tabSeg.selectedSegment)
    }

    private func switchTab(_ idx: Int) {
        tabContent.subviews.forEach { $0.removeFromSuperview() }
        let v = tabs[idx]
        v.frame = tabContent.bounds
        tabContent.addSubview(v)
    }

    // MARK: 基础
    private func buildBasicTab(displayMode: Int, sourceType: Int, baseURL: String, apiKey: String, interval: Int) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 372))

        v.addSubview(label("API Key", NSRect(x: 20, y: 308, width: 64, height: 20)))
        keyField.stringValue = apiKey
        keyField.placeholderString = "sk-…"
        keyField.font = .systemFont(ofSize: 12)
        keyField.frame = NSRect(x: 88, y: 304, width: 210, height: 24)
        v.addSubview(keyField)
        showKey.target = self
        showKey.action = #selector(toggleKeyVisible)
        showKey.frame = NSRect(x: 306, y: 306, width: 58, height: 20)
        v.addSubview(showKey)

        v.addSubview(label("显示模式", NSRect(x: 20, y: 264, width: 90, height: 20)))
        modePopup.frame = NSRect(x: 114, y: 260, width: 190, height: 26)
        modePopup.removeAllItems()
        modePopup.addItem(withTitle: "极简 · 只显示总余额")
        modePopup.lastItem?.tag = 0
        modePopup.addItem(withTitle: "标准 · 含赠送/充值明细")
        modePopup.lastItem?.tag = 1
        modePopup.addItem(withTitle: "看板 · 余额+用量曲线")
        modePopup.lastItem?.tag = 2
        modePopup.selectItem(withTag: displayMode)
        if modePopup.selectedTag() == -1 { modePopup.selectItem(withTag: 0) }
        v.addSubview(modePopup)

        v.addSubview(label("数据源", NSRect(x: 20, y: 222, width: 90, height: 20)))
        sourcePopup.frame = NSRect(x: 114, y: 218, width: 190, height: 26)
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "DeepSeek 官方 API")
        sourcePopup.lastItem?.tag = 0
        sourcePopup.addItem(withTitle: "自定义网关（中转站）")
        sourcePopup.lastItem?.tag = 1
        sourcePopup.selectItem(withTag: sourceType)
        if sourcePopup.selectedTag() == -1 { sourcePopup.selectItem(withTag: 0) }
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        v.addSubview(sourcePopup)

        v.addSubview(label("网关地址", NSRect(x: 20, y: 180, width: 90, height: 20)))
        baseField.stringValue = baseURL
        baseField.placeholderString = "https://your-gateway.com（可选 /v1）"
        baseField.font = .systemFont(ofSize: 12)
        baseField.frame = NSRect(x: 114, y: 176, width: 250, height: 24)
        baseField.isEnabled = (sourcePopup.selectedTag() == 1)
        v.addSubview(baseField)

        v.addSubview(label("自动刷新间隔", NSRect(x: 20, y: 138, width: 100, height: 20)))
        intervalPopup.frame = NSRect(x: 124, y: 134, width: 120, height: 26)
        intervalPopup.removeAllItems()
        for iv in intervals {
            intervalPopup.addItem(withTitle: "\(iv) 秒")
            intervalPopup.lastItem?.tag = iv
        }
        intervalPopup.selectItem(withTag: interval)
        if intervalPopup.selectedTag() == -1 { intervalPopup.selectItem(withTag: 60) }
        v.addSubview(intervalPopup)
        return v
    }

    // MARK: 外观
    private func buildAppearanceTab(alwaysOnTop: Bool, opacity: Double, accent: Int, appearanceMode: Int) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 372))

        v.addSubview(label("主题色", NSRect(x: 20, y: 308, width: 90, height: 20)))
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
            b.frame = NSRect(x: x, y: 304, width: 20, height: 20)
            b.toolTip = t.name
            v.addSubview(b)
            accentButtons.append(b)
        }
        updateAccentSelection()

        v.addSubview(label("面板透明度", NSRect(x: 20, y: 266, width: 90, height: 20)))
        opacitySlider.doubleValue = max(0.5, min(1.0, opacity))
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.frame = NSRect(x: 112, y: 264, width: 150, height: 20)
        v.addSubview(opacitySlider)
        opacityValue.font = .systemFont(ofSize: 12)
        opacityValue.textColor = .secondaryLabelColor
        opacityValue.frame = NSRect(x: 268, y: 266, width: 52, height: 20)
        opacityValue.stringValue = "\(Int(round(opacity * 100)))%"
        v.addSubview(opacityValue)

        v.addSubview(label("外观", NSRect(x: 20, y: 224, width: 90, height: 20)))
        appearancePopup.frame = NSRect(x: 114, y: 220, width: 150, height: 26)
        appearancePopup.removeAllItems()
        appearancePopup.addItem(withTitle: "跟随系统")
        appearancePopup.lastItem?.tag = 0
        appearancePopup.addItem(withTitle: "深色")
        appearancePopup.lastItem?.tag = 1
        appearancePopup.addItem(withTitle: "浅色")
        appearancePopup.lastItem?.tag = 2
        appearancePopup.selectItem(withTag: appearanceMode)
        if appearancePopup.selectedTag() == -1 { appearancePopup.selectItem(withTag: 0) }
        v.addSubview(appearancePopup)

        v.addSubview(label("窗口置顶", NSRect(x: 20, y: 180, width: 90, height: 20)))
        topCheck.state = alwaysOnTop ? .on : .off
        topCheck.frame = NSRect(x: 112, y: 178, width: 160, height: 20)
        v.addSubview(topCheck)
        return v
    }

    // MARK: 看板
    private func buildDashboardTab(dashCards: [Int], dashRange: Int, showChart: Bool) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 372))
        v.addSubview(label("悬浮窗看板显示卡片", NSRect(x: 20, y: 308, width: 150, height: 20)))
        for (i, cb) in dashCardChecks.enumerated() {
            cb.state = dashCards.contains(i) ? .on : .off
            cb.frame = NSRect(x: 112 + CGFloat(i / 3) * 120, y: 278 - CGFloat(i % 3) * 34, width: 110, height: 22)
            v.addSubview(cb)
        }
        v.addSubview(label("默认时间范围", NSRect(x: 20, y: 168, width: 100, height: 20)))
        dashRangePopup.frame = NSRect(x: 124, y: 164, width: 120, height: 26)
        dashRangePopup.removeAllItems()
        dashRangePopup.addItem(withTitle: "近 7 天")
        dashRangePopup.lastItem?.tag = 7
        dashRangePopup.addItem(withTitle: "近 30 天")
        dashRangePopup.lastItem?.tag = 30
        dashRangePopup.addItem(withTitle: "全部")
        dashRangePopup.lastItem?.tag = 0
        dashRangePopup.selectItem(withTag: dashRange)
        if dashRangePopup.selectedTag() == -1 { dashRangePopup.selectItem(withTag: 7) }
        v.addSubview(dashRangePopup)

        chartCheck.state = showChart ? .on : .off
        chartCheck.frame = NSRect(x: 20, y: 126, width: 140, height: 22)
        v.addSubview(chartCheck)
        return v
    }

    // MARK: 提醒
    private func buildAlertTab(lowAlert: Bool, lowThreshold: Double) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 372))
        lowCheck.state = lowAlert ? .on : .off
        lowCheck.frame = NSRect(x: 20, y: 300, width: 260, height: 22)
        v.addSubview(lowCheck)

        v.addSubview(label("提醒阈值（元）", NSRect(x: 20, y: 260, width: 100, height: 20)))
        thresholdField.stringValue = String(format: "%.0f", lowThreshold)
        thresholdField.font = .systemFont(ofSize: 12)
        thresholdField.frame = NSRect(x: 124, y: 256, width: 80, height: 24)
        v.addSubview(thresholdField)

        let clearButton = NSButton(title: "清除历史数据…", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 20, y: 200, width: 140, height: 30)
        v.addSubview(clearButton)
        return v
    }

    // MARK: - 动作
    @objc private func toggleKeyVisible() {
        (keyField.cell as? NSSecureTextFieldCell)?.echosBullets = !(showKey.state == .on)
    }

    @objc private func sourceChanged() {
        baseField.isEnabled = (sourcePopup.selectedTag() == 1)
    }

    @objc private func opacityChanged() {
        opacityValue.stringValue = "\(Int(round(opacitySlider.doubleValue * 100)))%"
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

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清除历史数据？"
        alert.informativeText = "将删除本地记录的余额历史（看板曲线与累计统计会重新从当前余额开始记录）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            SharedStore.clearHistory()
        }
    }

    @objc private func save() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = KeychainStore.set(key, for: "apiKey")
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
        SharedStore.set("appearanceMode", appearancePopup.selectedTag() >= 0 ? appearancePopup.selectedTag() : 0)
        var cards: [Int] = []
        for (i, cb) in dashCardChecks.enumerated() where cb.state == .on { cards.append(i) }
        if cards.isEmpty { cards = [0] }
        SharedStore.set("dashCards", cards)
        SharedStore.set("dashRange", dashRangePopup.selectedTag() >= 0 ? dashRangePopup.selectedTag() : 7)
        SharedStore.set("showChart", chartCheck.state == .on)
        SharedStore.set("lowBalanceAlert", lowCheck.state == .on)
        let thr = Double(thresholdField.stringValue) ?? 10.0
        SharedStore.set("lowBalanceThreshold", max(0.5, thr))
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
    private var webView: WKWebView?
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
        let wv = WKWebView(frame: contentView!.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        contentView?.addSubview(wv)
        webView = wv
        center()
    }

    /// 关闭时彻底释放 WebView，让 WebContent 进程退出，内存回落
    func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        loaded = false
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
        webView?.loadFileURL(index, allowingReadAccessTo: d)
    }

    func refreshData() {
        let entries = SharedStore.historyJSON() ?? "[]"
        let balance = SharedStore.readBalance()
        let total = balance?["total"] as? String ?? ""
        let topped = balance?["topped"] as? String ?? "0"
        let sign = balance?["sign"] as? String ?? "¥"
        let accent = AccentTheme(rawValue: SharedStore.get("accent") as? Int ?? 0)?.hex ?? "#0A84FF"
        let js = "window.__DS_DATA__ = { sign: \(Self.jsStr(sign)), current: \(Self.jsStr(total)), topped: \(Self.jsStr(topped)), entries: \(entries), accent: \(Self.jsStr(accent)) }; console.log('injected', JSON.stringify(window.__DS_DATA__).slice(0, 300)); renderDashboard();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
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
            w.delegate = self
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

    // 看板窗口关闭时彻底释放（WebContent 进程随之退出，内存回落）
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? DashboardWindow else { return }
        w.teardown()
        if dashboard === w { dashboard = nil }
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

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

    /// 写余额缓存（供小组件读取）；rate 为显示货币换算系数（CNY=1.0，USD≈1/7.2）
    /// tag 非空时额外写一份 `balance-<tag>.json`，用于并列显示副账号
    static func writeBalance(_ b: AccountBalance, sign: String, rate: Double = 1.0, tag: String? = nil) {
        let payload: [String: Any] = [
            "total": b.total,
            "sign": sign,
            "rate": rate,
            "currency": b.currency,
            "granted": b.granted ?? "0",
            "topped": b.toppedUp ?? "0",
            "available": b.isAvailable,
            "provider": b.provider,
            "plan": b.plan ?? "",
            "planUntil": b.planValidUntil ?? "",
            "q5Total": b.quota5Total ?? 0,
            "q5Used": b.quota5Used ?? 0,
            "q5Pct": b.quota5Percent ?? 0,
            "q5Reset": b.quota5Reset ?? "",
            "qwTotal": b.quotaWeekTotal ?? 0,
            "qwUsed": b.quotaWeekUsed ?? 0,
            "qwPct": b.quotaWeekPercent ?? 0,
            "qwReset": b.quotaWeekReset ?? "",
            "updatedAt": Date().timeIntervalSince1970,
        ]
        // 只有当前账号才写主缓存（balance.json 被小组件/网页看板读取）；
        // 副账号只写自己的 balance-<tag>.json，避免覆盖主账号数据
        if let tag = tag, !tag.isEmpty {
            write(balanceFileName(tag), payload)
            if tag != currentAccountTag() { return }
        }
        write("balance.json", payload)
    }

    static func balanceFileName(_ tag: String) -> String {
        "balance-" + tag.replacingOccurrences(of: "#", with: "-") + ".json"
    }

    /// 读余额缓存（看板/小组件共用）
    static func readBalance() -> [String: Any]? { read("balance.json") }

    /// 读指定账号的余额缓存（并列显示用）
    static func readBalance(tag: String) -> [String: Any]? { read(balanceFileName(tag)) }

    /// 某账号的 tag（与 appendHistory 口径一致）
    static func tag(for index: Int, provider: String) -> String { "\(provider)#\(index)" }

    /// API Key 读取：优先当前账号，兜底共享配置/旧钥匙串
    static func apiKey() -> String? {
        if let a = currentAccount(), let k = a["key"] as? String, !k.isEmpty { return k }
        if let k = get("apiKey") as? String, !k.isEmpty { return k }
        return KeychainStore.get("apiKey")
    }

    // MARK: - 多账号管理
    /// 账号列表：[[name, key], ...]（config["accounts"]）
    static func accounts() -> [[String: Any]] {
        get("accounts") as? [[String: Any]] ?? []
    }
    static func accountIndex() -> Int {
        min(max(get("accountIndex") as? Int ?? 0, 0), max(accounts().count - 1, 0))
    }
    /// 当前账号 dict（无 accounts 时返回 nil）
    static func currentAccount() -> [String: Any]? {
        let list = accounts()
        guard !list.isEmpty else { return nil }
        return list[accountIndex()]
    }
    static func accountName() -> String {
        if let a = currentAccount(), let n = a["name"] as? String, !n.isEmpty { return n }
        return "Account \(accountIndex() + 1)"
    }

    // MARK: - 数据源 provider（按账号记录）：deepseek / zhipu / custom
    static let providerDeepSeek = "deepseek"
    static let providerZhipu = "zhipu"
    static let providerCustom = "custom"

    static func currentProvider() -> String {
        if let a = currentAccount(), let p = a["provider"] as? String, !p.isEmpty { return p }
        return (get("sourceType") as? Int ?? 0) == 1 ? providerCustom : providerDeepSeek
    }
    static func setCurrentProvider(_ p: String) {
        var list = accounts()
        if list.isEmpty {
            list.append(["name": "Account 1", "key": apiKey() ?? "", "provider": p])
        } else {
            let i = accountIndex()
            var a = list[i]
            a["provider"] = p
            list[i] = a
        }
        set("accounts", list)
    }
    static func providerLabel(_ p: String) -> String {
        switch p {
        case providerZhipu:  return L.t("智谱 AI")
        case providerCustom: return L.t("自定义网关")
        default:             return "DeepSeek"
        }
    }
    /// 账号在 UI 中的显示名（名称 · provider）
    static func accountTitle(_ a: [String: Any], index: Int) -> String {
        let name = a["name"] as? String ?? "Account \(index + 1)"
        let p = a["provider"] as? String ?? ((get("sourceType") as? Int ?? 0) == 1 ? providerCustom : providerDeepSeek)
        return "\(name) · \(providerLabel(p))"
    }
    /// 添加/更新当前账号 key：无 accounts 时创建；已有则更新当前项
    static func upsertCurrentAccount(key: String) {
        var list = accounts()
        if list.isEmpty {
            list.append(["name": "Account 1", "key": key])
        } else {
            let i = accountIndex()
            var a = list[i]
            a["key"] = key
            list[i] = a
        }
        set("accounts", list)
    }
    static func addAccount(key: String, provider: String = providerDeepSeek) {
        var list = accounts()
        list.append(["name": "Account \(list.count + 1)", "key": key, "provider": provider])
        set("accounts", list)
        set("accountIndex", list.count - 1)
    }
    /// 并列显示用：返回副账号（优先不同 provider 的账号，其次任意其它账号）
    static func secondaryAccountIndex() -> Int? {
        let list = accounts()
        guard list.count > 1 else { return nil }
        let main = accountIndex()
        let mainProvider = currentProvider()
        // 1) 先找 provider 不同的账号
        for (i, a) in list.enumerated() where i != main {
            let p = a["provider"] as? String ?? providerDeepSeek
            if p != mainProvider { return i }
        }
        // 2) 否则取相邻账号
        return main == 0 ? 1 : 0
    }

    static func account(at index: Int) -> [String: Any]? {
        let list = accounts()
        return index >= 0 && index < list.count ? list[index] : nil
    }

    static func provider(of index: Int) -> String {
        account(at: index)?["provider"] as? String ?? providerDeepSeek
    }

    static func key(of index: Int) -> String? {
        let k = account(at: index)?["key"] as? String ?? ""
        return k.isEmpty ? nil : k
    }

    /// 是否启用并列显示（config: sideBySide，默认开）
    static func sideBySideEnabled() -> Bool {
        if let v = get("sideBySide") as? Bool { return v }
        return true
    }

    static func removeCurrentAccount() {
        var list = accounts()
        guard !list.isEmpty else { return }
        let i = accountIndex()
        list.remove(at: i)
        if list.isEmpty {
            set("accounts", list)
            set("accountIndex", 0)
        } else {
            set("accounts", list)
            set("accountIndex", min(max(i, 0), list.count - 1))
        }
    }

    // MARK: - 余额历史（看板数据源）

    /// 追加一条余额记录到共享历史（同一次刷新 5 秒内去重，保留近 90 天）
    /// 存储策略：近 48 小时保留全部细粒度采样；更早的数据按自然日折叠为首尾两条，
    /// 从而"记录天数"能真实覆盖数天/数十天，且文件不会无限膨胀。
    /// 当前账号标识：provider + 账号序号，用于按账号隔离余额历史（避免切换账号后把余额骤降误算成消耗）
    static func currentAccountTag() -> String { "\(currentProvider())#\(accountIndex())" }

    static func appendHistory(total: String) {
        var entries = historyEntries()
        let ts = Date().timeIntervalSince1970
        if let last = entries.last, let lastTs = last["ts"] as? Double, ts - lastTs < 5,
           (last["acct"] as? String ?? "deepseek#0") == currentAccountTag() {
            entries.removeLast()
        }
        entries.append(["ts": ts, "total": total, "acct": currentAccountTag()])
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

    /// 当前账号的余额历史（旧记录没有 acct 字段，视为 DeepSeek 的第一个账号）
    static func scopedHistoryEntries() -> [[String: Any]] {
        let tag = currentAccountTag()
        return historyEntries().filter { ($0["acct"] as? String ?? "deepseek#0") == tag }
    }

    /// 返回当前账号历史 JSON 字符串（供看板注入）
    static func historyJSON() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: scopedHistoryEntries()) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 清除余额历史（保留当前余额）
    static func clearHistory() {
        let url = dirURL().appendingPathComponent("history.json")
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 本地化（zh / en）
enum L {
    static var lang: String { SharedStore.get("lang") as? String ?? "zh" }
    static var isEn: Bool { lang == "en" }

    private static let en: [String: String] = [
        "DeepSeek 用量": "DeepSeek Usage",
        "DeepSeek 用量面板 · 设置": "DeepSeek Usage · Settings",
        "DeepSeek 用量看板": "DeepSeek Dashboard",
        "基础": "General",
        "外观": "Appearance",
        "看板": "Dashboard",
        "提醒": "Alerts",
        "取消": "Cancel",
        "保存": "Save",
        "显示": "Show",
        "API Key": "API Key",
        "显示模式": "Display Mode",
        "极简 · 只显示总余额": "Minimal · Balance only",
        "标准 · 含赠送/充值明细": "Standard · Grant/Top-up detail",
        "看板 · 余额+用量曲线": "Dashboard · Balance + Usage",
        "数据源": "Data Source",
        "DeepSeek 官方 API": "DeepSeek Official API",
        "智谱 AI（GLM）": "Zhipu AI (GLM)",
        "智谱 AI": "Zhipu AI",
        "智谱 用量": "Zhipu Usage",
        "智谱 用量看板": "Zhipu Dashboard",
        "套餐": "Plan",
        "套餐到期": "Plan Expiry",
        "套餐有效": "Plan Active",
        "无套餐": "No plan",
        "5 小时额度": "5-hour quota",
        "本周额度": "Weekly quota",
        "本周用尽": "Weekly limit hit",
        "到期 %@": "expires %@",
        "自定义网关（中转站）": "Custom Gateway",
        "网关地址": "Gateway URL",
        "自动刷新间隔": "Refresh Interval",
        "秒": "s",
        "主题色": "Accent Color",
        "系统蓝": "Blue",
        "石墨灰": "Graphite",
        "绿色": "Green",
        "橙色": "Orange",
        "紫罗兰": "Violet",
        "粉色": "Pink",
        "青色": "Cyan",
        "红色": "Red",
        "面板透明度": "Panel Opacity",
        "跟随系统": "System",
        "深色": "Dark",
        "浅色": "Light",
        "语言": "Language",
        "中文": "中文",
        "English": "English",
        "窗口置顶": "Always on Top",
        "显示货币": "Currency",
        "自动跟随": "Auto",
        "人民币 CNY": "CNY ¥",
        "美元 USD": "USD $",
        "窗口始终置顶": "Always on Top",
        "置顶": "Pin",
        "取消置顶": "Unpin",
        "悬浮窗看板显示卡片": "Panel Cards",
        "默认时间范围": "Default Range",
        "近 7 天": "Last 7 Days",
        "近 30 天": "Last 30 Days",
        "全部": "All",
        "7天": "7D",
        "30天": "30D",
        "显示曲线图": "Show Chart",
        "看板窗口置顶": "Dashboard on Top",
        "余额低于阈值时发送系统通知": "Notify when balance below threshold",
        "提醒阈值（元）": "Threshold (¥)",
        "清除历史数据…": "Clear History…",
        "清除历史数据？": "Clear history data?",
        "将删除本地记录的余额历史（看板曲线与累计统计会重新从当前余额开始记录）。": "This removes locally recorded balance history. Dashboard chart and totals restart from the current balance.",
        "清除": "Clear",
        "好": "OK",
        "导出历史数据…": "Export History CSV…",
        "账号管理": "Accounts",
        "当前账号": "Account",
        "添加账号": "Add Account",
        "删除当前账号": "Remove Account",
        "当前余额": "Balance",
        "今日消耗": "Today",
        "累计消耗": "Total Usage",
        "累计充值": "Top-ups",
        "记录天数": "Days",
        "区间最高": "Peak",
        "预估可用": "Days Left",
        "天": "d",
        "等待获取…": "Waiting…",
        "加载中…": "Loading…",
        "获取中…": "Fetching…",
        "刷新": "Refresh",
        "设置": "Settings",
        "隐藏": "Hide",
        "隐藏面板": "Hide Panel",
        "显示面板": "Show Panel",
        "设置…": "Settings…",
        "用量看板…": "Dashboard…",
        "退出": "Quit",
        "开机自启": "Launch at Login",
        "总余额": "Balance",
        "赠送余额": "Granted",
        "充值余额": "Top-up",
        "未设置 Key": "No API Key",
        "点「设置」填入 API Key": "Click Settings to add your API Key",
        "如何获取 API Key？": "How to get an API Key?",
        "获取 API Key 指引": "Get API Key guide",
        "打开 DeepSeek 开放平台 API Key 页面": "Open DeepSeek Platform API Keys page",
        "注册/登录 → 充值 → 创建 API Key → 粘贴到上方输入框": "Sign up/Log in → Top up → Create an API Key → paste it into the field above",
        "未配置网关": "No Gateway",
        "点「设置」填写网关地址": "Click Settings to set gateway URL",
        "可用": "OK",
        "余额不足": "Low Balance",
        "暂无数据，等待记录…": "No data yet…",
        "无效 URL": "Invalid URL",
        "Key 无效或已过期": "Invalid or expired Key",
        "解析失败：": "Parse error: ",
        "接口无余额数据": "No balance data",
        "非 JSON 对象": "Not a JSON object",
        "无响应数据": "No response data",
        "请求失败 HTTP ": "HTTP ",
        "DeepSeek 余额不足": "DeepSeek balance low",
        "无法开启开机自启": "Cannot enable launch at login",
        "无法关闭开机自启": "Cannot disable launch at login",
        "请把应用移到「应用程序」文件夹后重试，或到 系统设置 → 通用 → 登录项 手动调整。": "Move the app to the Applications folder and retry, or enable it manually in System Settings → General → Login Items.",
    ]

    static func t(_ key: String) -> String {
        guard isEn else { return key }
        return en[key] ?? key
    }

    /// 带插值的本地化：key 为模板，args 按序替换 %@
    static func fmt(_ key: String, _ args: String...) -> String {
        var s = t(key)
        for a in args { s = s.replacingOccurrences(of: "%@", with: a) }
        return s
    }
}

// MARK: - 通用余额模型（兼容 DeepSeek balance_infos、OpenAI 网关 data[] 与智谱财务总览三种返回）
struct AccountBalance {
    var currency: String = "CNY"
    var total: String = "0"
    var granted: String?
    var toppedUp: String?
    var isAvailable: Bool = true
    /// 智谱：当前有效套餐名（如 GLM Coding Lite）
    var plan: String?
    /// 智谱：套餐到期日（YYYY-MM-DD）
    var planValidUntil: String?
    /// 智谱：Coding Plan 额度（5 小时窗口）
    var quota5Total: Int?
    var quota5Used: Int?
    var quota5Percent: Int?
    var quota5Reset: String?
    /// 智谱：Coding Plan 额度（每周窗口）
    var quotaWeekTotal: Int?
    var quotaWeekUsed: Int?
    var quotaWeekPercent: Int?
    var quotaWeekReset: String?
    /// 数据源标识：deepseek / zhipu / custom
    var provider: String = "deepseek"
}

enum BalanceAPIError: LocalizedError {
    case invalidURL, unauthorized, http(Int), network(String), decode(String), empty
    var errorDescription: String? {
        switch self {
        case .invalidURL:   return L.t("无效 URL")
        case .unauthorized: return L.t("Key 无效或已过期")
        case .http(let c):  return L.t("请求失败 HTTP ") + "\(c)"
        case .network(let m): return m
        case .decode(let m): return L.t("解析失败：") + m
        case .empty:        return L.t("接口无余额数据")
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

    // MARK: - 智谱 AI（bigmodel.cn）
    // 余额：GET https://open.bigmodel.cn/api/biz/account/finance-overview
    //   → data.availableTotalBalance（现金+赠金可用余额，CNY）
    // 套餐：GET https://open.bigmodel.cn/api/biz/subscription/list
    //   → 取 status=VALID 的订阅（productName / valid 结束日期）
    // 注意：智谱业务码 200 表示成功（非 0）；套餐积分（5 小时/每周）无公开接口，不在本面板展示。

    private func getJSON(_ urlString: String, key: String,
                         completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(BalanceAPIError.invalidURL)); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(BalanceAPIError.network(err.localizedDescription))); return
            }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 {
                    if let d = data,
                       let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                       let msg = obj["msg"] as? String, !msg.isEmpty {
                        completion(.failure(BalanceAPIError.network(msg))); return
                    }
                    completion(.failure(BalanceAPIError.unauthorized)); return
                }
                completion(.failure(BalanceAPIError.http(http.statusCode))); return
            }
            guard let d = data else {
                completion(.failure(BalanceAPIError.network("无响应数据"))); return
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                completion(.failure(BalanceAPIError.decode("非 JSON 对象"))); return
            }
            let code = (obj["code"] as? Int) ?? 0
            if code == 200 || code == 0 {
                completion(.success(obj))
            } else {
                let msg = obj["msg"] as? String ?? "code \(code)"
                completion(.failure(BalanceAPIError.network(msg)))
            }
        }.resume()
    }

    /// 智谱：账户余额 + 当前套餐（两个请求串行，先套餐后余额，保证结果一次回调）
    func fetchZhipu(key: String, completion: @escaping (Result<AccountBalance, Error>) -> Void) {
        fetchZhipuPlan(key: key) { [self] plan, until in
            getJSON("https://open.bigmodel.cn/api/biz/account/finance-overview", key: key) { result in
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let obj):
                    var b = AccountBalance()
                    b.provider = SharedStore.providerZhipu
                    b.currency = "CNY"
                    if let data = obj["data"] as? [String: Any] {
                        let total = (data["availableTotalBalance"] as? NSNumber)?.doubleValue ?? 0
                        b.total = String(format: "%.2f", total)
                    } else {
                        b.total = "0.00"
                    }
                    b.plan = plan
                    b.planValidUntil = until
                    // 有余额或有有效套餐即视为可用
                    b.isAvailable = (Double(b.total) ?? 0) > 0.001 || plan != nil
                    fetchZhipuQuota(key: key) { quota in
                        if let quota = quota {
                            b.quota5Total = quota.0
                            b.quota5Used = quota.1
                            b.quota5Percent = quota.2
                            b.quota5Reset = quota.3
                            b.quotaWeekTotal = quota.4
                            b.quotaWeekUsed = quota.5
                            b.quotaWeekPercent = quota.6
                            b.quotaWeekReset = quota.7
                        }
                        completion(.success(b))
                    }
                }
            }
        }
    }

    /// 智谱 Coding Plan 额度：/api/monitor/usage/quota/limit
    /// 返回 (5h总量, 5h已用, 5h百分比, 5h重置, 周总量, 周已用, 周百分比, 周重置)
    private func fetchZhipuQuota(key: String,
                                 completion: @escaping ((Int, Int, Int, String, Int, Int, Int, String)?) -> Void) {
        getJSON("https://open.bigmodel.cn/api/monitor/usage/quota/limit", key: key) { result in
            guard case .success(let obj) = result,
                  let data = obj["data"] as? [String: Any],
                  let limits = data["limits"] as? [[String: Any]] else {
                completion(nil); return
            }
            // 5 小时窗口与每周窗口都是 CREDIT_LIMIT，按总量区分：小的为 5 小时
            var parsed: [(total: Int, used: Int, pct: Int, reset: String)] = []
            for item in limits {
                let total = (item["usage"] as? NSNumber)?.intValue ?? 0
                let used = (item["currentValue"] as? NSNumber)?.intValue ?? 0
                let pct = (item["percentage"] as? NSNumber)?.intValue ?? 0
                var reset = ""
                if let ms = (item["nextResetTime"] as? NSNumber)?.doubleValue, ms > 0 {
                    let d = Date(timeIntervalSince1970: ms / 1000)
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "zh_CN")
                    f.dateFormat = "MM-dd HH:mm"
                    reset = f.string(from: d)
                }
                if total > 0 { parsed.append((total, used, pct, reset)) }
            }
            guard parsed.count >= 2 else { completion(nil); return }
            parsed.sort { $0.total < $1.total }
            let five = parsed[0], week = parsed[1]
            completion((five.total, five.used, five.pct, five.reset,
                        week.total, week.used, week.pct, week.reset))
        }
    }

    /// 智谱套餐：订阅列表中取 VALID 的个人套餐
    private func fetchZhipuPlan(key: String, completion: @escaping (String?, String?) -> Void) {
        getJSON("https://open.bigmodel.cn/api/biz/subscription/list", key: key) { result in
            guard case .success(let obj) = result,
                  let list = obj["data"] as? [[String: Any]] else {
                completion(nil, nil); return
            }
            let valid = list.first { ($0["status"] as? String) == "VALID" }
            let name = valid?["productName"] as? String
            var until: String?
            if let v = valid?["valid"] as? String {
                // "2026-12-07 10:00:00-2027-03-07 10:00:00" → 取最后一个日期
                let re = try? NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}")
                let ms = re?.matches(in: v, range: NSRange(v.startIndex..., in: v)) ?? []
                if let m = ms.last, let r = Range(m.range, in: v) {
                    until = String(v[r])
                }
            }
            completion(name, until)
        }
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

    /// 是否显示副账号（并列）：需要有第二个账号且未关闭
    private var sideBySide: Bool {
        SharedStore.sideBySideEnabled() && SharedStore.secondaryAccountIndex() != nil
    }
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
    private var totalLabel: DragLabel!
    private var titleLabel: DragLabel!
    private var grantedLabel: DragLabel!
    private var toppedLabel: DragLabel!
    private var totalValue: DragLabel!
    private var grantedValue: DragLabel!
    private var toppedValue: DragLabel!
    private var footerLabel: DragLabel!
    private var refreshButton: NSButton!
    private var settingsButton: NSButton!
    private var quitButton: NSButton!
    private var pinButton: NSButton!
    // 并列显示：副账号区块
    private var subTitleLabel: DragLabel!
    private var subStatusDot: DragView!
    private var subTotalLabel: DragLabel!
    private var subTotalValue: DragLabel!
    private var subGrantedLabel: DragLabel!
    private var subGrantedValue: DragLabel!
    private var subToppedLabel: DragLabel!
    private var subToppedValue: DragLabel!
    private var subMiniLabel: DragLabel!       // 极简模式下副账号的一行摘要

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        let mode = SharedStore.get("displayMode") as? Int ?? 0
        let hasChart = SharedStore.get("showChart") as? Bool ?? true
        let h: CGFloat
        switch mode {
        case 0: h = 88
        case 1: h = SharedStore.secondaryAccountIndex() != nil && SharedStore.sideBySideEnabled() ? 334 : 228
        default:
            let cardCount = (SharedStore.get("dashCards") as? [Int] ?? [0, 1, 2, 3, 4, 5]).count
            let side = SharedStore.secondaryAccountIndex() != nil && SharedStore.sideBySideEnabled()
            let singleRow = cardCount <= 3 && !side
            let chart = hasChart && SharedStore.currentProvider() != SharedStore.providerZhipu
            h = chart ? (singleRow ? 208 : 250) : (singleRow ? 118 : 176)
        }
        let w: CGFloat = mode == 2 ? 320 : (mode == 0 ? 300 : 320)
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
    /// 副账号在看板里的三张卡（标签唯一，供布局与更新共用）
    private func secondaryCardSpecs() -> [(Int, String)] {
        guard sideBySide, let idx = SharedStore.secondaryAccountIndex() else { return [] }
        if SharedStore.provider(of: idx) == SharedStore.providerZhipu {
            return [(6, "智谱 5h"), (7, "智谱 本周"), (8, "智谱 套餐")]
        }
        return [(6, "DeepSeek 余额"), (7, "DeepSeek 赠送"), (8, "DeepSeek 充值")]
    }

    private func dashboardRows() -> Int {
        let base = dashCards.count <= 3 ? 1 : 2
        if sideBySide && !secondaryCardSpecs().isEmpty { return 2 }
        return base
    }
    private func dashboardHeight() -> CGFloat {
        let twoRows = dashboardRows() == 2
        let chart = showChart && SharedStore.currentProvider() != SharedStore.providerZhipu
        if chart { return twoRows ? 250 : 208 }
        return twoRows ? 176 : 118
    }

    /// 置顶小开关（面板右上角）
    @objc private func togglePin() {
        setAlwaysOnTop(!alwaysOnTop)
    }
    private func updatePinIcon() {
        guard pinButton != nil else { return }
        if #available(macOS 11.0, *) {
            pinButton.image = NSImage(systemSymbolName: alwaysOnTop ? "pin.fill" : "pin",
                                      accessibilityDescription: L.t("置顶"))
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
        let w: CGFloat = isDashboard ? 320 : (isMini ? 300 : 320)
        let h: CGFloat = isDashboard ? dashboardHeight() : (isMini ? 88 : (sideBySide ? 334 : 228))
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

        // 标题 + 时间范围（分段控件）+ 置顶开关——坐标随卡片行数/曲线开关自适应（紧凑版）
        // 智谱只有额度、没有余额历史，因此不占曲线空间
        let hasChart = showChart && SharedStore.currentProvider() != SharedStore.providerZhipu
        let twoRows = dashboardRows() == 2
        let titleY: CGFloat = hasChart ? (twoRows ? 220 : 180) : (twoRows ? 158 : 92)
        let segY: CGFloat = hasChart ? (twoRows ? 216 : 176) : (twoRows ? 152 : 88)
        let row1LabelY: CGFloat = hasChart ? (twoRows ? 184 : 150) : (twoRows ? 102 : 48)
        let row1ValY: CGFloat = hasChart ? (twoRows ? 166 : 132) : (twoRows ? 84 : 26)
        let row2LabelY: CGFloat = hasChart ? 136 : 54
        let row2ValY: CGFloat = hasChart ? 118 : 36

        titleLabel = DragLabel(labelWithString: panelTitleText())
        titleLabel.font = .systemFont(ofSize: 10)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 12, y: titleY, width: 140, height: 12)
        content.addSubview(titleLabel)

        let seg = NSSegmentedControl(labels: [L.t("7天"), L.t("30天"), L.t("全部")], trackingMode: .selectOne,
                                     target: self, action: #selector(dashRangeChanged))
        seg.selectedSegment = dashRange == 30 ? 1 : (dashRange == 0 ? 2 : 0)
        seg.segmentStyle = .rounded
        if #available(macOS 11.0, *) { seg.selectedSegmentBezelColor = accentColor }
        seg.frame = NSRect(x: 184, y: segY, width: 100, height: 20)
        content.addSubview(seg)
        rangeControl = seg

        // 置顶小开关（右上角）
        pinButton = makePinButton()
        pinButton.frame = NSRect(x: 292, y: segY + 1, width: 18, height: 18)
        content.addSubview(pinButton)
        updatePinIcon()

        // 卡片（按用户勾选显示；最多 6 张，3 列）
        let allSpecs: [(Int, String)] = [
            (0, "当前余额"), (1, "今日消耗"), (2, "累计消耗"),
            (3, "累计充值"), (4, "记录天数"), (5, "区间最高")
        ]
        let isZhipu = SharedStore.currentProvider() == SharedStore.providerZhipu
        var specs: [(Int, String)]
        if isZhipu {
            // 智谱没有"今日/累计消耗/充值/预估可用"的口径，用套餐信息占位，卡片数量不变
            specs = allSpecs.filter { dashCards.contains($0.0) }.map { spec -> (Int, String) in
                switch spec.0 {
                case 0: return (0, "5 小时额度")
                case 1: return (1, "本周额度")
                case 2: return (2, "套餐")
                default: return spec
                }
            }.filter { $0.0 == 0 || $0.0 == 1 || $0.0 == 2 }
            if specs.isEmpty { specs = [(0, "5 小时额度")] }
        } else {
            specs = allSpecs.filter { dashCards.contains($0.0) }
        }
        // 并列：主账号三卡在上面一行，副账号三卡在下面一行
        let subSpecs = secondaryCardSpecs()
        let mainCount = specs.count
        if !subSpecs.isEmpty { specs += subSpecs }
        let cols = min(3, max(1, mainCount))
        let cardW: CGFloat = (content.bounds.width - 24 - CGFloat(cols - 1) * 8) / CGFloat(cols)
        // 智谱单行三卡（余额 / 套餐 / 到期）按内容宽度分配：套餐名最长，给更多空间
        var customXs: [CGFloat] = [], customWs: [CGFloat] = []
        if isZhipu && mainCount == 3 {
            let total = content.bounds.width - 24 - 2 * 8
            let w0 = total * 0.22, w1 = total * 0.24
            let w2 = total - w0 - w1
            customXs = [12, 12 + w0 + 8, 12 + w0 + 8 + w1 + 8]
            customWs = [w0, w1, w2]
        }
        for (i, spec) in specs.enumerated() {
            let col = i % cols, row = i / cols
            // 主卡行按内容宽度分配；副卡行（并列第二行）用等宽三列
            let useCustom = !customXs.isEmpty && row == 0
            let x = useCustom ? customXs[col] : 12 + CGFloat(col) * (cardW + 8)
            let w = useCustom ? customWs[col] : cardW
            let labelY: CGFloat = row == 0 ? row1LabelY : row2LabelY
            let valY: CGFloat = row == 0 ? row1ValY : row2ValY
            let label = DragLabel(labelWithString: L.t(spec.1))
            label.font = .systemFont(ofSize: 9)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: x, y: labelY, width: w, height: 12)
            content.addSubview(label)
            let val = DragLabel(labelWithString: "—")
            let isText = spec.1 == "套餐" || spec.1.hasSuffix("套餐")   // 套餐名是文字，字号略小以免被截断
            val.font = isText ? .systemFont(ofSize: 11.5, weight: .semibold)
                              : .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            val.textColor = spec.1 == "当前余额" ? accentColor : .labelColor
            val.lineBreakMode = .byTruncatingTail
            val.frame = NSRect(x: x, y: valY, width: w, height: 17)
            content.addSubview(val)
            dashboardValues[spec.1] = val
        }

        // 迷你余额曲线（可隐藏）
        if hasChart {
            let chartH: CGFloat = twoRows ? 100 : 112
            let chart = MiniChartView(frame: NSRect(x: 12, y: 8, width: content.bounds.width - 24, height: chartH))
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
        let entries = SharedStore.scopedHistoryEntries()
        let balance = SharedStore.readBalance()
        let total = balance?["total"] as? String ?? "—"
        let sign = balance?["sign"] as? String ?? "¥"
        let rate = balance?["rate"] as? Double ?? 1.0
        dashboardValues["当前余额"]?.stringValue = fmtMoney(Double(total) ?? 0, sign: sign, rate: rate)

        // 今日消耗 / 累计消耗 / 累计充值（余额差推导，原始 CNY 差值按显示货币换算）
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
        dashboardValues["今日消耗"]?.stringValue = todayUsage > 0.001 ? fmtMoney(todayUsage, sign: sign, rate: rate) : fmtMoney(0, sign: sign, rate: rate)
        dashboardValues["累计消耗"]?.stringValue = cumUsage > 0.001 ? fmtMoney(cumUsage, sign: sign, rate: rate) : fmtMoney(0, sign: sign, rate: rate)
        // 累计充值：优先取官方充值余额（topped_up_balance，用户实际充值的钱），
        // 记录期内检测到的充值事件作为补充（API 快照已含记录期充值，故取较大值）
        let topped = Double(balance?["topped"] as? String ?? "0") ?? 0
        let cumTopup = max(topup, topped)
        dashboardValues["累计充值"]?.stringValue = cumTopup > 0.001 ? fmtMoney(cumTopup, sign: sign, rate: rate) : fmtMoney(0, sign: sign, rate: rate)

        // 记录天数：实际有记录的自然日数（与看板一致）
        let daySet = Set(entries.compactMap { e -> Int? in
            guard let t = e["ts"] as? Double, t > 0 else { return nil }
            return Int(floor(t / 86400))
        })
        let days = daySet.count
        dashboardValues["记录天数"]?.stringValue = days > 0 ? "\(days) " + L.t("天") : "—"
        let maxV = entries.reduce(0.0) { max($0, Double($1["total"] as? String ?? "0") ?? 0) }
        dashboardValues["区间最高"]?.stringValue = maxV > 0 ? fmtMoney(maxV, sign: sign, rate: rate) : "—"

        // 智谱专属卡片：5 小时额度 / 本周额度 / 套餐
        if SharedStore.currentProvider() == SharedStore.providerZhipu {
            let plan = balance?["plan"] as? String ?? ""
            let q5 = (balance?["q5Pct"] as? NSNumber)?.intValue
            let qw = (balance?["qwPct"] as? NSNumber)?.intValue
            let rem5 = q5.map { max(0, 100 - $0) }
            let remW = qw.map { max(0, 100 - $0) }
            dashboardValues["5 小时额度"]?.stringValue = rem5.map { String($0) + "%" } ?? "—"
            dashboardValues["本周额度"]?.stringValue = remW.map { String($0) + "%" } ?? "—"
            dashboardValues["套餐"]?.stringValue = plan.isEmpty ? L.t("无套餐") : plan
            if let r = rem5 { dashboardValues["5 小时额度"]?.textColor = r == 0 ? .systemRed : (r < 10 ? .systemOrange : accentColor) }
            if let r = remW { dashboardValues["本周额度"]?.textColor = r == 0 ? .systemRed : (r < 10 ? .systemOrange : .labelColor) }
        }

        // 副账号卡片（并列第二行）：数据来自 balance-<tag>.json
        if let idx = SharedStore.secondaryAccountIndex(), sideBySide {
            let provider = SharedStore.provider(of: idx)
            let sb = SharedStore.readBalance(tag: SharedStore.tag(for: idx, provider: provider))
            let ssign = sb?["sign"] as? String ?? "¥"
            let srate = sb?["rate"] as? Double ?? 1.0
            if provider == SharedStore.providerZhipu {
                let q5 = (sb?["q5Pct"] as? NSNumber)?.intValue
                let qw = (sb?["qwPct"] as? NSNumber)?.intValue
                let rem5 = q5.map { max(0, 100 - $0) }
                let remW = qw.map { max(0, 100 - $0) }
                dashboardValues["智谱 5h"]?.stringValue = rem5.map { String($0) + "%" } ?? "—"
                dashboardValues["智谱 本周"]?.stringValue = remW.map { String($0) + "%" } ?? "—"
                let plan = sb?["plan"] as? String ?? ""
                dashboardValues["智谱 套餐"]?.stringValue = plan.isEmpty ? L.t("无套餐") : plan
                if let r = rem5 { dashboardValues["智谱 5h"]?.textColor = r == 0 ? .systemRed : (r < 10 ? .systemOrange : .labelColor) }
                if let r = remW { dashboardValues["智谱 本周"]?.textColor = r == 0 ? .systemRed : (r < 10 ? .systemOrange : .labelColor) }
            } else {
                let st = Double(sb?["total"] as? String ?? "0") ?? 0
                dashboardValues["DeepSeek 余额"]?.stringValue = sb == nil ? "—" : fmtMoney(st, sign: ssign, rate: srate)
                let sg = Double(sb?["granted"] as? String ?? "0") ?? 0
                let sp2 = Double(sb?["topped"] as? String ?? "0") ?? 0
                dashboardValues["DeepSeek 赠送"]?.stringValue = sb == nil ? "—" : fmtMoney(sg, sign: ssign, rate: srate)
                dashboardValues["DeepSeek 充值"]?.stringValue = sb == nil ? "—" : fmtMoney(sp2, sign: ssign, rate: srate)
                if sb != nil {
                    dashboardValues["DeepSeek 余额"]?.textColor = st < 5 ? .systemRed : (st < 20 ? .systemOrange : .labelColor)
                }
            }
        }

        // 智谱没有余额历史曲线：直接不画
        if SharedStore.currentProvider() == SharedStore.providerZhipu {
            chartView?.setPoints([])
            return
        }

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
        titleLabel = DragLabel(labelWithString: panelTitleText())
        titleLabel.font = .systemFont(ofSize: 10)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 12, y: 68, width: 120, height: 12)

        statusDot = DragView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.frame = NSRect(x: 240, y: 70, width: 8, height: 8)

        statusLabel = DragLabel(labelWithString: L.t("加载中…"))
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 254, y: 67, width: 70, height: 12)

        // 并列：标题右侧给副账号一行摘要（极简窗口放不下完整第二块）
        if sideBySide {
            subMiniLabel = DragLabel(labelWithString: "")
            subMiniLabel.font = .systemFont(ofSize: 9)
            subMiniLabel.textColor = .tertiaryLabelColor
            subMiniLabel.alignment = .right
            subMiniLabel.frame = NSRect(x: 132, y: 67, width: 104, height: 13)
            content.addSubview(subMiniLabel)
        }

        // 总余额大字
        totalValue = DragLabel(labelWithString: "—")
        totalValue.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        totalValue.textColor = accentColor
        totalValue.frame = NSRect(x: 12, y: 30, width: 276, height: 28)

        // 底部：倒计时 + 按钮
        footerLabel = DragLabel(labelWithString: L.t("等待获取…"))
        footerLabel.font = .systemFont(ofSize: 9)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: 12, y: 12, width: 160, height: 12)

        refreshButton = makeButton(L.t("刷新"), action: #selector(refresh))
        refreshButton.frame = NSRect(x: 170, y: 3, width: 40, height: 22)
        settingsButton = makeButton(L.t("设置"), action: #selector(openSettings))
        settingsButton.frame = NSRect(x: 212, y: 3, width: 40, height: 22)
        quitButton = makeButton(L.t("隐藏"), action: #selector(hidePanel))
        quitButton.frame = NSRect(x: 254, y: 3, width: 40, height: 22)

        for v in [titleLabel!, statusDot!, statusLabel!, totalValue!, footerLabel!,
                  refreshButton!, settingsButton!, quitButton!] as [NSView] {
            content.addSubview(v)
        }
    }

    private func buildFullLayout(_ content: NSView) {
        // 并列显示时整体上移 106pt，为副账号区块腾出空间
        let dy: CGFloat = sideBySide ? 106 : 0

        titleLabel = DragLabel(labelWithString: panelTitleText())
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 16, y: 196 + dy, width: 160, height: 18)

        statusDot = DragView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.frame = NSRect(x: 186, y: 200 + dy, width: 8, height: 8)

        statusLabel = DragLabel(labelWithString: L.t("加载中…"))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.frame = NSRect(x: 198, y: 197 + dy, width: 46, height: 14)

        // 置顶小开关（右上角）
        pinButton = makePinButton()
        pinButton.frame = NSRect(x: 250, y: 196 + dy, width: 18, height: 18)
        content.addSubview(pinButton)
        updatePinIcon()

        let divider = DragView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        divider.frame = NSRect(x: 16, y: 184 + dy, width: 288, height: 1)

        totalLabel = DragLabel(labelWithString: L.t("总余额"))
        totalLabel.font = .systemFont(ofSize: 11)
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.frame = NSRect(x: 16, y: 156 + dy, width: 80, height: 18)

        totalValue = DragLabel(labelWithString: "—")
        totalValue.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        totalValue.textColor = accentColor
        totalValue.alignment = .right
        totalValue.frame = NSRect(x: 176, y: 152 + dy, width: 124, height: 22)

        let grantedLabel = DragLabel(labelWithString: L.t("赠送余额"))
        grantedLabel.font = .systemFont(ofSize: 11)
        grantedLabel.textColor = .secondaryLabelColor
        grantedLabel.frame = NSRect(x: 16, y: 128 + dy, width: 80, height: 18)
        self.grantedLabel = grantedLabel

        grantedValue = DragLabel(labelWithString: "—")
        grantedValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        grantedValue.textColor = .secondaryLabelColor
        grantedValue.alignment = .right
        grantedValue.frame = NSRect(x: 176, y: 124 + dy, width: 124, height: 20)

        let toppedLabel = DragLabel(labelWithString: L.t("充值余额"))
        toppedLabel.font = .systemFont(ofSize: 11)
        toppedLabel.textColor = .secondaryLabelColor
        toppedLabel.frame = NSRect(x: 16, y: 100 + dy, width: 80, height: 18)
        self.toppedLabel = toppedLabel

        toppedValue = DragLabel(labelWithString: "—")
        toppedValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        toppedValue.textColor = .secondaryLabelColor
        toppedValue.alignment = .right
        toppedValue.frame = NSRect(x: 176, y: 96 + dy, width: 124, height: 20)

        footerLabel = DragLabel(labelWithString: L.t("等待获取…"))
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: 16, y: 64, width: 288, height: 14)

        refreshButton = makeButton(L.t("刷新"), action: #selector(refresh))
        refreshButton.frame = NSRect(x: 146, y: 24, width: 52, height: 24)
        settingsButton = makeButton(L.t("设置"), action: #selector(openSettings))
        settingsButton.frame = NSRect(x: 202, y: 24, width: 52, height: 24)
        quitButton = makeButton(L.t("隐藏"), action: #selector(hidePanel))
        quitButton.frame = NSRect(x: 254, y: 24, width: 52, height: 24)

        var views: [NSView] = [titleLabel!, statusDot!, statusLabel!, divider,
                               totalLabel, totalValue!, grantedLabel, grantedValue!,
                               toppedLabel, toppedValue!, footerLabel!,
                               refreshButton!, settingsButton!, quitButton!]

        // 副账号区块（并列）：小标题 + 状态点 + 三行
        if sideBySide {
            let divider2 = DragView()
            divider2.wantsLayer = true
            divider2.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            divider2.frame = NSRect(x: 16, y: 192, width: 288, height: 1)

            subTitleLabel = DragLabel(labelWithString: secondaryTitleText())
            subTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            subTitleLabel.textColor = .secondaryLabelColor
            subTitleLabel.frame = NSRect(x: 16, y: 174, width: 200, height: 15)

            subStatusDot = DragView()
            subStatusDot.wantsLayer = true
            subStatusDot.layer?.cornerRadius = 3
            subStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            subStatusDot.frame = NSRect(x: 296, y: 179, width: 6, height: 6)

            subTotalLabel = DragLabel(labelWithString: "—")
            subTotalLabel.font = .systemFont(ofSize: 11)
            subTotalLabel.textColor = .secondaryLabelColor
            subTotalLabel.frame = NSRect(x: 16, y: 152, width: 80, height: 18)

            subTotalValue = DragLabel(labelWithString: "—")
            subTotalValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            subTotalValue.textColor = .labelColor
            subTotalValue.alignment = .right
            subTotalValue.frame = NSRect(x: 176, y: 149, width: 124, height: 20)

            subGrantedLabel = DragLabel(labelWithString: "—")
            subGrantedLabel.font = .systemFont(ofSize: 11)
            subGrantedLabel.textColor = .secondaryLabelColor
            subGrantedLabel.frame = NSRect(x: 16, y: 128, width: 80, height: 18)

            subGrantedValue = DragLabel(labelWithString: "—")
            subGrantedValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            subGrantedValue.textColor = .secondaryLabelColor
            subGrantedValue.alignment = .right
            subGrantedValue.frame = NSRect(x: 176, y: 125, width: 124, height: 18)

            subToppedLabel = DragLabel(labelWithString: "—")
            subToppedLabel.font = .systemFont(ofSize: 11)
            subToppedLabel.textColor = .secondaryLabelColor
            subToppedLabel.frame = NSRect(x: 16, y: 104, width: 80, height: 18)

            subToppedValue = DragLabel(labelWithString: "—")
            subToppedValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            subToppedValue.textColor = .secondaryLabelColor
            subToppedValue.alignment = .right
            subToppedValue.frame = NSRect(x: 176, y: 101, width: 124, height: 18)

            views += [divider2, subTitleLabel!, subStatusDot!,
                      subTotalLabel!, subTotalValue!, subGrantedLabel!, subGrantedValue!,
                      subToppedLabel!, subToppedValue!]
        }

        for v in views { content.addSubview(v) }
    }

    /// 副账号小标题：名称 · 数据源
    private func secondaryTitleText() -> String {
        guard let idx = SharedStore.secondaryAccountIndex() else { return "" }
        let name = (SharedStore.account(at: idx)?["name"] as? String) ?? "Account \(idx + 1)"
        return "\(name) · \(SharedStore.providerLabel(SharedStore.provider(of: idx)))"
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

    /// 浮窗标题按数据源切换
    private func panelTitleText() -> String {
        SharedStore.currentProvider() == SharedStore.providerZhipu ? L.t("智谱 用量") : L.t("DeepSeek 用量")
    }

    /// 按 provider 拉取余额：智谱走财务总览+套餐；DeepSeek/网关走 /user/balance
    private func fetchBalance(provider: String, key: String,
                              completion: @escaping (Result<AccountBalance, Error>) -> Void) {
        if provider == SharedStore.providerZhipu {
            api.fetchZhipu(key: key, completion: completion)
            return
        }
        guard let base = resolvedBaseURL() else {
            completion(.failure(BalanceAPIError.invalidURL)); return
        }
        api.fetchBalance(baseURL: base, key: key, completion: completion)
    }

    @objc func refresh() {
        refreshSecondary()
        let isZhipu = SharedStore.currentProvider() == SharedStore.providerZhipu
        // 看板模式：不触碰原生控件，仅拉数据 + 更新卡片/曲线
        if isDashboard {
            guard let key = SharedStore.apiKey(), !key.isEmpty else { return }
            fetchBalance(provider: SharedStore.currentProvider(), key: key) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if case .success(let b) = result {
                        let spec = self.moneySpec(for: b)
                        SharedStore.writeBalance(b, sign: spec.sign, rate: spec.rate)
                        SharedStore.appendHistory(total: b.total)
                    }
                    self.updateDashboardUI()
                }
            }
            return
        }
        guard let key = SharedStore.apiKey(), !key.isEmpty else {
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = L.t("未设置 Key")
            footerLabel.stringValue = L.t("点「设置」填入 API Key")
            return
        }
        if !isZhipu && resolvedBaseURL() == nil {
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = L.t("未配置网关")
            footerLabel.stringValue = L.t("点「设置」填写网关地址")
            return
        }
        statusLabel.stringValue = L.t("获取中…")
        fetchBalance(provider: SharedStore.currentProvider(), key: key) { [weak self] result in
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

    /// 并列显示：拉取副账号余额（失败只影响副块，不影响主账号）
    private func refreshSecondary() {
        guard sideBySide,
              let idx = SharedStore.secondaryAccountIndex(),
              let key = SharedStore.key(of: idx) else { return }
        let provider = SharedStore.provider(of: idx)
        fetchBalance(provider: provider, key: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let b):
                    let tag = SharedStore.tag(for: idx, provider: provider)
                    let spec = self.moneySpec(for: b)
                    SharedStore.writeBalance(b, sign: spec.sign, rate: spec.rate, tag: tag)
                    self.applySecondary(b)
                case .failure(let err):
                    self.subStatusDot?.layer?.backgroundColor = NSColor.systemRed.cgColor
                    self.subTotalValue?.stringValue = "—"
                    self.subGrantedLabel?.stringValue = err.localizedDescription
                }
            }
        }
    }

    /// 渲染副账号区块（DeepSeek：余额/赠送/充值；智谱：5 小时/本周/套餐）
    private func applySecondary(_ b: AccountBalance) {
        guard sideBySide else { return }
        let spec = moneySpec(for: b)
        let sign = spec.sign, rate = spec.rate
        // 极简模式：只写标题右侧一行摘要
        if isMini {
            let short = b.provider == SharedStore.providerZhipu ? "智谱" : "DS"
            if b.provider == SharedStore.providerZhipu {
                let rem5 = b.quota5Percent.map { max(0, 100 - $0) }
                let remW = b.quotaWeekPercent.map { max(0, 100 - $0) }
                subMiniLabel?.stringValue = short + " " + (rem5.map { String($0) + "%" } ?? "—")
                    + "/" + (remW.map { String($0) + "%" } ?? "—")
            } else {
                // 极简窗口窄：只留整数金额，避免和右侧状态文字挤在一起
                let shown = (Double(b.total) ?? 0) * rate
                subMiniLabel?.stringValue = short + " " + sign + String(format: "%.0f", shown)
            }
            subMiniLabel?.textColor = (b.quotaWeekPercent ?? 0) >= 100 && b.provider == SharedStore.providerZhipu
                ? .systemRed : .tertiaryLabelColor
            return
        }
        guard subTotalValue != nil else { return }
        if b.provider == SharedStore.providerZhipu {
            let rem5 = b.quota5Percent.map { max(0, 100 - $0) }
            let remW = b.quotaWeekPercent.map { max(0, 100 - $0) }
            subTotalLabel.stringValue = L.t("5 小时额度")
            subTotalValue.stringValue = rem5.map { String($0) + "%" } ?? "—"
            subGrantedLabel.stringValue = L.t("本周额度")
            subGrantedValue.stringValue = remW.map { String($0) + "%" } ?? "—"
            subToppedLabel.stringValue = L.t("套餐")
            subToppedValue.stringValue = b.plan ?? L.t("无套餐")
            subTotalValue.textColor = rem5 == 0 ? .systemRed : (rem5.map { $0 < 10 } == true ? .systemOrange : .labelColor)
            subGrantedValue.textColor = remW == 0 ? .systemRed : (remW.map { $0 < 10 } == true ? .systemOrange : .secondaryLabelColor)
            subToppedValue.textColor = .secondaryLabelColor
            if let pw = b.quotaWeekPercent, pw >= 100 {
                subStatusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            } else {
                subStatusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            }
        } else {
            subTotalLabel.stringValue = L.t("总余额")
            subTotalValue.stringValue = fmtMoney(Double(b.total) ?? 0, sign: sign, rate: rate)
            subGrantedLabel.stringValue = L.t("赠送余额")
            subGrantedValue.stringValue = b.granted.map { fmtMoney(Double($0) ?? 0, sign: sign, rate: rate) } ?? "—"
            subToppedLabel.stringValue = L.t("充值余额")
            subToppedValue.stringValue = b.toppedUp.map { fmtMoney(Double($0) ?? 0, sign: sign, rate: rate) } ?? "—"
            let shown = (Double(b.total) ?? 0) * rate
            subTotalValue.textColor = shown < 5 ? .systemRed : (shown < 20 ? .systemOrange : .labelColor)
            subGrantedValue.textColor = .secondaryLabelColor
            subToppedValue.textColor = .secondaryLabelColor
            subStatusDot.layer?.backgroundColor = b.isAvailable ? NSColor.systemGreen.cgColor : NSColor.systemRed.cgColor
        }
    }

    private func apply(_ b: AccountBalance) {
        let isZhipu = b.provider == SharedStore.providerZhipu
        let spec = moneySpec(for: b)
        let sign = spec.sign, rate = spec.rate
        let total = Double(b.total) ?? 0
        totalValue.stringValue = fmtMoney(total, sign: sign, rate: rate)
        if isZhipu {
            // 智谱 Coding Plan：主指标是套餐额度（现金余额通常为 0，降为 footer 显示）
            let p5 = b.quota5Percent
            let pw = b.quotaWeekPercent
            let rem5 = p5.map { max(0, 100 - $0) }
            let remW = pw.map { max(0, 100 - $0) }
            if isMini {
                totalValue.stringValue = rem5.map { "剩 " + String($0) + "%" } ?? "—"
            } else {
                totalLabel?.stringValue = L.t("5 小时额度")
                totalValue.stringValue = rem5.map { String($0) + "%" } ?? "—"
            }
            grantedLabel?.stringValue = L.t("本周额度")
            grantedValue?.stringValue = remW.map { String($0) + "%" } ?? "—"
            toppedLabel?.stringValue = L.t("套餐")
            toppedValue?.stringValue = b.plan ?? L.t("无套餐")
        } else {
            grantedLabel?.stringValue = L.t("赠送余额")
            toppedLabel?.stringValue = L.t("充值余额")
            // 极简模式下赠送/充值控件不存在，用可选链避免崩溃
            if let g = b.granted { grantedValue?.stringValue = fmtMoney(Double(g) ?? 0, sign: sign, rate: rate) }
            if let t = b.toppedUp { toppedValue?.stringValue = fmtMoney(Double(t) ?? 0, sign: sign, rate: rate) }
        }

        if isZhipu, let pw = b.quotaWeekPercent, pw >= 100 {
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = L.t("本周用尽")
        } else if b.isAvailable {
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = isZhipu && b.plan != nil ? L.t("套餐有效") : L.t("可用")
        } else {
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = L.t("余额不足")
        }
        // 浮窗标题跟随数据源（切换账号后无需重建窗口也能正确显示）
        titleLabel?.stringValue = panelTitleText()

        let shown = total * rate
        if isZhipu {
            // 按 5 小时窗口剩余额度染色：<10% 橙、0 红
            let rem = b.quota5Percent.map { max(0, 100 - $0) }
            if let rem = rem, rem == 0 {
                totalValue.textColor = .systemRed
            } else if let rem = rem, rem < 10 {
                totalValue.textColor = .systemOrange
            } else {
                totalValue.textColor = accentColor
            }
        } else if isZhipu && b.plan != nil {
            totalValue.textColor = accentColor      // 套餐有效时现金余额为 0 属正常，不标红
        } else {
            totalValue.textColor = shown < 5 ? .systemRed : (shown < 20 ? .systemOrange : accentColor)
        }
        if isZhipu {
            // 额度用尽标红、剩余紧张标橙，其余保持次级色
            if let pw = b.quotaWeekPercent {
                let rem = max(0, 100 - pw)
                grantedValue?.textColor = rem == 0 ? .systemRed : (rem < 10 ? .systemOrange : .secondaryLabelColor)
            }
        } else {
            grantedValue?.textColor = .secondaryLabelColor
        }
        toppedValue?.textColor = .secondaryLabelColor

        lastUpdated = Self.timeFormatter.string(from: Date())
        SharedStore.writeBalance(b, sign: sign, rate: rate,
                                 tag: SharedStore.currentAccountTag())
        SharedStore.appendHistory(total: b.total)
        checkLowBalance(total: total, sign: sign, provider: b.provider, hasPlan: b.plan != nil)
        updateFooter()
    }

    /// 低余额提醒（低于阈值发一次系统通知，恢复后重置）
    /// 智谱用户若持有有效套餐，现金余额为 0 属正常，不触发提醒
    private func checkLowBalance(total: Double, sign: String, provider: String = "", hasPlan: Bool = false) {
        guard lowBalanceAlert else { return }
        if provider == SharedStore.providerZhipu && hasPlan {
            SharedStore.set("lowNotified", false)
            return
        }
        if total < lowBalanceThreshold {
            guard !(SharedStore.get("lowNotified") as? Bool ?? false) else { return }
            let center = UNUserNotificationCenter.current()
            // 仅首次提醒时请求授权（避免每次刷新都请求）
            if !(SharedStore.get("notifAuthAsked") as? Bool ?? false) {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                SharedStore.set("notifAuthAsked", true)
            }
            let content = UNMutableNotificationContent()
            content.title = L.t("DeepSeek 余额不足")
            content.body = L.isEn
                ? "Balance \(sign) \(String(format: "%.2f", total)) is below alert threshold \(sign) \(String(format: "%.2f", lowBalanceThreshold))"
                : "当前余额 \(sign) \(String(format: "%.2f", total))，低于提醒阈值 \(sign) \(String(format: "%.2f", lowBalanceThreshold))"
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
        if !lastUpdated.isEmpty { t = L.t("更新于 %@").replacingOccurrences(of: "%@", with: lastUpdated) }
        if SharedStore.currentProvider() == SharedStore.providerZhipu {
            let bal = SharedStore.readBalance()
            let cash = bal?["total"] as? String ?? "0.00"
            let until = bal?["planUntil"] as? String ?? ""
            var parts = ["¥" + cash]
            if !until.isEmpty { parts.append(L.t("到期 %@").replacingOccurrences(of: "%@", with: until)) }
            t = parts.joined(separator: " · ")
            if isMini {
                // 极简窗口窄，底部按钮会压到文字：只留余额与到期，不追加刷新倒计时
                footerLabel.stringValue = t
                return
            }
        }
        t += (L.isEn ? " · %@s" : " · %@s 后刷新").replacingOccurrences(of: "%@", with: String(secondsLeft))
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

    /// 显示货币模式：0=自动跟随 API，1=强制人民币，2=强制美元（按汇率换算显示）
    private var displayCurrencyMode: Int { SharedStore.get("displayCurrency") as? Int ?? 0 }
    /// USD 显示换算汇率（1 USD = 7.2 CNY，可在代码中调整）
    private static let usdRate: Double = 7.2

    /// 解析当前显示货币 → (符号, 换算系数)；CNY=1.0，USD≈0.1389（即 /7.2）
    private func moneySpec(for b: AccountBalance) -> (sign: String, rate: Double) {
        switch displayCurrencyMode {
        case 1: return ("¥", 1.0)
        case 2: return ("$", 1.0 / Self.usdRate)
        default:
            switch b.currency.uppercased() {
            case "USD", "US": return ("$", 1.0)
            case "EUR": return ("€", 1.0)
            default: return ("¥", 1.0)   // CNY / CN / 其他按人民币
            }
        }
    }

    /// 按显示货币格式化金额（内部以 CNY 计，rate 换算）
    private func fmtMoney(_ v: Double, sign: String, rate: Double) -> String {
        "\(sign) \(String(format: "%.2f", v * rate))"
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
                                   lowThreshold: SharedStore.get("lowBalanceThreshold") as? Double ?? 10.0,
                                   displayCurrency: SharedStore.get("displayCurrency") as? Int ?? 0)
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
            (L.t("暂无数据，等待记录…") as NSString).draw(at: NSPoint(x: 8, y: bounds.height / 2 - 6), withAttributes: attrs)
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
    private let showKey = NSButton(checkboxWithTitle: L.t("显示"), target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseField = NSTextField(frame: .zero)
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let intervals = [15, 30, 60, 120, 300]
    // 外观
    private let topCheck = NSButton(checkboxWithTitle: L.t("窗口始终置顶"), target: nil, action: nil)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let currencyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "100%")
    private var accentButtons: [NSButton] = []
    private var currentAccent: Int = 0
    // 账号
    private let accountPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    // 看板
    private let dashCardChecks = ["当前余额", "今日消耗", "累计消耗", "累计充值", "记录天数", "区间最高"].map {
        NSButton(checkboxWithTitle: L.t($0), target: nil, action: nil)
    }
    private let dashRangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chartCheck = NSButton(checkboxWithTitle: L.t("显示曲线图"), target: nil, action: nil)
    private let dashTopCheck = NSButton(checkboxWithTitle: L.t("看板窗口置顶"), target: nil, action: nil)
    // 提醒
    private let lowCheck = NSButton(checkboxWithTitle: L.t("余额低于阈值时发送系统通知"), target: nil, action: nil)
    private let thresholdField = NSTextField(frame: .zero)
    // 标签栏
    private var tabSeg: NSSegmentedControl!
    private let tabContent = NSView()
    private var tabs: [NSView] = []

    init(displayMode: Int, sourceType: Int, baseURL: String, apiKey: String, interval: Int,
         alwaysOnTop: Bool, opacity: Double, accent: Int, appearanceMode: Int,
         dashCards: [Int], dashRange: Int, showChart: Bool, lowAlert: Bool, lowThreshold: Double,
         displayCurrency: Int) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 402),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L.t("DeepSeek 用量面板 · 设置")
        isReleasedWhenClosed = false
        buildUI(displayMode: displayMode, sourceType: sourceType, baseURL: baseURL,
                apiKey: apiKey, interval: interval, alwaysOnTop: alwaysOnTop,
                opacity: opacity, accent: accent, appearanceMode: appearanceMode,
                dashCards: dashCards, dashRange: dashRange, showChart: showChart,
                lowAlert: lowAlert, lowThreshold: lowThreshold,
                displayCurrency: displayCurrency)
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
                         lowAlert: Bool, lowThreshold: Double, displayCurrency: Int) {
        let content = contentView!

        // ---- 标签栏（分段控件，高 30，点击区域大）----
        tabSeg = NSSegmentedControl(labels: [L.t("基础"), L.t("外观"), L.t("看板"), L.t("提醒")],
                                    trackingMode: .selectOne, target: self, action: #selector(tabChanged))
        tabSeg.selectedSegment = 0
        tabSeg.segmentStyle = .rounded
        tabSeg.frame = NSRect(x: 10, y: 346, width: 380, height: 30)
        content.addSubview(tabSeg)

        // 内容容器（紧凑高度：内容区填满窗口，消除底部大片空白）
        tabContent.frame = NSRect(x: 10, y: 38, width: 380, height: 300)
        content.addSubview(tabContent)

        // 预构建 4 个标签页
        tabs = [
            buildBasicTab(displayMode: displayMode, sourceType: sourceType,
                          baseURL: baseURL, apiKey: apiKey, interval: interval),
            buildAppearanceTab(alwaysOnTop: alwaysOnTop, opacity: opacity,
                               accent: accent, appearanceMode: appearanceMode,
                               displayCurrency: displayCurrency),
            buildDashboardTab(dashCards: dashCards, dashRange: dashRange, showChart: showChart),
            buildAlertTab(lowAlert: lowAlert, lowThreshold: lowThreshold)
        ]
        switchTab(0)

        // 按钮
        let cancelButton = NSButton(title: L.t("取消"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 208, y: 8, width: 82, height: 28)
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: L.t("保存"), target: self, action: #selector(save))
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

    // MARK: 自适应行布局（Apple 风格：label 左对齐统一宽、控件右对齐；中英文各算各的）
    private func rowWidths(_ texts: [String]) -> (labelW: CGFloat, cx: CGFloat, cw: CGFloat) {
        let maxText = texts.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width }.max() ?? 0
        let labelW = min(150, max(64, ceil(maxText) + 10))
        let cx = 20 + labelW + 8   // label 右缘 = 控件列左起点（右对齐时每行按 rightX 计算）
        let cw = max(80, 380 - cx - 14)
        return (labelW, cx, cw)
    }
    /// 控件右缘（Apple 设置右对齐 padding 16）
    private let rightX: CGFloat = 364

    // MARK: 基础（6 行 × 44，控件右对齐）
    private func buildBasicTab(displayMode: Int, sourceType: Int, baseURL: String, apiKey: String, interval: Int) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        let r = rowWidths([L.t("当前账号"), L.t("API Key"), L.t("显示模式"), L.t("数据源"), L.t("网关地址"), L.t("自动刷新间隔")])
        // 行 Y（label 底边）：260/216/172/128/84/40（44px 行距，顶部留白 20）

        // 账号管理（多账号切换）：下拉 + [−][+] 一组右对齐，右缘 364
        v.addSubview(label(L.t("当前账号"), NSRect(x: 20, y: 260, width: r.labelW, height: 20)))
        let popW = max(100, min(170, 364 - 82 - (20 + r.labelW) - 6))
        accountPopup.frame = NSRect(x: 274 - popW, y: 257, width: popW, height: 26)
        accountPopup.removeAllItems()
        let accs = SharedStore.accounts()
        if accs.isEmpty {
            accountPopup.addItem(withTitle: "Account 1")
            accountPopup.lastItem?.tag = 0
        } else {
            for (i, a) in accs.enumerated() {
                accountPopup.addItem(withTitle: SharedStore.accountTitle(a, index: i))
                accountPopup.lastItem?.tag = i
            }
        }
        accountPopup.selectItem(withTag: SharedStore.accountIndex())
        accountPopup.target = self
        accountPopup.action = #selector(accountChanged)
        v.addSubview(accountPopup)
        let addBtn = NSButton(title: "+", target: self, action: #selector(addAccountAction))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: 282, y: 254, width: 38, height: 24)
        addBtn.toolTip = L.t("添加账号")
        v.addSubview(addBtn)
        let delBtn = NSButton(title: "−", target: self, action: #selector(removeAccountAction))
        delBtn.bezelStyle = .rounded
        delBtn.frame = NSRect(x: 326, y: 254, width: 38, height: 24)
        delBtn.toolTip = L.t("删除当前账号")
        v.addSubview(delBtn)

        // API Key：输入框 + 显示开关右对齐
        v.addSubview(label(L.t("API Key"), NSRect(x: 20, y: 216, width: r.labelW, height: 20)))
        keyField.stringValue = apiKey
        keyField.placeholderString = SharedStore.currentProvider() == SharedStore.providerZhipu
            ? (L.isEn ? "id.secret (Zhipu API Key)" : "id.secret（智谱 API Key）")
            : "sk-…"
        keyField.font = .systemFont(ofSize: 12)
        keyField.frame = NSRect(x: r.cx, y: 212, width: max(100, 364 - 66 - r.cx), height: 24)
        v.addSubview(keyField)
        showKey.target = self
        showKey.action = #selector(toggleKeyVisible)
        showKey.frame = NSRect(x: 306, y: 214, width: 58, height: 20)
        v.addSubview(showKey)

        // 显示模式 / 数据源 / 网关：控件右对齐
        v.addSubview(label(L.t("显示模式"), NSRect(x: 20, y: 172, width: r.labelW, height: 20)))
        modePopup.frame = NSRect(x: r.cx, y: 168, width: 364 - r.cx, height: 26)
        modePopup.removeAllItems()
        modePopup.addItem(withTitle: L.t("极简 · 只显示总余额"))
        modePopup.lastItem?.tag = 0
        modePopup.addItem(withTitle: L.t("标准 · 含赠送/充值明细"))
        modePopup.lastItem?.tag = 1
        modePopup.addItem(withTitle: L.t("看板 · 余额+用量曲线"))
        modePopup.lastItem?.tag = 2
        modePopup.selectItem(withTag: displayMode)
        if modePopup.selectedTag() == -1 { modePopup.selectItem(withTag: 0) }
        v.addSubview(modePopup)

        v.addSubview(label(L.t("数据源"), NSRect(x: 20, y: 128, width: r.labelW, height: 20)))
        sourcePopup.frame = NSRect(x: r.cx, y: 124, width: 364 - r.cx, height: 26)
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: L.t("DeepSeek 官方 API"))
        sourcePopup.lastItem?.tag = 0
        sourcePopup.addItem(withTitle: L.t("智谱 AI（GLM）"))
        sourcePopup.lastItem?.tag = 1
        sourcePopup.addItem(withTitle: L.t("自定义网关（中转站）"))
        sourcePopup.lastItem?.tag = 2
        sourcePopup.selectItem(withTag: self.tagForProvider(SharedStore.currentProvider()))
        if sourcePopup.selectedTag() == -1 { sourcePopup.selectItem(withTag: 0) }
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        v.addSubview(sourcePopup)

        v.addSubview(label(L.t("网关地址"), NSRect(x: 20, y: 84, width: r.labelW, height: 20)))
        baseField.stringValue = baseURL
        baseField.placeholderString = L.isEn ? "https://your-gateway.com (optional /v1)" : "https://your-gateway.com（可选 /v1）"
        baseField.font = .systemFont(ofSize: 12)
        baseField.frame = NSRect(x: r.cx, y: 80, width: 364 - r.cx, height: 24)
        baseField.isEnabled = (sourcePopup.selectedTag() == 2)
        v.addSubview(baseField)

        v.addSubview(label(L.t("自动刷新间隔"), NSRect(x: 20, y: 40, width: r.labelW, height: 20)))
        intervalPopup.frame = NSRect(x: 364 - min(150, 364 - r.cx), y: 36, width: min(150, 364 - r.cx), height: 26)
        intervalPopup.removeAllItems()
        for iv in intervals {
            intervalPopup.addItem(withTitle: "\(iv) " + L.t("秒"))
            intervalPopup.lastItem?.tag = iv
        }
        intervalPopup.selectItem(withTag: interval)
        if intervalPopup.selectedTag() == -1 { intervalPopup.selectItem(withTag: 60) }
        v.addSubview(intervalPopup)

        // 获取 API Key 指引（首次使用引导入口）
        let guideBtn = NSButton(title: L.t("如何获取 API Key？"), target: self, action: #selector(openAPIKeyGuide))
        guideBtn.isBordered = false
        guideBtn.contentTintColor = .systemBlue
        guideBtn.font = .systemFont(ofSize: 12)
        guideBtn.frame = NSRect(x: 20, y: 8, width: min(240, 364 - 20), height: 22)
        guideBtn.toolTip = L.t("注册/登录 → 充值 → 创建 API Key → 粘贴到上方输入框")
        guideBtn.setAccessibilityLabel(L.t("获取 API Key 指引"))
        v.addSubview(guideBtn)
        return v
    }

    /// 打开 DeepSeek 开放平台 API Key 页面（获取 API Key 指引）
    @objc private func openAPIKeyGuide() {
        if let url = URL(string: "https://platform.deepseek.com/api_keys") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 外观（5 行 × 52，控件右对齐）
    private func buildAppearanceTab(alwaysOnTop: Bool, opacity: Double, accent: Int, appearanceMode: Int, displayCurrency: Int) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        let r = rowWidths([L.t("主题色"), L.t("面板透明度"), L.t("外观"), L.t("语言"), L.t("窗口置顶"), L.t("显示货币")])
        // 行 Y：260/216/172/128/84/40（44px 行距）

        v.addSubview(label(L.t("主题色"), NSRect(x: 20, y: 260, width: r.labelW, height: 20)))
        currentAccent = accent
        for (i, t) in AccentTheme.allCases.enumerated() {
            let x = r.cx + CGFloat(i) * 30
            let b = NSButton(title: "", target: self, action: #selector(accentPicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = t.color.cgColor
            b.layer?.cornerRadius = 10
            b.layer?.masksToBounds = true
            b.frame = NSRect(x: x, y: 256, width: 20, height: 20)
            b.toolTip = L.t(t.name)
            v.addSubview(b)
            accentButtons.append(b)
        }
        updateAccentSelection()

        // 透明度：滑块 + 数值右对齐
        v.addSubview(label(L.t("面板透明度"), NSRect(x: 20, y: 216, width: r.labelW, height: 20)))
        opacitySlider.doubleValue = max(0.5, min(1.0, opacity))
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.frame = NSRect(x: r.cx, y: 214, width: max(80, 250 - r.cx), height: 20)
        v.addSubview(opacitySlider)
        opacityValue.font = .systemFont(ofSize: 12)
        opacityValue.textColor = .secondaryLabelColor
        opacityValue.frame = NSRect(x: 314, y: 216, width: 50, height: 20)
        opacityValue.stringValue = "\(Int(round(opacity * 100)))%"
        v.addSubview(opacityValue)

        v.addSubview(label(L.t("外观"), NSRect(x: 20, y: 172, width: r.labelW, height: 20)))
        appearancePopup.frame = NSRect(x: 194, y: 168, width: 170, height: 26)
        appearancePopup.removeAllItems()
        appearancePopup.addItem(withTitle: L.t("跟随系统"))
        appearancePopup.lastItem?.tag = 0
        appearancePopup.addItem(withTitle: L.t("深色"))
        appearancePopup.lastItem?.tag = 1
        appearancePopup.addItem(withTitle: L.t("浅色"))
        appearancePopup.lastItem?.tag = 2
        appearancePopup.selectItem(withTag: appearanceMode)
        if appearancePopup.selectedTag() == -1 { appearancePopup.selectItem(withTag: 0) }
        v.addSubview(appearancePopup)

        v.addSubview(label(L.t("语言"), NSRect(x: 20, y: 128, width: r.labelW, height: 20)))
        langPopup.frame = NSRect(x: 194, y: 124, width: 170, height: 26)
        langPopup.removeAllItems()
        langPopup.addItem(withTitle: "中文")
        langPopup.lastItem?.tag = 0
        langPopup.addItem(withTitle: "English")
        langPopup.lastItem?.tag = 1
        langPopup.selectItem(withTag: L.isEn ? 1 : 0)
        v.addSubview(langPopup)

        v.addSubview(label(L.t("窗口置顶"), NSRect(x: 20, y: 84, width: r.labelW, height: 20)))
        topCheck.state = alwaysOnTop ? .on : .off
        topCheck.frame = NSRect(x: 324, y: 82, width: 40, height: 20)
        v.addSubview(topCheck)

        // 显示货币：自动跟随 / 人民币 / 美元（USD 显示按汇率换算）
        v.addSubview(label(L.t("显示货币"), NSRect(x: 20, y: 40, width: r.labelW, height: 20)))
        currencyPopup.frame = NSRect(x: 194, y: 36, width: 170, height: 26)
        currencyPopup.removeAllItems()
        currencyPopup.addItem(withTitle: L.t("自动跟随"))
        currencyPopup.lastItem?.tag = 0
        currencyPopup.addItem(withTitle: L.t("人民币 CNY"))
        currencyPopup.lastItem?.tag = 1
        currencyPopup.addItem(withTitle: L.t("美元 USD"))
        currencyPopup.lastItem?.tag = 2
        currencyPopup.selectItem(withTag: displayCurrency)
        if currencyPopup.selectedTag() == -1 { currencyPopup.selectItem(withTag: 0) }
        v.addSubview(currencyPopup)
        return v
    }

    // MARK: 看板（卡片组 + 3 行，右对齐）
    private func buildDashboardTab(dashCards: [Int], dashRange: Int, showChart: Bool) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        let r = rowWidths([L.t("悬浮窗看板显示卡片"), L.t("默认时间范围")])
        // 行 Y：卡片 label 260（卡片 3 行 252/222/192）、时间范围 170、曲线 118、置顶 66

        v.addSubview(label(L.t("悬浮窗看板显示卡片"), NSRect(x: 20, y: 260, width: r.labelW, height: 20)))
        let colW = max(100, (364 - r.cx - 6) / 2)  // 两列 checkbox 右对齐均分
        for (i, cb) in dashCardChecks.enumerated() {
            cb.state = dashCards.contains(i) ? .on : .off
            let col = i / 3, row = i % 3
            let x = 364 - (col == 0 ? colW * 2 + 6 : colW)
            cb.frame = NSRect(x: x, y: 252 - CGFloat(row) * 30, width: colW, height: 22)
            v.addSubview(cb)
        }
        v.addSubview(label(L.t("默认时间范围"), NSRect(x: 20, y: 170, width: r.labelW, height: 20)))
        dashRangePopup.frame = NSRect(x: 214, y: 166, width: 150, height: 26)
        dashRangePopup.removeAllItems()
        dashRangePopup.addItem(withTitle: L.t("近 7 天"))
        dashRangePopup.lastItem?.tag = 7
        dashRangePopup.addItem(withTitle: L.t("近 30 天"))
        dashRangePopup.lastItem?.tag = 30
        dashRangePopup.addItem(withTitle: L.t("全部"))
        dashRangePopup.lastItem?.tag = 0
        dashRangePopup.selectItem(withTag: dashRange)
        if dashRangePopup.selectedTag() == -1 { dashRangePopup.selectItem(withTag: 7) }
        v.addSubview(dashRangePopup)

        chartCheck.state = showChart ? .on : .off
        chartCheck.frame = NSRect(x: 20, y: 118, width: 200, height: 22)
        v.addSubview(chartCheck)

        dashTopCheck.state = (SharedStore.get("dashTop") as? Bool ?? true) ? .on : .off
        dashTopCheck.frame = NSRect(x: 20, y: 66, width: 240, height: 22)
        v.addSubview(dashTopCheck)
        return v
    }

    // MARK: 提醒（4 行 × 52，控件右对齐）
    private func buildAlertTab(lowAlert: Bool, lowThreshold: Double) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        // 行 Y：260/208/156/104（52px 行距）
        lowCheck.state = lowAlert ? .on : .off
        lowCheck.frame = NSRect(x: 20, y: 258, width: 344, height: 22)
        v.addSubview(lowCheck)

        let rt = rowWidths([L.t("提醒阈值（元）")])
        v.addSubview(label(L.t("提醒阈值（元）"), NSRect(x: 20, y: 208, width: rt.labelW, height: 20)))
        thresholdField.stringValue = String(format: "%.0f", lowThreshold)
        thresholdField.font = .systemFont(ofSize: 12)
        thresholdField.frame = NSRect(x: 284, y: 204, width: 80, height: 24)
        v.addSubview(thresholdField)

        let clearButton = NSButton(title: L.t("清除历史数据…"), target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 194, y: 156, width: 170, height: 30)
        v.addSubview(clearButton)

        let exportButton = NSButton(title: L.t("导出历史数据…"), target: self, action: #selector(exportCSV))
        exportButton.bezelStyle = .rounded
        exportButton.frame = NSRect(x: 194, y: 104, width: 170, height: 30)
        v.addSubview(exportButton)
        return v
    }

    // MARK: - 动作
    @objc private func toggleKeyVisible() {
        (keyField.cell as? NSSecureTextFieldCell)?.echosBullets = !(showKey.state == .on)
    }

    /// 切换当前账号：更新 accountIndex + keyField 显示该账号 Key
    @objc private func accountChanged() {
        let i = accountPopup.selectedTag()
        SharedStore.set("accountIndex", max(0, i))
        if let a = SharedStore.currentAccount(), let k = a["key"] as? String {
            keyField.stringValue = k
        }
        // 数据源选择跟随当前账号
        sourcePopup.selectItem(withTag: tagForProvider(SharedStore.currentProvider()))
        baseField.isEnabled = (sourcePopup.selectedTag() == 2)
        keyField.placeholderString = sourcePopup.selectedTag() == 1
            ? (L.isEn ? "id.secret (Zhipu API Key)" : "id.secret（智谱 API Key）")
            : "sk-…"
    }

    @objc private func addAccountAction() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        SharedStore.addAccount(key: key, provider: providerForTag(sourcePopup.selectedTag()))
        // 刷新账号下拉
        accountPopup.removeAllItems()
        let accs = SharedStore.accounts()
        for (i, a) in accs.enumerated() {
            accountPopup.addItem(withTitle: SharedStore.accountTitle(a, index: i))
            accountPopup.lastItem?.tag = i
        }
        accountPopup.selectItem(withTag: SharedStore.accountIndex())
    }

    @objc private func removeAccountAction() {
        SharedStore.removeCurrentAccount()
        accountPopup.removeAllItems()
        let accs = SharedStore.accounts()
        if accs.isEmpty {
            accountPopup.addItem(withTitle: "Account 1")
            accountPopup.lastItem?.tag = 0
        } else {
            for (i, a) in accs.enumerated() {
                accountPopup.addItem(withTitle: SharedStore.accountTitle(a, index: i))
                accountPopup.lastItem?.tag = i
            }
        }
        accountPopup.selectItem(withTag: SharedStore.accountIndex())
        keyField.stringValue = SharedStore.apiKey() ?? ""
    }

    /// 导出历史数据为 CSV 到 ~/Downloads
    @objc private func exportCSV() {
        let entries = SharedStore.scopedHistoryEntries()
        var csv = "timestamp,balance\n"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in entries {
            let ts = e["ts"] as? Double ?? 0
            let t = df.string(from: Date(timeIntervalSince1970: ts))
            csv += "\(t),\(e["total"] as? String ?? "")\n"
        }
        let fm = FileManager.default
        guard let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let url = dl.appendingPathComponent("DeepSeekUsagePanel_history.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            let alert = NSAlert()
            alert.messageText = L.isEn ? "Exported" : "已导出"
            alert.informativeText = url.path
            alert.alertStyle = .informational
            alert.addButton(withTitle: L.t("好"))
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = L.isEn ? "Export failed" : "导出失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L.t("好"))
            alert.runModal()
        }
    }

    @objc private func sourceChanged() {
        baseField.isEnabled = (sourcePopup.selectedTag() == 2)
        // Key 输入框提示随数据源变化
        keyField.placeholderString = sourcePopup.selectedTag() == 1
            ? (L.isEn ? "id.secret (Zhipu API Key)" : "id.secret（智谱 API Key）")
            : "sk-…"
    }

    private func tagForProvider(_ p: String) -> Int {
        p == SharedStore.providerZhipu ? 1 : (p == SharedStore.providerCustom ? 2 : 0)
    }
    private func providerForTag(_ t: Int) -> String {
        t == 1 ? SharedStore.providerZhipu : (t == 2 ? SharedStore.providerCustom : SharedStore.providerDeepSeek)
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
        alert.messageText = L.t("清除历史数据？")
        alert.informativeText = L.t("将删除本地记录的余额历史（看板曲线与累计统计会重新从当前余额开始记录）。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.t("清除"))
        alert.addButton(withTitle: L.t("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            SharedStore.clearHistory()
        }
    }

    @objc private func save() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = KeychainStore.set(key, for: "apiKey")
        SharedStore.set("apiKey", key)
        SharedStore.upsertCurrentAccount(key: key)
        let mode = modePopup.selectedTag()
        let source = sourcePopup.selectedTag()
        var base = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        SharedStore.set("displayMode", mode >= 0 ? mode : 0)
        let src = source >= 0 ? source : 0
        let provider = providerForTag(src)
        SharedStore.setCurrentProvider(provider)
        SharedStore.set("sourceType", provider == SharedStore.providerCustom ? 1 : 0)
        SharedStore.set("provider", provider)
        SharedStore.set("baseURL", base)
        let tag = intervalPopup.selectedTag()
        SharedStore.set("refreshInterval", tag > 0 ? tag : 60)
        SharedStore.set("alwaysOnTop", topCheck.state == .on)
        SharedStore.set("opacity", opacitySlider.doubleValue)
        SharedStore.set("accent", currentAccent)
        SharedStore.set("appearanceMode", appearancePopup.selectedTag() >= 0 ? appearancePopup.selectedTag() : 0)
        SharedStore.set("lang", langPopup.selectedTag() == 1 ? "en" : "zh")
        let cur = currencyPopup.selectedTag()
        SharedStore.set("displayCurrency", cur >= 0 ? cur : 0)
        var cards: [Int] = []
        for (i, cb) in dashCardChecks.enumerated() where cb.state == .on { cards.append(i) }
        if cards.isEmpty { cards = [0] }
        SharedStore.set("dashCards", cards)
        SharedStore.set("dashRange", dashRangePopup.selectedTag() >= 0 ? dashRangePopup.selectedTag() : 7)
        SharedStore.set("showChart", chartCheck.state == .on)
        SharedStore.set("dashTop", dashTopCheck.state == .on)
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
        title = SharedStore.currentProvider() == SharedStore.providerZhipu ? L.t("智谱 用量看板") : L.t("DeepSeek 用量看板")
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 380)
        appearance = NSAppearance(named: .darkAqua)
        applyTopLevel()
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

    /// 看板窗口"显示在最顶部"：设置·看板 tab 的「看板窗口置顶」控制
    func applyTopLevel() {
        let on = SharedStore.get("dashTop") as? Bool ?? true
        level = on ? .floating : .normal
        collectionBehavior = on
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
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
        let lang = L.lang
        let provider = balance?["provider"] as? String ?? "deepseek"
        let plan = balance?["plan"] as? String ?? ""
        let planUntil = balance?["planUntil"] as? String ?? ""
        let q5 = (balance?["q5Pct"] as? NSNumber)?.intValue ?? -1
        let qw = (balance?["qwPct"] as? NSNumber)?.intValue ?? -1
        // 并列：把副账号的缓存一并注入，供网页看板渲染第二行卡片
        var sideJS = "null"
        if let idx = SharedStore.secondaryAccountIndex(), SharedStore.sideBySideEnabled() {
            let sp = SharedStore.provider(of: idx)
            let sb = SharedStore.readBalance(tag: SharedStore.tag(for: idx, provider: sp)) ?? [:]
            let sdi: [String: Any] = [
                "provider": sp,
                "total": sb["total"] as? String ?? "",
                "granted": sb["granted"] as? String ?? "0",
                "topped": sb["topped"] as? String ?? "0",
                "plan": sb["plan"] as? String ?? "",
                "q5Pct": sb["q5Pct"] as? Int ?? -1,
                "qwPct": sb["qwPct"] as? Int ?? -1,
                "name": SharedStore.account(at: idx)?["name"] as? String ?? "Account \(idx + 1)",
            ]
            if let d = try? JSONSerialization.data(withJSONObject: sdi),
               let str = String(data: d, encoding: .utf8) {
                sideJS = str
            }
        }
        let js = "window.__DS_DATA__ = { sign: \(Self.jsStr(sign)), current: \(Self.jsStr(total)), topped: \(Self.jsStr(topped)), entries: \(entries), accent: \(Self.jsStr(accent)), lang: \(Self.jsStr(lang)), provider: \(Self.jsStr(provider)), plan: \(Self.jsStr(plan)), planUntil: \(Self.jsStr(planUntil)), q5Pct: \(q5 >= 0 ? String(q5) : "null"), qwPct: \(qw >= 0 ? String(qw) : "null"), side: \(sideJS) }; console.log('injected', JSON.stringify(window.__DS_DATA__).slice(0, 300)); renderDashboard();"
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
    private let launchItem = NSMenuItem(title: L.t("开机自启"), action: nil, keyEquivalent: "")
    private var settingsItem: NSMenuItem?
    private var dashboardItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSLog("DSAPP diag: dir=\(SharedStore.diagPath()) cfg=\(SharedStore.loadConfig())")
        setupStatusItem()
        let p = FloatingPanel()
        panel = p
        NSLog("DSAPP launch: panel created, alwaysOnTop=\(SharedStore.get("alwaysOnTop") as? Bool ?? true) level=\(p.level.rawValue)")
        p.orderFrontRegardless()
        // 右键浮窗任意位置：弹出与菜单栏相同的下拉菜单（用量看板/显示或隐藏面板/设置/开机自启/退出）
        p.contentView?.menu = statusMenu
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
                                     accessibilityDescription: L.t("DeepSeek 用量"))
        let menu = NSMenu()
        menu.delegate = self

        // 用量看板… 放第一位（用户高频入口）
        let dashboardItem = menu.addItem(withTitle: L.t("用量看板…"), action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        self.dashboardItem = dashboardItem

        toggleItem.title = L.t("显示面板")
        toggleItem.target = self
        toggleItem.action = #selector(togglePanel)
        menu.addItem(toggleItem)

        let settingsItem = menu.addItem(withTitle: L.t("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        self.settingsItem = settingsItem

        menu.addItem(.separator())

        launchItem.target = self
        launchItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = menu.addItem(withTitle: L.t("退出"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        self.quitItem = quitItem

        // 点击图标直接弹出菜单（不区分单击/双击）
        item.menu = menu
        statusMenu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let visible = panel?.isVisible ?? false
        toggleItem.title = visible ? L.t("隐藏面板") : L.t("显示面板")
        launchItem.title = L.t("开机自启")
        settingsItem?.title = L.t("设置…")
        dashboardItem?.title = L.t("用量看板…")
        quitItem?.title = L.t("退出")
        launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func togglePanel() {
        guard let p = panel else { return }
        if p.isVisible { p.orderOut(nil) } else { p.orderFront(nil); p.orderFrontRegardless() }
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
        dashboard?.applyTopLevel()
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
            alert.informativeText = L.t("请把应用移到「应用程序」文件夹后重试，或到 系统设置 → 通用 → 登录项 手动调整。") + "\n" + error.localizedDescription
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

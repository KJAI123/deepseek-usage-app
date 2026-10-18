// DeepSeek 用量小组件（WidgetKit, macOS 14+）
// 只读主应用写入共享目录的 balance.json（temporary-exception entitlement），每 15 分钟刷新一次
import WidgetKit
import SwiftUI

private func balanceFile() -> URL {
    // 沙盒内 home 被重定向到容器，用 passwd 取真实 home 定位共享目录
    let home: String
    if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir {
        home = String(cString: d)
    } else {
        home = NSHomeDirectory()
    }
    return URL(fileURLWithPath: home)
        .appendingPathComponent("Library/Application Support/DeepSeekUsagePanel/balance.json")
}

struct BalanceEntry: TimelineEntry {
    let date: Date
    let total: String
    let sign: String
    let updatedAt: Date?
    let available: Bool
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(date: Date(), total: "—", sign: "¥", updatedAt: nil, available: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let entry = current()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func current() -> BalanceEntry {
        // 通过共享目录读取主应用写入的余额（temporary-exception 只读授权）
        guard let data = try? Data(contentsOf: balanceFile()),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BalanceEntry(date: Date(), total: "—", sign: "¥", updatedAt: nil, available: true)
        }
        let ts = json["updatedAt"] as? Double ?? 0
        return BalanceEntry(
            date: Date(),
            total: json["total"] as? String ?? "—",
            sign: json["sign"] as? String ?? "¥",
            updatedAt: ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
            available: json["available"] as? Bool ?? true
        )
    }
}

struct BalanceWidgetView: View {
    var entry: BalanceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "yensign.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                Text("DeepSeek 余额")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
            }
            Spacer(minLength: 1)
            Text("\(entry.sign) \(entry.total)")
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundColor(entry.available ? .white : Color(red: 1, green: 0.42, blue: 0.38))
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let t = entry.updatedAt {
                Text("更新于 \(Self.time(t))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Text("打开面板后自动刷新")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.10, blue: 0.26),
                         Color(red: 0.10, green: 0.33, blue: 0.86)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeepSeekBalanceWidget", provider: BalanceProvider()) { entry in
            BalanceWidgetView(entry: entry)
        }
        .configurationDisplayName("DeepSeek 用量")
        .description("显示 DeepSeek API 账户总余额")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct DSWidgetBundle: WidgetBundle {
    var body: some Widget { BalanceWidget() }
}

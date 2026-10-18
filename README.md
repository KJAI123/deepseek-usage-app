# DeepSeek 用量面板（DeepSeek Usage Panel）

> 常驻屏幕角落的 DeepSeek API 余额悬浮窗 + 桌面小组件 + 用量看板。
> 极简显示、实时刷新、支持官方 API 与自建网关，macOS / Windows 双端开源。

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue)
![license](https://img.shields.io/badge/license-MIT-green)
![build](https://img.shields.io/github/actions/workflow/status/<your-github>/deepseek-usage-app/build.yml?label=build)

## 功能一览

| 能力 | macOS | Windows |
|---|---|---|
| 悬浮窗（极简模式：只显示总余额大字） | ✅ | ✅ |
| 标准模式（总余额 + 赠送 + 充值） | ✅ | 🚧 规划中 |
| 窗口始终置顶开关（可在设置中关闭） | ✅ | ✅ |
| 菜单栏常驻 / 系统托盘 | ✅ | ✅ |
| 桌面小组件（WidgetKit） | ✅ | — |
| 用量看板（余额历史曲线，7/30 天/全部） | ✅ | ✅ |
| 开机自启 | ✅ | 🚧 规划中 |
| 自定义网关（new-api / one-api） | ✅ | ✅ |
| 低余额提醒 | ✅ | 🚧 规划中 |

## 快速开始

### macOS（macOS 13+）

```bash
cd apps/macos
./build.sh          # 编译主应用 + 小组件 + 看板（需要 Xcode 命令行工具）
open DeepSeekUsagePanel.app
```

首次启动会自动弹出设置，粘贴 API Key（`sk-…`）保存即可。之后程序常驻**菜单栏 ¥ 图标**：左键显示/隐藏悬浮窗；菜单里有设置、用量看板、开机自启、退出。

**窗口置顶**：默认悬浮窗始终置顶；在「设置… → 窗口始终置顶」取消勾选后，悬浮窗会变为普通窗口层级，不再遮挡其他应用。

**桌面小组件**（macOS 14+）：桌面右键 → 编辑小组件 → 搜索 **DeepSeek**，拖到桌面即可（小/中两种尺寸，每 15 分钟刷新）。

### Windows（Tauri 2）

```bash
cd apps/windows
npm install
npx tauri dev       # 开发运行
npx tauri build     # 打包 NSIS 安装包（产物在 src-tauri/target/release/bundle/nsis/）
```

Windows 端同样提供透明无边框悬浮窗 + 系统托盘 + 用量看板；数据存在 `%APPDATA%/deepseek-usage-app/`。

## 数据源与口径

- **官方接口**：`GET https://api.deepseek.com/user/balance`（Bearer Key 认证），返回账户级余额（充值 + 赠送合计）。**余额是账号级的，不分 Key**——任意 Key 查询都是同一账号总余额。
- **自定义网关**：兼容 new-api / one-api 等 OpenAI 风格网关，自动探测 `{网关}/user/balance` 与 `{网关}/v1/user/balance`，DeepSeek / OpenAI 两种返回格式都支持。
- **用量看板**：官方无"每日用量明细"公开接口（网页后台的用量数据是内部接口）。看板基于应用**本地记录的余额历史**绘制曲线，展示余额变化趋势与今日消耗估算；按 Key/按模型的每日明细需要自建网关记账（二期规划）。
- **低余额提醒**：总余额 < ¥20 变橙，< ¥5 变红。

## 安全与隐私

- API Key **只保存在本机**：macOS 存于受沙盒保护的 App Group 容器与钥匙串；Windows 存于 `%APPDATA%` 本地文件。
- 应用**不采集、不上传任何数据**，所有请求仅指向你配置的 DeepSeek 官方地址或自建网关。
- 开源代码，Key 存储方式完全可见，可自行审计。

## 工程结构

```
deepseek-usage-app/
├── apps/
│   ├── macos/            # Swift/AppKit 原生（悬浮窗 + WidgetKit 小组件 + 看板窗口）
│   │   ├── DeepSeekUsagePanel.swift
│   │   ├── widget/       # WidgetKit 小组件扩展
│   │   └── build.sh      # 一键构建（arm64 + x86_64 + 签名）
│   └── windows/          # Tauri 2（Rust）：悬浮窗 + 系统托盘 + 看板
│       ├── src-tauri/    # Rust 后端 + tauri.conf.json
│       └── src/          # 前端（悬浮窗 / 设置页）
├── shared/
│   └── ui/               # 跨平台共用的看板 Web UI（ECharts）
└── .github/workflows/    # CI：macOS / Windows 自动构建
```

## 开发与贡献

- macOS 端为单文件 Swift（无 Xcode 工程），直接改 `apps/macos/DeepSeekUsagePanel.swift` 后 `./build.sh` 即可。
- Windows 端为标准 Tauri 2 工程，Rust 逻辑在 `src-tauri/src/lib.rs`，前端为纯静态 HTML。
- 看板 UI（`shared/ui/dashboard.html`）两端共用：macOS 由宿主注入 `window.__DS_DATA__`，Tauri 端通过 `invoke` 拉取。
- 欢迎提交 issue / PR。构建由 GitHub Actions 自动完成（打 `v*` tag 自动出 Release）。

## 路线图

- [ ] Windows：标准模式、开机自启、低余额提醒
- [ ] 每日用量明细（自建网关记账 / 本地代理记账）
- [ ] App Store 上架（需 Apple Developer Program 账号 + 正式签名/公证，工程已按沙盒规范构建）

## License

[MIT](./LICENSE) © 2026 DeepSeek Usage App contributors

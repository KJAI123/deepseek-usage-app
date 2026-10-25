# DeepSeek Usage Panel

> A tiny always-on-top floating panel for your DeepSeek API balance, with a usage dashboard and desktop widget.
> Minimal display, real-time refresh, official API & custom gateway support. Open source for **macOS / Windows**.

[简体中文](./README.zh-CN.md) | English

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue)
![license](https://img.shields.io/badge/license-MIT-green)
![build](https://img.shields.io/github/actions/workflow/status/KJAI123/deepseek-usage-app/build.yml?label=build)

## Features

| Capability | macOS | Windows |
|---|---|---|
| Floating panel (Minimal mode: total balance only) | ✅ | ✅ |
| Standard mode (balance + gift + top-up detail) | ✅ | 🚧 Planned |
| Dashboard mode (cards + chart inside the floating panel) | ✅ | 🚧 Planned |
| Always-on-top toggle (can be disabled in Settings) | ✅ | ✅ |
| Menu bar / system tray resident | ✅ | ✅ |
| Menu bar icon: single-click menu, double-click pops the floating panel | ✅ | — |
| Desktop widget (WidgetKit) | ✅ | — |
| Usage dashboard (balance curve / daily usage / dual-axis, customizable cards) | ✅ | ✅ |
| Launch at login | ✅ | 🚧 Planned |
| Custom gateway (new-api / one-api) | ✅ | ✅ |
| Low-balance alert | ✅ | 🚧 Planned |

## Quick Start

### Getting an API Key

The app reads your balance with a DeepSeek **API Key**. Your key never leaves your machine.

1. Open [platform.deepseek.com](https://platform.deepseek.com) → **Sign up / Log in** (email or phone).
2. **Top up** a small amount if the balance is 0 (new accounts get a small free grant).
3. **API Keys → Create new API key** → copy the `sk-…` string.
4. Launch the app — the Settings window opens automatically on first launch. Paste the key and click **Save**.

> In Settings, the blue link **"How to get an API Key?"** (bottom of the General tab) opens the official API Keys page directly. Full walkthrough with screenshots: [User Guide](./docs/USAGE-GUIDE.md) · [中文使用指南](./docs/USAGE-GUIDE.zh-CN.md)

| Settings | Floating panel | Dashboard |
|---|---|---|
| ![settings](docs/screenshots/settings-general.png) | ![panel](docs/screenshots/panel-dashboard-mode.png) | ![dashboard](docs/screenshots/dashboard.png) |

> Balance is **account-level, not per-key** — any key of the same account returns the same total. Multi-account switching is available via the **+ / −** buttons in Settings.

### macOS (macOS 13+)

```bash
cd apps/macos
./build.sh          # Build app + widget + dashboard (requires Xcode Command Line Tools)
open DeepSeekUsagePanel.app
```

On first launch the Settings window opens automatically — paste your API Key (`sk-…`) and save. The app then lives in the **menu bar (¥ icon)**: single-click opens the menu; **double-click pops the floating panel**; the menu offers Dashboard, Settings, Launch at Login and Quit.

**Always on top**: the panel stays above all windows by default; uncheck *Settings → Window always on top* to let it behave like a normal window.

**Data storage**: config & balance history live in `~/Library/Application Support/DeepSeekUsagePanel/` (API Key is also written to Keychain as a fallback). Local builds use non-sandboxed mode (ad-hoc signing without an Apple Developer team id, so App Group & sandbox file access are unavailable); **the App Store build will restore sandbox + App Group** (the desktop widget will then read the shared balance directly).

**Desktop widget** (macOS 14+): right-click the desktop → Edit Widgets → search **DeepSeek**, drag it to the desktop (small / medium sizes, refreshes every 15 minutes).

### Windows (Tauri 2)

```bash
cd apps/windows
npm install
npx tauri dev       # development
npx tauri build     # NSIS installer (output in src-tauri/target/release/bundle/nsis/)
```

The Windows build ships a transparent borderless floating panel + system tray + usage dashboard; data lives in `%APPDATA%/deepseek-usage-app/`.

## Data Source & Semantics

- **Official API**: `GET https://api.deepseek.com/user/balance` (Bearer Key auth) returns account-level balance (top-ups + gifts combined). **Balance is account-level, not per-key** — any key of the same account returns the same total.
- **Custom gateway**: compatible with new-api / one-api style OpenAI gateways; auto-probes `{gateway}/user/balance` and `{gateway}/v1/user/balance`, supporting both DeepSeek and OpenAI response formats.
- **Usage dashboard**: there is no public per-day usage endpoint (the web console uses an internal API). The dashboard derives both dimensions from **locally recorded balance history**: **balance** (line) and **usage** (drop between consecutive balances = consumption; rise = top-up/gift). Three chart modes (balance trend / daily usage / dual-axis balance+usage) and selectable cards (balance, today, total, top-ups, days recorded, peak balance); settings persist in the dashboard's localStorage (shared across platforms). Per-key / per-model daily detail requires gateway-side billing (phase 2).
- **Low-balance alert**: total balance < ¥20 turns orange, < ¥5 turns red.

## Security & Privacy

- API Key **never leaves your machine**: macOS stores it in `~/Library/Application Support/DeepSeekUsagePanel/config.json` plus a Keychain fallback; Windows in `%APPDATA%/deepseek-usage-app`.
- The app **collects and uploads nothing** — all requests go only to your configured DeepSeek endpoint or your own gateway.
- Fully open source: the key storage path is visible and auditable.

## Project Layout

```
deepseek-usage-app/
├── apps/
│   ├── macos/            # Swift/AppKit native (floating panel + WidgetKit + dashboard window)
│   │   ├── DeepSeekUsagePanel.swift
│   │   ├── widget/       # WidgetKit extension
│   │   └── build.sh      # one-shot build (arm64 + x86_64 + sign)
│   └── windows/          # Tauri 2 (Rust): floating panel + system tray + dashboard
│       ├── src-tauri/    # Rust backend + tauri.conf.json
│       └── src/          # frontend (panel / settings)
├── shared/
│   └── ui/               # cross-platform dashboard Web UI (ECharts)
└── .github/workflows/    # CI: automated macOS / Windows builds
```

## Development & Contributing

- The macOS app is a single-file Swift app (no Xcode project): edit `apps/macos/DeepSeekUsagePanel.swift`, then `./build.sh`.
- The Windows app is a standard Tauri 2 project: Rust logic in `src-tauri/src/lib.rs`, static-HTML frontend.
- The dashboard UI (`shared/ui/dashboard.html`) is shared: macOS injects `window.__DS_DATA__` from the host; Tauri fetches it via `invoke`.
- Issues & PRs are welcome. GitHub Actions builds both platforms automatically (tag `v*` to publish a Release).

## Roadmap

- [ ] Windows: standard mode, launch at login, low-balance alert
- [ ] Per-day usage detail (gateway billing / local proxy accounting)
- [ ] App Store release (requires Apple Developer Program + proper signing/notarization; the project is already structured for sandboxing)

## License

[MIT](./LICENSE) © 2026 DeepSeek Usage App contributors

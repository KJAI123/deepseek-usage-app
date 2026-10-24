# DeepSeek Usage Panel — User Guide

A tiny always-on-top floating panel that shows your DeepSeek API balance, with a usage dashboard and a desktop widget.

![Settings](screenshots/settings-general.png)
![Floating panel](screenshots/panel-dashboard-mode.png)
![Usage dashboard](screenshots/dashboard.png)

## 1. Get an API Key (first launch)

The app needs a DeepSeek **API Key** to read your account balance. Your key never leaves your machine.

1. Open <https://platform.deepseek.com> and **Sign up / Log in** (email or phone).
2. **Top up** a small amount if the balance is 0 (API usage is prepaid; the platform gives a small free grant for new accounts).
3. Go to **API Keys → Create new API key**, name it (e.g. `floating-panel`), and copy the `sk-…` string.
4. Launch the app — the Settings window opens automatically on first launch. Paste the key into the **API Key** field and click **Save**.

> In Settings, the blue link **"How to get an API Key?"** (bottom of the General tab) opens the official API Keys page directly.

**Tip**: balance is **account-level, not per-key** — every key of the same account returns the same total, so you can create several keys and paste any of them. To switch accounts, use the **+ / −** buttons next to the Account selector (multi-account support).

## 2. The floating panel

The app lives in the **menu bar (¥ icon)**. Click the icon to show/hide the panel.

Three display modes (Settings → Display Mode):

| Mode | What it shows |
|---|---|
| **Minimal** | Total balance only |
| **Standard** | Balance + granted + top-up detail |
| **Dashboard** | Cards + mini usage chart inside the panel |

The panel refreshes automatically (default every 30 s). Drag the window title area to move it. Use the **Pin** button in the top-right corner (or Settings → Window always on top) to keep it above all windows — disable it to let the panel behave like a normal window.

## 3. Usage dashboard

Menu → **Dashboard…** (or press `⌘D`) opens the full dashboard:

- Six key cards: **Balance, Today, Total Usage, Top-ups, Days recorded, Peak balance** (+ estimated **Days Left**)
- Balance trend + daily usage chart (one day per column)
- Time ranges: **Last 7 Days / Last 30 Days / All**
- **Customize** lets you show/hide cards and switch chart modes (balance trend / daily usage / dual-axis), toggle the chart, and keep the dashboard window on top — choices persist.

## 4. Settings

| Tab | What you can configure |
|---|---|
| **General** | Account, API Key (Show to reveal), Display Mode, Data Source, Gateway URL, Refresh Interval, API-Key guide |
| **Appearance** | Accent color (8 Apple-style colors), panel opacity, light/dark/system appearance, language (中文 / English), always-on-top |
| **Dashboard** | Which cards are shown, default time range, show/hide chart, dashboard-window-on-top |
| **Alerts** | Low-balance threshold notification, clear history, export history CSV |

## 5. Data source & semantics

- **Official API**: `GET https://api.deepseek.com/user/balance` (Bearer-key auth) — account-level balance, refreshed on your chosen interval.
- **Custom gateway**: compatible with new-api / one-api gateways; auto-probes `{gateway}/user/balance` and `{gateway}/v1/user/balance` (DeepSeek and OpenAI response formats).
- **Usage chart**: there is no public per-day usage endpoint, so the dashboard derives usage from **locally recorded balance history** — balance (line) and daily usage (drop between consecutive balances; a rise means a top-up/grant).

## 6. Data & privacy

- Data lives in `~/Library/Application Support/DeepSeekUsagePanel/` (macOS) or `%APPDATA%/deepseek-usage-app/` (Windows). The API Key is also stored in the macOS Keychain as a fallback.
- The app collects and uploads **nothing** — all requests go only to your configured DeepSeek endpoint or your own gateway.

## 7. Troubleshooting

| Issue | Fix |
|---|---|
| Panel shows "No API Key" | Open Settings, paste your `sk-…` key, Save |
| "Key invalid or expired" | Recreate the key on the platform; check that you didn't paste extra spaces |
| Balance stays 0 | Top up on the platform first |
| Custom gateway not working | Make sure the URL points at a new-api/one-api style gateway and optionally ends with `/v1` |
| Widget shows nothing (macOS 14+) | Right-click desktop → Edit Widgets → add **DeepSeek**; it refreshes every 15 minutes |

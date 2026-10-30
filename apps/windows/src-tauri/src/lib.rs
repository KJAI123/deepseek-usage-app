// DeepSeek 用量面板（Windows / Tauri 2）
// 悬浮窗（透明无边框）+ 系统托盘 + 用量看板（shared/ui）+ 本地数据存储
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

#[derive(Serialize, Deserialize, Clone, Default)]
struct Config {
    api_key: String,
    base_url: String,
    refresh_interval: u64,
    #[serde(default = "default_true")]
    always_on_top: bool,
    /// 显示货币：0=自动跟随 API，1=人民币，2=美元（按汇率换算显示）
    #[serde(default)]
    display_currency: u64,
    /// 数据源：deepseek / zhipu / custom
    #[serde(default)]
    provider: String,
    /// 并列显示的第二个账号（留空则不显示）
    #[serde(default)]
    second_api_key: String,
    /// 第二个账号的数据源：deepseek / zhipu
    #[serde(default)]
    second_provider: String,
}

fn default_true() -> bool {
    true
}

impl Config {
    fn normalized(&self) -> Config {
        Config {
            api_key: self.api_key.trim().to_string(),
            base_url: if self.base_url.trim().is_empty() {
                "https://api.deepseek.com".to_string()
            } else {
                self.base_url.trim_end_matches('/').to_string()
            },
            refresh_interval: if self.refresh_interval == 0 { 60 } else { self.refresh_interval },
            always_on_top: self.always_on_top,
            display_currency: if self.display_currency > 2 { 0 } else { self.display_currency },
            provider: match self.provider.trim() {
                "zhipu" => "zhipu".to_string(),
                "custom" => "custom".to_string(),
                _ => "deepseek".to_string(),
            },
            second_api_key: self.second_api_key.trim().to_string(),
            second_provider: match self.second_provider.trim() {
                "zhipu" => "zhipu".to_string(),
                "custom" => "custom".to_string(),
                "" => String::new(),
                _ => "deepseek".to_string(),
            },
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Default)]
struct Balance {
    total: String,
    granted: Option<String>,
    topped: Option<String>,
    available: bool,
    error: Option<String>,
    updated_at: u64,
    /// API 返回币种（如 CNY / USD），供"自动跟随"显示
    #[serde(default)]
    currency: String,
    #[serde(default)]
    provider: String,
    #[serde(default)]
    plan: String,
    #[serde(default)]
    plan_until: String,
    #[serde(default)]
    q5_pct: i64,
    #[serde(default)]
    q5_total: i64,
    #[serde(default)]
    q5_used: i64,
    #[serde(default)]
    q5_reset: String,
    #[serde(default)]
    qw_pct: i64,
    #[serde(default)]
    qw_total: i64,
    #[serde(default)]
    qw_used: i64,
    #[serde(default)]
    qw_reset: String,
    /// 并列：副账号快照
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secondary: Option<Box<Balance>>,
}

// ---------- 本地数据（%APPDATA%/deepseek-usage-app） ----------
fn data_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("deepseek-usage-app")
}

fn read_json<T: for<'a> Deserialize<'a>>(name: &str) -> Option<T> {
    let p = data_dir().join(name);
    let data = fs::read(&p).ok()?;
    serde_json::from_slice(&data).ok()
}

fn write_json<T: Serialize>(name: &str, val: &T) {
    let dir = data_dir();
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    if let Ok(data) = serde_json::to_vec_pretty(val) {
        let _ = fs::write(dir.join(name), data);
    }
}

/// 毫秒时间戳 → "MM-dd HH:mm"（固定东八区，免第三方依赖）
fn fmt_reset_ts(ms: i64) -> String {
    if ms <= 0 { return String::new(); }
    let secs = ms / 1000 + 8 * 3600;
    let days = secs / 86400;
    let rem = secs % 86400;
    let (hh, mm) = (rem / 3600, (rem % 3600) / 60);
    // 1970-01-01 起的天数 → 公历年月日（Howard Hinnant 算法）
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let _ = y;
    format!("{:02}-{:02} {:02}:{:02}", m, d, hh, mm)
}

fn now_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------- Commands ----------
#[tauri::command]
fn get_config() -> Config {
    read_json("config.json").unwrap_or_default()
}

#[tauri::command]
fn save_config(cfg: Config) {
    write_json("config.json", &cfg.normalized());
}

/// 切换悬浮窗是否始终置顶，并持久化到 config.json
#[tauri::command]
fn set_always_on_top(window: tauri::Window, enabled: bool) {
    let _ = window.set_always_on_top(enabled);
    let mut cfg: Config = read_json("config.json").unwrap_or_default();
    cfg.always_on_top = enabled;
    write_json("config.json", &cfg.normalized());
}

#[tauri::command]
fn get_balance_cached() -> Balance {
    read_json("balance.json").unwrap_or_default()
}

#[tauri::command]
fn get_history() -> Vec<serde_json::Value> {
    let provider = get_config().normalized().provider;
    let entries: Vec<serde_json::Value> = read_json("history.json").unwrap_or_default();
    entries
        .into_iter()
        .filter(|e| {
            let acct = e.get("acct").and_then(|v| v.as_str()).unwrap_or("deepseek");
            acct == provider
        })
        .collect()
}

/// 指定数据源的余额历史（看板并列时切到副账号画曲线用）
#[tauri::command]
fn history_for(provider: String) -> Vec<serde_json::Value> {
    let entries: Vec<serde_json::Value> = read_json("history.json").unwrap_or_default();
    entries
        .into_iter()
        .filter(|e| {
            let acct = e.get("acct").and_then(|v| v.as_str()).unwrap_or("deepseek");
            acct == provider
        })
        .collect()
}

fn append_history(total: &str, provider: &str) {
    let mut entries: Vec<serde_json::Value> = read_json("history.json").unwrap_or_default();
    let ts = now_ts();
    if let Some(last) = entries.last() {
        if let Some(last_ts) = last.get("ts").and_then(|v| v.as_u64()) {
            let last_provider = last.get("acct").and_then(|v| v.as_str()).unwrap_or("deepseek");
            if ts - last_ts < 5 && last_provider == provider {
                entries.pop();
            }
        }
    }
    entries.push(serde_json::json!({ "ts": ts, "total": total, "acct": provider }));
    // 保留近 90 天 / 最多 1000 条
    let cutoff = now_ts().saturating_sub(86400 * 90);
    entries.retain(|e| e.get("ts").and_then(|v| v.as_u64()).unwrap_or(0) > cutoff);
    if entries.len() > 1000 {
        entries = entries[entries.len() - 1000..].to_vec();
    }
    write_json("history.json", &entries);
}

#[tauri::command]
fn refresh() -> Balance {
    let cfg = get_config().normalized();
    let mut primary = refresh_primary(&cfg, true);
    // 并列：配置了第二个账号就一起拉，失败只影响副块
    if !cfg.second_api_key.is_empty() {
        let secondary_cfg = Config {
            api_key: cfg.second_api_key.clone(),
            provider: if cfg.second_provider.is_empty() {
                "deepseek".to_string()
            } else {
                cfg.second_provider.clone()
            },
            ..cfg.clone()
        };
        primary.secondary = Some(Box::new(refresh_primary(&secondary_cfg, false)));
    }
    primary
}

/// 拉取单个账号；persist=false 时不写 balance.json / history（副账号用）
fn refresh_primary(cfg: &Config, persist: bool) -> Balance {
    if cfg.api_key.is_empty() {
        return Balance {
            error: Some("未设置 API Key，请在设置中填写".into()),
            ..Default::default()
        };
    }

    let client = match reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
    {
        Ok(c) => c,
        Err(_) => {
            return Balance {
                error: Some("HTTP 客户端初始化失败".into()),
                ..Default::default()
            }
        }
    };

    if cfg.provider == "zhipu" {
        return refresh_zhipu(&client, cfg, persist);
    }

    // 自动探测 {base}/user/balance 与 {base}/v1/user/balance
    let candidates = vec![
        format!("{}/user/balance", cfg.base_url),
        format!("{}/v1/user/balance", cfg.base_url),
    ];
    let mut last_err = "请求失败".to_string();
    let mut parsed: Option<serde_json::Value> = None;
    for url in candidates {
        let req = client.get(&url).bearer_auth(&cfg.api_key);
        match req.send() {
            Ok(resp) => {
                if resp.status().is_success() {
                    if let Ok(v) = resp.json::<serde_json::Value>() {
                        parsed = Some(v);
                        break;
                    }
                } else {
                    last_err = format!("HTTP {}", resp.status());
                }
            }
            Err(e) => last_err = e.to_string(),
        }
    }

    let v = match parsed {
        Some(v) => v,
        None => {
            return Balance {
                error: Some(last_err),
                ..Default::default()
            }
        }
    };

    // DeepSeek 格式: { is_available, balance_infos: [{currency, total_balance, granted_balance, topped_up_balance}] }
    // OpenAI 格式: { total_available, total_used, ... }
    let available = v.get("is_available").and_then(|x| x.as_bool()).unwrap_or(true);
    let mut total = String::new();
    let mut granted: Option<String> = None;
    let mut topped: Option<String> = None;
    let mut currency = String::new();

    if let Some(infos) = v.get("balance_infos").and_then(|x| x.as_array()) {
        if let Some(first) = infos.first() {
            if let Some(t) = first.get("total_balance").and_then(|x| x.as_str()) {
                total = t.to_string();
            }
            granted = first.get("granted_balance").and_then(|x| x.as_str()).map(|s| s.to_string());
            topped = first.get("topped_up_balance").and_then(|x| x.as_str()).map(|s| s.to_string());
            currency = first.get("currency").and_then(|x| x.as_str()).unwrap_or("CNY").to_string();
        }
    }
    if total.is_empty() {
        if let Some(t) = v.get("total_available").and_then(|x| x.as_f64()) {
            total = format!("{:.2}", t);
        }
    }
    if total.is_empty() {
        return Balance {
            error: Some("响应格式无法解析".into()),
            ..Default::default()
        };
    }

    let b = Balance {
        total,
        granted,
        topped,
        available,
        error: None,
        updated_at: now_ts(),
        currency: currency.to_uppercase(),
        provider: cfg.provider.clone(),
        plan: String::new(),
        plan_until: String::new(),
        q5_pct: -1,
        q5_total: 0,
        q5_used: 0,
        q5_reset: String::new(),
        qw_pct: -1,
        qw_total: 0,
        qw_used: 0,
        qw_reset: String::new(),
        secondary: None,
    };
    if persist {
        write_json("balance.json", &b);
        append_history(&b.total, &b.provider);
    }
    b
}

/// 智谱 AI（GLM）：可用余额 + Coding Plan 套餐名/到期日
/// 业务码约定：code == 200 才算成功（不是 0）
fn refresh_zhipu(client: &reqwest::blocking::Client, cfg: &Config, persist: bool) -> Balance {
    let mut last_err = "请求失败".to_string();

    // 1) 财务总览：data.availableTotalBalance
    let overview = client
        .get("https://open.bigmodel.cn/api/biz/account/finance-overview")
        .bearer_auth(&cfg.api_key)
        .send();
    let mut total: Option<f64> = None;
    match overview {
        Ok(resp) => {
            let status = resp.status();
            if let Ok(v) = resp.json::<serde_json::Value>() {
                let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(-1);
                if code == 200 {
                    total = v
                        .get("data")
                        .and_then(|d| d.get("availableTotalBalance"))
                        .and_then(|x| x.as_f64());
                } else {
                    last_err = v
                        .get("msg")
                        .and_then(|x| x.as_str())
                        .unwrap_or("智谱接口返回异常")
                        .to_string();
                }
            } else {
                last_err = format!("HTTP {}", status);
            }
        }
        Err(e) => last_err = e.to_string(),
    }

    let total = match total {
        Some(t) => t,
        None => {
            return Balance {
                provider: "zhipu".into(),
                error: Some(last_err),
                updated_at: now_ts(),
                ..Default::default()
            }
        }
    };

    // 2) 订阅列表：取 status == VALID 的套餐
    let mut plan = String::new();
    let mut plan_until = String::new();
    if let Ok(resp) = client
        .get("https://open.bigmodel.cn/api/biz/subscription/list")
        .bearer_auth(&cfg.api_key)
        .send()
    {
        if let Ok(v) = resp.json::<serde_json::Value>() {
            if v.get("code").and_then(|x| x.as_i64()).unwrap_or(-1) == 200 {
                if let Some(list) = v.get("data").and_then(|x| x.as_array()) {
                    for item in list {
                        if item.get("status").and_then(|x| x.as_str()) == Some("VALID") {
                            plan = item
                                .get("productName")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            // valid 形如 "2026-12-07 10:00:00-2027-03-07 10:00:00"，取最后一个日期
                            if let Some(valid) = item.get("valid").and_then(|x| x.as_str()) {
                                let dates: Vec<&str> =
                                    valid.split(|c: char| !c.is_ascii_digit() && c != '-').filter(|s| s.len() == 10).collect();
                                if let Some(d) = dates.last() {
                                    plan_until = d.to_string();
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }
    }

    // 3) Coding Plan 额度：/api/monitor/usage/quota/limit
    let mut q5_pct = -1i64;
    let mut q5_total = 0i64;
    let mut q5_used = 0i64;
    let mut q5_reset = String::new();
    let mut qw_pct = -1i64;
    let mut qw_total = 0i64;
    let mut qw_used = 0i64;
    let mut qw_reset = String::new();
    if let Ok(resp) = client
        .get("https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        .bearer_auth(&cfg.api_key)
        .send()
    {
        if let Ok(v) = resp.json::<serde_json::Value>() {
            if (v.get("code").and_then(|x| x.as_i64()).unwrap_or(-1)) == 200 {
                if let Some(limits) = v.get("data").and_then(|d| d.get("limits")).and_then(|x| x.as_array()) {
                    let mut parsed: Vec<(i64, i64, i64, String)> = limits
                        .iter()
                        .filter_map(|it| {
                            let total = it.get("usage").and_then(|x| x.as_i64()).unwrap_or(0);
                            let used = it.get("currentValue").and_then(|x| x.as_i64()).unwrap_or(0);
                            let pct = it.get("percentage").and_then(|x| x.as_i64()).unwrap_or(0);
                            let reset = it
                                .get("nextResetTime")
                                .and_then(|x| x.as_i64())
                                .map(|ms| {
                                    // 毫秒时间戳 → 本地 MM-dd HH:mm
                                    fmt_reset_ts(ms)
                                })
                                .unwrap_or_default();
                            if total > 0 { Some((total, used, pct, reset)) } else { None }
                        })
                        .collect();
                    parsed.sort_by_key(|p| p.0);
                    if parsed.len() >= 2 {
                        q5_total = parsed[0].0; q5_used = parsed[0].1; q5_pct = parsed[0].2; q5_reset = parsed[0].3.clone();
                        qw_total = parsed[1].0; qw_used = parsed[1].1; qw_pct = parsed[1].2; qw_reset = parsed[1].3.clone();
                    }
                }
            }
        }
    }

    let b = Balance {
        total: format!("{:.2}", total),
        granted: None,
        topped: None,
        available: true,
        error: None,
        updated_at: now_ts(),
        currency: "CNY".into(),
        provider: "zhipu".into(),
        plan,
        plan_until,
        q5_pct,
        q5_total,
        q5_used,
        q5_reset,
        qw_pct,
        qw_total,
        qw_used,
        qw_reset,
        secondary: None,
    };
    if persist {
        write_json("balance.json", &b);
        append_history(&b.total, &b.provider);
    }
    b
}

// ---------- 窗口 ----------
fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}

#[tauri::command]
fn open_dashboard(app: tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("dashboard") {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    if let Ok(w) = WebviewWindowBuilder::new(&app, "dashboard", WebviewUrl::App("dashboard.html".into()))
        .title("DeepSeek 用量看板")
        .inner_size(820.0, 560.0)
        .min_inner_size(600.0, 400.0)
        .build()
    {
        let _ = w.show();
    }
}

#[tauri::command]
fn open_settings(app: tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    if let Ok(w) = WebviewWindowBuilder::new(&app, "settings", WebviewUrl::App("settings.html".into()))
        .title("设置")
        .inner_size(420.0, 320.0)
        .resizable(false)
        .build()
    {
        let _ = w.show();
    }
}

// ---------- 托盘 ----------
fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let show_item = MenuItemBuilder::with_id("toggle", "显示/隐藏面板").build(app)?;
    let dashboard_item = MenuItemBuilder::with_id("dashboard", "用量看板…").build(app)?;
    let settings_item = MenuItemBuilder::with_id("settings", "设置…").build(app)?;
    let quit_item = MenuItemBuilder::with_id("quit", "退出").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&show_item)
        .item(&dashboard_item)
        .item(&settings_item)
        .separator()
        .item(&quit_item)
        .build()?;

    let _tray = TrayIconBuilder::with_id("main-tray")
        .icon(app.default_window_icon().unwrap().clone())
        .tooltip("DeepSeek 用量面板")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "toggle" => {
                if let Some(w) = app.get_webview_window("main") {
                    if w.is_visible().unwrap_or(false) {
                        let _ = w.hide();
                    } else {
                        show_main(app);
                    }
                }
            }
            "dashboard" => {
                let _ = open_dashboard(app.clone());
            }
            "settings" => {
                let _ = open_settings(app.clone());
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(w) = app.get_webview_window("main") {
                    if w.is_visible().unwrap_or(false) {
                        let _ = w.hide();
                    } else {
                        show_main(app);
                    }
                }
            }
        })
        .build(app)?;

    app.manage(_tray);
    Ok(())
}

// ---------- 入口 ----------
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            setup_tray(app)?;
            // 悬浮窗定位到主屏右上角
            if let Ok(Some(monitor)) = app.primary_monitor() {
                let size = monitor.size();
                let scale = monitor.scale_factor();
                let w = 340.0 * scale as f64;
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.set_position(tauri::PhysicalPosition::new(
                        (size.width as f64 - w - 24.0 * scale as f64) as i32,
                        (size.height as f64 - 120.0 * scale as f64 - 24.0 * scale as f64) as i32,
                    ));
                }
            }
            // 按已保存配置应用置顶状态（默认置顶）
            let cfg: Config = read_json("config.json").unwrap_or_default();
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.set_always_on_top(cfg.always_on_top);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            set_always_on_top,
            get_balance_cached,
            get_history,
            history_for,
            refresh,
            open_dashboard,
            open_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

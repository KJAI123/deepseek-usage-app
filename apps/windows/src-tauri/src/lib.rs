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
    read_json("history.json").unwrap_or_default()
}

fn append_history(total: &str) {
    let mut entries: Vec<serde_json::Value> = read_json("history.json").unwrap_or_default();
    let ts = now_ts();
    if let Some(last) = entries.last() {
        if let Some(last_ts) = last.get("ts").and_then(|v| v.as_u64()) {
            if ts - last_ts < 5 {
                entries.pop();
            }
        }
    }
    entries.push(serde_json::json!({ "ts": ts, "total": total }));
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

    if let Some(infos) = v.get("balance_infos").and_then(|x| x.as_array()) {
        if let Some(first) = infos.first() {
            if let Some(t) = first.get("total_balance").and_then(|x| x.as_str()) {
                total = t.to_string();
            }
            granted = first.get("granted_balance").and_then(|x| x.as_str()).map(|s| s.to_string());
            topped = first.get("topped_up_balance").and_then(|x| x.as_str()).map(|s| s.to_string());
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
    };
    write_json("balance.json", &b);
    append_history(&b.total);
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
            refresh,
            open_dashboard,
            open_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

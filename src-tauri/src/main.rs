#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod auth;
mod autostart;
mod overlay;
mod screenshot;

use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            // Overlay
            overlay::show_overlay,
            overlay::hide_overlay,
            overlay::hide_all_overlays,
            // Auth
            auth::start_oidc_flow,
            auth::keyring_store,
            auth::keyring_read,
            auth::keyring_delete,
            // Screenshot
            screenshot::capture_screenshot,
            // Autostart
            autostart::get_autostart_enabled,
            autostart::set_autostart_enabled,
        ])
        .setup(|app| {
            // --- System tray ---
            let settings = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
            let capture = MenuItem::with_id(app, "capture", "Capture Screen", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &capture, &quit])?;

            TrayIconBuilder::new()
                .tooltip("Sewa Companion")
                .menu(&menu)
                .on_menu_event(move |app, event| {
                    let id = event.id().as_ref();
                    match id {
                        "quit" => app.exit(0),
                        "settings" => {
                            if let Some(win) = app.get_webview_window("main") {
                                let _ = win.show();
                                let _ = win.set_focus();
                                let _ = win.emit("toggle-settings", ());
                            }
                        }
                        "capture" => {
                            if let Some(win) = app.get_webview_window("main") {
                                let _ = win.emit("manual-screenshot", ());
                            }
                        }
                        _ => {}
                    }
                })
                .build(app)?;

            // --- Global Escape shortcut to dismiss overlays ---
            let escape = Shortcut::new(Some(Modifiers::empty()), Code::Escape);
            let escape_handle = app.handle().clone();

            app.global_shortcut().on_shortcut(
                escape,
                move |_app, _shortcut, event| {
                    if event.state == ShortcutState::Pressed {
                        let _ = overlay::hide_all_overlays(escape_handle.clone());
                        for window in _app.webview_windows().values() {
                            if window.label().starts_with("overlay-") {
                                let _ = window.emit("pointer-dismissed", ());
                            }
                        }
                    }
                },
            )?;

            // --- Push-to-talk hotkey (Ctrl+Space default) ---
            let ptt = Shortcut::new(Some(Modifiers::CONTROL), Code::Space);

            app.global_shortcut().on_shortcut(
                ptt,
                move |_app, _shortcut, event| {
                    if let Some(win) = _app.get_webview_window("main") {
                        match event.state {
                            ShortcutState::Pressed => {
                                let _ = win.emit("hotkey-down", ());
                            }
                            ShortcutState::Released => {
                                let _ = win.emit("hotkey-up", ());
                            }
                        }
                    }
                },
            )?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running sewa-companion");
}

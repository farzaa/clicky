#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod overlay;

use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            overlay::show_overlay,
            overlay::hide_overlay,
            overlay::hide_all_overlays,
        ])
        .setup(|app| {
            // System tray
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&quit])?;

            TrayIconBuilder::new()
                .tooltip("Sewa Companion")
                .menu(&menu)
                .on_menu_event(|app, event| {
                    if event.id() == "quit" {
                        app.exit(0);
                    }
                })
                .build(app)?;

            // Global Escape shortcut to dismiss overlays
            let escape = Shortcut::new(Some(Modifiers::empty()), Code::Escape);
            let escape_handle = app.handle().clone();

            app.global_shortcut().on_shortcut(escape, move |_app, _shortcut, event| {
                if event.state == ShortcutState::Pressed {
                    let _ = overlay::hide_all_overlays(escape_handle.clone());
                    for window in _app.webview_windows().values() {
                        if window.label().starts_with("overlay-") {
                            let _ = window.emit("pointer-dismissed", ());
                        }
                    }
                }
            })?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running sewa-companion");
}

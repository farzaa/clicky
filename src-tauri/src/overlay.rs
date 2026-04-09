// src-tauri/src/overlay.rs
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

fn advance_shortcuts() -> [Shortcut; 2] {
    [
        Shortcut::new(Some(Modifiers::empty()), Code::Space),
        Shortcut::new(Some(Modifiers::empty()), Code::ArrowRight),
    ]
}

/// Register Space/Right Arrow global shortcuts for chain step advancement.
/// Only active while an overlay is visible so they don't steal keypresses.
fn register_advance_shortcuts(app: &AppHandle) {
    let gs = app.global_shortcut();
    for shortcut in advance_shortcuts() {
        if gs.is_registered(shortcut) {
            continue;
        }
        let _ = gs.on_shortcut(shortcut, |_app, _shortcut, event| {
            if event.state == ShortcutState::Pressed {
                for window in _app.webview_windows().values() {
                    if window.label().starts_with("overlay-") {
                        let _ = window.emit("pointer-advance", ());
                    }
                }
            }
        });
    }
}

/// Unregister chain-advance shortcuts when no overlays are visible.
fn unregister_advance_shortcuts(app: &AppHandle) {
    let gs = app.global_shortcut();
    for shortcut in advance_shortcuts() {
        let _ = gs.unregister(shortcut);
    }
}

/// Create or show the overlay window for a given screen index.
#[tauri::command]
pub fn show_overlay(app: AppHandle, screen: u32) -> Result<(), String> {
    let label = format!("overlay-{}", screen);

    // If window already exists, just show it
    if let Some(window) = app.get_webview_window(&label) {
        window.show().map_err(|e| e.to_string())?;
        return Ok(());
    }

    // Find the target monitor
    let monitors = app.available_monitors().map_err(|e| e.to_string())?;
    let monitor = monitors
        .into_iter()
        .nth(screen as usize)
        .ok_or_else(|| format!("Monitor {} not found", screen))?;

    let position = monitor.position();
    let size = monitor.size();

    // Create transparent, always-on-top, click-through overlay
    let window = WebviewWindowBuilder::new(&app, &label, WebviewUrl::App("overlay.html".into()))
        .title("")
        .inner_size(size.width as f64, size.height as f64)
        .position(position.x as f64, position.y as f64)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())?;

    window
        .set_ignore_cursor_events(true)
        .map_err(|e| e.to_string())?;
    window.show().map_err(|e| e.to_string())?;

    register_advance_shortcuts(&app);

    Ok(())
}

/// Hide the overlay window for a given screen index.
#[tauri::command]
pub fn hide_overlay(app: AppHandle, screen: u32) -> Result<(), String> {
    let label = format!("overlay-{}", screen);
    if let Some(window) = app.get_webview_window(&label) {
        window.hide().map_err(|e| e.to_string())?;
    }

    // Unregister advance shortcuts if no overlays remain visible
    let any_visible = app
        .webview_windows()
        .values()
        .any(|w| w.label().starts_with("overlay-") && w.is_visible().unwrap_or(false));
    if !any_visible {
        unregister_advance_shortcuts(&app);
    }

    Ok(())
}

/// Hide all overlay windows (triggered by Escape).
#[tauri::command]
pub fn hide_all_overlays(app: AppHandle) -> Result<(), String> {
    for window in app.webview_windows().values() {
        if window.label().starts_with("overlay-") {
            let _ = window.hide();
        }
    }
    unregister_advance_shortcuts(&app);
    Ok(())
}

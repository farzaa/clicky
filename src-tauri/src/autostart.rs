// XDG autostart .desktop file management
use std::fs;
use std::path::PathBuf;
use tauri::command;

fn autostart_dir() -> PathBuf {
    dirs::config_dir()
        .or_else(|| dirs::home_dir().map(|h| h.join(".config")))
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("autostart")
}

fn desktop_file_path() -> PathBuf {
    autostart_dir().join("sewa-companion.desktop")
}

fn desktop_entry() -> String {
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "sewa-companion".to_string());

    format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Sewa Companion\n\
         Exec={}\n\
         StartupNotify=false\n\
         Terminal=false\n\
         Comment=Sewa AI companion for voice, screen, and pointer overlay\n",
        exe
    )
}

#[command]
pub fn get_autostart_enabled() -> bool {
    desktop_file_path().exists()
}

#[command]
pub fn set_autostart_enabled(enabled: bool) -> Result<(), String> {
    let path = desktop_file_path();

    if enabled {
        let dir = autostart_dir();
        fs::create_dir_all(&dir)
            .map_err(|e| format!("Failed to create autostart dir: {}", e))?;

        fs::write(&path, desktop_entry())
            .map_err(|e| format!("Failed to write .desktop file: {}", e))?;
    } else if path.exists() {
        fs::remove_file(&path)
            .map_err(|e| format!("Failed to remove .desktop file: {}", e))?;
    }

    Ok(())
}

// OIDC callback server, keyring integration, browser launch

use keyring::Entry;
use serde::Serialize;
use std::net::TcpListener;
use tauri::command;
use tiny_http::{Header, Response, Server};

const SERVICE_NAME: &str = "sewa-companion";

#[derive(Serialize)]
pub struct OidcCallbackResult {
    pub code: String,
    pub port: u16,
}

#[command]
pub fn keyring_store(key: String, value: String) -> Result<(), String> {
    let entry = Entry::new(SERVICE_NAME, &key).map_err(|e| e.to_string())?;
    entry.set_password(&value).map_err(|e| e.to_string())
}

#[command]
pub fn keyring_read(key: String) -> Result<Option<String>, String> {
    let entry = Entry::new(SERVICE_NAME, &key).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(val) => Ok(Some(val)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

#[command]
pub fn keyring_delete(key: String) -> Result<(), String> {
    let entry = Entry::new(SERVICE_NAME, &key).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

#[command]
pub async fn start_oidc_flow(
    authorize_url: String,
    client_id: String,
    redirect_path: String,
) -> Result<OidcCallbackResult, String> {
    // Find a free port
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    drop(listener);

    let redirect_uri = format!("http://127.0.0.1:{}{}", port, redirect_path);

    // Build the full authorize URL
    let full_url = format!(
        "{}&redirect_uri={}&client_id={}&response_type=code&scope=openid%20profile%20email",
        authorize_url,
        urlencoding::encode(&redirect_uri),
        urlencoding::encode(&client_id),
    );

    // Start the callback server
    let server = Server::http(format!("127.0.0.1:{}", port)).map_err(|e| e.to_string())?;

    // Open browser
    open::that(&full_url).map_err(|e| format!("Failed to open browser: {}", e))?;

    // Wait for the callback (with 120s timeout)
    let callback_port = port;
    let code = tokio::task::spawn_blocking(move || -> Result<String, String> {
        let request = server
            .recv_timeout(std::time::Duration::from_secs(120))
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "OIDC callback timed out after 120 seconds".to_string())?;

        let url = request.url().to_string();

        // Parse the code from ?code=...
        let code = url
            .split('?')
            .nth(1)
            .and_then(|query| {
                query.split('&').find_map(|param| {
                    let mut parts = param.splitn(2, '=');
                    match (parts.next(), parts.next()) {
                        (Some("code"), Some(val)) => Some(val.to_string()),
                        _ => None,
                    }
                })
            })
            .ok_or_else(|| "No authorization code in callback".to_string())?;

        // Respond with a success page
        let html = "<html><body><h2>Authentication successful</h2><p>You can close this tab.</p><script>window.close()</script></body></html>";
        let header = Header::from_bytes("Content-Type", "text/html").unwrap();
        let response = Response::from_string(html).with_header(header);
        let _ = request.respond(response);

        Ok(code)
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| e.to_string())?;

    Ok(OidcCallbackResult { code, port: callback_port })
}

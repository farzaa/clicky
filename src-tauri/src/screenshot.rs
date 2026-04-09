// XDG Desktop Portal capture via ashpd, JPEG compression
use ashpd::desktop::screenshot::Screenshot;
use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::ImageReader;
use std::io::Cursor;
use tauri::command;

const MAX_DIMENSION: u32 = 1280;

#[command]
pub async fn capture_screenshot(quality: Option<u8>) -> Result<String, String> {
    let jpeg_quality = quality.unwrap_or(80).clamp(50, 95);

    // Request screenshot via XDG Desktop Portal
    let response = Screenshot::request()
        .interactive(false)
        .send()
        .await
        .map_err(|e| format!("Portal request failed: {}", e))?
        .response()
        .map_err(|e| format!("Portal response failed: {}", e))?;

    // uri() returns &url::Url; .path() gives the filesystem path without file:// prefix
    let path = response.uri().path().to_owned();

    // Read and decode the image
    let img = ImageReader::open(&path)
        .map_err(|e| format!("Failed to read screenshot: {}", e))?
        .decode()
        .map_err(|e| format!("Failed to decode screenshot: {}", e))?;

    // Resize if larger than MAX_DIMENSION (preserves aspect ratio)
    let resized = if img.width() > MAX_DIMENSION || img.height() > MAX_DIMENSION {
        img.resize(MAX_DIMENSION, MAX_DIMENSION, FilterType::Lanczos3)
    } else {
        img
    };

    // Encode as JPEG with requested quality
    let mut jpeg_buf = Cursor::new(Vec::new());
    let encoder = JpegEncoder::new_with_quality(&mut jpeg_buf, jpeg_quality);
    resized
        .write_with_encoder(encoder)
        .map_err(|e| format!("JPEG encode failed: {}", e))?;

    // Base64 encode
    let b64 = base64::engine::general_purpose::STANDARD.encode(jpeg_buf.into_inner());

    // Clean up temp file (best-effort)
    let _ = std::fs::remove_file(&path);

    Ok(b64)
}

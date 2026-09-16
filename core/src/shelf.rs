use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StagedItem {
    pub id: String,
    pub original_path: String,
    pub filename: String,
    pub extension: String,
    pub size_bytes: u64,
    pub formatted_size: String,
    pub is_directory: bool,
    pub kind: String,
    pub staged_at: u64,
}

pub struct ShelfManager {
    items: Vec<StagedItem>,
    max_items: usize,
}

impl ShelfManager {
    pub fn new(max_items: usize) -> Self {
        Self {
            items: Vec::new(),
            max_items,
        }
    }

    pub fn stage_file(&mut self, path_str: &str) -> Result<StagedItem, String> {
        let clean_path = path_str.trim().trim_start_matches("file://");
        let decoded_path = urlencoding_decode(clean_path);
        let path = Path::new(&decoded_path);

        if !path.exists() {
            return Err(format!("File does not exist: {}", decoded_path));
        }

        // Don't re-stage if already present at the top; instead move to top
        if let Some(idx) = self.items.iter().position(|item| item.original_path == decoded_path) {
            let existing = self.items.remove(idx);
            self.items.insert(0, existing.clone());
            return Ok(existing);
        }

        let metadata = path.metadata().map_err(|e| e.to_string())?;
        let is_dir = metadata.is_dir();
        let size_bytes = if is_dir { 0 } else { metadata.len() };

        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("Untitled")
            .to_string();

        let extension = path
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("")
            .to_lowercase();

        let kind = detect_kind(&extension, is_dir).to_string();
        let formatted_size = format_size(size_bytes, is_dir);

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let id = format!("{}_{}", now, generate_short_id());

        let item = StagedItem {
            id,
            original_path: decoded_path,
            filename,
            extension,
            size_bytes,
            formatted_size,
            is_directory: is_dir,
            kind,
            staged_at: now,
        };

        self.items.insert(0, item.clone());
        if self.items.len() > self.max_items {
            self.items.pop();
        }

        Ok(item)
    }

    pub fn remove_item(&mut self, id: &str) -> bool {
        let initial_len = self.items.len();
        self.items.retain(|item| item.id != id);
        self.items.len() < initial_len
    }

    pub fn clear_all(&mut self) {
        self.items.clear();
    }

    pub fn get_items(&self) -> &[StagedItem] {
        &self.items
    }
}

fn detect_kind(extension: &str, is_dir: bool) -> &'static str {
    if is_dir {
        return "folder";
    }
    match extension {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "heic" | "bmp" => "image",
        "mp4" | "mov" | "mkv" | "avi" | "webm" | "m4v" => "video",
        "mp3" | "wav" | "flac" | "m4a" | "aac" | "ogg" => "audio",
        "zip" | "tar" | "gz" | "bz2" | "7z" | "rar" | "dmg" | "pkg" => "archive",
        "pdf" | "doc" | "docx" | "pages" | "txt" | "md" | "rtf" => "document",
        "rs" | "swift" | "js" | "ts" | "py" | "c" | "cpp" | "json" | "html" | "css" => "code",
        _ => "other",
    }
}

fn format_size(bytes: u64, is_dir: bool) -> String {
    if is_dir {
        return "Folder".to_string();
    }
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

fn generate_short_id() -> String {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(100);
    let val = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{:x}", val)
}

fn urlencoding_decode(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%' {
            let h1 = chars.next();
            let h2 = chars.next();
            if let (Some(c1), Some(c2)) = (h1, h2) {
                if let Ok(byte) = u8::from_str_radix(&format!("{}{}", c1, c2), 16) {
                    result.push(byte as char);
                    continue;
                }
            }
        }
        result.push(c);
    }
    result
}

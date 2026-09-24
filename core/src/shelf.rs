use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StagedItem {
    pub id: String,
    /// Items dropped together share a group and render as a single stack.
    pub group_id: String,
    pub original_path: String,
    pub filename: String,
    pub extension: String,
    pub size_bytes: u64,
    pub formatted_size: String,
    pub is_directory: bool,
    pub kind: String,
    pub staged_at: u64,
    /// True when the file lives in NotchCove's inbox (text snippets, web images,
    /// promised files, archives) and should be deleted when removed from the shelf.
    #[serde(default)]
    pub owned: bool,
}

pub struct ShelfManager {
    items: Vec<StagedItem>,
    max_items: usize,
    storage_dir: Option<PathBuf>,
}

impl ShelfManager {
    pub fn new(max_items: usize) -> Self {
        Self {
            items: Vec::new(),
            max_items,
            storage_dir: None,
        }
    }

    /// Creates a manager persisted to `storage_dir/shelf.json`, restoring any
    /// previously saved items whose files still exist.
    pub fn with_storage(max_items: usize, storage_dir: &Path) -> Self {
        let _ = fs::create_dir_all(storage_dir.join("Inbox"));
        let mut shelf = Self {
            items: Vec::new(),
            max_items,
            storage_dir: Some(storage_dir.to_path_buf()),
        };
        if let Ok(data) = fs::read_to_string(shelf.state_file().unwrap()) {
            if let Ok(items) = serde_json::from_str::<Vec<StagedItem>>(&data) {
                shelf.items = items;
            }
        }
        shelf.prune_missing();
        shelf
    }

    pub fn inbox_dir(&self) -> Option<PathBuf> {
        self.storage_dir.as_ref().map(|d| d.join("Inbox"))
    }

    fn state_file(&self) -> Option<PathBuf> {
        self.storage_dir.as_ref().map(|d| d.join("shelf.json"))
    }

    fn save(&self) {
        let Some(file) = self.state_file() else { return };
        if let Ok(json) = serde_json::to_string_pretty(&self.items) {
            let tmp = file.with_extension("json.tmp");
            if fs::write(&tmp, json).is_ok() {
                let _ = fs::rename(&tmp, &file);
            }
        }
    }

    fn is_in_inbox(&self, path: &Path) -> bool {
        self.inbox_dir()
            .map(|inbox| path.starts_with(inbox))
            .unwrap_or(false)
    }

    /// Stages a single path as its own group.
    pub fn stage_file(&mut self, path_str: &str) -> Result<StagedItem, String> {
        self.stage_files(&[path_str.to_string()])
            .and_then(|mut v| v.pop().ok_or_else(|| "Nothing staged".to_string()))
    }

    /// Stages several paths as one group (a stack). Paths already on the shelf
    /// are moved into the new group. Missing paths are skipped.
    pub fn stage_files(&mut self, paths: &[String]) -> Result<Vec<StagedItem>, String> {
        let now = now_secs();
        let group_id = format!("g{}_{}", now, next_id());
        let mut staged = Vec::new();

        for raw in paths {
            let clean = raw.trim();
            let clean = clean.strip_prefix("file://").unwrap_or(clean);
            let path = Path::new(clean);
            if !path.exists() {
                eprintln!("[NotchCove Core] Skipping missing path: {}", clean);
                continue;
            }
            let path_string = path.to_string_lossy().to_string();
            if staged.iter().any(|i: &StagedItem| i.original_path == path_string) {
                continue;
            }
            self.items.retain(|i| i.original_path != path_string);

            let metadata = path.metadata().map_err(|e| e.to_string())?;
            let is_dir = metadata.is_dir();
            let (size_bytes, size_is_partial) = if is_dir {
                dir_size(path)
            } else {
                (metadata.len(), false)
            };
            let filename = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "Untitled".to_string());
            let extension = path
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();

            staged.push(StagedItem {
                id: format!("i{}_{}", now, next_id()),
                group_id: group_id.clone(),
                kind: detect_kind(&extension, is_dir).to_string(),
                formatted_size: if size_is_partial {
                    format!("{}+", format_size(size_bytes))
                } else {
                    format_size(size_bytes)
                },
                owned: self.is_in_inbox(path),
                original_path: path_string,
                filename,
                extension,
                size_bytes,
                is_directory: is_dir,
                staged_at: now,
            });
        }

        if staged.is_empty() {
            return Err("No valid files to stage".to_string());
        }

        for (offset, item) in staged.iter().enumerate() {
            self.items.insert(offset, item.clone());
        }
        while self.items.len() > self.max_items {
            if let Some(evicted) = self.items.pop() {
                self.delete_if_owned(&evicted);
            }
        }
        self.save();
        Ok(staged)
    }

    fn delete_if_owned(&self, item: &StagedItem) {
        let path = Path::new(&item.original_path);
        if item.owned && self.is_in_inbox(path) {
            let _ = if path.is_dir() {
                fs::remove_dir_all(path)
            } else {
                fs::remove_file(path)
            };
            // Clean up the per-drop folder if it's now empty.
            if let Some(parent) = path.parent() {
                if Some(parent.to_path_buf()) != self.inbox_dir() {
                    let _ = fs::remove_dir(parent);
                }
            }
        }
    }

    /// Removes an item. Pass `delete_owned = false` when the file was moved
    /// elsewhere by a drag-out and must not be deleted.
    pub fn remove_item(&mut self, id: &str, delete_owned: bool) -> bool {
        let Some(idx) = self.items.iter().position(|i| i.id == id) else {
            return false;
        };
        let item = self.items.remove(idx);
        if delete_owned {
            self.delete_if_owned(&item);
        }
        self.save();
        true
    }

    pub fn remove_group(&mut self, group_id: &str) -> bool {
        let (removed, kept): (Vec<_>, Vec<_>) = self
            .items
            .drain(..)
            .partition(|i| i.group_id == group_id);
        self.items = kept;
        for item in &removed {
            self.delete_if_owned(item);
        }
        self.save();
        !removed.is_empty()
    }

    /// Splits a stack so each file becomes its own group.
    pub fn ungroup(&mut self, group_id: &str) -> bool {
        let mut changed = false;
        for item in self.items.iter_mut().filter(|i| i.group_id == group_id) {
            item.group_id = format!("g{}_{}", item.staged_at, next_id());
            changed = true;
        }
        if changed {
            self.save();
        }
        changed
    }

    pub fn clear_all(&mut self) {
        for item in std::mem::take(&mut self.items) {
            self.delete_if_owned(&item);
        }
        self.save();
    }

    /// Removes items staged more than `max_age_secs` before `now` (owned inbox
    /// files are deleted; user files are only taken off the shelf).
    pub fn expire_older_than(&mut self, max_age_secs: u64, now: u64) -> usize {
        let cutoff = now.saturating_sub(max_age_secs);
        let (expired, kept): (Vec<_>, Vec<_>) =
            self.items.drain(..).partition(|i| i.staged_at < cutoff);
        self.items = kept;
        for item in &expired {
            self.delete_if_owned(item);
        }
        if !expired.is_empty() {
            self.save();
        }
        expired.len()
    }

    /// Unix time at which the oldest item expires, if any.
    pub fn next_expiry(&self, max_age_secs: u64) -> Option<u64> {
        self.items.iter().map(|i| i.staged_at + max_age_secs).min()
    }

    /// Drops items whose files have been deleted or moved outside NotchCove.
    pub fn prune_missing(&mut self) -> usize {
        let before = self.items.len();
        self.items.retain(|i| Path::new(&i.original_path).exists());
        let removed = before - self.items.len();
        if removed > 0 {
            self.save();
        }
        removed
    }

    pub fn get_items(&self) -> &[StagedItem] {
        &self.items
    }
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn next_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    format!("{:x}{:x}", COUNTER.fetch_add(1, Ordering::Relaxed), nanos)
}

/// Recursive size of a folder. Staging runs on the UI thread, so the walk is
/// capped; the bool is true when the cap was hit and the size is a lower bound.
fn dir_size(path: &Path) -> (u64, bool) {
    fn walk(path: &Path, budget: &mut u32) -> u64 {
        let Ok(entries) = fs::read_dir(path) else { return 0 };
        let mut total = 0;
        for entry in entries.flatten() {
            if *budget == 0 {
                break;
            }
            *budget -= 1;
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                total += walk(&entry.path(), budget);
            } else {
                total += meta.len();
            }
        }
        total
    }
    let mut budget = 5_000;
    let total = walk(path, &mut budget);
    (total, budget == 0)
}

pub fn detect_kind(extension: &str, is_dir: bool) -> &'static str {
    if is_dir {
        return match extension {
            "app" => "app",
            _ => "folder",
        };
    }
    match extension {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "heic" | "bmp" | "tiff" | "tif" => {
            "image"
        }
        "mp4" | "mov" | "mkv" | "avi" | "webm" | "m4v" => "video",
        "mp3" | "wav" | "flac" | "m4a" | "aac" | "ogg" | "aiff" => "audio",
        "zip" | "tar" | "gz" | "bz2" | "7z" | "rar" | "dmg" | "pkg" | "xz" => "archive",
        "pdf" | "doc" | "docx" | "pages" | "txt" | "md" | "rtf" | "key" | "numbers" | "xlsx"
        | "pptx" | "csv" => "document",
        "rs" | "swift" | "js" | "ts" | "py" | "c" | "cpp" | "h" | "json" | "html" | "css"
        | "go" | "java" | "rb" | "sh" | "yml" | "yaml" | "toml" => "code",
        "webloc" | "url" => "link",
        _ => "other",
    }
}

pub fn format_size(bytes: u64) -> String {
    const KB: f64 = 1000.0;
    const MB: f64 = KB * 1000.0;
    const GB: f64 = MB * 1000.0;
    let b = bytes as f64;
    // Decimal units, matching Finder.
    if b >= GB {
        format!("{:.1} GB", b / GB)
    } else if b >= MB {
        format!("{:.1} MB", b / MB)
    } else if b >= KB {
        format!("{:.0} KB", b / KB)
    } else {
        format!("{} B", bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cove-test-{}-{}", name, next_id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(dir: &Path, name: &str, contents: &str) -> String {
        let p = dir.join(name);
        fs::write(&p, contents).unwrap();
        p.to_string_lossy().to_string()
    }

    #[test]
    fn stages_group_and_keeps_order() {
        let dir = temp_dir("group");
        let a = touch(&dir, "a.txt", "a");
        let b = touch(&dir, "b.png", "bb");
        let mut shelf = ShelfManager::new(100);
        let staged = shelf.stage_files(&[a.clone(), b.clone()]).unwrap();
        assert_eq!(staged.len(), 2);
        assert_eq!(staged[0].group_id, staged[1].group_id);
        assert_eq!(shelf.get_items()[0].original_path, a);
        assert_eq!(shelf.get_items()[1].kind, "image");
    }

    #[test]
    fn restaging_moves_item_to_new_group() {
        let dir = temp_dir("restage");
        let a = touch(&dir, "a.txt", "a");
        let b = touch(&dir, "b.txt", "b");
        let mut shelf = ShelfManager::new(100);
        shelf.stage_files(&[a.clone(), b.clone()]).unwrap();
        let again = shelf.stage_file(&a).unwrap();
        assert_eq!(shelf.get_items().len(), 2);
        assert_eq!(shelf.get_items()[0].id, again.id);
        assert_ne!(shelf.get_items()[0].group_id, shelf.get_items()[1].group_id);
    }

    #[test]
    fn preserves_percent_and_unicode_names() {
        let dir = temp_dir("names");
        let p = touch(&dir, "100% café.txt", "x");
        let mut shelf = ShelfManager::new(100);
        let item = shelf.stage_file(&p).unwrap();
        assert_eq!(item.filename, "100% café.txt");
    }

    #[test]
    fn persists_and_prunes() {
        let storage = temp_dir("storage");
        let files = temp_dir("files");
        let keep = touch(&files, "keep.txt", "k");
        let gone = touch(&files, "gone.txt", "g");
        {
            let mut shelf = ShelfManager::with_storage(100, &storage);
            shelf.stage_files(&[keep.clone(), gone.clone()]).unwrap();
        }
        fs::remove_file(&gone).unwrap();
        let shelf = ShelfManager::with_storage(100, &storage);
        assert_eq!(shelf.get_items().len(), 1);
        assert_eq!(shelf.get_items()[0].original_path, keep);
    }

    #[test]
    fn owned_inbox_files_are_deleted_on_remove() {
        let storage = temp_dir("owned");
        let mut shelf = ShelfManager::with_storage(100, &storage);
        let drop_dir = shelf.inbox_dir().unwrap().join("drop1");
        fs::create_dir_all(&drop_dir).unwrap();
        let snippet = touch(&drop_dir, "snippet.txt", "hello");
        let item = shelf.stage_file(&snippet).unwrap();
        assert!(item.owned);
        assert!(shelf.remove_item(&item.id, true));
        assert!(!Path::new(&snippet).exists());
        assert!(!drop_dir.exists());
    }

    #[test]
    fn user_files_are_never_deleted() {
        let storage = temp_dir("safe");
        let files = temp_dir("userfiles");
        let p = touch(&files, "important.txt", "x");
        let mut shelf = ShelfManager::with_storage(100, &storage);
        shelf.stage_file(&p).unwrap();
        shelf.clear_all();
        assert!(Path::new(&p).exists());
    }

    #[test]
    fn ungroup_splits_stack() {
        let dir = temp_dir("ungroup");
        let a = touch(&dir, "a.txt", "a");
        let b = touch(&dir, "b.txt", "b");
        let mut shelf = ShelfManager::new(100);
        let staged = shelf.stage_files(&[a, b]).unwrap();
        assert!(shelf.ungroup(&staged[0].group_id));
        let items = shelf.get_items();
        assert_ne!(items[0].group_id, items[1].group_id);
    }

    #[test]
    fn expires_old_items_and_their_inbox_files() {
        let storage = temp_dir("expire");
        let files = temp_dir("expire-user");
        let mut shelf = ShelfManager::with_storage(100, &storage);
        let drop_dir = shelf.inbox_dir().unwrap().join("old-drop");
        fs::create_dir_all(&drop_dir).unwrap();
        let old_snippet = touch(&drop_dir, "old.txt", "o");
        let old_user = touch(&files, "old-user.txt", "u");
        let fresh = touch(&files, "fresh.txt", "f");
        shelf.stage_files(&[old_snippet.clone(), old_user.clone()]).unwrap();
        shelf.stage_file(&fresh).unwrap();

        let now = now_secs();
        let twelve_hours = 12 * 3600;
        // Age the first stack by 13 hours.
        for item in shelf.items.iter_mut().filter(|i| i.original_path != fresh) {
            item.staged_at = now - 13 * 3600;
        }
        assert_eq!(shelf.next_expiry(twelve_hours), Some(now - 3600));

        assert_eq!(shelf.expire_older_than(twelve_hours, now), 2);
        assert_eq!(shelf.get_items().len(), 1);
        assert_eq!(shelf.get_items()[0].original_path, fresh);
        assert!(!Path::new(&old_snippet).exists(), "owned inbox file is deleted");
        assert!(Path::new(&old_user).exists(), "user file is never deleted");
        assert_eq!(shelf.expire_older_than(twelve_hours, now), 0);
    }

    #[test]
    fn evicts_oldest_beyond_capacity() {
        let dir = temp_dir("evict");
        let mut shelf = ShelfManager::new(2);
        for n in 0..3 {
            let p = touch(&dir, &format!("{}.txt", n), "x");
            shelf.stage_file(&p).unwrap();
        }
        assert_eq!(shelf.get_items().len(), 2);
        assert!(shelf.get_items()[1].filename.starts_with('1'));
    }
}

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StagedItem {
    pub id: String,
    /// Items dropped together share a group and render as a single stack.
    pub group_id: String,
    pub original_path: String,
    pub filename: String,
    pub size_bytes: u64,
    pub staged_at: u64,
    /// The file lives in NotchCove's inbox and is deleted when removed from the shelf.
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

    /// Restores items from `storage_dir/shelf.json`, dropping any whose files are gone.
    pub fn with_storage(max_items: usize, storage_dir: &Path) -> Self {
        let _ = fs::create_dir_all(storage_dir.join("Inbox"));
        let mut shelf = Self {
            storage_dir: Some(storage_dir.to_path_buf()),
            ..Self::new(max_items)
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
        if let Ok(json) = serde_json::to_vec(&self.items) {
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

    #[cfg(test)]
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
        let mut seen = HashSet::new();

        for raw in paths {
            let clean = raw.trim();
            let clean = clean.strip_prefix("file://").unwrap_or(clean);
            let path = Path::new(clean);
            if !path.exists() {
                eprintln!("[NotchCove Core] Skipping missing path: {}", clean);
                continue;
            }
            let path_string = path.to_string_lossy().to_string();
            if !seen.insert(path_string.clone()) {
                continue;
            }

            let metadata = path.metadata().map_err(|e| e.to_string())?;
            staged.push(StagedItem {
                id: format!("i{}_{}", now, next_id()),
                group_id: group_id.clone(),
                filename: path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| "Untitled".to_string()),
                size_bytes: if metadata.is_dir() { dir_size(path) } else { metadata.len() },
                staged_at: now,
                owned: self.is_in_inbox(path),
                original_path: path_string,
            });
        }

        if staged.is_empty() {
            return Err("No valid files to stage".to_string());
        }

        self.items.retain(|i| !seen.contains(&i.original_path));
        self.items.splice(0..0, staged.iter().cloned());
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
        }
        self.remove_empty_drop_folder(item);
    }

    /// Removes an owned item's per-drop folder once nothing is left in it but
    /// Finder's .DS_Store: after its file was deleted, moved out by a drag, or
    /// went missing. Other items from the same drop keep it.
    fn remove_empty_drop_folder(&self, item: &StagedItem) {
        let path = Path::new(&item.original_path);
        if !item.owned || !self.is_in_inbox(path) {
            return;
        }
        let Some(parent) = path.parent() else { return };
        if Some(parent.to_path_buf()) == self.inbox_dir() {
            return;
        }
        let Ok(entries) = fs::read_dir(parent) else { return };
        if entries.flatten().all(|e| e.file_name() == ".DS_Store") {
            let _ = fs::remove_file(parent.join(".DS_Store"));
            let _ = fs::remove_dir(parent);
        }
    }

    /// Removes items. Pass `delete_owned = false` when the files were moved
    /// elsewhere by a drag-out and must not be deleted.
    pub fn remove_items(&mut self, ids: &[String], delete_owned: bool) -> usize {
        let ids: HashSet<&str> = ids.iter().map(String::as_str).collect();
        self.remove_where(|i| ids.contains(i.id.as_str()), delete_owned)
    }

    /// Removes matching items and saves if anything changed. Returns the count removed.
    fn remove_where(&mut self, pred: impl Fn(&StagedItem) -> bool, delete_owned: bool) -> usize {
        let (removed, kept): (Vec<_>, Vec<_>) = self.items.drain(..).partition(|i| pred(i));
        self.items = kept;
        for item in &removed {
            if delete_owned {
                self.delete_if_owned(item);
            } else {
                self.remove_empty_drop_folder(item);
            }
        }
        if !removed.is_empty() {
            self.save();
        }
        removed.len()
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
        self.remove_where(|_| true, true);
    }

    /// Removes items staged more than `max_age_secs` before `now`.
    pub fn expire_older_than(&mut self, max_age_secs: u64, now: u64) -> usize {
        let cutoff = now.saturating_sub(max_age_secs);
        self.remove_where(|i| i.staged_at < cutoff, true)
    }

    /// Unix time at which the oldest item expires, if any.
    pub fn next_expiry(&self, max_age_secs: u64) -> Option<u64> {
        self.items.iter().map(|i| i.staged_at + max_age_secs).min()
    }

    /// Drops items whose files have been deleted or moved outside NotchCove.
    pub fn prune_missing(&mut self) -> usize {
        let (missing, kept): (Vec<_>, Vec<_>) =
            self.items.drain(..).partition(|i| !Path::new(&i.original_path).exists());
        self.items = kept;
        for item in &missing {
            self.remove_empty_drop_folder(item);
        }
        if !missing.is_empty() {
            self.save();
        }
        missing.len()
    }

    pub fn get_items(&self) -> &[StagedItem] {
        &self.items
    }
}

fn since_epoch() -> Duration {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default()
}

pub fn now_secs() -> u64 {
    since_epoch().as_secs()
}

fn next_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!("{:x}{:x}", COUNTER.fetch_add(1, Ordering::Relaxed), since_epoch().subsec_nanos())
}

/// Recursive size of a folder. Staging runs on the UI thread, so the walk is capped.
fn dir_size(path: &Path) -> u64 {
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
    walk(path, &mut 5_000)
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
        assert_eq!(shelf.get_items()[1].original_path, b);
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
        assert_eq!(shelf.remove_items(&[item.id], true), 1);
        assert!(!Path::new(&snippet).exists());
        assert!(!drop_dir.exists());
    }

    #[test]
    fn moved_out_inbox_files_leave_no_empty_folder() {
        let storage = temp_dir("moved");
        let mut shelf = ShelfManager::with_storage(100, &storage);
        let drop_dir = shelf.inbox_dir().unwrap().join("drop1");
        fs::create_dir_all(&drop_dir).unwrap();
        let snippet = touch(&drop_dir, "snippet.txt", "hello");
        let item = shelf.stage_file(&snippet).unwrap();
        // A drag moved the file out, and Finder left its .DS_Store behind.
        let elsewhere = temp_dir("moved-dest").join("snippet.txt");
        fs::rename(&snippet, &elsewhere).unwrap();
        touch(&drop_dir, ".DS_Store", "");
        assert_eq!(shelf.remove_items(&[item.id], false), 1);
        assert!(elsewhere.exists());
        assert!(!drop_dir.exists());
    }

    #[test]
    fn drop_folder_stays_while_other_items_use_it() {
        let storage = temp_dir("shared");
        let mut shelf = ShelfManager::with_storage(100, &storage);
        let drop_dir = shelf.inbox_dir().unwrap().join("drop1");
        fs::create_dir_all(&drop_dir).unwrap();
        let a = touch(&drop_dir, "a.txt", "a");
        let b = touch(&drop_dir, "b.txt", "b");
        let staged = shelf.stage_files(&[a.clone(), b.clone()]).unwrap();
        let a_id = staged.iter().find(|i| i.original_path == a).unwrap().id.clone();
        fs::remove_file(&a).unwrap();
        assert_eq!(shelf.remove_items(&[a_id], false), 1);
        assert!(Path::new(&b).exists());
        assert_eq!(shelf.prune_missing(), 0);
        fs::remove_file(&b).unwrap();
        assert_eq!(shelf.prune_missing(), 1);
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
